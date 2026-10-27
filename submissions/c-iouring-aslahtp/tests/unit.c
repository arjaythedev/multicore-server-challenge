/* Unit tests for the parts that need no network or database: crypto, JWT, JSON, bcrypt, small parsers.
 * Expected values come from tests/vectors.h (generated with Python's own implementations).
 *
 *     bash tests/unit.sh */
#include "../src/arena.h"
#include "../src/base64.h"
#include "../src/bcrypt.h"
#include "../src/buf.h"
#include "../src/hmac.h"
#include "../src/json_in.h"
#include "../src/json_out.h"
#include "../src/pg_wire.h"
#include "../src/jwt.h"
#include "../src/sha256.h"
#include "../src/util.h"
#include "vectors.h"

static int failures, checks;

#define CHECK(cond, ...)                                          \
    do {                                                          \
        checks++;                                                 \
        if (!(cond)) {                                            \
            failures++;                                           \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);  \
            fprintf(stderr, __VA_ARGS__);                         \
            fputc('\n', stderr);                                  \
        }                                                         \
    } while (0)

static void msg(uint8_t *out, size_t n) {
    for (size_t i = 0; i < n; i++) out[i] = (uint8_t)(i * 7 + 3);
}

static void hex(char *out, const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", p[i]);
}

static void test_sha256(void) {
    static uint8_t m[1000];
    uint8_t d[32];
    char h[65];
    msg(m, sizeof m);
    for (size_t i = 0; i < ARRAY_LEN(sha_vecs); i++) {
        size_t n = sha_vecs[i].len;
        sha256(m, n, d);
        hex(h, d, 32);
        CHECK(strcmp(h, sha_vecs[i].hex) == 0, "sha256 len %zu: %s", n, h);

        /* The same message fed in uneven pieces. */
        struct sha256 s;
        sha256_init(&s);
        for (size_t off = 0, step = 1; off < n; off += step, step = step * 3 % 70 + 1)
            sha256_update(&s, m + off, off + step > n ? n - off : step);
        sha256_final(&s, d);
        hex(h, d, 32);
        CHECK(strcmp(h, sha_vecs[i].hex) == 0, "sha256 pieces len %zu: %s", n, h);
    }
}

/* The selected block function (SHA-NI where the CPU has it) against the generic one, 1..8 blocks of varied data. */
static void test_sha256_blocks(void) {
    uint8_t data[8 * SHA256_BLOCK];
    uint32_t x = 12345;
    for (int round = 0; round < 64; round++) {
        for (size_t i = 0; i < sizeof data; i++) data[i] = (uint8_t)((x = x * 1103515245 + 12345) >> 16);
        size_t nb = (size_t)round % 8 + 1;
        uint32_t a[8], b[8];
        for (int i = 0; i < 8; i++) a[i] = b[i] = x ^ (uint32_t)(i * 0x9e3779b9u);
        sha256_blocks_generic(a, data, nb);
        sha256_blocks(b, data, nb);
        CHECK(memcmp(a, b, sizeof a) == 0, "sha256 block function matches generic, round %d", round);
    }
}

static void test_hmac(void) {
    uint8_t m[200], k[100], kr[100], d[32];
    char h[65];
    msg(m, sizeof m);
    for (size_t i = 0; i < ARRAY_LEN(hmac_vecs); i++) {
        size_t kl = hmac_vecs[i].klen;
        msg(k, kl);
        for (size_t j = 0; j < kl; j++) kr[j] = k[kl - 1 - j];
        hmac_sha256(kr, kl, m, hmac_vecs[i].mlen, d);
        hex(h, d, 32);
        CHECK(strcmp(h, hmac_vecs[i].hex) == 0, "hmac klen %zu: %s", kl, h);
    }

    uint8_t salt[32];
    ptrdiff_t sl = b64_decode(salt, LIT("W22ZaJ0SNY7soEsUEjb6gQ=="));
    CHECK(sl == 16, "b64 decode salt: %td", sl);
    pbkdf2_sha256("pencil", 6, salt, 16, 4096, d);
    hex(h, d, 32);
    CHECK(strcmp(h, pbkdf2_hex) == 0, "pbkdf2: %s", h);
}

