// bcrypt ($2b$), with up to five hashes interleaved on one thread. Blowfish is bound by load latency: each round
// waits for the previous round's four S-box loads, so independent hashes ("lanes") fill each other's stalls. Every
// hash is still a full bcrypt of its own cost.
//
// The hashing threads take jobs from the queue for BJob and write each answer to the pipe the job names, which
// sits in the asking event loop's epoll set.

import bcrypt_tables;
import std;
import sys;

struct Lane { s0: u32[256], s1: u32[256], s2: u32[256], s3: u32[256], p: u32[18] }

// "OrpheanBeholderScryDoubt" as big-endian words.
let CTEXT: u32[6] = [0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274];

inline fn f(st: Lane&, x: u32) -> u32 {
    ((st.s0[x >> 24] + st.s1[(x >> 16) & 0xff]) ^ st.s2[(x >> 8) & 0xff]) + st.s3[x & 0xff]
}

// One Blowfish encryption of (l, r) in place. Each round XORs its P word in before F's result arrives, keeping
// that XOR off the chain the round waits on.
inline fn encipher(st: Lane&, l: u32&, r: u32&) {
    var a = l ^ st.p[0];
    var b = r;
    const for <J> in [1, 3, 5, 7, 9, 11, 13, 15] {
        b ^= st.p[J]; b ^= f(st, a);
        a ^= st.p[J + 1]; a ^= f(st, b);
    }
    l = b ^ st.p[17];
    r = a;
}

// The same for five lanes, their rounds interleaved: lane k's halves are l[k], r[k].
inline fn encipher5(st: Lane[5]&, l: u32[5]&, r: u32[5]&) {
    const for <K> in [0, 1, 2, 3, 4] { l[K] ^= st[K].p[0]; }
    const for <J> in [1, 3, 5, 7, 9, 11, 13, 15] {
        const for <K> in [0, 1, 2, 3, 4] { r[K] ^= st[K].p[J]; r[K] ^= f(st[K], l[K]); }
        const for <K> in [0, 1, 2, 3, 4] { l[K] ^= st[K].p[J + 1]; l[K] ^= f(st[K], r[K]); }
    }
    const for <K> in [0, 1, 2, 3, 4] {
        let t = r[K] ^ st[K].p[17];
        r[K] = l[K];
        l[K] = t;
    }
}

fn init(st: Lane&) {
    st.s0 = S0; st.s1 = S1; st.s2 = S2; st.s3 = S3; st.p = P0;
}

// Blowfish_expandstate: the key into P, then P and S re-derived while mixing in the salt. Once per hash.
fn expand_state(st: Lane&, key: u32[18]&, salt: u32[18]&) {
    for i in 18 { st.p[i] ^= key[i]; }
    var l: u32 = 0;
    var r: u32 = 0;
    var j = 0;                                    // the 16-byte salt repeats every 4 words
    for h in 9 {
        l ^= salt[j]; r ^= salt[j + 1]; j = (j + 2) % 4;
        encipher(st, l, r);
        st.p[2 * h] = l; st.p[2 * h + 1] = r;
    }
    const for <B> in [0, 1, 2, 3] {
        for h in 128 {
            l ^= salt[j]; r ^= salt[j + 1]; j = (j + 2) % 4;
            encipher(st, l, r);
            if B == 0 { st.s0[2 * h] = l; st.s0[2 * h + 1] = r; }
            else if B == 1 { st.s1[2 * h] = l; st.s1[2 * h + 1] = r; }
            else if B == 2 { st.s2[2 * h] = l; st.s2[2 * h + 1] = r; }
            else { st.s3[2 * h] = l; st.s3[2 * h + 1] = r; }
        }
    }
}

// Blowfish_expand0state for one lane: w into P, then P and S re-derived from a zero block.
fn expand0(st: Lane&, w: u32[18]&) {
    for i in 18 { st.p[i] ^= w[i]; }
    var l: u32 = 0;
    var r: u32 = 0;
    for h in 9 { encipher(st, l, r); st.p[2 * h] = l; st.p[2 * h + 1] = r; }
    for h in 128 { encipher(st, l, r); st.s0[2 * h] = l; st.s0[2 * h + 1] = r; }
    for h in 128 { encipher(st, l, r); st.s1[2 * h] = l; st.s1[2 * h + 1] = r; }
    for h in 128 { encipher(st, l, r); st.s2[2 * h] = l; st.s2[2 * h + 1] = r; }
    for h in 128 { encipher(st, l, r); st.s3[2 * h] = l; st.s3[2 * h + 1] = r; }
}

