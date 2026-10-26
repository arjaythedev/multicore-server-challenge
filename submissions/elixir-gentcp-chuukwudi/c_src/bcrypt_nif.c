/* bcrypt NIF: the unmodified Openwall/libxcrypt core (crypt-bcrypt.c, public domain) plus the round-interleaving
 * header from the challenge's rust-tokio-Scooter1337 submission (bcrypt-batch-impl.h, MIT), which runs two to four
 * independent hashes in lock-step so a core's load ports stay busy. Every hash does the full cost of its own setting
 * with its own salt; nothing is shared between lanes except the instruction stream.
 *
 *   hash_many([{Key, Setting}]) -> [Hash60 | error]   (dirty CPU scheduler)
 *   gensalt(Random16)            -> "$2b$10$" ++ 22 chars
 */
#include "crypt-bcrypt.c"
#include <erl_nif.h>

static inline BF_word batch_f(const BF_ctx *s, BF_word x) {
    return ((s->S[0][x >> 24] + s->S[1][(x >> 16) & 255]) ^
             s->S[2][(x >> 8) & 255]) + s->S[3][x & 255];
}
#define JOIN_(a,b) a##b
#define JOIN(a,b) JOIN_(a,b)
#define LANES 2
#include "bcrypt-batch-impl.h"
#undef LANES
#define LANES 3
#include "bcrypt-batch-impl.h"
#undef LANES
#define LANES 4
#include "bcrypt-batch-impl.h"
#undef LANES

#define MAX_LANES 4

/* One hash through the reference path (with its built-in self-test). */
static int single(const char *key, const char *setting, unsigned char out[61]) {
    unsigned char scratch[ALG_SPECIFIC_SIZE] __attribute__((aligned(16)));
    unsigned char buf[CRYPT_OUTPUT_SIZE];
    memset(buf, 0, sizeof buf);
    crypt_bcrypt_rn(key, strlen(key), setting, strlen(setting), buf, sizeof buf, scratch, sizeof scratch);
    volatile unsigned char *wipe = scratch;
    for (size_t i = 0; i < sizeof scratch; ++i) wipe[i] = 0;
    if (buf[0] != '$' || buf[60] != 0) return 0;
    memcpy(out, buf, 61);
    return 1;
}

static ERL_NIF_TERM hash_many(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    unsigned n;
    if (argc != 1 || !enif_get_list_length(env, argv[0], &n) || n == 0 || n > MAX_LANES) return enif_make_badarg(env);
    char keys[MAX_LANES][73], settings[MAX_LANES][61];
    const char *kp[MAX_LANES], *sp[MAX_LANES];
    unsigned char out[MAX_LANES][61];
    int ok[MAX_LANES];
    ERL_NIF_TERM list = argv[0], head;
    for (unsigned i = 0; i < n; ++i) {
        const ERL_NIF_TERM *tup;
        int arity;
        ErlNifBinary k, s;
        if (!enif_get_list_cell(env, list, &head, &list) || !enif_get_tuple(env, head, &arity, &tup) || arity != 2 ||
            !enif_inspect_binary(env, tup[0], &k) || !enif_inspect_binary(env, tup[1], &s) || s.size < 29 || s.size > 60)
            return enif_make_badarg(env);
        size_t kl = k.size > 72 ? 72 : k.size;   /* bcrypt only ever uses the first 72 bytes */
        memcpy(keys[i], k.data, kl);
        keys[i][kl] = 0;
        memcpy(settings[i], s.data, s.size);
        settings[i][s.size] = 0;
        kp[i] = keys[i];
        sp[i] = settings[i];
        ok[i] = 0;
    }
    int batched = 0;
    switch (n) {
    case 2: batched = batch_run2(kp, sp, out); break;
    case 3: batched = batch_run3(kp, sp, out); break;
    case 4: batched = batch_run4(kp, sp, out); break;
    }
    if (batched) for (unsigned i = 0; i < n; ++i) ok[i] = 1;
    else for (unsigned i = 0; i < n; ++i) ok[i] = single(kp[i], sp[i], out[i]);

    ERL_NIF_TERM res = enif_make_list(env, 0);
    for (int i = (int)n - 1; i >= 0; --i) {
        ERL_NIF_TERM t;
        if (ok[i]) {
            unsigned char *b = enif_make_new_binary(env, 60, &t);
            memcpy(b, out[i], 60);
        } else {
            t = enif_make_atom(env, "error");
        }
        res = enif_make_list_cell(env, t, res);
    }
    volatile unsigned char *wipe = (volatile unsigned char *)keys;
    for (size_t i = 0; i < sizeof keys; ++i) wipe[i] = 0;
    return res;
}

static ERL_NIF_TERM gensalt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary r;
    if (argc != 1 || !enif_inspect_binary(env, argv[0], &r) || r.size != 16) return enif_make_badarg(env);
    uint8_t buf[30];
    memset(buf, 0, sizeof buf);
    gensalt_bcrypt_rn(10, r.data, 16, buf, sizeof buf);
    if (buf[0] != '$') return enif_make_badarg(env);
    ERL_NIF_TERM t;
    memcpy(enif_make_new_binary(env, 29, &t), buf, 29);
    return t;
}

static ErlNifFunc funcs[] = {
    {"hash_many", 1, hash_many, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"gensalt", 1, gensalt, 0},
};

ERL_NIF_INIT(Elixir.Conduit.Bcrypt.Nif, funcs, NULL, NULL, NULL, NULL)