static void test_base64(void) {
    uint8_t in[64], out[64];
    char enc[100];
    msg(in, sizeof in);
    for (size_t n = 0; n <= 64; n++) {
        size_t el = b64url_encode(enc, in, n);
        CHECK(el == (n * 4 + 2) / 3, "b64url len %zu -> %zu", n, el);
        CHECK(b64url_decode(out, enc, el) == (ptrdiff_t)n && memcmp(in, out, n) == 0, "b64url round trip %zu", n);
        el = b64_encode(enc, in, n);
        CHECK(el == B64_ENC_LEN(n), "b64 len %zu", n);
        CHECK(b64_decode(out, enc, el) == (ptrdiff_t)n && memcmp(in, out, n) == 0, "b64 round trip %zu", n);
    }
    CHECK(b64url_decode(out, LIT("ab=")) < 0, "b64url rejects padding");
    CHECK(b64url_decode(out, LIT("a")) < 0, "b64url rejects length 1 mod 4");
    CHECK(b64url_decode(out, LIT("a+bc")) < 0, "b64url rejects '+'");
    CHECK(b64_decode(out, LIT("abc")) < 0, "b64 needs padding");
}

static struct arena A;

static const struct jval *parse(const char *s) { return json_parse(&A, s, strlen(s)); }

static bool str_is(const struct jval *v, const char *want, size_t n) {
    return v && v->type == J_STR && v->len == n && memcmp(v->s, want, n) == 0;
}

static void test_json_in(void) {
    static const char *good[] = {
        "{}", "[]", " { \"a\" : [1, -2.5e+3, true, false, null, \"x\"] } ", "0", "-0", "1E9", "\"\"",
        "{\"user\":{\"email\":\"a@b\",\"password\":\"p\"}}", "[[[[[]]]]]",
    };
    static const char *bad[] = {
        "", " ", "{", "}", "{\"a\"}", "{\"a\":}", "{\"a\":1,}", "[1,]", "[1 2]", "01", "1.", ".5", "+1", "-",
        "1e", "tru", "nul", "\"abc", "\"a\\x\"", "\"\\u12\"", "\"tab\there\"", "{} x", "{\"a\":1}}", "[\"a\"\"b\"]",
        "{'a':1}", "{a:1}", "NaN", "\"\\\"",
    };
    for (size_t i = 0; i < ARRAY_LEN(good); i++) CHECK(parse(good[i]) != NULL, "json accepts %s", good[i]);
    for (size_t i = 0; i < ARRAY_LEN(bad); i++) CHECK(parse(bad[i]) == NULL, "json rejects %s", bad[i]);

    char deep[200];
    memset(deep, '[', 100);
    memset(deep + 100, ']', 100);
    CHECK(json_parse(&A, deep, 200) == NULL, "json depth limit");

    const struct jval *v = parse("{\"a\":1,\"b\":{\"c\":\"x\"},\"a\":\"last\"}");
    CHECK(v && v->type == J_OBJ && v->len == 3, "object members");
    CHECK(str_is(json_getl(v, "a"), LIT("last")), "duplicate key: last wins");
    CHECK(str_is(json_getl(json_getl(v, "b"), "c"), LIT("x")), "nested get");
    CHECK(json_getl(v, "A") == NULL, "keys are case-sensitive");
    CHECK(json_getl(json_getl(v, "a"), "x") == NULL, "get on a non-object");

    v = parse("\"q\\\" \\\\ \\/ \\b\\f\\n\\r\\t \\u00e9 \\uD83D\\uDE00\"");
    CHECK(str_is(v, LIT("q\" \\ / \b\f\n\r\t \xc3\xa9 \xf0\x9f\x98\x80")), "escapes");

    v = parse("\"\\uD83D x \\uDE00 \\uD83D\\u0041\"");
    CHECK(str_is(v, LIT("\xef\xbf\xbd x \xef\xbf\xbd \xef\xbf\xbd" "A")), "unpaired surrogates become U+FFFD");

    v = parse("\"a\xff" "b\xc3\x28\xed\xa0\x80\xf4\x90\x80\x80\xe2\x82\xac\"");
    CHECK(str_is(v, LIT("a\xef\xbf\xbd" "b\xef\xbf\xbd(\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd"
                        "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xe2\x82\xac")),
          "invalid UTF-8 becomes U+FFFD per byte: %.*s", v ? (int)v->len : 0, v ? v->s : "");

    v = parse("\"a\\u0000b\"");
    CHECK(v && (v->flags & JF_NUL) && v->len == 3, "NUL is flagged");
    v = parse("\"plain\"");
    CHECK(v && !(v->flags & JF_NUL), "no NUL flag");

    v = parse("1.5e3");
    CHECK(v && v->type == J_NUM && json_num(v) == 1500.0, "number value");
    arena_reset(&A);
}

