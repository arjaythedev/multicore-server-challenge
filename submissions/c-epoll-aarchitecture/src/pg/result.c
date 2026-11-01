#include "pg/pg_internal.h"

/* accessors are total: a missing/failed result reads as empty. rows/cols are
 * batch-relative: first_row hides other requests' rows, col_offset the routing
 * column */

int pg_result_rows(const pg_result *r) {
    return r ? r->rows : 0;
}

int pg_result_fields(const pg_result *r) {
    if (!r || !r->raw) return 0;
    int fields = PQnfields(r->raw) - r->col_offset;
    return fields > 0 ? fields : 0;
}

const char *pg_result_value(const pg_result *r, int row, int col) {
    if (!r || !r->raw || row < 0 || col < 0) return "";
    int raw_row = r->first_row + row;
    int raw_col = r->col_offset + col;
    if (raw_row < 0 || raw_row >= r->first_row + r->rows) return "";
    if (raw_col < 0 || raw_col >= PQnfields(r->raw)) return "";
    return PQgetvalue(r->raw, raw_row, raw_col);
}

bool pg_result_is_null(const pg_result *r, int row, int col) {
    if (!r || !r->raw || row < 0 || col < 0) return true;
    int raw_row = r->first_row + row;
    int raw_col = r->col_offset + col;
    if (raw_row < 0 || raw_row >= r->first_row + r->rows) return true;
    if (raw_col < 0 || raw_col >= PQnfields(r->raw)) return true;
    return PQgetisnull(r->raw, raw_row, raw_col) != 0;
}

const char *pg_result_sqlstate(const pg_result *r) {
    if (!r || !r->raw) return "08000";
    const char *state = PQresultErrorField(r->raw, PG_DIAG_SQLSTATE);
    return state ? state : "08000";
}
