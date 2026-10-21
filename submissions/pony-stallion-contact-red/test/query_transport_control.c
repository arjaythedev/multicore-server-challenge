#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <libpq-fe.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int64_t records[256][4];
static uint32_t used;
static int overflow;
static PGconn *selected;
static int chosen, armed, remaining, scenario;
static _Thread_local int inside_send;

static void append(int function, int scripted, int result) {
  pthread_mutex_lock(&lock);
  if (used < 256) {
    records[used][0] = 1;
    records[used][1] = function;
    records[used][2] = scripted;
    records[used][3] = result;
    used++;
  } else overflow = 1;
  pthread_mutex_unlock(&lock);
}

int64_t conduit_query_storage_ledger_get(uint32_t record, uint32_t field) {
  int64_t result = INT64_MIN;
  pthread_mutex_lock(&lock);
  if (record == UINT32_MAX) {
    if (field == 0) result = 1;
    if (field == 1) result = used;
    if (field == 2) result = overflow;
    if (field == 3) {
      const char *mode = getenv("CONDUIT_QUERY_SCENARIO");
      result = chosen ? scenario : (mode ? atoi(mode) : 0);
    }
  } else if (record < used && field < 4) result = records[record][field];
  pthread_mutex_unlock(&lock);
  return result;
}

static int choose(PGconn *conn, const char *value) {
  const char *marker = getenv("CONDUIT_QUERY_MARKER");
  const char *mode = getenv("CONDUIT_QUERY_SCENARIO");
  if (!marker || !mode || strcmp(value, marker)) return 0;
  pthread_mutex_lock(&lock);
  if (chosen) {
    overflow = 1;
    pthread_mutex_unlock(&lock);
    return -1;
  }
  chosen = 1;
  selected = conn;
  scenario = atoi(mode);
  armed = 1;
  remaining = (scenario == 3 || scenario == 5) ? 2 :
    ((scenario == 4 || scenario == 6) ? 1 : 0);
  pthread_mutex_unlock(&lock);
  if (scenario == 7) {
    int size = 1024 * 1024;
    append(4, 0, setsockopt(PQsocket(conn), SOL_SOCKET, SO_SNDBUF,
      &size, sizeof(size)));
  }
  return 1;
}

int PQsendQueryParams(PGconn *conn, const char *sql, int count,
  const Oid *types, const char *const *values, const int *lengths,
  const int *formats, int result_format) {
  int (*next)(PGconn *, const char *, int, const Oid *,
    const char *const *, const int *, const int *, int);
  *(void **)(&next) = dlsym(RTLD_NEXT, "PQsendQueryParams");
  if (!next) abort();
  int match = choose(conn, sql);
  if (match < 0) { append(1, 1, 0); return 0; }
  if (match && (scenario == 1 || scenario == 8)) {
    armed = 0; append(1, 1, 0); return 0;
  }
  inside_send++;
  int result = next(conn, sql, count, types, values, lengths, formats,
    result_format);
  inside_send--;
  if (match) { append(1, 0, result); if (result != 1) armed = 0; }
  return result;
}

int PQsendQueryPrepared(PGconn *conn, const char *name, int count,
  const char *const *values, const int *lengths, const int *formats,
  int result_format) {
  int (*next)(PGconn *, const char *, int, const char *const *,
    const int *, const int *, int);
  *(void **)(&next) = dlsym(RTLD_NEXT, "PQsendQueryPrepared");
  if (!next) abort();
  int match = choose(conn, name);
  if (match < 0) { append(2, 1, 0); return 0; }
  if (match && (scenario == 1 || scenario == 8)) {
    armed = 0; append(2, 1, 0); return 0;
  }
  inside_send++;
  int result = next(conn, name, count, values, lengths, formats, result_format);
  inside_send--;
  if (match) { append(2, 0, result); if (result != 1) armed = 0; }
  return result;
}

int PQflush(PGconn *conn) {
  int (*next)(PGconn *);
  *(void **)(&next) = dlsym(RTLD_NEXT, "PQflush");
  if (!next) abort();
  if (!inside_send && chosen && armed && selected == conn) {
    if (scenario == 2) { armed = 0; append(3, 1, -1); return -1; }
    if (remaining > 0) { remaining--; append(3, 1, 1); return 1; }
    int result = next(conn);
    append(3, 0, result);
    if (result != 1) armed = 0;
    return result;
  }
  return next(conn);
}
