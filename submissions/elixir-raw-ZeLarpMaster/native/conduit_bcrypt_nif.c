/* NIF over the vendored bcrypt (see README.md here): crypt-bcrypt.c, Solar Designer's public-domain Openwall core
 * from libxcrypt 4.4.36, and bcrypt-batch.c, which interleaves 2-4 independent hashes (from the
 * rust-tokio-Scooter1337 submission, MIT). Included as one translation unit so the static core is visible here.
 *
 * hash/2 (Keys, Settings): two lists of the same length, 1 to 4 binaries. A key is a password of at most 72 bytes
 * without NUL; a setting is a stored hash or a salt ("$2b$10$" + 22 chars), and every setting in one call must have
 * the same cost. Returns the list of 60-byte hashes, or the atom `error`. Every hash runs every one of its 2^cost
 * iterations: a batch only interleaves independent computations. Runs on a dirty CPU scheduler.
 *
 * salt/1 (16 random bytes): "$2b$10$" + their 22-char bcrypt base64.
 *
 * idle_start/1 and hash_idle/3: the same hashes on threads of our own under SCHED_IDLE (below). */
#define _GNU_SOURCE /* SCHED_IDLE */
#include "bcrypt-batch.c"
#include <erl_nif.h>
#include <errno.h>
#include <sched.h>

#define MAX_LANES 6

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

/* The n hashes of kp / sp into out; 1 if every one came out as a 60-byte hash. */
static int compute(const char **kp, const char **sp, int n, unsigned char out[MAX_LANES][64]) {
    int ok;
    memset(out, 0, MAX_LANES * 64);
    if (n == 1) {
        _Alignas(16) unsigned char scratch[ALG_SPECIFIC_SIZE];
        crypt_bcrypt_rn(kp[0], strlen(kp[0]), sp[0], strlen(sp[0]), out[0], 64, scratch, sizeof scratch);
        wipe(scratch, sizeof scratch);
        ok = out[0][0] == '$';
    } else {
        unsigned char lanes[MAX_LANES][61];
        ok = conduit_bcrypt_batch(kp, sp, lanes, (unsigned)n);
        for (int i = 0; i < n; ++i) memcpy(out[i], lanes[i], 61);
        wipe(lanes, sizeof lanes);
    }
    for (int i = 0; ok && i < n; ++i)
        if (out[i][0] != '$' || strnlen((const char *)out[i], 61) != 60) ok = 0;
    return ok;
}

/* The list of hashes, or the atom `error`, in env. */
static ERL_NIF_TERM result_term(ErlNifEnv *env, int ok, int n, unsigned char out[MAX_LANES][64]) {
    if (!ok) return enif_make_atom(env, "error");
    ERL_NIF_TERM hashes[MAX_LANES];
    for (int i = 0; i < n; ++i) memcpy(enif_make_new_binary(env, 60, &hashes[i]), out[i], 60);
    return enif_make_list_from_array(env, hashes, (unsigned)n);
}

/* A job's inputs, parsed from the two lists; n < 1 if they don't fit. */
typedef struct job {
    struct job *next;
    int n;
    char keys[MAX_LANES][73], settings[MAX_LANES][61];
    const char *kp[MAX_LANES], *sp[MAX_LANES];
    ErlNifPid to;
    ErlNifEnv *env; /* the reply's env, holding the copied ref */
    ERL_NIF_TERM ref;
} job;

static int parse(ErlNifEnv *env, const ERL_NIF_TERM argv[], job *j) {
    int n = c_strings(env, argv[0], &j->keys[0][0], sizeof j->keys[0], 0, 72, j->kp);
    int m = c_strings(env, argv[1], &j->settings[0][0], sizeof j->settings[0], 29, 60, j->sp);
    j->n = n >= 1 && n == m ? n : 0;
    return j->n;
}

static void wipe_job(job *j) {
    wipe(j->keys, sizeof j->keys);
    wipe(j->settings, sizeof j->settings);
}

