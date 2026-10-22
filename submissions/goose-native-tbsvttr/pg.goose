// The Postgres v3 wire protocol: a blocking sign-in (cleartext or SCRAM-SHA-256), statements prepared once, then
// requests as Bind/Execute messages with binary parameters and results, and the reading of what comes back.

import base64;
import crypto;
import std;
import sys;

let OID_INT8 = 20;
let OID_TEXT = 25;
let OID_TEXT_ARRAY = 1009;
let OID_INT8_ARRAY = 1016;

fn be32(out: u8[>..]&, v: i64) {
    out.push((v >> 24 & 0xff) as! u8); out.push((v >> 16 & 0xff) as! u8);
    out.push((v >> 8 & 0xff) as! u8); out.push((v & 0xff) as! u8);
}

fn be16(out: u8[>..]&, v: i64) { out.push((v >> 8 & 0xff) as! u8); out.push((v & 0xff) as! u8); }

fn read32(b: const u8[:], at: i64) -> i64 {
    let v = (b[at] as i64) << 24 | (b[at + 1] as i64) << 16 | (b[at + 2] as i64) << 8 | b[at + 3];
    return if v >= 0x80000000 { v - 0x100000000 } else { v };
}

fn read16(b: const u8[:], at: i64) -> i64 { (b[at] as i64) << 8 | b[at + 1] }

fn read64(b: const u8[:]) -> i64 {
    var v: u64 = 0;
    for i in 8 { v = v << 8 | b[i]; }
    return v as! i64;
}

// Writes the 4-byte length of the message that starts at `start` (its type byte) and runs to the end of out.
fn seal(out: u8[:], start: i64) {
    let n = out.len - start - 1;
    out[start + 1] = (n >> 24 & 0xff) as! u8; out[start + 2] = (n >> 16 & 0xff) as! u8;
    out[start + 3] = (n >> 8 & 0xff) as! u8; out[start + 4] = (n & 0xff) as! u8;
}

fn begin_msg(out: u8[>..]&, kind: u8) -> i64 {
    let start = out.len;
    out.push(kind);
    be32(out, 0);
    return start;
}

// ---------- requests ----------

// Bind of a prepared statement with nparams binary parameters; the parameters follow, then bind_end.
fn bind_begin(out: u8[>..]&, stmt: i64, nparams: i64) -> i64 {
    let start = begin_msg(out, 'B');
    out.push(0);                                   // the unnamed portal
    format(out, "s", stmt); out.push(0);
    be16(out, 1); be16(out, 1);                    // every parameter binary
    be16(out, nparams);
    return start;
}

fn param_int(out: u8[>..]&, v: i64) {
    be32(out, 8);
    for i in 8 { out.push((v >> (56 - 8 * i) & 0xff) as! u8); }
}

fn param_text(out: u8[>..]&, s: const u8[:]) { be32(out, s.len); out.append(s); }

fn param_null(out: u8[>..]&) { be32(out, -1); }

// A text[] of the n strings packed in `items` with their ends in `ends`.
fn param_text_array(out: u8[>..]&, items: const u8[:], ends: const i64[:]) {
    let at = out.len;
    be32(out, 0);
    if ends.len == 0 {
        be32(out, 0); be32(out, 0); be32(out, OID_TEXT);
    } else {
        be32(out, 1); be32(out, 0); be32(out, OID_TEXT);
        be32(out, ends.len); be32(out, 1);
        var from = 0;
        for e in ends { be32(out, e - from); out.append(items[from..e]); from = e; }
    }
    let n = out.len - at - 4;
    out[at] = (n >> 24 & 0xff) as! u8; out[at + 1] = (n >> 16 & 0xff) as! u8;
    out[at + 2] = (n >> 8 & 0xff) as! u8; out[at + 3] = (n & 0xff) as! u8;
}

// Where the parameter values of a Bind made by bind_begin start, and how many there are.
fn bind_values(m: const u8[:]) -> i64, i64 {
    var at = 5;
    while m[at] != 0 { at += 1; }                  // the portal
    at += 1;
    while m[at] != 0 { at += 1; }                  // the statement
    at += 1;
    at += 2 + 2 * read16(m, at);
    return at + 2, read16(m, at);
}

// The length of the value (length prefix included) at `at`.
fn value_size(m: const u8[:], at: i64) -> i64 { 4 + max(read32(m, at), 0) }

// Parameter k of a Bind made by bind_begin, with its length prefix.
fn bind_param(m: const u8[:], k: i64) -> const u8[:] {
    var at, n = bind_values(m);
    for i in k { at += value_size(m, at); }
    return m[at..at + value_size(m, at)];
}

// The parameters after the first, as one run of bytes: equal for two Binds of a statement that differ only in $1.
fn bind_rest(m: const u8[:]) -> const u8[:] {
    var at, n = bind_values(m);
    at += value_size(m, at);
    var end = at;
    for i in n - 1 { end += value_size(m, end); }
    return m[at..end];
}

