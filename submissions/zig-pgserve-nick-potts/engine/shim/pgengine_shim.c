/*
 * pgengine shim: the C side of the engine. See pgengine.h for why each piece is C. Module magic and
 * _PG_init, the untranslatable-macro wrappers Zig links against, the planner hook and CustomScan that
 * turn a marker statement into an engine call, the executor hooks that run it, and the session callbacks.
 */
#define _GNU_SOURCE 1 /* dladdr */
#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "access/genam.h"
#include "access/htup_details.h"
#include "access/itup.h"
#include "access/relation.h"
#include "catalog/namespace.h"
#include "catalog/pg_attribute.h"
#include "catalog/pg_index.h"
#include "nodes/makefuncs.h"
#include "storage/lockdefs.h"
#include "utils/elog.h"
#include "utils/palloc.h"
#include "utils/rel.h"
#include "catalog/pg_type.h"
#include "executor/executor.h"
#include "executor/tuptable.h"
#include "nodes/extensible.h"
#include "nodes/nodeFuncs.h"
#include "nodes/plannodes.h"
#include "optimizer/planner.h"
#include "access/stratnum.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/xact.h"
#include "storage/ipc.h"
#include "utils/builtins.h"
#include "utils/acl.h"
#include "utils/inval.h"
#include "utils/memutils.h"
#include "utils/snapmgr.h"
#include "utils/guc.h"
#include "postmaster/bgworker.h"
#include "tcop/tcopprot.h"
#include "mb/pg_wchar.h"

#include <malloc.h>
#include <dlfcn.h>

#include "pgengine.h"

PG_MODULE_MAGIC; /* (magic) marks this .so as a PG 18 module */

/* ---- untranslatable-macro wrappers (verified against translate-c on PG 18.6) ---- */

const char *
shim_text_ptr(uintptr_t datum, int32_t *len_out)
{
	struct varlena *v = (struct varlena *) DatumGetPointer(datum);
	*len_out = (int32_t) VARSIZE_ANY_EXHDR(v);
	return (const char *) VARDATA_ANY(v);
}

uintptr_t
shim_detoast(uintptr_t datum)
{
	return PointerGetDatum(pg_detoast_datum_packed((struct varlena *) DatumGetPointer(datum)));
}

void
shim_check_interrupts(void)
{
	CHECK_FOR_INTERRUPTS();
}

/* ---- catalog resolution for schema validation ---- */

uint32_t
shim_relid(const char *name)
{
	RangeVar   *rv = makeRangeVar("public", (char *) name, -1);

	return (uint32_t) RangeVarGetRelid(rv, AccessShareLock, true);
}

bool
shim_can_select(uint32_t oid)
{
	return pg_class_aclcheck((Oid) oid, GetUserId(), ACL_SELECT) == ACLCHECK_OK;
}

void *
shim_rel_open(uint32_t oid)
{
	return relation_open((Oid) oid, NoLock);
}

void
shim_rel_close(void *rel)
{
	relation_close((Relation) rel, NoLock);
}

int
shim_rel_natts(void *rel)
{
	return RelationGetDescr((Relation) rel)->natts;
}

void
shim_rel_attr(void *rel, int i, ShimAttr *out)
{
	Form_pg_attribute a = TupleDescAttr(RelationGetDescr((Relation) rel), i);

	out->attnum = a->attnum;
	out->typid = a->attisdropped ? InvalidOid : a->atttypid;
	out->collation = a->attcollation;
	out->notnull = a->attnotnull;
	strlcpy(out->name, NameStr(a->attname), sizeof(out->name));
}

void
shim_index_info(uint32_t idxoid, ShimIndexInfo *out)
{
	Relation	idx = index_open((Oid) idxoid, NoLock);
	Form_pg_index ix = idx->rd_index;
	int			n = ix->indnatts;

	memset(out, 0, sizeof(*out));
	out->indrelid = ix->indrelid;
	out->indnatts = n;
	for (int k = 0; k < n && k < 8; k++)
	{
		out->indkey[k] = ix->indkey.values[k];
		out->indoption[k] = idx->rd_indoption[k];
		out->opfamily[k] = idx->rd_opfamily[k];
	}
	out->collation0 = idx->rd_indcollation[0];
	out->relam = idx->rd_rel->relam;
	index_close(idx, NoLock);
}

/* ---- error + memory ---- */

void
shim_ereport_str(const char *msg)
{
	ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("pgengine: %s", msg)));
	pg_unreachable();
}

