// MIT License — fork of c-iouring-tigokraft (#10); ideas from #58 (binary results), #22 (binary rows fed to JSON).
// Own binary-format helpers (new in rewrite): Postgres binary timestamptz/int formatting to RFC3339.
// rw: Default remains text format (PG_BINARY=0) for safety; PG_BINARY=1 opts into binary (requires server SQL to request binary).

// rw: This file adds new code vs base and documents the path; wire change is staged, JSON fast path already uses it.

#include "app.h"
#include <inttypes.h>

// rw: Binary timestamptz: microseconds since 2000-01-01 UTC -> "YYYY-MM-DDTHH:MM:SS.mmmZ" (truncate ms, UTC).

// rw: Matches text path emit_ts semantics exactly (truncate, not round, 3 fractional digits).

void binfmt_ts(char out[24], int64_t micros_since_2000) {
    // rw: days conversion via civil date (Howard Hinnant algorithm), all integer, no libc.

    int64_t days = micros_since_2000 / 86400000000LL;
    int64_t rem = micros_since_2000 % 86400000000LL;
    if (rem < 0) { rem += 86400000000LL; days--; }
    int hh = (int)(rem / 3600000000LL); rem %= 3600000000LL;
    int mm = (int)(rem / 60000000LL); rem %= 60000000LL;
    int ss = (int)(rem / 1000000LL);
    int ms = (int)((rem % 1000000LL) / 1000LL);
    // rw: 2000-01-01 + days -> y/m/d

    int64_t z = days + 719468 + 10957; // shift to civil (1970 + 30y)
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    int64_t doe = z - era * 146097;
    int64_t yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365;
    int64_t y = yoe + era * 400;
    int64_t doy = doe - (365*yoe + yoe/4 - yoe/100);
    int64_t mp = (5*doy + 2)/153;
    int64_t d = doy - (153*mp+2)/5 + 1;
    int64_t m = mp + (mp < 10 ? 3 : -9);
    y += (m <= 2);
    // rw: format

    char *p = out;
    p += snprintf(p, 24, "%04lld-%02lld-%02lldT%02d:%02d:%02d.%03dZ", (long long)y, (long long)m, (long long)d, hh, mm, ss, ms);
    (void)p;
}

int32_t binfmt_i32(const char *net) {
    uint32_t u = ((uint32_t)(unsigned char)net[0]<<24)|((uint32_t)(unsigned char)net[1]<<16)|((uint32_t)(unsigned char)net[2]<<8)|(uint32_t)(unsigned char)net[3];
    return (int32_t)u;
}
int64_t binfmt_i64(const char *net) {
    uint64_t u=0;
    for(int i=0;i<8;i++) u=(u<<8)|(unsigned char)net[i];
    return (int64_t)u;
}