// A one-dimensional binary array parameter of n elements of type elem; the elements (each with its length prefix)
// follow, then param_array_end(out, at).
fn param_array_begin(out: u8[>..]&, elem: i64, n: i64) -> i64 {
    let at = out.len;
    be32(out, 0);
    be32(out, 1); be32(out, 0); be32(out, elem);
    be32(out, n); be32(out, 1);
    return at;
}

fn param_array_end(out: u8[>..]&, at: i64) {
    let n = out.len - at - 4;
    out[at] = (n >> 24 & 0xff) as! u8; out[at + 1] = (n >> 16 & 0xff) as! u8;
    out[at + 2] = (n >> 8 & 0xff) as! u8; out[at + 3] = (n & 0xff) as! u8;
}

// Ends the Bind (every result column binary) and executes the portal.
fn bind_end(out: u8[>..]&, start: i64) {
    be16(out, 1); be16(out, 1);
    seal(out, start);
    let e = begin_msg(out, 'E');
    out.push(0);
    be32(out, 0);
    seal(out, e);
}

fn sync(out: u8[>..]&) { out.push('S'); be32(out, 4); }

// ---------- responses ----------

// The length of the complete message at the start of b (type byte included), or 0 when it hasn't all arrived.
fn msg_len(b: const u8[:]) -> i64 {
    if b.len < 5 { return 0; }
    let n = read32(b, 1) + 1;
    return if b.len >= n { n } else { 0 };
}

// A DataRow's columns, read in order.
struct Row { data: const u8[:], pos: i64 = 7 }

fn row(msg: const u8[:]) -> Row { Row { data: msg, .. } }

// The next column, and false when it is NULL.
fn col(r: Row&) -> const u8[:], bool {
    let n = read32(r.data, r.pos);
    r.pos += 4;
    if n < 0 { return "", false; }
    let v = r.data[r.pos..r.pos + n];
    r.pos += n;
    return v, true;
}

fn col_int(r: Row&) -> i64 { let v, ok = col(r); return if ok { read64(v) } else { 0 }; }
fn col_bool(r: Row&) -> bool { let v, ok = col(r); return ok && v[0] == 1; }
fn col_skip(r: Row&) { col(r); }

// F(msg) for each DataRow among the messages in b.
fn each_row<F>(b: const u8[:]) {
    var at = 0;
    while at < b.len {
        let n = read32(b, at + 1) + 1;
        if b[at] == 'D' { F(b[at..at + n]); }
        at += n;
    }
}

// The SQLSTATE of an ErrorResponse, and its message.
fn error_fields(msg: const u8[:]) -> const u8[:], const u8[:] {
    var code = msg[0..0];
    var text = msg[0..0];
    var at = 5;
    while at < msg.len && msg[at] != 0 {
        let kind = msg[at];
        var end = at + 1;
        while end < msg.len && msg[end] != 0 { end += 1; }
        if kind == 'C' { code = msg[at + 1..end]; }
        if kind == 'M' { text = msg[at + 1..end]; }
        at = end + 1;
    }
    return code, text;
}

// ---------- the blocking start ----------

fn send_all(fd: i32, data: const u8[:]) -> bool {
    var done = 0;
    while done < data.len {
        let n = sys_send(fd, data[done..], MSG_NOSIGNAL);
        if n <= 0 { return false; }
        done += n;
    }
    return true;
}

fn recv_exact(fd: i32, out: u8[>..]&, n: i64) -> bool {
    let from = out.len;
    out.resize(from + n, 0);
    var done = 0;
    while done < n {
        let k = sys_recv(fd, out[from + done..from + n], 0);
        if k <= 0 { return false; }
        done += k;
    }
    return true;
}

// The next whole message into msg (type byte and length included); false when the connection ends.
fn read_msg(fd: i32, msg: u8[>..]&) -> bool {
    msg.clear();
    if !recv_exact(fd, msg, 5) { return false; }
    return recv_exact(fd, msg, read32(msg, 1) - 4);
}

fn fail(what: const u8[:], detail: const u8[:]) {
    write_stderr_line(str("postgres: ", what, " ", detail));
}

fn write_stderr_line(s: const u8[:]) {
    sys_write(2, s);
    sys_write(2, "\n");
}

fn error_text(msg: const u8[:]) -> u8[>..] {
    let code, text = error_fields(msg);
    return str(code, " ", text);
}

// Comma-separated "k=value" attributes of a SCRAM message.
fn scram_attr(s: const u8[:], key: u8) -> const u8[:] {
    var at = 0;
    while at < s.len {
        var end = at;
        while end < s.len && s[end] != ',' { end += 1; }
        if end - at >= 2 && s[at] == key && s[at + 1] == '=' { return s[at + 2..end]; }
        at = end + 1;
    }
    return "";
}