void
shim_log(const char *msg)
{
	ereport(LOG, (errmsg_internal("%s", msg)));
}

void
shim_ereport_schema(const char *reason)
{
	ereport(ERROR, (errcode(ERRCODE_INVALID_TABLE_DEFINITION),
					errmsg("pgengine: schema changed under a running session: %s", reason)));
	pg_unreachable();
}

void *shim_palloc(uint64_t size)   { return palloc((Size) size); }
void *shim_palloc0(uint64_t size)  { return palloc0((Size) size); }
void *shim_repalloc(void *p, uint64_t size) { return repalloc(p, (Size) size); }

/*
 * ---- marker recognition and the CustomScan (magic: plan/exec nodes come from makeNode) ----
 *
 * A marker is a SELECT with no FROM whose targets declare the output row and whose WHERE carries the
 * one parameter, every request of the batch packed into a bytea (decode_packed):
 *     SELECT NULL::int2 AS engine_article, NULL::bytea AS body
 *      WHERE current_setting('pgengine.required') IS NOT NULL AND $1::bytea IS NOT NULL
 * The targets fix the portal's result type (status int2, body bytea). The planner hook replaces the whole
 * plan with one CustomScan, which reads the parameter once, calls engine_exec for the whole batch, and
 * emits one row per request, in packed order, so the server demultiplexes by row position.
 * Without the engine loaded, standard planning keeps the current_setting qual, and execution fails with
 * "unrecognized configuration parameter": a marker can never be answered by plain SQL.
 */

static const char *const endpoint_names[EP_COUNT] = {
	"engine_article", "engine_list_all", "engine_list_tag", "engine_list_author",
	"engine_list_favorited", "engine_feed", "engine_comments", "engine_profile",
	"engine_user", "engine_tags", "engine_mega",
};
/* the type of each request field, per endpoint, in packed order (decode_packed); 0 ends the list. The
 * first is the viewer (for user, the user id; for tags, unread). */
static const Oid endpoint_fields[EP_COUNT][ENGINE_MAX_PARAMS + 1] = {
	[EP_ARTICLE] = {INT8OID, TEXTOID},
	[EP_LIST_ALL] = {INT8OID, INT8OID, INT8OID},
	[EP_LIST_TAG] = {INT8OID, INT8OID, INT8OID, TEXTOID},
	[EP_LIST_AUTHOR] = {INT8OID, INT8OID, INT8OID, TEXTOID},
	[EP_LIST_FAVORITED] = {INT8OID, INT8OID, INT8OID, TEXTOID},
	[EP_FEED] = {INT8OID, INT8OID, INT8OID},
	[EP_COMMENTS] = {INT8OID, TEXTOID},
	[EP_PROFILE] = {INT8OID, TEXTOID},
	[EP_USER] = {INT8OID, TEXTOID},
	[EP_TAGS] = {INT8OID},
	/* EP_MEGA: each request names its endpoint first (decode_mega) */
};

static planner_hook_type prev_planner_hook = NULL;

typedef struct EngineScanState
{
	CustomScanState css;
	ParamListInfo params;		/* the statement's bound parameters */
	EngineExec	x;
	int			next;			/* next ordinal to emit */
	bool		ran;
} EngineScanState;

static Node *engine_create_scan_state(CustomScan *cscan);

static CustomScanMethods engine_plan_methods = {
	.CustomName = "pgengine",
	.CreateCustomScanState = engine_create_scan_state,
};

static int
marker_endpoint(Query *parse)
{
	TargetEntry *first, *second;

	if (parse->commandType != CMD_SELECT || parse->rtable != NIL || list_length(parse->targetList) != 2 ||
		parse->jointree == NULL || parse->jointree->quals == NULL || parse->hasAggs ||
		parse->hasWindowFuncs || parse->hasSubLinks || parse->hasTargetSRFs ||
		parse->groupClause != NIL || parse->sortClause != NIL || parse->limitCount != NULL ||
		parse->limitOffset != NULL || parse->cteList != NIL || parse->setOperations != NULL)
		return -1;
	first = (TargetEntry *) linitial(parse->targetList);
	if (first->resname == NULL || strncmp(first->resname, "engine_", 7) != 0)
		return -1;
	second = (TargetEntry *) lsecond(parse->targetList);
	if (exprType((Node *) first->expr) != INT2OID || exprType((Node *) second->expr) != BYTEAOID)
		ereport(ERROR, (errcode(ERRCODE_SYNTAX_ERROR),
						errmsg("pgengine: marker %s must select (int2, bytea)", first->resname)));
	for (int e = 0; e < EP_COUNT; e++)
		if (strcmp(first->resname, endpoint_names[e]) == 0)
			return e;
	ereport(ERROR, (errcode(ERRCODE_UNDEFINED_FUNCTION),
					errmsg("pgengine: unknown marker \"%s\"", first->resname)));
	return -1;
}

