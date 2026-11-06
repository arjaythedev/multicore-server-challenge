#ifndef NC_NATIVE_H
#define NC_NATIVE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct nc_request nc_request;
typedef struct nc_buffer nc_buffer;
typedef struct nc_json nc_json;
typedef struct nc_db nc_db;
typedef struct pg_result nc_result;

/* Host/HTTP. create copies its complete input; transport may release raw bytes. */
ssize_t nc_request_size(const char *data, size_t length);
nc_request *nc_request_create(const char *data, size_t length);
void nc_request_free(nc_request *request);
const char *nc_method(nc_request *request);
const char *nc_segment(nc_request *request, int index);
int nc_segments(nc_request *request);
const char *nc_query(nc_request *request, const char *name);
bool nc_keepalive(nc_request *request);
bool nc_eq(const char *left, const char *right);
size_t nc_length(const char *value);
int64_t nc_parse_uint(const char *value); /* -1 on empty/invalid/overflow */
char *nc_decimal(nc_request *request, int64_t value);

/* Body JSON: absent/null is kind 0, object 1, array 2, string 3, other 4. */
nc_json *nc_body(nc_request *request, const char *wrapper);
nc_json *nc_field(nc_json *object, const char *name);
int nc_kind(nc_json *value);
const char *nc_string(nc_json *value);
int nc_array_length(nc_json *array);
nc_json *nc_array_item(nc_json *array, int index);
char *nc_tag_array(nc_request *request, nc_json *array); /* PG text[] encoding */
char *nc_text_vector(nc_request *request, const char *const *values, int count);
char *nc_int_vector(nc_request *request, const int64_t *values, int count);

/* Authentication is checked afresh for every call/request. */
int64_t nc_auth(nc_request *request); /* -1 invalid present, 0 absent, >0 valid */
const char *nc_token(nc_request *request);
char *nc_issue_token(nc_request *request, int64_t id);
char *nc_hash(nc_request *request, const char *password); /* bcrypt cost10 */
bool nc_verify(const char *password, const char *hash);

/* Result writer; all structural JSON and business objects are emitted by Nelua. */
nc_buffer *nc_begin(nc_request *request, int status);
void nc_write(nc_buffer *buffer, const char *value);
void nc_write_n(nc_buffer *buffer, const char *value, size_t length);
void nc_putc(nc_buffer *buffer, char value);
void nc_error(nc_request *request, int status);
const char *nc_response_data(nc_request *request, size_t *length);
int nc_status(nc_request *request);
void nc_json_string(nc_buffer *buffer, unsigned char *data, size_t length);
void nc_json_int64(nc_buffer *buffer, int64_t value);

/* Per-worker prepared libpq connection. Responses follow completed commit. */
nc_db *nc_db_open(const char *url);
void nc_db_close(nc_db *db);
nc_result *nc_db_query(nc_db *db, int id, const char *sql, int count, const char *const *parameters);
/* Optional batch-local read pipeline, enabled only by READ_PIPELINE=1.
 * Stage calls queue IDs90..98; flush drains one Sync; the same queries then
 * claim their results once. End releases all unclaimed results. */
bool nc_db_pipeline_begin(nc_db *db);
bool nc_db_pipeline_staging(nc_db *db);
bool nc_db_pipeline_flush(nc_db *db);
void nc_db_pipeline_end(nc_db *db);
bool nc_tx(nc_db *db, const char *command);
bool nc_db_ok(nc_result *result);
bool nc_db_unique(nc_result *result);
void nc_result_free(nc_result *result);
int nc_rows(nc_result *result);
bool nc_null(nc_result *result, int row, int column);
const char *nc_value(nc_result *result, int row, int column);
size_t nc_value_length(nc_result *result, int row, int column);
int64_t nc_integer(nc_result *result, int row, int column);
bool nc_boolean(nc_result *result, int row, int column);
void nc_timestamp(nc_buffer *buffer, nc_result *result, int row, int column);
void nc_text_array(nc_buffer *buffer, nc_result *result, int row, int column);

/* Nelua entrypoints called by the transport. lane: 0 read,1 write,2 bcrypt. */
void conduit_handle(nc_request *request, nc_db *db);
void conduit_batch(nc_request **requests, int count, nc_db *db);
int conduit_lane(nc_request *request);
#endif
