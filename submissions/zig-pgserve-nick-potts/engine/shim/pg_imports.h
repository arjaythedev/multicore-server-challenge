/*
 * The Postgres 18 server headers the engine reads, plus the shim boundary. build.sh runs
 * `zig translate-c` over this file and hands the result to the Zig sources as the module `pg_c`.
 * Struct layouts and extern functions come straight from these headers. The macros translate-c
 * can't render are reached through pgengine.h instead.
 */
#include "postgres.h"
#include "access/genam.h"
#include "access/heapam.h"
#include "access/nbtree.h"
#include "access/relscan.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/visibilitymap.h"
#include "access/xact.h"
#include "catalog/namespace.h"
#include "catalog/pg_type.h"
#include "executor/executor.h"
#include "executor/tuptable.h"
#include "miscadmin.h"
#include "storage/buf_internals.h"
#include "storage/lmgr.h"
#include "utils/rel.h"
#include "utils/inval.h"
#include "utils/lsyscache.h"
#include "utils/varlena.h"
#include "pgengine.h"
