/* NIF over the vendored bcrypt (see README.md here): crypt-bcrypt.c, Solar Designer's public-domain Openwall core
 * from libxcrypt 4.4.36, and bcrypt-batch.c, which interleaves 2-4 independent hashes (from the
 * rust-tokio-Scooter1337 submission, MIT). Included as one translation unit so the static core is visible here.
 *
 * hash/2 (Keys, Settings): two lists of the same length, 1 to 4 binaries. A key is a password of at most 72 bytes
 * without NUL; a setting is a stored hash or a salt ("$2b$10$" + 22 chars), and every setting in one call must have
 * the same cost. Returns the list of 60-byte hashes, or the atom `error`. Every hash runs every one of its 2^cost
 * iterations: a batch only interleaves independent computations. Runs on a dirty CPU scheduler.
 *
 * salt/1 (16 random bytes): "$2b$10$" + their 22-char bcrypt base64. */
#include "bcrypt-batch.c"
#include <erl_nif.h>

#define MAX_LANES 4

static void wipe(void *p, size_t n) {
    volatile unsigned char *v = p;
    while (n--) *v++ = 0;
}

/* A list of up to MAX_LANES binaries of min..max bytes without NUL -> NUL-terminated rows of `buf` (row size
 * `row`, > max), pointers in `ptrs`. Returns the count, or -1 if anything doesn't fit. */
static int c_strings(ErlNifEnv *env, ERL_NIF_TERM list, char *buf, size_t row, size_t min, size_t max,
                     const char **ptrs) {
    ERL_NIF_TERM head;
    ErlNifBinary b;
    int n = 0;
    while (enif_get_list_cell(env, list, &head, &list)) {
        if (n == MAX_LANES || !enif_inspect_binary(env, head, &b) || b.size < min || b.size > max ||
            memchr(b.data, 0, b.size))
            return -1;
        char *dst = buf + (size_t)n * row;
        memcpy(dst, b.data, b.size);
        dst[b.size] = 0;
        ptrs[n++] = dst;
    }
    return enif_is_empty_list(env, list) ? n : -1;
}

static ERL_NIF_TERM hash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    char keys[MAX_LANES][73], settings[MAX_LANES][61];
    unsigned char out[MAX_LANES][64];
    const char *kp[MAX_LANES], *sp[MAX_LANES];
    unsigned ok = 0;
    ERL_NIF_TERM result = enif_make_atom(env, "error");

    int n = c_strings(env, argv[0], &keys[0][0], sizeof keys[0], 0, 72, kp);
    int m = c_strings(env, argv[1], &settings[0][0], sizeof settings[0], 29, 60, sp);
    if (n < 1 || n != m) goto done;

    memset(out, 0, sizeof out);
    if (n == 1) {
        _Alignas(16) unsigned char scratch[ALG_SPECIFIC_SIZE];
        crypt_bcrypt_rn(kp[0], strlen(kp[0]), sp[0], strlen(sp[0]), out[0], sizeof out[0], scratch, sizeof scratch);
        wipe(scratch, sizeof scratch);
        ok = out[0][0] == '$';
    } else {
        unsigned char lanes[MAX_LANES][61];
        ok = conduit_bcrypt_batch(kp, sp, lanes, (unsigned)n);
        for (int i = 0; i < n; ++i) memcpy(out[i], lanes[i], 61);
        wipe(lanes, sizeof lanes);
    }
    if (ok) {
        ERL_NIF_TERM hashes[MAX_LANES];
        for (int i = 0; i < n; ++i) {
            if (out[i][0] != '$' || strnlen((const char *)out[i], 61) != 60) {
                ok = 0;
                break;
            }
            memcpy(enif_make_new_binary(env, 60, &hashes[i]), out[i], 60);
        }
        if (ok) result = enif_make_list_from_array(env, hashes, (unsigned)n);
    }
done:
    wipe(keys, sizeof keys);
    wipe(settings, sizeof settings);
    wipe(out, sizeof out);
    return result;
}

static ERL_NIF_TERM salt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary random;
    uint8_t setting[7 + 22 + 1] = {0};
    ERL_NIF_TERM term;
    if (!enif_inspect_binary(env, argv[0], &random) || random.size != 16) return enif_make_badarg(env);
    gensalt_bcrypt_rn(10, random.data, random.size, setting, sizeof setting);
    if (setting[0] != '$') return enif_make_badarg(env);
    memcpy(enif_make_new_binary(env, 29, &term), setting, 29);
    return term;
}

static ErlNifFunc funcs[] = {
    {"hash", 2, hash, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"salt", 1, salt, 0},
};

ERL_NIF_INIT(Elixir.Conduit.Bcrypt.Nif, funcs, NULL, NULL, NULL, NULL)