static void test_json_out(void) {
    struct buf b;
    buf_init(&b, 4);
    json_str(&b, LIT("a\"b\\c\n\x01\x1f\xc3\xa9/<"));
    static const char want_esc[] = "\"a\\\"b\\\\c\\n\\u0001\\u001f\xc3\xa9/<\"";
    CHECK(b.len == sizeof want_esc - 1 && memcmp(b.p, want_esc, b.len) == 0, "escape: %.*s", (int)b.len, b.p);

    static const struct { int64_t us; const char *want; } ts[] = {
        {0, "\"2000-01-01T00:00:00.000Z\""},
        {796824000123999, "\"2025-04-01T12:00:00.123Z\""},
        {762566399999999, "\"2024-02-29T23:59:59.999Z\""},
        {-1, "\"1999-12-31T23:59:59.999Z\""},
        {3160857600001000, "\"2100-03-01T00:00:00.001Z\""},
        {-946684800000000, "\"1970-01-01T00:00:00.000Z\""},
    };
    for (size_t i = 0; i < ARRAY_LEN(ts); i++) {
        b.len = 0;
        json_ts(&b, ts[i].us);
        CHECK(b.len == 26 && memcmp(b.p, ts[i].want, 26) == 0, "ts %lld: %.*s", (long long)ts[i].us, (int)b.len,
              b.p);
    }

    b.len = 0;
    buf_put_i64(&b, INT64_MIN);
    buf_putc(&b, ' ');
    buf_put_u64(&b, UINT64_MAX);
    buf_putc(&b, ' ');
    buf_put_i64(&b, 0);
    CHECK(b.len == 43 && memcmp(b.p, "-9223372036854775808 18446744073709551615 0", 43) == 0, "ints: %.*s",
          (int)b.len, b.p);
    buf_free(&b);
}

static void test_jwt(void) {
    jwt_init(LIT(JWT_SECRET_VEC));
    for (size_t i = 0; i < ARRAY_LEN(jwt_vecs); i++) {
        int64_t uid = 0;
        const char *t = jwt_vecs[i].tok;
        bool ok = jwt_verify(&A, t, strlen(t), (double)JWT_NOW_VEC, &uid);
        if (jwt_vecs[i].uid) CHECK(ok && uid == jwt_vecs[i].uid, "jwt %s: ok=%d uid=%lld", jwt_vecs[i].name, ok,
                                   (long long)uid);
        else CHECK(!ok, "jwt %s should fail", jwt_vecs[i].name);
        arena_reset(&A);
    }

    /* Our own tokens: verify now, fail after 30 days, and carry exactly sub, iat, exp. */
    char tok[JWT_MAX];
    size_t n = jwt_sign(tok, 987654321, JWT_NOW_VEC);
    int64_t uid = 0;
    CHECK(jwt_verify(&A, tok, n, JWT_NOW_VEC + 5.0, &uid) && uid == 987654321, "own token verifies");
    CHECK(!jwt_verify(&A, tok, n, JWT_NOW_VEC + JWT_TTL, &uid), "own token expires");
    const char *d1 = memchr(tok, '.', n), *d2 = memchr(d1 + 1, '.', n - (size_t)(d1 + 1 - tok));
    char payload[128];
    ptrdiff_t pl = b64url_decode(payload, d1 + 1, (size_t)(d2 - d1 - 1));
    const char want[] = "{\"sub\":\"987654321\",\"iat\":1800000000,\"exp\":1802592000}";
    CHECK(pl == (ptrdiff_t)sizeof want - 1 && memcmp(payload, want, sizeof want - 1) == 0, "payload %.*s",
          (int)pl, payload);
    arena_reset(&A);
}