fn scram(fd: i32, password: const u8[:], msg: u8[>..]&) -> bool {
    var raw: u8[18] = [0; 18];
    random_bytes(raw);
    var nonce: u8[>..] = [];
    base64::encode(nonce, raw);
    let first_bare = str("n=,r=", nonce);
    let first = str("n,,", first_bare);
    var out: u8[>..] = [];
    let p = begin_msg(out, 'p');
    out.append("SCRAM-SHA-256"); out.push(0);
    be32(out, first.len); out.append(first);
    seal(out, p);
    if !send_all(fd, out) { return false; }

    if !read_msg(fd, msg) || msg[0] != 'R' || read32(msg, 5) != 11 { fail("SCRAM", "no server-first message"); return false; }
    let server_first = str(msg[9..]);
    let full_nonce = scram_attr(server_first, 'r');
    var salt: u8[>..] = [];
    let iterations, iok = parse_int(scram_attr(server_first, 'i'));
    if !starts_with(full_nonce, nonce) || !base64::decode(salt, scram_attr(server_first, 's')) || !iok {
        fail("SCRAM", "bad server-first message");
        return false;
    }
    let final_bare = str("c=biws,r=", full_nonce);
    let auth_message = str(first_bare, ",", server_first, ",", final_bare);

    var salted: u8[32] = [0; 32];
    pbkdf2(password, salt, iterations, salted);
    let salted_key = hmac_key(salted);
    var client_key: u8[32] = [0; 32];
    hmac1(salted_key, "Client Key", client_key);
    var stored_key: u8[32] = [0; 32];
    sha256_of(client_key, stored_key);
    var signature: u8[32] = [0; 32];
    let stored = hmac_key(stored_key);
    hmac1(stored, auth_message, signature);
    var proof: u8[32] = [0; 32];
    for i in 32 { proof[i] = client_key[i] ^ signature[i]; }

    var final = str(final_bare, ",p=");
    base64::encode(final, proof);
    out.clear();
    let q = begin_msg(out, 'p');
    out.append(final);
    seal(out, q);
    if !send_all(fd, out) { return false; }
    if !read_msg(fd, msg) { return false; }
    if msg[0] == 'E' { fail("sign-in refused:", error_text(msg)); return false; }
    return msg[0] == 'R' && read32(msg, 5) == 12;
}

// Signs in with the given session settings ("name\0value\0" pairs), prepares the statements, and returns the
// connected socket, or -1.
fn pg_connect(addr: u32, port: i64, user: const u8[:], password: const u8[:], db: const u8[:],
              settings: const u8[:], stmts: const u8[:]) -> i32 {
    let fd = connect_to(addr, port);
    if fd < 0 { fail("connect failed", ""); return -1; }
    var out: u8[>..] = [];
    be32(out, 0);
    be32(out, 196608);
    out.append("user"); out.push(0); out.append(user); out.push(0);
    out.append("database"); out.push(0); out.append(db); out.push(0);
    out.append(settings);
    out.push(0);
    let n = out.len;
    out[0] = (n >> 24 & 0xff) as! u8; out[1] = (n >> 16 & 0xff) as! u8;
    out[2] = (n >> 8 & 0xff) as! u8; out[3] = (n & 0xff) as! u8;
    if !send_all(fd, out) { sys_close(fd); return -1; }

    var msg: u8[>..] = [];
    loop {
        if !read_msg(fd, msg) { fail("connection closed during sign-in", ""); sys_close(fd); return -1; }
        if msg[0] == 'E' { fail("sign-in refused:", error_text(msg)); sys_close(fd); return -1; }
        if msg[0] == 'Z' { break; }
        if msg[0] != 'R' { continue; }
        let code = read32(msg, 5);
        if code == 3 {
            out.clear();
            let p = begin_msg(out, 'p');
            out.append(password); out.push(0);
            seal(out, p);
            if !send_all(fd, out) { sys_close(fd); return -1; }
        } else if code == 10 {
            if find(msg[9..], "SCRAM-SHA-256") < 0 { fail("no SCRAM-SHA-256 offered", ""); sys_close(fd); return -1; }
            if !scram(fd, password, msg) { sys_close(fd); return -1; }
        } else if code != 0 && code != 12 {
            fail("unsupported authentication", str(code));
            sys_close(fd); return -1;
        }
    }

    if !send_all(fd, stmts) { sys_close(fd); return -1; }
    loop {
        if !read_msg(fd, msg) { sys_close(fd); return -1; }
        if msg[0] == 'E' { fail("prepare failed:", error_text(msg)); sys_close(fd); return -1; }
        if msg[0] == 'Z' { break; }
    }
    return fd;
}

// A Parse of statement `name` with its parameter types, appended to out.
fn parse_stmt(out: u8[>..]&, name: i64, sql: const u8[:], types: const i64[:]) {
    let p = begin_msg(out, 'P');
    format(out, "s", name); out.push(0);
    out.append(sql); out.push(0);
    be16(out, types.len);
    for t in types { be32(out, t); }
    seal(out, p);
}
