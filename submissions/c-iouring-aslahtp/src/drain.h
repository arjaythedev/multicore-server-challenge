/* The drain process: all Postgres reads of every worker, on one set of connections. */
#pragma once

void drain_run(void);