/* The marker's one parameter, $1 bytea, from its WHERE clause; any other parameter is an error. */
static bool
find_param(Node *node, Param **out)
{
	if (node == NULL)
		return false;
	if (IsA(node, Param))
	{
		Param	   *p = (Param *) node;

		if (p->paramkind != PARAM_EXTERN || p->paramid != 1 || p->paramtype != BYTEAOID)
			ereport(ERROR, (errcode(ERRCODE_SYNTAX_ERROR),
							errmsg("pgengine: a marker takes one parameter, $1 bytea")));
		*out = p;
		return false;
	}
	return expression_tree_walker(node, find_param, out);
}

static PlannedStmt *
engine_plan(Query *parse, int ep)
{
	CustomScan *cs = makeNode(CustomScan);
	Plan	   *plan = &cs->scan.plan;
	PlannedStmt *result = makeNode(PlannedStmt);
	Param	   *param = NULL;

	find_param(parse->jointree->quals, &param);
	if (param == NULL)
		ereport(ERROR, (errcode(ERRCODE_SYNTAX_ERROR),
						errmsg("pgengine: %s takes one parameter, $1 bytea", endpoint_names[ep])));

	plan->startup_cost = 0;
	plan->total_cost = 1;
	plan->plan_rows = 1;
	plan->plan_width = 1024;
	plan->targetlist = list_make2(
		makeTargetEntry((Expr *) makeVar(INDEX_VAR, 1, INT2OID, -1, InvalidOid, 0), 1, "status", false),
		makeTargetEntry((Expr *) makeVar(INDEX_VAR, 2, BYTEAOID, -1, InvalidOid, 0), 2, "body", false));
	cs->scan.scanrelid = 0;
	cs->custom_exprs = list_make1(copyObject(param));
	cs->custom_scan_tlist = list_make2(
		makeTargetEntry((Expr *) makeNullConst(INT2OID, -1, InvalidOid), 1, "status", false),
		makeTargetEntry((Expr *) makeNullConst(BYTEAOID, -1, InvalidOid), 2, "body", false));
	cs->methods = &engine_plan_methods;
	cs->custom_private = list_make1_int(ep);

	result->commandType = CMD_SELECT;
	result->queryId = parse->queryId;
	result->canSetTag = parse->canSetTag;
	result->planTree = plan;
	result->stmt_location = parse->stmt_location;
	result->stmt_len = parse->stmt_len;
	return result;
}

static PlannedStmt *
engine_planner(Query *parse, const char *query_string, int cursorOptions, ParamListInfo boundParams)
{
	int			ep = marker_endpoint(parse);

	if (ep >= 0)
		return engine_plan(parse, ep);
	if (prev_planner_hook)
		return prev_planner_hook(parse, query_string, cursorOptions, boundParams);
	return standard_planner(parse, query_string, cursorOptions, boundParams);
}

static void engine_begin(CustomScanState *node, EState *estate, int eflags);
static TupleTableSlot *engine_exec_node(CustomScanState *node);
static void engine_end(CustomScanState *node);
static void engine_rescan(CustomScanState *node);

static CustomExecMethods engine_exec_methods = {
	.CustomName = "pgengine",
	.BeginCustomScan = engine_begin,
	.ExecCustomScan = engine_exec_node,
	.EndCustomScan = engine_end,
	.ReScanCustomScan = engine_rescan,
};

static Node *
engine_create_scan_state(CustomScan *cscan)
{
	EngineScanState *st = (EngineScanState *) newNode(sizeof(EngineScanState), T_CustomScanState);

	st->css.methods = &engine_exec_methods;
	return (Node *) st;
}

static void
engine_begin(CustomScanState *node, EState *estate, int eflags)
{
	EngineScanState *st = (EngineScanState *) node;
	CustomScan *cs = (CustomScan *) node->ss.ps.plan;

	st->params = estate->es_param_list_info;
	st->x.endpoint = linitial_int(cs->custom_private);
	st->x.snapshot = estate->es_snapshot;
	st->ran = false;
	st->next = 0;
}

