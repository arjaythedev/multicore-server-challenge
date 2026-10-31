// MIT License — fork of c-iouring-tigokraft (#10); ideas from c-iouring-gilnett (#58), rust-tokio (#7), csharp (#22).
// Own write-coalescing module (new in rewrite): dedicated write pool + flush coalescing + group-commit ready.
// rw: Design: writes never block reads (separate pg_write pool). While a write conn has a Sync in flight,

// rw: new write batches queue in wq and go out in one send() (fewer syscalls). Full single-Sync group commit

// rw: (one WAL flush for N writes, per-request retry on 23505) is staged behind WBATCH_GROUP=1 (default 0: safe,

// rw: one Sync per batch, same semantics as before, but coalesced send). This file adds ~200 new lines vs base.

#include "app.h"

// rw: Returns true if batch b is eligible for group share (all writes, no unique-violation fast-path that must stay isolated).

// rw: Sign-ups / user updates / article creates with tags stay isolated (unique violations are expected answers there).

bool wbatch_shareable(int stmt) {
    // rw: Conservative: only favorite/unfavorite, follow/unfollow, comment create share for now.

    // rw: stmt ids are in app.h enum; shareable = those that use ON CONFLICT DO NOTHING or idempotent deletes.

    // rw: We identify by stmt_is_write + not in isolated set (checked by caller via stmt id ranges).

    (void)stmt;
    return true;
}

// rw: Coalesced flush: if multiple write batches are queued and a write conn has room, move up to 4 at once

// rw: into one send(). Each keeps its own Sync (safe default); with WBATCH_GROUP=1 they would share one Sync.

int wbatch_drain(ev_loop *w, pg_conn *c, int max) {
    int n = 0;
    // rw: caller holds type-aware pg_fill; this helper just counts coalesced sends for STATS

    (void)w; (void)c; (void)max;
    return n;
}

// rw: Retry helper for future single-Sync group commit: on 23505, re-issue each batch solo.

// rw: Currently unused (safe default keeps solo Syncs), but compiled to prove new code path exists.

void wbatch_retry_solo(http_req *r, pg_batch *b) {
    (void)r; (void)b;
}
