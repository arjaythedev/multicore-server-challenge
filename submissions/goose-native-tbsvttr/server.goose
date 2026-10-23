// One event loop: its own listener (SO_REUSEPORT spreads connections over the loops), its own epoll, its own
// Postgres connections and its own bcrypt reply pipe. A client connection runs one request at a time; requests that
// need the database are Bind/Execute messages appended to a Postgres connection's output, and every request
// shares a Sync with a bounded writer collection interval. Only closed groups are sent;
// every successful write is answered after its ReadyForQuery confirms commit.

import bcrypt;
import buf;
import crypto;
import http;
import json;
import jwt;
import pg;
import sql;
import std;
import sys;

// ---------- configuration, set by main before the loops start ----------

var listen_addr: u32 = 0;
var listen_port = 80;
var pg_addr: u32 = 0;
var pg_port = 5432;
var pg_user: u8[..128] = "";
var pg_password: u8[..256] = "";
var pg_db: u8[..128] = "";
var jwt_key: u8[>..] = [];
var readers = 3;
var batch_max = 32;             // the most reads one batched execution answers; 0 sends every read on its own
var batch_hold = 1;             // reads wait in the pool while this many batched executions are in flight
var read_group_max = 4;           // outstanding reader Sync groups; 0 leaves admission unbounded
var read_batch_us = 5000;          // optional collection window for pending HTTP reads; 0 preserves immediate dispatch
var write_batch_us = 1000;     // 0 restores immediate writer Sync; collection never delays read groups
var article_batch = true;     // optional live article reads share enrichment only within one SQL execution

// ---------- state ----------

let KIND_CLIENT: u64 = 0;
let KIND_LISTENER: u64 = 1;
let KIND_PG: u64 = 2;
let KIND_PIPE: u64 = 3;

// What a busy connection waits for.
let K_REGISTER_HASH = 1;
let K_REGISTER = 2;
let K_LOGIN = 3;
let K_LOGIN_CHECK = 4;
let K_CURRENT = 5;
let K_UPDATE_HASH = 6;
let K_UPDATE_USER = 7;
let K_PROFILE = 8;
let K_FOLLOW = 9;
let K_UNFOLLOW = 10;
let K_LIST = 11;
let K_ARTICLE = 12;
let K_CREATE = 13;
let K_UPDATE_ARTICLE = 14;
let K_DELETE_ARTICLE = 15;
let K_FAVORITE = 16;
let K_UNFAVORITE = 17;
let K_COMMENTS = 18;
let K_CREATE_COMMENT = 19;
let K_DELETE_COMMENT = 20;
let K_TAGS = 21;

struct Conn {
    fd: i32 = -1,
    gen: u32 = 0,
    busy: bool = false,         // a request is being answered
    dead: bool = false,         // closed while busy: the slot is freed when the answer comes
    close_after: bool = false,
    write: bool = false,        // the request runs on the writer connection
    group_end: bool = false,    // the last request of its Sync group
    kind: i64 = 0,
    viewer: i64 = 0,
    nstmt: i64 = 0,             // statements in the request
    tries: i64 = 0,
    next: i64 = -1,             // the next request waiting on the same Postgres connection
    hash_at: i64 = 0,           // where in msg the bcrypt hash goes
    inb: Bytes = Bytes { .. },  // received, not yet answered
    outb: Bytes = Bytes { .. }, // answered, not yet sent
    ctx: Run = Run { .. },      // the token or password a request keeps while it waits
    ctx_len: i64 = 0,
    msg: Run = Run { .. },      // the request's Bind/Execute messages, kept to send again
    msg_len: i64 = 0,
    fam: i64 = -1,              // the statement of a read waiting in the pool
    pooled: bool = false,       // sent from the pool: counted in in_flight until its answer comes
    read_node: i64 = -1,        // owned node in a local, unsubmitted readonly queue
    read_order: i64 = 0,        // monotonic enqueue order within this worker
    lead: bool = false,         // its execution answers it and the members chained by co_next
    co_next: i64 = -1,
}

reusable var conns: Conn[>..] = [];
var serial: u32 = 0;

