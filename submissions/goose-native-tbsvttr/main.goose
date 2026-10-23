// Conduit (the RealWorld API) for the multicore server challenge: epoll event loops that each own their
// connections, pipelined Postgres, and bcrypt on threads of its own.
//
// Environment: DATABASE_URL, JWT_SECRET, HOST, PORT; WORKERS (event loops, 2), PG_READERS (read connections per
// loop, 3; each loop also has one writer), HASHERS (bcrypt threads, 2), BCRYPT_BATCH_MS (250), READ_BATCH (most
// list reads one execution answers, 32; 0 off), READ_HOLD (batches in flight before reads wait, 1),
// WRITE_BATCH_US (writer collection, 1000; 0 disables it), READ_BATCH_US (pending read collection, 5000 by default),
// PG_READ_GROUPS (outstanding Sync groups per reader, 4; 0 unbounded), and ARTICLE_BATCH (1 by default;
// 1 lets queued article reads share metadata within one execution).

import bcrypt;
import crypto;
import http;
import os;
import routes;
import server;
import std;
import sys;

fn env_or(name: const u8[:], fallback: const u8[:]) -> u8[>..] {
    var v: u8[>..] = [];
    if !env(name, v) || v.len == 0 { v.clear(); v.append(fallback); }
    return v;
}

fn env_int(name: const u8[:], fallback: i64) -> i64 {
    let v = env_or(name, "");
    if v.len == 0 { return fallback; }
    let n, ok = parse_uint(v);
    if !ok || n < 1 { abort(str(name, " must be a positive integer")); }
    return n;
}

fn address(host: const u8[:]) -> u32 {
    if host == "localhost" { return 0x0100007f; }
    let a, ok = parse_ipv4(host);
    if !ok { abort(str("not an IPv4 address: ", host)); }
    return a;
}

fn decoded(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    if !pct_decode(out, s, false) { abort("DATABASE_URL has a bad escape"); }
    return out;
}

// postgres://user:password@host:port/database
fn parse_database_url(url: const u8[:]) {
    let scheme = find(url, "://");
    if scheme < 0 { abort("DATABASE_URL must be postgres://user:password@host:port/database"); }
    var rest = url[scheme + 3..];
    let q = find(rest, "?");
    if q >= 0 { rest = rest[..q]; }
    var at = -1;
    for c, i in rest { if c == '@' { at = i; } }
    let slash = find(rest[at + 1..], "/");
    let hostport = if slash < 0 { rest[at + 1..] } else { rest[at + 1..at + 1 + slash] };
    if slash >= 0 { let db = decoded(rest[at + 2 + slash..]); pg_db.append(db[..min(db.len, 127)]); }
    if at >= 0 {
        let info = rest[..at];
        let colon = find(info, ":");
        let user = decoded(if colon < 0 { info } else { info[..colon] });
        pg_user.append(user[..min(user.len, 127)]);
        if colon >= 0 { let pw = decoded(info[colon + 1..]); pg_password.append(pw[..min(pw.len, 255)]); }
    }
    let colon = find(hostport, ":");
    pg_addr = address(if colon < 0 { hostport } else { hostport[..colon] });
    if colon >= 0 {
        let port, ok = parse_uint(hostport[colon + 1..]);
        if !ok || port > 65535 { abort("DATABASE_URL has a bad port"); }
        pg_port = port;
    }
    if pg_db.len == 0 { pg_db.append(pg_user); }
}

fn main() {
    let url = env_or("DATABASE_URL", "");
    let secret = env_or("JWT_SECRET", "");
    if url.len == 0 || secret.len == 0 { abort("DATABASE_URL and JWT_SECRET are required"); }
    parse_database_url(url);
    jwt_key.append(secret);
    let host = env_or("HOST", "0.0.0.0");
    let port = env_int("PORT", 3000);
    listen_addr = if host == "0.0.0.0" { 0 } else { address(host) };
    listen_port = port;
    let workers = env_int("WORKERS", 2);
    readers = env_int("PG_READERS", 3);
    // Each loop owns readers plus one writer. Check before adding or multiplying
    // untrusted environment integers, and leave five connections for the box.
    if readers > 94 { abort("PG_READERS leaves no room within the 95-connection limit"); }
    if workers > 95 / (readers + 1) { abort("WORKERS * (PG_READERS + 1) must be at most 95"); }
    let hashers = env_int("HASHERS", 2);
    batch_ms = env_int("BCRYPT_BATCH_MS", 250);
    write_batch_us = if env_or("WRITE_BATCH_US", "") == "0" { 0 } else { env_int("WRITE_BATCH_US", 1000) };
    if write_batch_us > 1000000 { abort("WRITE_BATCH_US must be at most 1000000"); }
    read_batch_us = if env_or("READ_BATCH_US", "5000") == "0" { 0 } else { env_int("READ_BATCH_US", 5000) };
    if read_batch_us > 1000000 { abort("READ_BATCH_US must be at most 1000000"); }
    read_group_max = if env_or("PG_READ_GROUPS", "4") == "0" { 0 } else { env_int("PG_READ_GROUPS", 4) };
    batch_max = if env_or("READ_BATCH", "") == "0" { 0 } else { env_int("READ_BATCH", 32) };
    batch_hold = env_int("READ_HOLD", 1);
    let article = env_or("ARTICLE_BATCH", "1");
    if article != "0" && article != "1" { abort("ARTICLE_BATCH must be 0 or 1"); }
    article_batch = article == "1";
    raise_nofile();

    var ids: i64[>..] = [];
    for i in hashers { ids.push(thread_spawn(hasher)); }
    for i in workers { ids.push(thread_spawn(worker, i)); }
    print("conduit (goose) on ", host, ":", port, ", ", workers, " loops, ", readers, " readers and 1 writer each, ",
          hashers, " bcrypt threads");
    for id in ids { thread_wait(id); }
}
