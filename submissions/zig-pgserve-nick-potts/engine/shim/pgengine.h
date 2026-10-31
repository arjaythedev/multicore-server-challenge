/*
 * pgengine shim: the C ABI boundary between Postgres and the Zig engine.
 *
 * Everything in the shim is C for one of three reasons, noted at each declaration:
 *   (magic)   a Postgres macro expands to a definition that only the C preprocessor can emit
 *             (PG_MODULE_MAGIC, the node-tag machinery).
 *   (longjmp) Postgres reports errors with setjmp/longjmp (ereport); the trampoline that catches
 *             them must be a C frame, because a longjmp through Zig frames skips their defers.
 *   (untranslatable) a macro that Zig's translate-c cannot render (varlena flexible-array access,
 *             CHECK_FOR_INTERRUPTS). Verified on PG 18.6 headers.
 *
 * Extern Postgres functions that translate-c renders correctly (heap_hot_search_buffer,
 * ReadRecentBuffer, getmissingattr, varstr_cmp, ...) are called from Zig directly (build.sh translates pg_imports.h);
 * they are NOT wrapped here.
 */
#ifndef PGENGINE_H
#define PGENGINE_H

#include <stdint.h>
#include <stdbool.h>

/* endpoint ids: must match the order of endpoints in engine.zig and the marker resname suffix (engine_<name>). EP_MEGA takes
 * requests of every other endpoint in one batch. */
enum { EP_ARTICLE = 0, EP_LIST_ALL, EP_LIST_TAG, EP_LIST_AUTHOR, EP_LIST_FAVORITED,
       EP_FEED, EP_COMMENTS, EP_PROFILE, EP_USER, EP_TAGS, EP_MEGA, EP_COUNT };

/* response status per request ordinal; the server maps (endpoint,status) to an HTTP status. */
enum { ST_OK = 0, ST_NOT_FOUND = 1 };

#define ENGINE_MAX_PARAMS 4

/* A text field's bytes, inside the marker's packed parameter (valid for the execution). */
typedef struct EngineText {
	const char *ptr;
	uint32_t	len;
} EngineText;

/* One request field across the batch, read out of the packed parameter by the shim, one entry per
 * request: values for an int8 field (the int64 bit pattern), texts for a text field. */
typedef struct EngineParam {
	uintptr_t  *values;
	EngineText *texts;
} EngineParam;

/* One finished response: a bytea varlena the shim stores in the output slot, or status NOT_FOUND. */
typedef struct EngineOut {
	int16_t		status;
	uintptr_t	body;   /* bytea Datum, valid when status == ST_OK */
} EngineOut;

/* Everything one batch execution needs. Built by the shim's run_engine, read by engine_exec. */
typedef struct EngineExec {
	int			endpoint;
	int			nreq;              /* requests in the batch; one output row per ordinal, in input order */
	int			nparams;
	void	   *snapshot;          /* es_snapshot: MVCC for every read in this batch */
	EngineParam	params[ENGINE_MAX_PARAMS];
	EngineOut  *out;               /* [nreq], filled by Zig */
	/* EP_MEGA: the batch split by endpoint, subs[e] holding endpoint e's requests in input order (nreq 0 when
	 * there are none); request i is subs[kind[i]]'s request pos[i]. */
	struct EngineExec *subs;       /* [EP_MEGA] */
	int		   *kind;              /* [nreq] */
	int		   *pos;               /* [nreq] */
} EngineExec;

/* ---- called by Zig, implemented in C (untranslatable macros) ---- */

/* varlena access: VARDATA_ANY / VARSIZE_ANY_EXHDR over a (possibly short-header) datum. */
const char *shim_text_ptr(uintptr_t datum, int32_t *len_out); /* (untranslatable) */
/* pg_detoast_datum_packed, returning a flat datum whose VARDATA_ANY is contiguous. */
uintptr_t shim_detoast(uintptr_t datum); /* (untranslatable) */
void shim_check_interrupts(void); /* (untranslatable: CHECK_FOR_INTERRUPTS) */

/* ---- error reporting (longjmp): raise a Postgres ERROR from Zig ---- */
void shim_ereport_str(const char *msg) __attribute__((noreturn)); /* (longjmp) */
void shim_ereport_schema(const char *reason) __attribute__((noreturn)); /* (longjmp) */
/* a LOG line in the server log */
void shim_log(const char *msg);

/* ---- per-query memory (palloc in the current context; reclaimed on abort) ---- */
void *shim_palloc(uint64_t size); /* (magic: MemoryContext current) */
void *shim_palloc0(uint64_t size);
void *shim_repalloc(void *p, uint64_t size);

/* ---- hot-path helpers used by engine_exec (macros / node construction) ---- */
void *shim_table_open(uint32_t oid);   /* NoLock: the engine holds a session lock (engine.zig); rels.zig keeps it open */
void *shim_index_open(uint32_t oid);
void  shim_close(void *rel, bool is_index);
uintptr_t shim_bytea(const char *buf, int32_t len); /* a bytea Datum copy of buf */