/*
 * ExecEvalParamExtern's lookup of an extern parameter, without building an ExprState per parameter in every
 * execution. The marker's parameter is PARAM_EXTERN (find_param).
 */
static Datum
extern_param(ParamListInfo pl, Param *param, bool *isnull)
{
	ParamExternData *prm;
	ParamExternData prmdata;

	if (pl == NULL || param->paramid < 1 || param->paramid > pl->numParams)
		ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT),
						errmsg("no value found for parameter %d", param->paramid)));
	prm = pl->paramFetch ? pl->paramFetch(pl, param->paramid, false, &prmdata) : &pl->params[param->paramid - 1];
	if (!OidIsValid(prm->ptype))
		ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT),
						errmsg("no value found for parameter %d", param->paramid)));
	if (prm->ptype != param->paramtype)
		ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH),
						errmsg("type of parameter %d (%s) does not match that when preparing the plan (%s)",
							   param->paramid, format_type_be(prm->ptype), format_type_be(param->paramtype))));
	*isnull = prm->isnull;
	return prm->value;
}

/* x's field arrays for n requests of its endpoint. */
static void
request_arrays(EngineExec *x, uint32 n)
{
	const Oid  *fields = endpoint_fields[x->endpoint];
	int			nf = 0;

	while (nf < ENGINE_MAX_PARAMS && fields[nf] != InvalidOid)
		nf++;
	x->nreq = (int) n;
	x->nparams = nf;
	for (int k = 0; k < nf; k++)
		if (fields[k] == INT8OID)
			x->params[k].values = palloc(sizeof(Datum) * Max(n, 1));
		else
			x->params[k].texts = palloc(sizeof(EngineText) * Max(n, 1));
}

/* Request i's fields from *p into x's arrays; false if malformed. */
static bool
decode_request(EngineExec *x, int i, const char **pp, const char *end)
{
	const char *p = *pp;
	const Oid  *fields = endpoint_fields[x->endpoint];

	for (int k = 0; k < ENGINE_MAX_PARAMS && fields[k] != InvalidOid; k++)
	{
		if (fields[k] == INT8OID)
		{
			int64		v;

			if (end - p < 8)
				return false;
			memcpy(&v, p, 8);
			p += 8;
			x->params[k].values[i] = Int64GetDatum(v);
		}
		else
		{
			uint32		len;

			if (end - p < 4)
				return false;
			memcpy(&len, p, 4);
			p += 4;
			if (len > (uint32) (end - p))
				return false;
			pg_verifymbstr(p, (int) len, false);	/* as text_recv: valid in the server encoding, no NUL */
			x->params[k].texts[i] = (EngineText) {p, len};
			p += len;
		}
	}
	*pp = p;
	return true;
}

/* Steps *p over one request of x's endpoint, checking only its lengths; false if malformed. */
static bool
skip_request(EngineExec *x, const char **pp, const char *end)
{
	const char *p = *pp;
	const Oid  *fields = endpoint_fields[x->endpoint];

	for (int k = 0; k < ENGINE_MAX_PARAMS && fields[k] != InvalidOid; k++)
	{
		uint32		len = 8;

		if (fields[k] != INT8OID)
		{
			if (end - p < 4)
				return false;
			memcpy(&len, p, 4);
			p += 4;
		}
		if (len > (uint32) (end - p))
			return false;
		p += len;
	}
	*pp = p;
	return true;
}

/*
 * engine_mega's n requests from p: each a u8 endpoint (any but EP_MEGA), then that endpoint's fields. Split
 * into x->subs, one sub-batch per endpoint holding its requests in input order, with x->kind and x->pos saying
 * where each request went. A first pass counts each endpoint's requests (stepping over their fields), the
 * second reads them.
 */
static bool
decode_mega(EngineExec *x, const char *p, const char *end, uint32 n)
{
	uint32		count[EP_MEGA] = {0};
	EngineExec	probe = {0};
	const char *q = p;

	x->subs = palloc0(sizeof(EngineExec) * EP_MEGA);
	for (int e = 0; e < EP_MEGA; e++)
		x->subs[e].endpoint = e;
	for (uint32 i = 0; i < n; i++)
	{
		if (end - q < 1 || (uint8) *q >= EP_MEGA)
			return false;
		probe.endpoint = (uint8) *q++;
		count[probe.endpoint]++;
		if (!skip_request(&probe, &q, end))
			return false;
	}
	if (q != end)
		return false;
	for (int e = 0; e < EP_MEGA; e++)
	{
		request_arrays(&x->subs[e], count[e]);
		x->subs[e].nreq = 0;
		x->subs[e].out = palloc0(sizeof(EngineOut) * Max(count[e], 1));
	}
	x->nreq = (int) n;
	x->kind = palloc(sizeof(int) * Max(n, 1));
	x->pos = palloc(sizeof(int) * Max(n, 1));
	for (uint32 i = 0; i < n; i++)
	{
		EngineExec *sub = &x->subs[(uint8) *p++];

		x->kind[i] = sub->endpoint;
		x->pos[i] = sub->nreq;
		if (!decode_request(sub, sub->nreq++, &p, end))
			return false;
	}
	return true;
}

