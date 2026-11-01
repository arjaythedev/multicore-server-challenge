#ifndef PG_PG_H
#define PG_PG_H

#include <stdbool.h>

#include "core/loop.h"
#include "pg/statements.h"

/* only public window into libpq; a pg_pool belongs to one worker. every submit
 * ends in exactly one callback, from the worker's event loop, with a result
 * view valid for the callback or PG_ERROR */

typedef struct pg_pool pg_pool;
typedef struct pg_result pg_result;

typedef enum {
    PG_ROWS = 0,        // SELECT: tuples available
    PG_COMMAND,         // INSERT/UPDATE/DELETE completed
    PG_ERROR,           // statement failed or conn lost
} pg_status;

typedef void (*pg_cb)(void *ctx, pg_status status, const pg_result *res);

/* one read: viewer/limit/offset/key copied into the pool's queue; key borrowed
 * until the callback; unused fields zero. list_kind selects the branch of the
 * merged list statement (PG_LIST_*) */
typedef struct pg_read {
    long long viewer;
    int limit;
    long long offset;
    const char *key;
    unsigned char list_kind;
} pg_read;

/* opens read/write conns synchronously, applies session settings, prepares every
 * statement; FATAL on failure */
void pg_pool_open(pg_pool **out, const char *url, int read_conns,
                  int write_conns, int read_batch, int read_window_ms,
                  int write_group, int write_window_ms, int worker_id, loop *l);
void pg_pool_tick(pg_pool *pool);

/* write stmt; param strings/array borrowed until the callback; params NULL when
 * nparams == 0 */
void pg_submit(pg_pool *pool, pg_stmt stmt, int nparams,
               const char *const *params, void *ctx, pg_cb cb);

/* batched read: the request joins the process-wide shared read queue; the
 * first free read conn of any worker takes the oldest ready kind, up to the
 * batch limit, as one execution — and the answer still runs back on this
 * worker's loop */
void pg_read_submit(pg_pool *pool, pg_read_kind kind, const pg_read *read,
                    void *ctx, pg_cb cb);

/* the view hides the routing column (col_offset) and exposes rows relative to
 * first_row */
int         pg_result_rows(const pg_result *r);
int         pg_result_fields(const pg_result *r);
const char *pg_result_value(const pg_result *r, int row, int col);
bool        pg_result_is_null(const pg_result *r, int row, int col);
const char *pg_result_sqlstate(const pg_result *r);

#endif