// The same for five lanes together; lane k reads w[k].
fn expand0_5(st: Lane[5]&, w: u32[18][5]&) {
    for i in 18 { const for <K> in [0, 1, 2, 3, 4] { st[K].p[i] ^= w[K][i]; } }
    var l: u32[5] = [0; 5];
    var r: u32[5] = [0; 5];
    for h in 9 {
        encipher5(st, l, r);
        const for <K> in [0, 1, 2, 3, 4] { st[K].p[2 * h] = l[K]; st[K].p[2 * h + 1] = r[K]; }
    }
    for h in 128 {
        encipher5(st, l, r);
        const for <K> in [0, 1, 2, 3, 4] { st[K].s0[2 * h] = l[K]; st[K].s0[2 * h + 1] = r[K]; }
    }
    for h in 128 {
        encipher5(st, l, r);
        const for <K> in [0, 1, 2, 3, 4] { st[K].s1[2 * h] = l[K]; st[K].s1[2 * h + 1] = r[K]; }
    }
    for h in 128 {
        encipher5(st, l, r);
        const for <K> in [0, 1, 2, 3, 4] { st[K].s2[2 * h] = l[K]; st[K].s2[2 * h + 1] = r[K]; }
    }
    for h in 128 {
        encipher5(st, l, r);
        const for <K> in [0, 1, 2, 3, 4] { st[K].s3[2 * h] = l[K]; st[K].s3[2 * h + 1] = r[K]; }
    }
}

// The 18 words the key schedule reads from data, taken cyclically as OpenBSD's Blowfish_stream2word does.
fn stream_words(data: const u8[:], words: u32[18]&) {
    var j = 0;
    for i in 18 {
        var w: u32 = 0;
        for k in 4 {
            w = w << 8 | data[j];
            j += 1;
            if j == data.len { j = 0; }
        }
        words[i] = w;
    }
}

// The final 64 encryptions of the magic text; ct gets the six ciphertext words.
fn finish(st: Lane&, ct: u32[6]&) {
    ct = CTEXT;
    for i in 64 {
        encipher(st, ct[0], ct[1]);
        encipher(st, ct[2], ct[3]);
        encipher(st, ct[4], ct[5]);
    }
}

fn hash1(key: u32[18]&, salt: u32[18]&, cost: i64, ct: u32[6]&) {
    var st: Lane = default<Lane>();
    init(st);
    expand_state(st, key, salt);
    for n in 1 << cost {
        expand0(st, key);
        expand0(st, salt);
    }
    finish(st, ct);
}

// Five hashes of one cost, interleaved; hash k's words are key[k], salt[k], and its ciphertext goes to ct[k].
fn hash5(key: u32[18][5]&, salt: u32[18][5]&, cost: i64, ct: u32[6][5]&) {
    var st: Lane[5] = default<Lane[5]>();
    const for <K> in [0, 1, 2, 3, 4] {
        init(st[K]);
        expand_state(st[K], key[K], salt[K]);
    }
    for n in 1 << cost {
        expand0_5(st, key);
        expand0_5(st, salt);
    }
    const for <K> in [0, 1, 2, 3, 4] { finish(st[K], ct[K]); }
}

// ---------- bcrypt's base64: its own alphabet, no padding ----------

let ALPHABET = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

fn index_of(c: u8) -> i64 {
    if c == '.' { return 0; }
    if c == '/' { return 1; }
    if c >= 'A' && c <= 'Z' { return c - 'A' + 2; }
    if c >= 'a' && c <= 'z' { return c - 'a' + 28; }
    if c >= '0' && c <= '9' { return c - '0' + 54; }
    return -1;
}

