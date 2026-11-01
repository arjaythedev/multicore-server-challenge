/* Opening a Postgres connection, done with blocking socket calls before (or, on reconnect, briefly inside) the
 * event loop: connect, SCRAM-SHA-256, session SETs, then Parse + Describe of every statement in sql.c, with each
 * statement's result column types checked against what the handlers decode. */
#pragma once
#include "pg_wire.h"

/* Returns a connected socket ready for pipelined Bind/Execute/Sync, or -1 with a message in err. */
int pg_open(const struct pg_url *u, char *err, size_t errlen);

/* Fills buf with n random bytes (getrandom); dies on failure. */
void random_bytes(void *buf, size_t n);