static void test_bcrypt(void) {
    for (size_t i = 0; i < ARRAY_LEN(bcrypt_vecs); i++) {
        const struct bcrypt_vec *v = &bcrypt_vecs[i];
        size_t hl = strlen(v->hash);
        CHECK(bcrypt_verify(v->pw, v->pwlen, v->hash, hl), "bcrypt verify %zu", i);
        CHECK(!bcrypt_verify("wrong", 5, v->hash, hl), "bcrypt rejects wrong password %zu", i);

        struct bcrypt_setting s;
        char out[BCRYPT_LEN + 1];
        CHECK(bcrypt_parse(v->hash, hl, &s), "bcrypt parse %zu", i);
        if (s.cost > 4) continue;
        bcrypt_hash(v->pw, v->pwlen, s.cost, s.salt, out);
        CHECK(memcmp(out + 4, v->hash + 4, BCRYPT_LEN - 4) == 0, "bcrypt hash %zu: %s", i, out);
    }
    static const char *malformed[] = {
        "", "$2a$10$short", "$3a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq",
        "$2a$03$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq",
        "$2a$1x$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq",
        "$2a$10$ZSfEoPvlcsj2XfvsSeK2!em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq",
        "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899w",
    };
    for (size_t i = 0; i < ARRAY_LEN(malformed); i++)
        CHECK(!bcrypt_verify(LIT("password123"), malformed[i], strlen(malformed[i])), "malformed hash %zu", i);
    CHECK(!bcrypt_verify("x", 73, bcrypt_vecs[0].hash, strlen(bcrypt_vecs[0].hash)), "73-byte password refused");

    /* The interleaved kernels against the reference, every batch size, lanes of different passwords and salts. */
    struct bcrypt_lane in[BCRYPT_LANES_MAX + 3];
    struct bcrypt_setting set[BCRYPT_LANES_MAX + 3];
    uint8_t ref[BCRYPT_LANES_MAX + 3][BCRYPT_RAW], got[BCRYPT_LANES_MAX + 3][BCRYPT_RAW];
    for (int k = 0; k < BCRYPT_LANES_MAX + 3; k++) {
        const struct bcrypt_vec *v = &bcrypt_vecs[(size_t)k % ARRAY_LEN(bcrypt_vecs)];
        bcrypt_parse(v->hash, strlen(v->hash), &set[k]);
        in[k] = (struct bcrypt_lane){v->pw, v->pwlen, set[k].salt};
        bcrypt_raw(v->pw, v->pwlen, set[k].salt, 4, ref[k]);
    }
    for (int n = 1; n <= BCRYPT_LANES_MAX + 3; n++) {
        memset(got, 0, sizeof got);
        bcrypt_raw_lanes(in, n, 4, got);
        CHECK(memcmp(got, ref, (size_t)n * BCRYPT_RAW) == 0, "bcrypt lanes, batch of %d", n);
    }
}

static void test_util(void) {
    int64_t v;
    CHECK(parse_uint(LIT("0"), &v) && v == 0, "uint 0");
    CHECK(parse_uint(LIT("05"), &v) && v == 5, "uint 05");
    CHECK(parse_uint(LIT("9223372036854775807"), &v) && v == INT64_MAX, "uint max");
    static const char *bad[] = {"", "+5", " 5", "5 ", "-1", "1.5", "abc", "9223372036854775808",
                                "99999999999999999999"};
    for (size_t i = 0; i < ARRAY_LEN(bad); i++) CHECK(!parse_uint(bad[i], strlen(bad[i]), &v), "uint rejects '%s'", bad[i]);

    char d[64];
    ptrdiff_t n = pct_decode(d, LIT("a%20b+c%2Fd%c3%A9"), true);
    CHECK(n == 9 && memcmp(d, "a b c/d\xc3\xa9", 9) == 0, "pct query: %.*s", (int)n, d);
    n = pct_decode(d, LIT("a+b"), false);
    CHECK(n == 3 && memcmp(d, "a+b", 3) == 0, "pct path keeps +");
    CHECK(pct_decode(d, LIT("a%2"), false) < 0, "pct truncated escape");
    CHECK(pct_decode(d, LIT("a%zz"), false) < 0, "pct bad hex");
}

/* Builds a backend message: type, length, body. */
static size_t backend_msg(uint8_t *out, char type, const void *body, size_t n) {
    out[0] = (uint8_t)type;
    store_be32(out + 1, (uint32_t)n + 4);
    memcpy(out + 5, body, n);
    return n + 5;
}

static size_t auth_msg(uint8_t *out, uint32_t code, const char *data, size_t n) {
    uint8_t body[256];
    store_be32(body, code);
    memcpy(body + 4, data, n);
    return backend_msg(out, 'R', body, n + 4);
}