// Decodes out.len bytes from text; false on a character outside the alphabet or text too short.
fn decode(text: const u8[:], out: u8[:]) -> bool {
    var o = 0;
    var i = 0;
    while o < out.len {
        if i + 1 >= text.len { return false; }
        let c1 = index_of(text[i]);
        let c2 = index_of(text[i + 1]);
        i += 2;
        if c1 < 0 || c2 < 0 { return false; }
        out[o] = (c1 << 2 | (c2 & 0x30) >> 4) as! u8; o += 1;
        if o == out.len { break; }
        if i >= text.len { return false; }
        let c3 = index_of(text[i]); i += 1;
        if c3 < 0 { return false; }
        out[o] = ((c2 & 0x0f) << 4 | (c3 & 0x3c) >> 2) as! u8; o += 1;
        if o == out.len { break; }
        if i >= text.len { return false; }
        let c4 = index_of(text[i]); i += 1;
        if c4 < 0 { return false; }
        out[o] = ((c3 & 0x03) << 6 | c4) as! u8; o += 1;
    }
    return true;
}

fn encode<B>(data: const u8[:], out: B&) {
    var i = 0;
    while i < data.len {
        var c1: i64 = data[i]; i += 1;
        out.push(ALPHABET[c1 >> 2]);
        c1 = (c1 & 0x03) << 4;
        if i >= data.len { out.push(ALPHABET[c1]); break; }
        var c2: i64 = data[i]; i += 1;
        out.push(ALPHABET[c1 | c2 >> 4]);
        c1 = (c2 & 0x0f) << 2;
        if i >= data.len { out.push(ALPHABET[c1]); break; }
        c2 = data[i]; i += 1;
        out.push(ALPHABET[c1 | c2 >> 6]);
        out.push(ALPHABET[c2 & 0x3f]);
    }
}

// The 31 hash characters of a ciphertext: its first 23 bytes, big-endian.
fn hash_text<B>(ct: u32[6]&, out: B&) {
    var bytes: u8[23] = [0; 23];
    for i in 23 { bytes[i] = (ct[i / 4] >> (24 - 8 * (i % 4)) as! u32) as! u8; }
    encode(bytes, out);
}

// ---------- jobs ----------

let PASSWORD_MAX = 72;                 // bcrypt reads at most 72 bytes of key; longer ones are refused upstream
let HASH_COST = 10;
let LANES = 5;

// verify: does password match hash? Otherwise: hash password with a fresh salt at HASH_COST.
struct BJob { tag: u64, reply_fd: i32, verify: bool, password: u8[..72], hash: u8[..60] }

// What goes back down the reply pipe: a fixed-size record, so a pipe write (atomic under 4 KiB) is never split.
let REPLY_SIZE = 72;
struct BReply { tag: u64, ok: bool, hash: u8[..60] }

fn reply_bytes(r: BReply, out: u8[72]&) {
    out = [0; 72];
    for i in 8 { out[i] = (r.tag >> (8 * i) as! u64) as! u8; }
    out[8] = if r.ok { 1 } else { 0 };
    out[9] = r.hash.len as! u8;
    for c, i in r.hash { out[10 + i] = c; }
}

fn parse_reply(b: const u8[:]) -> BReply {
    assert(b.len == REPLY_SIZE);
    var r = BReply { tag: 0, ok: b[8] == 1, hash: "" };
    for i in 8 { r.tag |= (b[i] as u64) << (8 * i) as! u64; }
    let n = min(b[9] as i64, 60);
    for i in n { r.hash.push(b[10 + i]); }
    return r;
}

// A parsed "$2a$", "$2b$" or "$2y$" hash: its cost, its salt, and the 31 characters it ends with.
struct Parsed { cost: i64, salt: u8[16], digest: u8[..31] }

fn parse_hash(h: const u8[:]) -> Parsed, bool {
    var p = Parsed { cost: 0, salt: [0; 16], digest: "" };
    if h.len != 60 || h[0] != '$' || h[1] != '2' || h[3] != '$' || h[6] != '$' { return p, false; }
    if h[2] != 'a' && h[2] != 'b' && h[2] != 'y' { return p, false; }
    if h[4] < '0' || h[4] > '3' || h[5] < '0' || h[5] > '9' { return p, false; }
    p.cost = (h[4] - '0') as i64 * 10 + (h[5] - '0');
    if p.cost < 4 || p.cost > 31 { return p, false; }
    if !decode(h[7..29], p.salt) { return p, false; }
    for c in h[29..60] { p.digest.push(c); }
    return p, true;
}

