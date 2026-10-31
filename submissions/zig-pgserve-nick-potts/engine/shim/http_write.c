/*
 * pgserve's writes: SPEC's write statements through SPI, from the engine's HTTP workers (serve.zig).
 *
 * A turn's writes share one transaction, so one commit (one WAL flush) covers them all. Each write runs in its own
 * subtransaction, so one that fails (a taken username, a statement error) rolls back alone and answers its own
 * request. (longjmp: the PG_TRY that catches a failed write must be a C frame.)
 *
 * The statements are SPEC's, reduced to the columns the worker needs: the response bodies of articles, profiles and
 * users come from the engine's reads after the commit, so a write returns only the keys those reads take.
 */
#include "postgres.h"
#include "access/xact.h"
#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/resowner.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"

#include "pgengine.h"

typedef struct WriteStmt
{
	const char *sql;
	int			nargs;
	Oid			types[6];
} WriteStmt;

#define SLUGIFY(t) "trim(both '-' from lower(regexp_replace(" t ", '[^A-Za-z0-9]+', '-', 'g')))"

static const WriteStmt stmts[W_COUNT] = {
	[W_FOLLOW] = {
		"WITH t AS (SELECT id FROM users WHERE username = $2),"
		" w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)"
		" SELECT id FROM t", 2, {INT8OID, TEXTOID}},
	[W_UNFOLLOW] = {
		"WITH t AS (SELECT id FROM users WHERE username = $2),"
		" w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t))"
		" SELECT id FROM t", 2, {INT8OID, TEXTOID}},
	[W_FAVORITE] = {
		"WITH t AS (SELECT id FROM articles WHERE slug = $2),"
		" w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)"
		" SELECT id FROM t", 2, {INT8OID, TEXTOID}},
	[W_UNFAVORITE] = {
		"WITH t AS (SELECT id FROM articles WHERE slug = $2),"
		" w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t))"
		" SELECT id FROM t", 2, {INT8OID, TEXTOID}},
	[W_ARTICLE_CREATE] = {
		"WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),"
		" a AS (INSERT INTO articles (id, slug, author_id, title, description, body)"
		"       SELECT n.id, " SLUGIFY("$2") " || '-' || n.id, $1, $2, $3, $4 FROM n RETURNING id, slug),"
		" existing AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($5::text[])),"
		" t AS (INSERT INTO tags (name)"
		"       SELECT name FROM (SELECT DISTINCT unnest($5::text[]) AS name) names"
		"       WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name)"
		"       ORDER BY name ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name),"
		" all_tags AS (SELECT id, name FROM existing UNION ALL SELECT id, name FROM t),"
		" x AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, all_tags.id FROM a, all_tags)"
		" SELECT a.slug FROM a", 5, {INT8OID, TEXTOID, TEXTOID, TEXTOID, TEXTARRAYOID}},
	[W_ARTICLE_UPDATE] = {
		"WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),"
		" w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description),"
		"       body = COALESCE($4, body),"
		"       slug = CASE WHEN $2::text IS NULL THEN slug ELSE " SLUGIFY("$2") " || '-' || id END,"
		"       updated_at = now()"
		"       WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING slug)"
		" SELECT t.author_id, (SELECT slug FROM w) FROM t", 5, {TEXTOID, TEXTOID, TEXTOID, TEXTOID, INT8OID}},
	[W_ARTICLE_DELETE] = {
		"WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),"
		" w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))"
		" SELECT author_id FROM t", 2, {TEXTOID, INT8OID}},
	[W_COMMENT_CREATE] = {
		"WITH t AS (SELECT id FROM articles WHERE slug = $1),"
		" c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t"
		"       RETURNING id, body, created_at, updated_at, author_id)"
		" SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image"
		" FROM c JOIN users u ON u.id = c.author_id", 3, {TEXTOID, INT8OID, TEXTOID}},
	[W_COMMENT_DELETE] = {
		"WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id"
		"           WHERE c.id = $1 AND a.slug = $2),"
		" w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))"
		" SELECT author_id FROM t", 3, {INT8OID, TEXTOID, INT8OID}},
	[W_USER_INSERT] = {
		"INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id",
		3, {TEXTOID, TEXTOID, TEXTOID}},
	[W_USER_UPDATE] = {
		"UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),"
		" password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)"
		" WHERE id = $1 RETURNING id", 6, {INT8OID, TEXTOID, TEXTOID, TEXTOID, TEXTOID, TEXTOID}},
	[W_USER_BY_EMAIL] = {
		"SELECT id, password_hash FROM users WHERE email = $1", 1, {TEXTOID}},
};

/* Prepared once per worker, kept for its life. */
static SPIPlanPtr plans[W_COUNT];