static void test_pg_auth(void) {
    uint8_t nonce[18], m[300];
    for (int i = 0; i < 18; i++) nonce[i] = (uint8_t)i;
    struct pg_auth a;
    struct pg_msg msg;
    struct buf out;
    buf_init(&out, 64);

    pg_auth_init(&a, "conduit", SCRAM_PASSWORD, nonce);
    size_t n = auth_msg(m, 10, "SCRAM-SHA-256-PLUS\0SCRAM-SHA-256\0", 33);
    CHECK(pg_next(m, n, &msg) == (ptrdiff_t)n && pg_auth_step(&a, &msg, &out) == PG_AUTH_MORE, "sasl start");
    /* 'p' len "SCRAM-SHA-256\0" int32 client-first */
    const char cf[] = SCRAM_CLIENT_FIRST;
    CHECK(out.len == 5 + 14 + 4 + sizeof cf - 1 && out.p[0] == 'p' &&
              memcmp(out.p + 5, "SCRAM-SHA-256", 14) == 0 && load_be32(out.p + 19) == sizeof cf - 1 &&
              memcmp(out.p + 23, cf, sizeof cf - 1) == 0,
          "client-first: %.*s", (int)out.len - 23, out.p + 23);

    out.len = 0;
    n = auth_msg(m, 11, LIT(SCRAM_SERVER_FIRST));
    CHECK(pg_next(m, n, &msg) > 0 && pg_auth_step(&a, &msg, &out) == PG_AUTH_MORE, "sasl continue");
    const char cfin[] = SCRAM_CLIENT_FINAL;
    CHECK(out.len == 5 + sizeof cfin - 1 && memcmp(out.p + 5, cfin, sizeof cfin - 1) == 0, "client-final: %.*s",
          (int)out.len - 5, out.p + 5);

    out.len = 0;
    n = auth_msg(m, 12, LIT(SCRAM_SERVER_FINAL));
    CHECK(pg_next(m, n, &msg) > 0 && pg_auth_step(&a, &msg, &out) == PG_AUTH_MORE, "sasl final");
    n = auth_msg(m, 0, "", 0);
    CHECK(pg_next(m, n, &msg) > 0 && pg_auth_step(&a, &msg, &out) == PG_AUTH_MORE, "auth ok");
    n = backend_msg(m, 'Z', "I", 1);
    CHECK(pg_next(m, n, &msg) > 0 && pg_auth_step(&a, &msg, &out) == PG_AUTH_READY, "ready");

    /* A forged server signature must fail. */
    pg_auth_init(&a, "conduit", SCRAM_PASSWORD, nonce);
    n = auth_msg(m, 10, "SCRAM-SHA-256\0", 14);
    pg_next(m, n, &msg), pg_auth_step(&a, &msg, &out);
    n = auth_msg(m, 11, LIT(SCRAM_SERVER_FIRST));
    pg_next(m, n, &msg), pg_auth_step(&a, &msg, &out);
    n = auth_msg(m, 12, LIT("v=v5fzavYBD310SQFTGkkR+AiB8aoeK7kdOB9HiO2Hw+Y="));
    CHECK(pg_next(m, n, &msg) > 0 && pg_auth_step(&a, &msg, &out) == PG_AUTH_FAILED, "bad server signature");

    /* A server nonce that does not extend ours must fail. */
    pg_auth_init(&a, "conduit", SCRAM_PASSWORD, nonce);
    n = auth_msg(m, 10, "SCRAM-SHA-256\0", 14);
    pg_next(m, n, &msg), pg_auth_step(&a, &msg, &out);
    n = auth_msg(m, 11, LIT("r=XXXX,s=ZGVm,i=4096"));
    CHECK(pg_next(m, n, &msg) > 0 && pg_auth_step(&a, &msg, &out) == PG_AUTH_FAILED, "foreign nonce");
    buf_free(&out);
}