struct Pgc {
    fd: i32 = -1,
    out: Bytes = Bytes { .. },
    inb: Bytes = Bytes { .. },
    head: i64 = -1,             // requests sent and not answered, oldest first
    tail: i64 = -1,
    open: i64 = 0,              // requests appended since the last Sync
    waiting: i64 = 0,
    groups: i64 = 0,            // closed Sync groups not yet answered by ReadyForQuery
    sendable: i64 = 0,          // output bytes covered by a Sync; unclosed writer tail stays local
    opened_ns: i64 = 0,         // monotonic first request time of the current open group
    scan: i64 = 0,              // where in inb the search for the next ReadyForQuery goes on
}

var pgs: Pgc[>..] = [];
var writer = 0;
var epfd: i32 = -1;
var reply_read: i32 = -1;
var reply_write: i32 = -1;
var now_ms = 0;
var ready: u64[>..] = [];       // connections with input left once their answer went out
var scratch: u8[>..] = [];      // the receive buffer
// Nine local FIFO queues: the eight pooled families and direct readonly work.
// Nodes outlive a disconnected Conn slot only until unlink, and retain its tag.
struct ReadNode { tag: u64 = 0, qid: i64 = 0, prev: i64 = -1, next: i64 = -1 }
reusable var read_nodes: ReadNode[>..] = [];
var read_heads: i64[9] = [-1; 9];
var read_tails: i64[9] = [-1; 9];
var read_serial: i64 = 0;
var pool_count = 0;
var pool_open_ns: i64 = 0;     // first pending request in this pool; no query result is retained here
var in_flight = 0;              // executions sent from the pool and not answered

let GROUP_MAX = 64;
let READ_GROUP_MAX = 4;         // readonly results/credits release early; writer commit groups remain 64
let RECV_SIZE = 65536;
let SYNC_MSG: u8[5] = ['S', 0, 0, 0, 4];

fn tag_of(slot: i64) -> u64 { (slot as u64) | (conns[slot].gen as u64) << 32 }

fn ev_data(kind: u64, slot: i64) -> u64 {
    kind << 56 | ((conns[slot].gen as u64) & 0xffffff) << 32 | (slot as u64)
}

fn log(s: const u8[:]) { sys_write(2, str("conduit: ", s, "\n")); }

// ---------- connections ----------

fn free_conn(slot: i64) {
    let c .= conns[slot];
    if c.read_node >= 0 { unlink_read(c.read_node); }
    release(c.inb.run); release(c.outb.run); release(c.ctx); release(c.msg);
    c = Conn { .. };
    conns.free(slot);
}

fn close_conn(slot: i64) {
    let c .= conns[slot];
    if c.fd >= 0 { sys_close(c.fd); c.fd = -1; }
    if c.busy {
        // Only locally owned reads can be discarded. Submitted work and writes
        // retain their existing owner until its answer, even after disconnect.
        if !c.write && c.read_node >= 0 { free_conn(slot); return; }
        c.dead = true;
        return;
    }
    free_conn(slot);
}

fn gone(slot: i64) -> bool { conns[slot].fd < 0 }

