/*
 * Two small NIFs on the response path: JSON string escaping and RFC 3339 timestamp formatting. Both are a few
 * hundred nanoseconds at most for the strings and timestamps Conduit produces, well under the NIF budget, and
 * replace several BIF calls and intermediate terms each.
 */
#include <stdint.h>
#include <string.h>
#include "erl_nif.h"

/* Extra bytes a character adds when escaped: 0 for the plain ones. */
static unsigned char escape_extra[256];

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    int c;
    (void)env; (void)priv; (void)info;
    for (c = 0; c < 256; c++) escape_extra[c] = 0;
    for (c = 0; c < 32; c++) escape_extra[c] = 5; /* \u00XX */
    escape_extra['\n'] = escape_extra['\r'] = escape_extra['\t'] = escape_extra['\b'] = escape_extra['\f'] = 1;
    escape_extra['"'] = escape_extra['\\'] = 1;
    return 0;
}

/*
 * json_string(Bin) -> iodata. When nothing needs escaping the result is [$", Bin, $"] around the original binary
 * (no copy); otherwise one new binary with the quotes and the escapes. Escapes exactly what RFC 8259 requires:
 * the quote, the backslash and the control characters below 0x20; everything else, including non-ASCII, is
 * passed through as UTF-8.
 */
static ERL_NIF_TERM nif_json_string(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary in;
    size_t i, extra = 0;
    const unsigned char *p;
    unsigned char *o;
    ERL_NIF_TERM out;
    static const char hex[] = "0123456789abcdef";
    if (argc != 1 || !enif_inspect_binary(env, argv[0], &in)) return enif_make_badarg(env);
    p = in.data;
    for (i = 0; i < in.size; i++) extra += escape_extra[p[i]];
    if (extra == 0) {
        ERL_NIF_TERM quote = enif_make_int(env, '"');
        return enif_make_list3(env, quote, argv[0], quote);
    }
    o = enif_make_new_binary(env, in.size + extra + 2, &out);
    *o++ = '"';
    for (i = 0; i < in.size; i++) {
        unsigned char c = p[i];
        if (escape_extra[c] == 0) {
            *o++ = c;
            continue;
        }
        *o++ = '\\';
        switch (c) {
        case '"': *o++ = '"'; break;
        case '\\': *o++ = '\\'; break;
        case '\n': *o++ = 'n'; break;
        case '\r': *o++ = 'r'; break;
        case '\t': *o++ = 't'; break;
        case '\b': *o++ = 'b'; break;
        case '\f': *o++ = 'f'; break;
        default:
            *o++ = 'u'; *o++ = '0'; *o++ = '0';
            *o++ = (unsigned char)hex[c >> 4];
            *o++ = (unsigned char)hex[c & 15];
            break;
        }
    }
    *o = '"';
    return out;
}

static int64_t floor_div(int64_t a, int64_t b) {
    int64_t q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) q--;
    return q;
}

static void put2(unsigned char *o, int64_t v) {
    o[0] = (unsigned char)('0' + (v / 10) % 10);
    o[1] = (unsigned char)('0' + v % 10);
}

/*
 * Formats microseconds since 2000-01-01T00:00:00Z (Postgres' binary timestamptz) as
 * "YYYY-MM-DDTHH:MM:SS.mmmZ", truncated to milliseconds. Same arithmetic as util.rfc3339 in Gleam, which the
 * tests compare this against.
 */
static void format_rfc3339(int64_t micros, unsigned char *o) {
    int64_t secs = floor_div(micros, 1000000);
    int64_t ms = (micros - secs * 1000000) / 1000;
    int64_t unix_s = secs + 946684800;
    int64_t days = floor_div(unix_s, 86400);
    int64_t sod = unix_s - days * 86400;
    int64_t z = days + 719468;
    int64_t era = floor_div(z, 146097);
    int64_t doe = z - era * 146097;
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t y = yoe + era * 400;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    int64_t mp = (5 * doy + 2) / 153;
    int64_t d = doy - (153 * mp + 2) / 5 + 1;
    int64_t m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2) y++;
    y %= 10000;
    if (y < 0) y += 10000;
    o[0] = (unsigned char)('0' + y / 1000);
    o[1] = (unsigned char)('0' + (y / 100) % 10);
    o[2] = (unsigned char)('0' + (y / 10) % 10);
    o[3] = (unsigned char)('0' + y % 10);
    o[4] = '-';
    put2(o + 5, m);
    o[7] = '-';
    put2(o + 8, d);
    o[10] = 'T';
    put2(o + 11, sod / 3600);
    o[13] = ':';
    put2(o + 14, (sod % 3600) / 60);
    o[16] = ':';
    put2(o + 17, sod % 60);
    o[19] = '.';
    o[20] = (unsigned char)('0' + ms / 100);
    o[21] = (unsigned char)('0' + (ms / 10) % 10);
    o[22] = (unsigned char)('0' + ms % 10);
    o[23] = 'Z';
}

static ERL_NIF_TERM nif_rfc3339(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifSInt64 micros;
    ERL_NIF_TERM out;
    unsigned char *o;
    if (argc != 1 || !enif_get_int64(env, argv[0], &micros)) return enif_make_badarg(env);
    o = enif_make_new_binary(env, 24, &out);
    format_rfc3339((int64_t)micros, o);
    return out;
}

/* The same timestamp as a JSON string literal, quotes included. */
static ERL_NIF_TERM nif_json_rfc3339(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifSInt64 micros;
    ERL_NIF_TERM out;
    unsigned char *o;
    if (argc != 1 || !enif_get_int64(env, argv[0], &micros)) return enif_make_badarg(env);
    o = enif_make_new_binary(env, 26, &out);
    o[0] = '"';
    format_rfc3339((int64_t)micros, o + 1);
    o[25] = '"';
    return out;
}

static ErlNifFunc funcs[] = {
    {"json_string", 1, nif_json_string, 0},
    {"rfc3339", 1, nif_rfc3339, 0},
    {"json_rfc3339", 1, nif_json_rfc3339, 0},
};

ERL_NIF_INIT(conduit_nif, funcs, load, NULL, NULL, NULL)