/*
 * The marker's parameter: every request's fields in one bytea, little-endian, the fields in endpoint_fields
 * order: u32 n, then per request each field, an int8 as 8 bytes, a text as a u32 byte length and the bytes.
 * Read into one array per field, a text as its place in the parameter, checked as text_recv checks it. One
 * bytea binds with a copy, where an array per field cost array_recv and a type lookup per field per bind.
 * engine_mega's parameter is the same but for a u8 endpoint before each request's fields (decode_mega).
 */
static void
decode_packed(EngineExec *x, Datum d)
{
	bytea	   *b = DatumGetByteaPP(d);
	const char *p = VARDATA_ANY(b), *end = p + VARSIZE_ANY_EXHDR(b);
	uint32		n;

	if (end - p < 4)
		goto malformed;
	memcpy(&n, p, 4);
	p += 4;
	if (n > (uint32) (end - p) / 8)	/* every request starts with an int8, the viewer */
		goto malformed;
	if (x->endpoint == EP_MEGA)
	{
		if (!decode_mega(x, p, end, n))
			goto malformed;
		return;
	}
	request_arrays(x, n);
	for (uint32 i = 0; i < n; i++)
		if (!decode_request(x, (int) i, &p, end))
			goto malformed;
	if (p != end)
		goto malformed;
	return;
malformed:
	ereport(ERROR, (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
					errmsg("pgengine: %s packed parameter is malformed", endpoint_names[x->endpoint])));
}

/* Reads the marker's parameter into x and runs the engine over the batch it holds. */
static void
run_engine(EngineExec *x, CustomScan *cs, ParamListInfo params)
{
	bool		isnull;
	Datum		d = extern_param(params, linitial_node(Param, cs->custom_exprs), &isnull);

	if (isnull)
		ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
						errmsg("pgengine: %s parameter is NULL", endpoint_names[x->endpoint])));
	decode_packed(x, d);
	x->out = palloc0(sizeof(EngineOut) * Max(x->nreq, 1));
	engine_exec(x);
}

static void
run_batch(EngineScanState *st)
{
	run_engine(&st->x, (CustomScan *) st->css.ss.ps.plan, st->params);
	st->ran = true;
}

/* Output row o into slot, a (status int2, body bytea) slot; NOT_FOUND rows have a NULL body. */
static TupleTableSlot *
store_out(TupleTableSlot *slot, EngineOut *o)
{
	ExecClearTuple(slot);
	slot->tts_values[0] = Int16GetDatum(o->status);
	slot->tts_isnull[0] = false;
	slot->tts_values[1] = o->body;
	slot->tts_isnull[1] = (o->status != ST_OK);
	return ExecStoreVirtualTuple(slot);
}

static TupleTableSlot *
engine_exec_node(CustomScanState *node)
{
	EngineScanState *st = (EngineScanState *) node;
	TupleTableSlot *slot = node->ss.ss_ScanTupleSlot;
	EngineOut  *o;

	if (!st->ran)
		run_batch(st);
	if (st->next >= st->x.nreq)
		return ExecClearTuple(slot);
	o = &st->x.out[st->next++];
	return store_out(slot, o);
}

static void
engine_end(CustomScanState *node)
{
}

static void
engine_rescan(CustomScanState *node)
{
	EngineScanState *st = (EngineScanState *) node;

	st->ran = false;
	st->next = 0;
}