static ERL_NIF_TERM hash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    job j;
    unsigned char out[MAX_LANES][64];
    ERL_NIF_TERM result = enif_make_atom(env, "error");
    if (parse(env, argv, &j)) result = result_term(env, compute(j.kp, j.sp, j.n, out), j.n, out);
    wipe_job(&j);
    wipe(out, sizeof out);
    return result;
}

/* ------------------------------------------------------------------ idle threads (after zig-iouring-nick-potts)
 * idle_start/1 starts N threads of our own under SCHED_IDLE: they only get a core no other thread wants (the
 * scheduler gives them a token share when every core is busy), so hashes yield to request handling and Postgres.
 * hash_idle/3 (Keys, Settings, Ref) queues a job and returns `ok` (or `error` for bad input, with nothing queued);
 * a thread then sends {Ref, Hashes | error} to the caller. The caller's watchdog covers a starved queue. */
static ErlNifMutex *mtx;
static ErlNifCond *cond;
static job *head, *tail;
static int threads, failed, reported;

static void *idle_loop(void *arg) {
    (void)arg;
    struct sched_param none = {0};
    int err = sched_setscheduler(0, SCHED_IDLE, &none) ? errno : 0;
    enif_mutex_lock(mtx);
    if (err) failed = err;
    reported++;
    enif_cond_broadcast(cond);
    enif_mutex_unlock(mtx);
    if (err) return NULL;

    for (;;) {
        enif_mutex_lock(mtx);
        while (!head) enif_cond_wait(cond, mtx);
        job *j = head;
        head = j->next;
        if (!head) tail = NULL;
        enif_mutex_unlock(mtx);

        unsigned char out[MAX_LANES][64];
        int ok = compute(j->kp, j->sp, j->n, out);
        wipe_job(j);
        ERL_NIF_TERM msg = enif_make_tuple2(j->env, j->ref, result_term(j->env, ok, j->n, out));
        wipe(out, sizeof out);
        enif_send(NULL, &j->to, j->env, msg);
        enif_free_env(j->env);
        enif_free(j);
    }
    return NULL;
}

static ERL_NIF_TERM idle_start(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int n;
    if (!enif_get_int(env, argv[0], &n) || n < 1 || n > 64) return enif_make_badarg(env);
    enif_mutex_lock(mtx);
    int start = threads == 0;
    if (start) threads = n;
    enif_mutex_unlock(mtx);
    if (!start) return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "started"));

    for (int i = 0; i < n; ++i) {
        ErlNifTid tid;
        if (enif_thread_create("conduit_bcrypt_idle", &tid, idle_loop, NULL, NULL)) {
            enif_mutex_lock(mtx);
            failed = failed ? failed : EAGAIN;
            reported++;
            enif_mutex_unlock(mtx);
        }
    }
    enif_mutex_lock(mtx);
    while (reported < n) enif_cond_wait(cond, mtx);
    int err = failed;
    enif_mutex_unlock(mtx);
    if (err) return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_int(env, err));
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM hash_idle(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    job *j = enif_alloc(sizeof *j);
    if (!j) return enif_make_atom(env, "error");
    if (!parse(env, argv, j) || !enif_self(env, &j->to)) {
        wipe_job(j);
        enif_free(j);
        return enif_make_atom(env, "error");
    }
    j->env = enif_alloc_env();
    j->ref = enif_make_copy(j->env, argv[2]);
    j->next = NULL;
    enif_mutex_lock(mtx);
    if (tail) tail->next = j; else head = j;
    tail = j;
    enif_cond_signal(cond);
    enif_mutex_unlock(mtx);
    return enif_make_atom(env, "ok");
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)env; (void)priv; (void)info;
    mtx = enif_mutex_create("conduit_bcrypt_idle");
    cond = enif_cond_create("conduit_bcrypt_idle");
    return !mtx || !cond;
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
    {"idle_start", 1, idle_start, 0},
    {"hash_idle", 3, hash_idle, 0},
};

ERL_NIF_INIT(Elixir.Conduit.Bcrypt.Nif, funcs, load, NULL, NULL, NULL)