/* ---- implemented in Zig, called by the shim ---- */

/* Schema resolution + validation. Returns NULL on success, or a reason string on mismatch. */
const char *engine_validate_schema(void);

/* ---- catalog resolution for schema validation (macros translate-c rejects) ---- */

/* RangeVarGetRelid(public.<name>, AccessShareLock, missing_ok=true); 0 if absent. (untranslatable macro) */
uint32_t shim_relid(const char *name);
/* pg_class_aclcheck(oid, GetUserId(), ACL_SELECT) == ACLCHECK_OK */
bool shim_can_select(uint32_t oid);

typedef struct ShimAttr {
	int32_t attnum;    /* 1-based */
	uint32_t typid;
	uint32_t collation;
	bool notnull;
	char name[64];
} ShimAttr;

/* Open/close a relation by OID under NoLock (the lock is already held from shim_relid). */
void *shim_rel_open(uint32_t oid);
void  shim_rel_close(void *rel);
int   shim_rel_natts(void *rel);                       /* attribute count of the tuple descriptor */
void  shim_rel_attr(void *rel, int i, ShimAttr *out);  /* 0-based i; TupleDescAttr (untranslatable) */

typedef struct ShimIndexInfo {
	uint32_t indrelid;   /* the table this index is on */
	int32_t indnatts;
	int16_t indkey[8];   /* key column attnums */
	int16_t indoption[8];/* per-key flags: bit0 DESC, bit1 NULLS FIRST */
	uint32_t collation0; /* collation of the first key column (for slug/tag ordering) */
	uint32_t relam;      /* access method (btree.zig reads btree pages) */
	uint32_t opfamily[8];/* per-key operator family (btree.zig compares integer keys natively) */
} ShimIndexInfo;

void shim_index_info(uint32_t idxoid, ShimIndexInfo *out); /* reads rd_index, rd_indcollation, rd_opfamily */
/* Fill x->out[0..nreq) for one batch. Reads x->params and x->snapshot. Raises ERROR on any
 * request it cannot serve; it never answers through SQL. */
void engine_exec(EngineExec *x);
const char *engine_version(void);
/* relcache invalidation for relid (0 = all relations); marks the resolved schema stale. */
void engine_relcache_inval(uint32_t relid);
/* The engine's session locks: gone with an aborted transaction, released at backend exit. */
void engine_session_locks_released(void);
void engine_session_unlock(void);

/* ---- HTTP from background workers (research: the engine as the whole server; default off) ---- */

/* The worker's request loop (serve.zig): collects its socket and the JWT secret from the launcher at
 * `launcher`, then accepts, parses, batches each turn's requests through engine_exec and answers. Returns
 * only by ERROR or FATAL (SIGTERM). */
void engine_http_serve(const char *launcher);
/* One turn's transaction: begin returns the active snapshot every batch of the turn reads. */
void *shim_http_begin(void);
void shim_http_end(void);
/* engine_exec under a PG_TRY: false when it raised an ERROR, which is logged and has aborted the turn's
 * transaction (begin a new one for the rest of the turn). (longjmp) */
bool shim_http_exec(struct EngineExec *x);

/* ---- pgserve's writes (http_write.c): SPEC's write statements through SPI ---- */

enum { W_FOLLOW = 0, W_UNFOLLOW, W_FAVORITE, W_UNFAVORITE, W_ARTICLE_CREATE, W_ARTICLE_UPDATE, W_ARTICLE_DELETE,
       W_COMMENT_CREATE, W_COMMENT_DELETE, W_USER_INSERT, W_USER_UPDATE, W_USER_BY_EMAIL, W_COUNT };
/* OK: a row came back; NONE: no row; UNIQUE: a unique violation (23505); ERROR: any other failure (logged). */
enum { WS_OK = 0, WS_NONE, WS_UNIQUE, WS_ERROR };
#define PGS_MAX_COLS 8

/* A statement argument, typed by the statement: int8 in i, text in ptr/len, text[] in items/nitems. */
typedef struct PgsArg {
	bool		isnull;
	int64_t		i;
	const char *ptr;
	uint32_t	len;
	const EngineText *items;
	uint32_t	nitems;
} PgsArg;

/* A result column: int8, int4, bool and timestamptz (microseconds) in i, anything else as text in ptr/len. */
typedef struct PgsCol {
	bool		isnull;
	int64_t		i;
	const char *ptr;
	uint32_t	len;
} PgsCol;

typedef struct PgsWrite {
	int			kind;
	PgsArg		args[6];
	int			status;            /* WS_* */
	PgsCol		cols[PGS_MAX_COLS]; /* the first row; texts valid until shim_write_end */
} PgsWrite;

/* One turn's write transaction; shim_write runs one write in its own subtransaction inside it. The commit is
 * synchronous: one WAL flush covers the turn's writes. */
void shim_write_begin(void);
void shim_write(PgsWrite *w); /* (longjmp) */
void shim_write_end(void);

#endif