/*
 * ---- executor bypass ----
 *
 * A marker plan is one CustomScan with nothing above it, so for a small batch the executor's own setup
 * and teardown cost more than the work: an executor state and an expression context (two memory
 * contexts), tuple descriptors built from both target lists (a syscache lookup per column), two slots,
 * and freeing it all. The executor hooks run a marker without any of it. ExecutorStart registers the
 * snapshot and hands the portal the result descriptor, built once per backend. ExecutorRun runs the
 * batch and sends each row straight to the DestReceiver, `count` at a time. ExecutorEnd unregisters the
 * snapshot and frees the batch's memory. The batch runs in a context of its own with the executor's
 * default sizes: the portal's context is a small one, where every response body would be a malloc of
 * its own. The portal and SPI read only es_processed of the executor state. EXPLAIN, instrumentation
 * and scrollable cursors keep the CustomScan path.
 */
typedef struct EngineQuery
{
	EState		estate;			/* es_processed, as the executor sets it */
	EngineExec	x;
	int			next;			/* the next output row to send */
	bool		ran;
} EngineQuery;

static ExecutorStart_hook_type prev_executor_start;
static ExecutorRun_hook_type prev_executor_run;
static ExecutorFinish_hook_type prev_executor_finish;
static ExecutorEnd_hook_type prev_executor_end;
static TupleDesc engine_tupdesc;	/* ExecTypeFromTL of a marker plan's target list */
static TupleTableSlot *engine_out_slot;

#define BYPASS_REFUSES (EXEC_FLAG_EXPLAIN_ONLY | EXEC_FLAG_EXPLAIN_GENERIC | EXEC_FLAG_REWIND | \
						EXEC_FLAG_BACKWARD | EXEC_FLAG_MARK | EXEC_FLAG_WITH_NO_DATA)

static bool
is_marker_plan(QueryDesc *qd)
{
	Plan	   *p = qd->plannedstmt->planTree;

	return p != NULL && IsA(p, CustomScan) && ((CustomScan *) p)->methods == &engine_plan_methods;
}

/* Started by the bypass: the standard path always leaves a plan state. */
static bool
bypassed(QueryDesc *qd)
{
	return qd->planstate == NULL && is_marker_plan(qd);
}

static void
engine_executor_start(QueryDesc *qd, int eflags)
{
	EngineQuery *q;

	if (!is_marker_plan(qd) || (eflags & BYPASS_REFUSES) || qd->instrument_options != 0)
	{
		if (prev_executor_start)
			prev_executor_start(qd, eflags);
		else
			standard_ExecutorStart(qd, eflags);
		return;
	}
	if (engine_tupdesc == NULL)
	{
		MemoryContext old = MemoryContextSwitchTo(TopMemoryContext);
		TupleDesc	d = ExecTypeFromTL(qd->plannedstmt->planTree->targetlist);

		engine_out_slot = MakeSingleTupleTableSlot(d, &TTSOpsVirtual);
		engine_tupdesc = d;
		MemoryContextSwitchTo(old);
	}
	q = palloc0(sizeof(EngineQuery));
	q->estate.type = T_EState;
	q->estate.es_query_cxt = AllocSetContextCreate(CurrentMemoryContext, "pgengine", ALLOCSET_DEFAULT_SIZES);
	q->estate.es_snapshot = RegisterSnapshot(qd->snapshot);
	q->estate.es_param_list_info = qd->params;
	q->estate.es_top_eflags = eflags;
	q->x.endpoint = linitial_int(((CustomScan *) qd->plannedstmt->planTree)->custom_private);
	q->x.snapshot = q->estate.es_snapshot;
	qd->estate = &q->estate;
	qd->tupDesc = engine_tupdesc;
}

static void
engine_executor_run(QueryDesc *qd, ScanDirection direction, uint64 count)
{
	EngineQuery *q = (EngineQuery *) qd->estate;
	DestReceiver *dest = qd->dest;
	uint64		sent = 0;

	if (!bypassed(qd))
	{
		if (prev_executor_run)
			prev_executor_run(qd, direction, count);
		else
			standard_ExecutorRun(qd, direction, count);
		return;
	}
	if (!q->ran)
	{
		MemoryContext old = MemoryContextSwitchTo(q->estate.es_query_cxt);

		run_engine(&q->x, (CustomScan *) qd->plannedstmt->planTree, qd->params);
		MemoryContextSwitchTo(old);
		q->ran = true;
	}
	dest->rStartup(dest, CMD_SELECT, qd->tupDesc);
	while (ScanDirectionIsForward(direction) && q->next < q->x.nreq && (count == 0 || sent < count))
	{
		if (!dest->receiveSlot(store_out(engine_out_slot, &q->x.out[q->next++]), dest))
			break;
		sent++;
	}
	ExecClearTuple(engine_out_slot);
	dest->rShutdown(dest);
	q->estate.es_processed = sent;
}