// The key words of a password: its bytes and the NUL after them, at most 72 bytes in all.
fn key_words(password: const u8[:], words: u32[18]&) {
    var bytes: u8[..73] = [];
    for c in password { if bytes.len < PASSWORD_MAX { bytes.push(c); } }
    if bytes.len < PASSWORD_MAX { bytes.push(0); }
    stream_words(bytes, words);
}

// One slot of a batch: the words in, the job it answers.
struct Slot { key: u32[18], salt: u32[18], cost: i64, expect: u8[..31], salt_bytes: u8[16] }

fn prepare(job: BJob&, s: Slot&) -> bool {
    key_words(job.password, s.key);
    if job.verify {
        let p, ok = parse_hash(job.hash);
        if !ok { return false; }
        s.cost = p.cost;
        s.expect = p.digest;
        s.salt_bytes = p.salt;
    } else {
        s.cost = HASH_COST;
        random_bytes(s.salt_bytes);
    }
    stream_words(s.salt_bytes, s.salt);
    return true;
}

fn answer(job: BJob&, s: Slot&, ct: u32[6]&) {
    var digest: u8[..31] = [];
    hash_text(ct, digest);
    var r = BReply { tag: job.tag, ok: true, hash: "" };
    if job.verify {
        var d: u8 = 0;
        for i in 31 { d |= digest[i] ^ s.expect[i]; }
        r.ok = d == 0;
    } else {
        format(r.hash, "$2b$", s.cost / 10, s.cost % 10, "$");
        encode(s.salt_bytes, r.hash);
        r.hash.append(digest);
    }
    send_reply(job, r);
}

fn send_reply(job: BJob&, r: BReply) {
    var bytes: u8[72] = [0; 72];
    reply_bytes(r, bytes);
    // A full nonblocking pipe must delay this worker, never lose a completed job.
    if native_write_atomic_reply(job.reply_fd, bytes) != REPLY_SIZE { abort("bcrypt reply delivery failed"); }
}

// How long the first job of a batch waits for company: five hashes interleaved cost about 1.3 times one hash,
// and sign-ins are about one request in a thousand, so the wait never shows in the p95.
var batch_ms = 250;

// Runs at a lower priority than the event loops, so a burst of sign-ins slows itself, not every other request.
thread_fn hasher() {
    sys_setpriority(PRIO_PROCESS, sys_gettid() as! u32, 10);
    var jobs: BJob[..5] = [];
    var slots: Slot[5] = [default<Slot>(); 5];
    loop {
        jobs.clear();
        jobs.push(qget<BJob>());
        let deadline = mono_ns() + batch_ms * 1000000;
        while jobs.len < LANES {
            let left = (deadline - mono_ns()) / 1000000;
            if left <= 0 { break; }
            let j, got = qget<BJob>(left);
            if !got { break; }
            jobs.push(j);
        }
        // Lanes of one cost run together; a malformed stored hash, or a cost unlike the first, runs on its own.
        var keys: u32[18][5] = [[0; 18]; 5];
        var salts: u32[18][5] = [[0; 18]; 5];
        var lane_of: i64[5] = [-1; 5];
        var lanes = 0;
        var cost = -1;
        for &job, i in jobs {
            if !prepare(job, slots[i]) {
                send_reply(job, BReply { tag: job.tag, ok: false, hash: "" });
                continue;
            }
            if cost < 0 { cost = slots[i].cost; }
            if slots[i].cost == cost {
                keys[lanes] = slots[i].key; salts[lanes] = slots[i].salt; lane_of[lanes] = i; lanes += 1;
            } else {
                var ct: u32[6] = [0; 6];
                hash1(slots[i].key, slots[i].salt, slots[i].cost, ct);
                answer(job, slots[i], ct);
            }
        }
        if lanes == 1 {
            var ct: u32[6] = [0; 6];
            hash1(keys[0], salts[0], cost, ct);
            answer(jobs[lane_of[0]], slots[lane_of[0]], ct);
        } else if lanes > 1 {
            for k in lanes..LANES { keys[k] = keys[0]; salts[k] = salts[0]; }   // idle lanes repeat lane 0
            var cts: u32[6][5] = [[0; 6]; 5];
            hash5(keys, salts, cost, cts);
            for k in lanes { answer(jobs[lane_of[k]], slots[lane_of[k]], cts[k]); }
        }
    }
}
