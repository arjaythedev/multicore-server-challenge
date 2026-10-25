// Every byte buffer that outlives one event (a connection's unread input or unsent output, a request's context,
// a Postgres connection's queues) is a run of this event loop's arena, named by offset so the structs holding it
// stay flat. Each event loop is a thread program with its own copy of the arena.

reusable[] var arena: u8[>..] = [];

struct Run { off: i64 = 0, cap: i64 = 0 }

fn view(r: Run) -> u8[:] { arena[r.off..r.off + r.cap] }

fn run_alloc(n: i64) -> Run {
    let s = arena.alloc_slice(n);
    return Run { off: arena.index_of(s[0]), cap: n };
}

// Room for at least n bytes, keeping what the run holds.
fn reserve(r: Run&, n: i64) {
    if r.cap >= n { return; }
    var want = max(r.cap * 2, 256);
    while want < n { want *= 2; }
    if r.cap == 0 { r = run_alloc(want); return; }
    let s = arena.realloc_slice(arena[r.off..r.off + r.cap], want);
    r.off = arena.index_of(s[0]);
    r.cap = want;
}

fn release(r: Run&) {
    if r.cap > 0 { arena.free_slice(arena[r.off..r.off + r.cap]); }
    r = Run { .. };
}

// A byte queue in a run: bytes [pos, len) are waiting.
struct Bytes { run: Run = Run { .. }, len: i64 = 0, pos: i64 = 0 }

fn pending(b: Bytes&) -> i64 { b.len - b.pos }

fn put(b: Bytes&, data: const u8[:]) {
    if b.pos > 0 && b.pos == b.len { b.pos = 0; b.len = 0; }
    if b.pos > 0 && b.len + data.len > b.run.cap { compact(b); }
    reserve(b.run, b.len + data.len);
    let dst = view(b.run);
    for c, i in data { dst[b.len + i] = c; }
    b.len += data.len;
}

// Room for n more bytes after the waiting ones, to receive into; grew(b, k) then takes k of them.
fn spare(b: Bytes&, n: i64) -> u8[:] {
    if b.pos > 0 && b.pos == b.len { b.pos = 0; b.len = 0; }
    if b.pos > 0 && b.len + n > b.run.cap { compact(b); }
    reserve(b.run, b.len + n);
    return view(b.run)[b.len..b.len + n];
}

fn grew(b: Bytes&, k: i64) { b.len += k; }

fn waiting(b: Bytes&) -> u8[:] { view(b.run)[b.pos..b.len] }

fn consume(b: Bytes&, n: i64) {
    b.pos += n;
    if b.pos == b.len { b.pos = 0; b.len = 0; }
}

// Moves the waiting bytes to the start of the run.
fn compact(b: Bytes&) {
    if b.pos == 0 { return; }
    let v = view(b.run);
    let n = b.len - b.pos;
    for i in n { v[i] = v[b.pos + i]; }
    b.pos = 0;
    b.len = n;
}

// Hands the run back once nothing waits in it, keeping small ones for reuse.
fn trim(b: Bytes&, keep: i64) {
    if b.len == b.pos && b.run.cap > keep { release(b.run); b.len = 0; b.pos = 0; }
}