static void
engine_executor_finish(QueryDesc *qd)
{
	if (bypassed(qd))
		return;
	if (prev_executor_finish)
		prev_executor_finish(qd);
	else
		standard_ExecutorFinish(qd);
}

static void
engine_executor_end(QueryDesc *qd)
{
	if (bypassed(qd))
	{
		UnregisterSnapshot(qd->estate->es_snapshot);
		MemoryContextDelete(qd->estate->es_query_cxt);
		qd->estate = NULL;
		qd->tupDesc = NULL;
		return;
	}
	if (prev_executor_end)
		prev_executor_end(qd);
	else
		standard_ExecutorEnd(qd);
}

/* ---- relation handles, opened once per execution under the engine's session locks (engine.zig) ---- */

void *
shim_table_open(uint32_t oid)
{
	return table_open((Oid) oid, NoLock);
}

void *
shim_index_open(uint32_t oid)
{
	return index_open((Oid) oid, NoLock);
}

void
shim_close(void *rel, bool is_index)
{
	if (is_index)
		index_close((Relation) rel, NoLock);
	else
		table_close((Relation) rel, NoLock);
}

/* A bytea of exactly len bytes from buf, in the current memory context. */
uintptr_t
shim_bytea(const char *buf, int32_t len)
{
	bytea	   *b = (bytea *) palloc(VARHDRSZ + len);

	SET_VARSIZE(b, VARHDRSZ + len);
	memcpy(VARDATA(b), buf, len);
	return PointerGetDatum(b);
}

static void
engine_relcache_cb(Datum arg, Oid relid)
{
	engine_relcache_inval((uint32_t) relid);
}

/* Abort releases session locks along with the transaction's (ProcReleaseLocks). */
static void
engine_xact_cb(XactEvent event, void *arg)
{
	if (event == XACT_EVENT_ABORT || event == XACT_EVENT_PARALLEL_ABORT)
		engine_session_locks_released();
}

/* Backend exit releases no session locks of the default lock method by itself. */
static void
engine_exit_cb(int code, Datum arg)
{
	engine_session_unlock();
}

/* ---- module load ---- */

/*
 * ---- HTTP from background workers (research; default off) ----
 *
 * pgengine.http = '<launcher socket path>:<workers>', set by one connection (its startup packet), starts that many dynamic
 * background workers. Each joins this database as this role, collects a listening socket and the JWT
 * secret from pgserve's launcher, and serves HTTP on it (engine_http_serve): no app process and no wire protocol between the request and the
 * engine. RegisterDynamicBackgroundWorker asks no privilege; the workers come out of max_worker_processes.
 * A worker that hits an ERROR exits and is not restarted.
 */
static char *http_setting = NULL;

PGDLLEXPORT void pgengine_http_main(Datum arg);

static void
start_http_workers(void)
{
	const char *colon = strrchr(http_setting, ':');
	int			n = colon != NULL ? atoi(colon + 1) : 0;
	size_t		plen = colon != NULL ? (size_t) (colon - http_setting) : 0;
	Dl_info		self;
	BackgroundWorker w = {0};
	Oid			ids[2] = {MyDatabaseId, GetUserId()};

	if (plen == 0 || plen >= BGW_EXTRALEN - sizeof(ids) || http_setting[0] != '/' || n <= 0 || n > 64)
		ereport(ERROR, (errmsg("pgengine.http must be '<launcher socket path>:<workers>', not \"%s\"", http_setting)));
	if (dladdr((void *) start_http_workers, &self) == 0 || self.dli_fname == NULL)
		ereport(ERROR, (errmsg("pgengine.http: cannot find the engine's own library path")));
	w.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	w.bgw_start_time = BgWorkerStart_RecoveryFinished;
	w.bgw_restart_time = BGW_NEVER_RESTART;
	strlcpy(w.bgw_library_name, self.dli_fname, sizeof(w.bgw_library_name));
	strlcpy(w.bgw_function_name, "pgengine_http_main", sizeof(w.bgw_function_name));
	strlcpy(w.bgw_name, "pgengine http", sizeof(w.bgw_name));
	strlcpy(w.bgw_type, "pgengine http", sizeof(w.bgw_type));
	/* bgw_extra: the database and role, then the launcher's socket path, NUL-terminated */
	memcpy(w.bgw_extra, ids, sizeof(ids));
	memcpy(w.bgw_extra + sizeof(ids), http_setting, plen);
	for (int i = 0; i < n; i++)
		if (!RegisterDynamicBackgroundWorker(&w, NULL))
			ereport(ERROR, (errmsg("pgengine.http: no background worker slot for worker %d of %d", i + 1, n)));
	ereport(LOG, (errmsg("pgengine.http: %d workers, launcher at %.*s", n, (int) plen, http_setting)));
}