void
shim_write_begin(void)
{
	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	/* SPI takes a fresh snapshot per statement, but wants an outer one to revalidate plans under */
	PushActiveSnapshot(GetTransactionSnapshot());
	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "pgengine http: SPI_connect failed");
}

void
shim_write_end(void)
{
	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();
}

/* A text value, refused as Postgres's own text input refuses it: a JSON \u0000 decodes to a NUL byte. */
static Datum
text_datum(const char *p, uint32_t len)
{
	if (memchr(p, 0, len) != NULL)
		ereport(ERROR, (errcode(ERRCODE_UNTRANSLATABLE_CHARACTER),
						errmsg("invalid byte sequence for encoding \"UTF8\": 0x00")));
	return PointerGetDatum(cstring_to_text_with_len(p, len));
}

static Datum
arg_datum(const PgsArg *a, Oid type)
{
	switch (type)
	{
		case INT8OID:
			return Int64GetDatum(a->i);
		case TEXTOID:
			return text_datum(a->ptr, a->len);
		default:
			{
				Datum	   *items = palloc(sizeof(Datum) * (a->nitems > 0 ? a->nitems : 1));

				for (uint32_t k = 0; k < a->nitems; k++)
					items[k] = text_datum(a->items[k].ptr, a->items[k].len);
				return PointerGetDatum(construct_array_builtin(items, a->nitems, TEXTOID));
			}
	}
}

/* The first row's columns into w->cols. Texts point into SPI memory, valid until shim_write_end. */
static void
take_row(PgsWrite *w)
{
	TupleDesc	desc = SPI_tuptable->tupdesc;
	HeapTuple	tup = SPI_tuptable->vals[0];

	for (int j = 0; j < desc->natts && j < PGS_MAX_COLS; j++)
	{
		bool		isnull;
		Datum		d = SPI_getbinval(tup, desc, j + 1, &isnull);
		PgsCol	   *col = &w->cols[j];

		col->isnull = isnull;
		if (isnull)
			continue;
		switch (SPI_gettypeid(desc, j + 1))
		{
			case INT8OID:
				col->i = DatumGetInt64(d);
				break;
			case INT4OID:
				col->i = DatumGetInt32(d);
				break;
			case BOOLOID:
				col->i = DatumGetBool(d);
				break;
			case TIMESTAMPTZOID:
				col->i = DatumGetTimestampTz(d);
				break;
			default:
				{
					struct varlena *v = pg_detoast_datum_packed((struct varlena *) DatumGetPointer(d));

					col->ptr = VARDATA_ANY(v);
					col->len = VARSIZE_ANY_EXHDR(v);
				}
		}
	}
}

void
shim_write(PgsWrite *w)
{
	const WriteStmt *s = &stmts[w->kind];
	MemoryContext cxt = CurrentMemoryContext;
	ResourceOwner owner = CurrentResourceOwner;
	Datum		values[6];
	char		nulls[6];

	memset(w->cols, 0, sizeof(w->cols));
	BeginInternalSubTransaction(NULL);
	MemoryContextSwitchTo(cxt);
	PG_TRY();
	{
		int			rc;

		if (plans[w->kind] == NULL)
		{
			SPIPlanPtr	p = SPI_prepare(s->sql, s->nargs, (Oid *) s->types);

			if (p == NULL || SPI_keepplan(p) != 0)
				elog(ERROR, "preparing it failed: %s", SPI_result_code_string(SPI_result));
			plans[w->kind] = p;
		}
		for (int k = 0; k < s->nargs; k++)
		{
			nulls[k] = w->args[k].isnull ? 'n' : ' ';
			values[k] = w->args[k].isnull ? (Datum) 0 : arg_datum(&w->args[k], s->types[k]);
		}
		rc = SPI_execute_plan(plans[w->kind], values, nulls, false, 0);

		if (rc < 0)
			elog(ERROR, "SPI_execute_plan: %s", SPI_result_code_string(rc));
		if (SPI_processed > 0 && SPI_tuptable != NULL)
		{
			take_row(w);
			w->status = WS_OK;
		}
		else
			w->status = WS_NONE;
		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(cxt);
		CurrentResourceOwner = owner;
	}
	PG_CATCH();
	{
		ErrorData  *e;

		MemoryContextSwitchTo(cxt);
		e = CopyErrorData();
		FlushErrorState();
		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(cxt);
		CurrentResourceOwner = owner;
		w->status = e->sqlerrcode == ERRCODE_UNIQUE_VIOLATION ? WS_UNIQUE : WS_ERROR;
		if (w->status == WS_ERROR)
			ereport(LOG, (errmsg("pgengine http: write %d failed: %s", w->kind, e->message)));
		FreeErrorData(e);
	}
	PG_END_TRY();
}
