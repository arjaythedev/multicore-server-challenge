#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef struct pg_conn PGconn;
extern PGconn *PQconnectStartParams(const char *const *,
                                   const char *const *, int);
extern void PQfinish(PGconn *);

typedef struct {
  int socket;
  char *host;
  char *port;
  char *user;
  char *password;
  char *database;
} pq_start_job;

static void free_job(pq_start_job *job) {
  free(job->host);
  free(job->port);
  free(job->user);
  free(job->password);
  free(job->database);
  free(job);
}

static void *start_connection(void *data) {
  pq_start_job *job = data;
  const char *keys[] = {"host", "port", "user", "password", "dbname",
                        "sslmode", "gssencmode", "options", "require_auth",
                        NULL};
  const char *values[] = {job->host, job->port, job->user, job->password,
                          job->database, "disable", "disable",
                          "-c timezone=UTC -c datestyle=ISO,YMD",
                          "scram-sha-256", NULL};
  PGconn *conn = PQconnectStartParams(keys, values, 0);
  ssize_t sent;
  do {
    sent = send(job->socket, &conn, sizeof(conn), MSG_NOSIGNAL);
  } while (sent == -1 && errno == EINTR);
  if (sent != sizeof(conn) && conn != NULL) PQfinish(conn);
  close(job->socket);
  free_job(job);
  return NULL;
}

int conduit_pq_start(const char *host, const char *port, const char *user,
                     const char *password, const char *database) {
  int sockets[2];
  if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC,
                 0, sockets) != 0) return -1;
  pq_start_job *job = calloc(1, sizeof(*job));
  if (job == NULL) goto error;
  job->socket = sockets[1];
  job->host = strdup(host);
  job->port = strdup(port);
  job->user = strdup(user);
  job->password = strdup(password);
  job->database = strdup(database);
  if (job->host == NULL || job->port == NULL || job->user == NULL ||
      job->password == NULL || job->database == NULL) goto job_error;
  pthread_t thread;
  if (pthread_create(&thread, NULL, start_connection, job) != 0)
    goto job_error;
  pthread_detach(thread);
  return sockets[0];

job_error:
  free_job(job);
error:
  close(sockets[0]);
  close(sockets[1]);
  return -1;
}

PGconn *conduit_pq_take(int socket) {
  PGconn *conn = NULL;
  ssize_t count;
  do {
    count = recv(socket, &conn, sizeof(conn), 0);
  } while (count == -1 && errno == EINTR);
  close(socket);
  return count == sizeof(conn) ? conn : NULL;
}

void conduit_pq_cancel(int socket) { close(socket); }

int conduit_pq_i64_decimal(const char *text, size_t length, int64_t *output) {
  if (length == 0) return 0;
  int negative = text[0] == '-';
  size_t index = negative ? 1 : 0;
  if (index == length) return 0;
  uint64_t limit = (uint64_t)INT64_MAX + negative;
  uint64_t magnitude = 0;
  for (; index < length; index++) {
    unsigned char ch = (unsigned char)text[index];
    if (ch < '0' || ch > '9') return 0;
    uint64_t digit = ch - '0';
    if (magnitude > (limit - digit) / 10) return 0;
    magnitude = magnitude * 10 + digit;
  }
  if (negative && magnitude == (uint64_t)INT64_MAX + 1) {
    *output = INT64_MIN;
  } else {
    *output = negative ? -(int64_t)magnitude : (int64_t)magnitude;
  }
  return 1;
}

int64_t conduit_pq_timestamp(const char *text) {
  int year, month, day, hour, minute, second;
  int count = 0;
  if (sscanf(text, "%d-%d-%d %d:%d:%d%n", &year, &month, &day,
             &hour, &minute, &second, &count) != 6) return INT64_MIN;
  int64_t fraction = 0;
  const char *cursor = text + count;
  if (*cursor == '.') {
    cursor++;
    int digits = 0;
    while (*cursor >= '0' && *cursor <= '9' && digits < 6) {
      fraction = fraction * 10 + (*cursor++ - '0');
      digits++;
    }
    while (digits++ < 6) fraction *= 10;
    if (*cursor >= '0' && *cursor <= '9') return INT64_MIN;
  }
  if (*cursor != '\0' && strcmp(cursor, "+00") != 0 &&
      strcmp(cursor, "+00:00") != 0) return INT64_MIN;
  struct tm tm = {0};
  tm.tm_year = year - 1900;
  tm.tm_mon = month - 1;
  tm.tm_mday = day;
  tm.tm_hour = hour;
  tm.tm_min = minute;
  tm.tm_sec = second;
  time_t seconds = timegm(&tm);
  return ((int64_t)seconds - 946684800) * 1000000 + fraction;
}