static void test_pg_messages(void) {
    struct buf b;
    struct pg_bind pb;
    buf_init(&b, 16);
    pg_bind_begin(&pb, &b, "s7");
    pg_bind_i64(&pb, -2);
    pg_bind_null(&pb);
    pg_bind_text(&pb, LIT("hé"));
    size_t at;
    pg_bind_array_begin(&pb, OID_TEXT, &at);
    pg_bind_array_text(&pb, LIT("a"));
    pg_bind_array_text(&pb, LIT("bc"));
    pg_bind_array_end(&pb, at, 2, false);
    pg_bind_i64_array(&pb, NULL, 0);
    pg_bind_end(&pb);

    /* Walk the Bind message by hand. */
    const uint8_t *p = (const uint8_t *)b.p;
    CHECK(p[0] == 'B' && load_be32(p + 1) == b.len - 1, "bind length");
    p += 5;
    CHECK(p[0] == 0 && memcmp(p + 1, "s7", 3) == 0, "portal and statement");
    p += 4;
    CHECK(load_be16(p) == 1 && load_be16(p + 2) == 1 && load_be16(p + 4) == 5, "formats and param count");
    p += 6;
    CHECK(load_be32(p) == 8 && (int64_t)load_be64(p + 4) == -2, "i64 param");
    p += 12;
    CHECK(load_be32(p) == 0xffffffff, "null param");
    p += 4;
    CHECK(load_be32(p) == 3 && memcmp(p + 4, "hé", 3) == 0, "text param");
    p += 7;
    struct pg_array arr;
    const uint8_t *val;
    int32_t alen = (int32_t)load_be32(p);
    CHECK(pg_array_init(&arr, p + 4, alen) && arr.n == 2 && arr.elem_oid == OID_TEXT, "text array header");
    CHECK(pg_array_next(&arr, &val) == 1 && val[0] == 'a', "array elem 1");
    CHECK(pg_array_next(&arr, &val) == 2 && memcmp(val, "bc", 2) == 0 && arr.p == arr.end, "array elem 2");
    CHECK(load_be32(p + 4 + 4) == 0 && load_be32(p + 4 + 16) == 1, "array flags and lower bound");
    p += 4 + alen;
    alen = (int32_t)load_be32(p);
    CHECK(alen == 12 && load_be32(p + 4) == 0 && load_be32(p + 12) == OID_INT8, "empty array: no dimensions");
    CHECK(pg_array_init(&arr, p + 4, alen) && arr.n == 0, "empty array parses");
    p += 4 + alen;
    CHECK(load_be16(p) == 1 && load_be16(p + 2) == 1 && p + 4 == (const uint8_t *)b.p + b.len, "result formats");

    /* Splitting a stream: a DataRow cut short is not a message yet. */
    uint8_t row[64], body[32];
    store_be16(body, 2);
    store_be32(body + 2, 8), store_be64(body + 6, 42);
    store_be32(body + 14, 0xffffffff);
    size_t n = backend_msg(row, 'D', body, 18);
    struct pg_msg m;
    CHECK(pg_next(row, n - 1, &m) == 0, "partial message");
    CHECK(pg_next(row, n, &m) == (ptrdiff_t)n && m.type == 'D', "whole message");
    struct pg_row r;
    CHECK(pg_row_init(&r, &m) && r.ncols == 2, "row columns");
    CHECK(pg_col(&r, &val) == 8 && pg_i64(val) == 42, "int8 column");
    CHECK(pg_col(&r, &val) == -1, "null column");
    CHECK(pg_col(&r, &val) == -2, "past the end");

    uint8_t err[80];
    n = backend_msg(err, 'E', "SERROR\0C23505\0Mduplicate key\0\0", 31);
    struct pg_error e;
    pg_next(err, n, &m);
    pg_parse_error(&m, &e);
    CHECK(strcmp(e.sqlstate, "23505") == 0 && strcmp(e.message, "duplicate key") == 0, "error fields");

    struct pg_url u;
    CHECK(pg_url_parse("postgres://conduit:c%40nduit@127.0.0.1:5432/conduit_dev?sslmode=disable", &u) &&
              !strcmp(u.user, "conduit") && !strcmp(u.password, "c@nduit") && !strcmp(u.host, "127.0.0.1") &&
              !strcmp(u.port, "5432") && !strcmp(u.dbname, "conduit_dev"),
          "url parse");
    CHECK(pg_url_parse("postgresql://localhost/db", &u) && !strcmp(u.port, "5432") && !strcmp(u.user, "postgres"),
          "url defaults");
    CHECK(!pg_url_parse("mysql://x", &u), "url scheme");
    buf_free(&b);
}

int main(void) {
    arena_init(&A, 4096);
    sha256_select();
    test_sha256();
    test_sha256_blocks();
    test_hmac();
    test_base64();
    test_json_in();
    test_json_out();
    test_jwt();
    test_bcrypt();
    test_util();
    test_pg_auth();
    test_pg_messages();
    arena_free(&A);
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