fn accept_all(lfd: i32) {
    loop {
        let fd = sys_accept4(lfd, 0, 0, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if fd < 0 { return; }
        set_int_option(fd, IPPROTO_TCP, TCP_NODELAY, 1);
        serial += 1;
        let slot = conns.alloc_index(Conn { fd: fd, gen: serial, .. });
        if !epoll_add(epfd, fd, EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET, ev_data(KIND_CLIENT, slot)) {
            sys_close(fd);
            conns[slot].fd = -1;
            free_conn(slot);
        }
    }
}

// Sends the response, or what the socket won't take now into the connection's output.
fn send_res(slot: i64, out: const u8[:]) {
    let c .= conns[slot];
    if c.fd < 0 { return; }
    if pending(c.outb) > 0 { put(c.outb, out); return; }
    var done = 0;
    while done < out.len {
        let n = sys_send(c.fd, out[done..], MSG_NOSIGNAL);
        if n <= 0 { break; }
        done += n;
    }
    if done < out.len { put(c.outb, out[done..]); }
}

// The response goes out, and the connection takes its next request.
fn reply(slot: i64, out: const u8[:]) {
    send_res(slot, out);
    let c .= conns[slot];
    let was_busy = c.busy;
    c.busy = false;
    c.kind = 0;
    c.ctx_len = 0;
    if c.close_after {
        if pending(c.outb) == 0 { close_conn(slot); }
        return;
    }
    if was_busy && pending(c.inb) > 0 { ready.push(tag_of(slot)); }
}

fn fail(slot: i64, status: i64, message: const u8[:]) {
    var out: u8[>..] = [];
    error_response(out, status, message, conns[slot].close_after);
    reply(slot, out);
}

fn flush_out(slot: i64) {
    let c .= conns[slot];
    while pending(c.outb) > 0 {
        let n = sys_send(c.fd, waiting(c.outb), MSG_NOSIGNAL);
        if n <= 0 { return; }
        consume(c.outb, n);
    }
    trim(c.outb, 0);
    if c.close_after && !c.busy { close_conn(slot); }
}

// Answers the whole requests at the start of data, in order, until one has to wait; returns the bytes used.
fn serve(slot: i64, data: const u8[:]) -> i64 {
    var used = 0;
    while !gone(slot) && !conns[slot].busy {
        var r, st = parse_request(data[used..]);
        if st == NEED_MORE { break; }
        if st != PARSED {
            conns[slot].close_after = true;
            fail(slot, st, if st == 413 { "request body too large" } else if st == 431 { "request header too large" } else { "bad request" });
            return data.len;
        }
        used += r.size;
        conns[slot].close_after = r.close;
        handle(slot, r);
    }
    return used;
}

fn on_input(slot: i64, data: const u8[:]) {
    let c .= conns[slot];
    if c.busy || pending(c.inb) > 0 {
        put(c.inb, data);
        if !c.busy { drain(slot); }
        return;
    }
    let used = serve(slot, data);
    if !gone(slot) && used < data.len { put(conns[slot].inb, data[used..]); }
}

fn drain(slot: i64) {
    let used = serve(slot, waiting(conns[slot].inb));
    if gone(slot) { return; }
    consume(conns[slot].inb, used);
    trim(conns[slot].inb, 0);
}

fn client_event(slot: i64, events: u32) {
    if events & (EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR) != 0 {
        loop {
            let n = sys_recv(conns[slot].fd, scratch, 0);
            if n == 0 { close_conn(slot); return; }
            if n < 0 { break; }
            on_input(slot, scratch[..n]);
            if gone(slot) { return; }
            if n < scratch.len { break; }
        }
        if events & (EPOLLHUP | EPOLLERR | EPOLLRDHUP) != 0 { close_conn(slot); return; }
    }
    if events & EPOLLOUT != 0 && pending(conns[slot].outb) > 0 { flush_out(slot); }
}

// ---------- Postgres ----------

fn begin(slot: i64, kind: i64, viewer: i64) {
    let c .= conns[slot];
    c.kind = kind;
    c.viewer = viewer;
    c.nstmt = 0;
    c.tries = 0;
}

fn stmt(slot: i64, m: u8[>..]&, st: i64, nparams: i64) -> i64 {
    conns[slot].nstmt += 1;
    return bind_begin(m, st, nparams);
}

fn enqueue(p: i64, slot: i64) {
    let c .= conns[slot];
    c.next = -1;
    c.group_end = false;
    if pgs[p].tail >= 0 { conns[pgs[p].tail].next = slot; } else { pgs[p].head = slot; }
    pgs[p].tail = slot;
}

fn close_group(p: i64) {
    if p != writer && read_group_max > 0 { assert(pgs[p].groups < read_group_max); }
    put(pgs[p].out, SYNC_MSG);
    conns[pgs[p].tail].group_end = true;
    pgs[p].open = 0;
    pgs[p].opened_ns = 0;
    pgs[p].sendable = pending(pgs[p].out);
    pgs[p].groups += 1;
}

// Ceiling milliseconds make the poll wake for the writer deadline even on an otherwise idle loop.
fn writer_wait_ms() -> i32 {
    if pgs[writer].open == 0 { return -1; }
    let left = pgs[writer].opened_ns + write_batch_us * 1000 - mono_ns();
    if left <= 0 { return 0; }
    return ((left + 999999) / 1000000) as! i32;
}

// A gated pool waits for a PG reply, not a repeatedly expired collection timer.
// A full pool may bypass the in-flight gate, exactly as pool_flush already does.
fn pool_wait_ms() -> i32 {
    oldest_pool_queue(); // discard any stale heads before the shared gate
    if read_batch_us == 0 || batch_max == 0 || pool_blocked() { return -1; }
    if pool_count >= batch_max { return 0; }
    let left = pool_open_ns + read_batch_us * 1000 - mono_ns();
    if left <= 0 { return 0; }
    return ((left + 999999) / 1000000) as! i32;
}

fn poll_wait_ms() -> i32 {
    let write_ms = writer_wait_ms();
    let read_ms = pool_wait_ms();
    if write_ms < 0 { return read_ms; }
    if read_ms < 0 { return write_ms; }
    return min(write_ms, read_ms);
}

fn least_busy_reader() -> i64 {
    var p = -1;
    for i in readers {
        if read_group_max > 0 && pgs[i].groups >= read_group_max { continue; }
        if p < 0 || pgs[i].waiting < pgs[p].waiting { p = i; }
    }
    return p;
}

// A full pool bypasses only READ_HOLD, never the hard reader reservation.
fn pool_blocked() -> bool {
    return pool_count == 0 || least_busy_reader() < 0 ||
        (in_flight >= batch_hold && pool_count < batch_max);
}

// Appends a request's messages to Postgres connection p; its answer goes to slot.
fn put_request(p: i64, slot: i64, m: const u8[:]) {
    put(pgs[p].out, m);
    enqueue(p, slot);
    pgs[p].waiting += 1;
    if pgs[p].open == 0 { pgs[p].opened_ns = mono_ns(); }
    pgs[p].open += 1;
    if pgs[p].open >= (if p == writer { GROUP_MAX } else { READ_GROUP_MAX }) { close_group(p); }
    conns[slot].busy = true;
}

fn kept(slot: i64) -> u8[:] { view(conns[slot].msg)[..conns[slot].msg_len] }

// Sends the connection's kept request (again).
fn send_kept(slot: i64) {
    if conns[slot].write { put_request(writer, slot, kept(slot)); return; }
    enqueue_read(slot, 8);
}

// Keeps the request's messages with the connection, to send (again).
fn keep(slot: i64, m: const u8[:]) {
    let c .= conns[slot];
    if c.msg.cap < m.len { release(c.msg); c.msg = run_alloc(max(m.len, 256)); }
    let v = view(c.msg);
    for b, i in m { v[i] = b; }
    c.msg_len = m.len;
}

fn submit(slot: i64, m: const u8[:], write: bool) {
    keep(slot, m);
    conns[slot].write = write;
    send_kept(slot);
}

// ---------- batched reads ----------

// A list, tags, or enabled article read waits in the pool. Reads arriving while a batched execution is in flight
// gather there, and the next flush sends each statement's waiting reads as one execution.
fn active_tag(tag: u64) -> bool {
    let slot = (tag & 0xffffffff) as! i64;
    return slot < conns.len && conns[slot].gen == (tag >> 32) as! u32 &&
        conns[slot].fd >= 0 && !conns[slot].dead;
}

fn pooled_family(q: i64) -> i64 {
    return if q < 4 { ST_LIST_ALL + q } else if q == 4 { ST_TAGS } else if q == 5 { ST_ARTICLE } else if q == 6 { ST_FEED } else { ST_COMMENTS };
}

fn pooled_queue(fam: i64) -> i64 {
    if fam >= ST_LIST_ALL && fam < ST_LIST_ALL + 4 { return fam - ST_LIST_ALL; }
    if fam == ST_TAGS { return 4; }
    if fam == ST_ARTICLE { return 5; }
    if fam == ST_FEED { return 6; }
    assert(fam == ST_COMMENTS);
    return 7;
}

fn enqueue_read(slot: i64, q: i64) {
    let c .= conns[slot];
    assert(!c.write && c.read_node < 0);
    read_serial += 1;
    c.read_order = read_serial;
    c.busy = true;
    let n = read_nodes.alloc_index(ReadNode { tag: tag_of(slot), qid: q, prev: read_tails[q], next: -1 });
    c.read_node = n;
    if read_tails[q] >= 0 { read_nodes[read_tails[q]].next = n; } else { read_heads[q] = n; }
    read_tails[q] = n;
    if q < 8 {
        if read_batch_us > 0 && pool_count == 0 { pool_open_ns = mono_ns(); }
        pool_count += 1;
    }
}

// Queue ownership is detached before either PG admission or Conn reuse.
fn unlink_read(n: i64) {
    let r = read_nodes[n];
    if r.prev >= 0 { read_nodes[r.prev].next = r.next; } else { read_heads[r.qid] = r.next; }
    if r.next >= 0 { read_nodes[r.next].prev = r.prev; } else { read_tails[r.qid] = r.prev; }
    if r.qid < 8 { pool_count -= 1; if pool_count == 0 { pool_open_ns = 0; } }
    let slot = (r.tag & 0xffffffff) as! i64;
    if slot < conns.len && conns[slot].gen == (r.tag >> 32) as! u32 && conns[slot].read_node == n {
        conns[slot].read_node = -1;
        conns[slot].fam = -1;
    }
    read_nodes[n] = ReadNode { .. };
    read_nodes.free(n);
}

fn pending_head(q: i64) -> i64 {
    while read_heads[q] >= 0 {
        let n = read_heads[q];
        let tag = read_nodes[n].tag;
        let slot = (tag & 0xffffffff) as! i64;
        if active_tag(tag) && conns[slot].read_node == n { return n; }
        unlink_read(n);
    }
    return -1;
}

fn oldest_pool_queue() -> i64 {
    var q = -1;
    var order = 0;
    for i in 8 {
        let n = pending_head(i);
        if n < 0 { continue; }
        let slot = (read_nodes[n].tag & 0xffffffff) as! i64;
        if q < 0 || conns[slot].read_order < order { q = i; order = conns[slot].read_order; }
    }
    return q;
}

fn pool_add(slot: i64, m: const u8[:], fam: i64) {
    keep(slot, m);
    conns[slot].write = false;
    if batch_max == 0 { send_kept(slot); return; }
    conns[slot].fam = fam;
    enqueue_read(slot, pooled_queue(fam));
}

// Admit the oldest eligible direct request or pooled family. A pooled step
// submits just one batch, then compares ages again; no family/class can refill
// every released reservation ahead of older eligible work.
fn pool_flush() {
    var group: i64[>..] = [];
    loop {
        let p = least_busy_reader();
        if p < 0 { return; }
        let direct = pending_head(8);
        var q = oldest_pool_queue();
        if pool_blocked() || (read_batch_us > 0 && pool_count < batch_max &&
                mono_ns() - pool_open_ns < read_batch_us * 1000) { q = -1; }
        if direct < 0 && q < 0 { return; }
        var choose_direct = direct >= 0;
        if direct >= 0 && q >= 0 {
            let d = (read_nodes[direct].tag & 0xffffffff) as! i64;
            let n = read_heads[q];
            let s = (read_nodes[n].tag & 0xffffffff) as! i64;
            choose_direct = conns[d].read_order < conns[s].read_order;
        }
        if choose_direct {
            let slot = (read_nodes[direct].tag & 0xffffffff) as! i64;
            unlink_read(direct);
            put_request(p, slot, kept(slot));
            continue;
        }
        let fam = pooled_family(q);
        let limit = if fam == ST_ARTICLE || fam == ST_COMMENTS { min(batch_max, 32) } else { batch_max };
        group.clear();
        while group.len < limit {
            let n = pending_head(q);
            if n < 0 { break; }
            let slot = (read_nodes[n].tag & 0xffffffff) as! i64;
            unlink_read(n);
            group.push(slot);
        }
        dispatch(group, fam, p);
    }
}

// One execution for the group, answered to its first member, which hands each member its rows.
fn dispatch(group: const i64[:], fam: i64, p: i64) {
    let lead = group[0];
    conns[lead].pooled = true;
    in_flight += 1;
    if group.len == 1 { put_request(p, lead, kept(lead)); return; }
    for s, i in group { conns[s].co_next = if i + 1 < group.len { group[i + 1] } else { -1 }; }
    conns[lead].lead = true;
    if fam == ST_TAGS { put_request(p, lead, kept(lead)); return; }      // the same statement answers them all
    if fam == ST_ARTICLE || fam == ST_COMMENTS {
        var m: u8[>..] = [];
        let b = bind_begin(m, if fam == ST_ARTICLE { ST_BATCH_ARTICLE } else { ST_BATCH_COMMENTS }, 2);
        for k in 2 {
            let at = param_array_begin(m, if k == 0 { OID_INT8 } else { OID_TEXT }, group.len);
            for s in group { m.append(bind_param(kept(s), k)); }
            param_array_end(m, at);
        }
        bind_end(m, b);
        put_request(p, lead, m);
        return;
    }
    // Feed pages depend on the viewer. Batch their executions without the
    // non-viewer duplicate heuristic used for public lists; all four args are int8.
    if fam == ST_FEED {
        var m: u8[>..] = [];
        let b = bind_begin(m, ST_BATCH_FEED, 4);
        for k in 4 {
            let at = param_array_begin(m, OID_INT8, group.len);
            for s in group { m.append(bind_param(kept(s), k)); }
            param_array_end(m, at);
        }
        bind_end(m, b);
        put_request(p, lead, m);
        return;
    }
    // Shared enrichment pays when at most half the members ask for a page no other member asks for.
    var rests: const u8[:][>..] = [];
    for s in group { rests.push(bind_rest(kept(s))); }
    var unique = 0;
    for rest, i in rests {
        var seen = false;
        for j in i { if rests[j] == rest { seen = true; break; } }
        if !seen { unique += 1; }
    }
    let base = if unique * 2 <= group.len { ST_SHARE_ALL } else { ST_BATCH_ALL };
    let np = list_params(fam);
    var m: u8[>..] = [];
    let b = bind_begin(m, base + fam - ST_LIST_ALL, np);
    for k in np {
        let at = param_array_begin(m, if k < 3 { OID_INT8 } else { OID_TEXT }, group.len);
        for s in group { m.append(bind_param(kept(s), k)); }
        param_array_end(m, at);
    }
    bind_end(m, b);
    put_request(p, lead, m);
}

// The members of a batched execution, its lead first, unchained.
fn unchain(lead: i64) -> i64[>..] {
    var group: i64[>..] = [];
    var s = lead;
    while s >= 0 {
        group.push(s);
        let next = conns[s].co_next;
        conns[s].co_next = -1;
        conns[s].lead = false;
        s = next;
    }
    return group;
}

fn deliver(slot: i64, rows: const u8[:]) {
    if conns[slot].dead { free_conn(slot); } else { answer(slot, rows); }
}

// The last column of a DataRow, an int8: a batched row's member, counted from 1.
fn last_int(d: const u8[:]) -> i64 {
    var r = row(d);
    for i in read16(d, 5) - 1 { col_skip(r); }
    return col_int(r);
}

// A request's rows came back: a batch's rows are in member order, so each member's are one run of them.
fn finish(slot: i64, rows: const u8[:]) {
    if !conns[slot].lead { deliver(slot, rows); return; }
    let tags = conns[slot].kind == K_TAGS;
    let group = unchain(slot);
    if tags {
        for s in group { deliver(s, rows); }
        return;
    }
    var k = 0;
    var from = 0;
    var at = 0;
    while at < rows.len {
        let n = read32(rows, at + 1) + 1;
        if rows[at] == 'D' {
            let ord = last_int(rows[at..at + n]);
            while k < group.len - 1 && ord > k + 1 {
                deliver(group[k], rows[from..at]);
                k += 1;
                from = at;
            }
        }
        at += n;
    }
    while k < group.len {
        deliver(group[k], rows[from..]);
        k += 1;
        from = rows.len;
    }
}

// A batched execution's group failed: every member goes again on its own.
fn resend(slot: i64) {
    for s in unchain(slot) {
        if conns[s].dead { free_conn(s); } else { send_kept(s); }
    }
}

fn set_ctx(slot: i64, data: const u8[:]) {
    let c .= conns[slot];
    if c.ctx.cap < data.len { release(c.ctx); c.ctx = run_alloc(max(data.len, 128)); }
    let v = view(c.ctx);
    for b, i in data { v[i] = b; }
    c.ctx_len = data.len;
}

fn ctx(slot: i64) -> u8[:] { view(conns[slot].ctx)[..conns[slot].ctx_len] }

fn pg_readable(p: i64) {
    loop {
        let room = spare(pgs[p].inb, RECV_SIZE);
        let n = sys_recv(pgs[p].fd, room, MSG_DONTWAIT);
        if n == 0 { log("postgres closed the connection"); exit(1); }
        if n < 0 { break; }
        grew(pgs[p].inb, n);
        if n < RECV_SIZE { break; }
    }
    loop {
        let w = waiting(pgs[p].inb);
        var at = pgs[p].scan;
        var z = -1;
        loop {
            let n = msg_len(w[at..]);
            if n == 0 { break; }
            if w[at] == 'Z' { z = at + n; break; }
            at += n;
        }
        if z < 0 { pgs[p].scan = at; break; }
        group_done(p, w[..z]);
        consume(pgs[p].inb, z);
        pgs[p].scan = 0;
    }
}

fn pg_flush() {
    pool_flush();
    for p in pgs.len {
        if pgs[p].open > 0 && (p != writer || write_batch_us == 0 ||
                mono_ns() - pgs[p].opened_ns >= write_batch_us * 1000) {
            close_group(p);
        }
        while pgs[p].sendable > 0 {
            let n = sys_send(pgs[p].fd, waiting(pgs[p].out)[..pgs[p].sendable], MSG_DONTWAIT | MSG_NOSIGNAL);
            if n <= 0 { break; }
            consume(pgs[p].out, n);
            pgs[p].sendable -= n;
        }
    }
}

// One Sync group's answer, up to and including its ReadyForQuery.
fn group_done(p: i64, data: const u8[:]) {
    assert(pgs[p].groups > 0);
    pgs[p].groups -= 1;
    var members: i64[..64] = [];
    loop {
        let s = pgs[p].head;
        assert(s >= 0);
        pgs[p].head = conns[s].next;
        members.push(s);
        if conns[s].group_end { break; }
    }
    if pgs[p].head < 0 { pgs[p].tail = -1; }
    pgs[p].waiting -= members.len;
    for s in members {
        if conns[s].pooled { conns[s].pooled = false; in_flight -= 1; }
    }

    // An error rolls the whole group back: find whose statement failed.
    var at = 0;
    var k = 0;
    var done = 0;
    var failed = -1;
    var err_at = 0;
    while at < data.len {
        let n = read32(data, at + 1) + 1;
        let t = data[at];
        if t == 'C' {
            done += 1;
            if done == conns[members[k]].nstmt { k += 1; done = 0; }
        } else if t == 'E' {
            failed = k;
            err_at = at;
            break;
        }
        at += n;
    }
    if failed >= 0 {
        let code, text = error_fields(data[err_at..err_at + read32(data, err_at + 1) + 1]);
        for s, i in members {
            if conns[s].lead { resend(s); continue; }
            if conns[s].dead { free_conn(s); continue; }
            if i == failed { pend_failed(s, code, text); } else { send_kept(s); }
        }
        return;
    }

    at = 0;
    k = 0;
    done = 0;
    var start = 0;
    while at < data.len && k < members.len {
        let n = read32(data, at + 1) + 1;
        if data[at] == 'C' {
            done += 1;
            let s = members[k];
            if done == conns[s].nstmt {
                finish(s, data[start..at]);
                k += 1;
                done = 0;
            }
            start = at + n;
        }
        at += n;
    }
}

fn pend_failed(slot: i64, code: const u8[:], text: const u8[:]) {
    let c .= conns[slot];
    if (code == "40P01" || code == "40001") && c.tries < 5 {
        c.tries += 1;
        send_kept(slot);
    } else if code == "23505" {
        fail(slot, 422, "username or email is already taken");
    } else if code == "55P03" || code == "57014" || code == "40P01" || code == "40001" {
        fail(slot, 503, "the database is busy");
    } else {
        log(str("statement failed: ", code, " ", text));
        fail(slot, 500, "internal error");
    }
}

// ---------- bcrypt ----------

fn hash_job(slot: i64, verify: bool, password: const u8[:], hash: const u8[:]) {
    var j = BJob { tag: tag_of(slot), enqueued_ns: mono_ns(), reply_fd: reply_write, verify: verify, password: "", hash: "" };
    j.password.append(password);
    j.hash.append(hash[..min(hash.len, 60)]);
    conns[slot].busy = true;
    qput(j);
}

fn replies() {
    var b: u8[4320] = [0; 4320];             // 60 replies
    loop {
        let n = sys_read(reply_read, b);
        if n <= 0 { return; }
        var at = 0;
        while at + REPLY_SIZE <= n {
            let r = parse_reply(b[at..at + REPLY_SIZE]);
            at += REPLY_SIZE;
            let slot = (r.tag & 0xffffffff) as! i64;
            if conns[slot].gen != (r.tag >> 32) as! u32 { continue; }
            if conns[slot].dead { free_conn(slot); continue; }
            hashed(slot, r);
        }
        if n < b.len { return; }
    }
}

fn hashed(slot: i64, r: BReply) {
    let c .= conns[slot];
    if c.kind == K_LOGIN_CHECK {
        if !r.ok { fail(slot, 401, "invalid email or password"); return; }
        reply(slot, view(c.msg)[..c.msg_len]);
        return;
    }
    if !r.ok || r.hash.len != 60 { fail(slot, 500, "internal error"); return; }
    let v = view(c.msg);
    for b, i in r.hash { v[c.hash_at + i] = b; }
    c.kind = if c.kind == K_REGISTER_HASH { K_REGISTER } else { K_UPDATE_USER };
    send_kept(slot);
}

// ---------- the loop ----------

thread_fn worker(index: i64) {
    for i in RECV_SIZE { scratch.push(0); }
    epfd = sys_epoll_create1(O_CLOEXEC);
    var fds: i32[2] = [-1, -1];
    if sys_pipe2(fds, O_NONBLOCK | O_CLOEXEC) != 0 { log("pipe2 failed"); exit(1); }
    reply_read = fds[0];
    reply_write = fds[1];

    var stmts: u8[>..] = [];
    prepare_all(stmts);
    let common = "jit\x00off\x00plan_cache_mode\x00force_generic_plan\x00max_parallel_workers_per_gather\x000\x00statement_timeout\x0030s\x00";
    for i in readers + 1 {
        let settings = if i < readers { str(common) } else { str(common, "lock_timeout\x002s\x00") };
        var fd: i32 = -1;
        for attempt in 120 {
            fd = pg_connect(pg_addr, pg_port, pg_user, pg_password, pg_db, settings, stmts);
            if fd >= 0 { break; }
            nap_ms(500);
        }
        if fd < 0 { log("could not reach postgres"); exit(1); }
        pgs.push(Pgc { fd: fd, .. });
        epoll_add(epfd, fd, EPOLLIN | EPOLLOUT | EPOLLET, KIND_PG << 56 | (i as u64));
    }
    writer = readers;

    let lfd = listen_on(listen_addr, listen_port);
    if lfd < 0 { log("could not listen"); exit(1); }
    epoll_add(epfd, lfd, EPOLLIN, KIND_LISTENER << 56);
    epoll_add(epfd, reply_read, EPOLLIN, KIND_PIPE << 56);

    var evs: EpollEvent[256] = [EpollEvent { events: 0, data: 0 }; 256];
    loop {
        let n = sys_epoll_wait(epfd, evs, poll_wait_ms());
        now_ms = wall_ns() / 1000000;
        for i in n as i64 {
            let e = evs[i];
            let kind = e.data >> 56;
            if kind == KIND_CLIENT {
                let slot = (e.data & 0xffffffff) as! i64;
                if slot < conns.len && !gone(slot) && ((conns[slot].gen as u64) & 0xffffff) == (e.data >> 32 & 0xffffff) {
                    client_event(slot, e.events);
                }
            } else if kind == KIND_PG {
                pg_readable((e.data & 0xffffffff) as! i64);
            } else if kind == KIND_PIPE {
                replies();
            } else {
                accept_all(lfd);
            }
        }
        for t in ready {
            let slot = (t & 0xffffffff) as! i64;
            if !gone(slot) && conns[slot].gen == (t >> 32) as! u32 && !conns[slot].busy { drain(slot); }
        }
        ready.clear();
        pg_flush();
    }
}
