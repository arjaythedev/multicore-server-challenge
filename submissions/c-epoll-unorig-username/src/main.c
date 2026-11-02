#include <signal.h>
#include <stdio.h>
#include <unistd.h>

#include "common.h"
#include "pg.h"

static int env_int(const char *k, int d) {
  const char *v = getenv(k);
  return v && *v ? atoi(v) : d;
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  pg_url = getenv("DATABASE_URL");
  const char *secret = getenv("JWT_SECRET"), *host = getenv("HOST"), *port = getenv("PORT");
  if (!pg_url || !secret) {
    fprintf(stderr, "DATABASE_URL and JWT_SECRET are required\n");
    return 1;
  }
  sha256_init_cpu();
  hmac_jwt_init(secret, strlen(secret));
  bcrypt_selftest();
  writes_start(env_int("WRITE_CONNS", 4));
  reads_start(env_int("READ_CONNS", 8));
  hashers_start(env_int("BCRYPT_THREADS", 2));
  loops_start(env_int("LOOPS", 4), host ? host : "0.0.0.0", port ? atoi(port) : 3000);
  for (;;) pause();
}