void
pgengine_http_main(Datum arg)
{
	Oid			ids[2];
	const char *reason;

	memcpy(ids, MyBgworkerEntry->bgw_extra, sizeof(ids));
	pqsignal(SIGTERM, die);
	BackgroundWorkerUnblockSignals();
	BackgroundWorkerInitializeConnectionByOid(ids[0], ids[1], 0);
	StartTransactionCommand();
	reason = engine_validate_schema();
	if (reason != NULL)
		ereport(ERROR, (errcode(ERRCODE_INVALID_TABLE_DEFINITION), errmsg("pgengine http refuses to start: %s", reason)));
	CommitTransactionCommand();
	engine_http_serve(MyBgworkerEntry->bgw_extra + sizeof(ids));
}

bool
shim_http_exec(EngineExec *x)
{
	MemoryContext cxt = CurrentMemoryContext;
	bool		ok = true;

	PG_TRY();
	{
		engine_exec(x);
	}
	PG_CATCH();
	{
		ErrorData  *e;

		MemoryContextSwitchTo(cxt);
		e = CopyErrorData();
		FlushErrorState();
		ereport(LOG, (errmsg("pgengine http: read batch %d failed: %s", x->endpoint, e->message)));
		FreeErrorData(e);
		AbortCurrentTransaction();
		ok = false;
	}
	PG_END_TRY();
	return ok;
}

void *
shim_http_begin(void)
{
	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());
	return GetActiveSnapshot();
}

void
shim_http_end(void)
{
	PopActiveSnapshot();
	CommitTransactionCommand();
}

void _PG_init(void);
void
_PG_init(void)
{
	/* a background worker has no database yet; pgengine_http_main validates once it joins one */
	const char *reason = AmBackgroundWorkerProcess() ? NULL : engine_validate_schema();

	if (reason != NULL)
		ereport(ERROR, (errcode(ERRCODE_INVALID_TABLE_DEFINITION),
						errmsg("pgengine refuses to load: %s", reason)));
	/*
	 * A large batch allocates several MB (response bodies, walk buffers; an engine_mega drain of 1,300
	 * requests about 6 MB, in AllocSet blocks of up to 8 MB) and frees it all at the end. Past glibc's
	 * default 128 KB trim threshold that memory goes back to the kernel with brk, and the next execution
	 * faults it in again page by page; a block past the mmap threshold is unmapped on free, with the same
	 * effect. Keep it in the backend: blocks up to glibc's largest mmap threshold (32 MB) come from the
	 * heap, and up to 64 MB of free heap stays. Setting the trim threshold freezes glibc's dynamic mmap
	 * threshold, so that one is set too.
	 */
	mallopt(M_MMAP_THRESHOLD, 32 << 20);
	mallopt(M_TRIM_THRESHOLD, 64 << 20);
	CacheRegisterRelcacheCallback(engine_relcache_cb, (Datum) 0);
	RegisterXactCallback(engine_xact_cb, NULL);
	before_shmem_exit(engine_exit_cb, (Datum) 0);
	RegisterCustomScanMethods(&engine_plan_methods);
	prev_planner_hook = planner_hook;
	planner_hook = engine_planner;
	prev_executor_start = ExecutorStart_hook;
	ExecutorStart_hook = engine_executor_start;
	prev_executor_run = ExecutorRun_hook;
	ExecutorRun_hook = engine_executor_run;
	prev_executor_finish = ExecutorFinish_hook;
	ExecutorFinish_hook = engine_executor_finish;
	prev_executor_end = ExecutorEnd_hook;
	ExecutorEnd_hook = engine_executor_end;
	DefineCustomStringVariable("pgengine.http", "Launcher socket and worker count for the engine's own HTTP workers (pgserve).",
							   NULL, &http_setting, "", PGC_USERSET, 0, NULL, NULL, NULL);
	if (!AmBackgroundWorkerProcess())
		ereport(LOG, (errmsg("pgengine %s loaded (pid %d, superuser=%d)",
							 engine_version(), MyProcPid, superuser() ? 1 : 0)));
	if (!AmBackgroundWorkerProcess() && http_setting != NULL && http_setting[0] != '\0')
		start_http_workers();
}
