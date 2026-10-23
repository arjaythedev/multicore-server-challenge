/*
 * Minimal bcrypt NIF for the Gleam Conduit server: encode_salt/2 and hashpw/2.
 * hashpw runs on a dirty CPU scheduler so a 60-100 ms hash never blocks a normal scheduler.
 * The hashing core (bcrypt.c, blowfish.c) is the OpenBSD implementation as packaged by erlang-bcrypt
 * (see LICENSE.bcrypt); the 2b/2y minor versions are accepted as aliases of 2a.
 */
#include <string.h>
#include "erl_nif.h"
#include "erl_blf.h"

int ts_bcrypt(char *, const char *, const char *);
void encode_salt(char *, u_int8_t *, u_int16_t, u_int8_t);

#define BCRYPT_MAXSALT 16
#define MAX_KEY 256
#define MAX_SALT 128

static ERL_NIF_TERM nif_encode_salt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary raw;
    unsigned int rounds;
    char salt[64];
    ERL_NIF_TERM out;
    unsigned char *p;
    if (argc != 2 || !enif_inspect_binary(env, argv[0], &raw) || raw.size != BCRYPT_MAXSALT ||
        !enif_get_uint(env, argv[1], &rounds) || rounds < 4 || rounds > 31)
        return enif_make_badarg(env);
    memset(salt, 0, sizeof(salt));
    encode_salt(salt, raw.data, (u_int16_t)raw.size, (u_int8_t)rounds);
    p = enif_make_new_binary(env, strlen(salt), &out);
    memcpy(p, salt, strlen(salt));
    return out;
}

static ERL_NIF_TERM nif_hashpw(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary pw, salt;
    char key[MAX_KEY + 1], s[MAX_SALT + 1], enc[128];
    ERL_NIF_TERM out;
    unsigned char *p;
    size_t n;
    if (argc != 2 || !enif_inspect_binary(env, argv[0], &pw) || !enif_inspect_binary(env, argv[1], &salt) ||
        pw.size > MAX_KEY || salt.size > MAX_SALT)
        return enif_make_badarg(env);
    memcpy(key, pw.data, pw.size);
    key[pw.size] = 0;
    memcpy(s, salt.data, salt.size);
    s[salt.size] = 0;
    memset(enc, 0, sizeof(enc));
    if (ts_bcrypt(enc, key, s) != 0) {
        memset(key, 0, sizeof(key));
        return enif_make_atom(env, "error");
    }
    memset(key, 0, sizeof(key));
    n = strlen(enc);
    p = enif_make_new_binary(env, n, &out);
    memcpy(p, enc, n);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), out);
}

static ErlNifFunc funcs[] = {
    {"encode_salt", 2, nif_encode_salt, 0},
    {"hashpw", 2, nif_hashpw, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(bcrypt_nif, funcs, NULL, NULL, NULL, NULL)
