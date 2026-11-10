/* bcrypt.c - bcrypt cost 10, up to 4 independent hashes step-locked per
 * gather batch so the serial Feistel chain of one hash overlaps the others
 * (instruction-level parallelism; roughly 4x the throughput of one hash at
 * a time). Semantics follow Go's x/crypto/bcrypt, which produced every
 * seeded hash: key = password bytes truncated to 72 with one 0x00 appended,
 * cycled over the key schedule; $2a$/$2b$/$2y$ compute identically for
 * ASCII passwords. Non-ASCII or >72-byte inputs fall back to libxcrypt's
 * crypt_rn on the bcrypt thread.
 *
 * Pool: dedicated threads pull jobs off one FIFO. When more jobs are
 * already queued they are gathered into a lane batch; a lone job runs
 * immediately with one lane (no added latency at low login rates). */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <crypt.h>

#include <stdio.h>

#include "bcrypt.h"
#include "bf_pi.h"
#include "conduit.h"
#include "util.h"

#define BCRYPT_MAX_LANES 4
#define BCRYPT_QUEUE 4096

typedef struct {
    uint32_t p[18];
    uint32_t s[4][256];
} bf_t;

typedef struct {
    bf_t st;
    const uint8_t *key;   /* password bytes + the appended 0x00 */
    size_t klen;
    const uint8_t *salt;  /* 16 bytes */
    uint8_t out[23];
} lane_t;

#define F(st, x) ((((st)->s[0][(x) >> 24] + (st)->s[1][((x) >> 16) & 255]) ^ \
                   (st)->s[2][((x) >> 8) & 255]) + (st)->s[3][(x) & 255])

__attribute__((always_inline)) static inline void enc1(bf_t *st, uint32_t *l, uint32_t *r)
{
    uint32_t xl = *l ^ st->p[0], xr = *r;
    xr ^= F(st, xl) ^ st->p[1];  xl ^= F(st, xr) ^ st->p[2];
    xr ^= F(st, xl) ^ st->p[3];  xl ^= F(st, xr) ^ st->p[4];
    xr ^= F(st, xl) ^ st->p[5];  xl ^= F(st, xr) ^ st->p[6];
    xr ^= F(st, xl) ^ st->p[7];  xl ^= F(st, xr) ^ st->p[8];
    xr ^= F(st, xl) ^ st->p[9];  xl ^= F(st, xr) ^ st->p[10];
    xr ^= F(st, xl) ^ st->p[11]; xl ^= F(st, xr) ^ st->p[12];
    xr ^= F(st, xl) ^ st->p[13]; xl ^= F(st, xr) ^ st->p[14];
    xr ^= F(st, xl) ^ st->p[15]; xl ^= F(st, xr) ^ st->p[16];
    *l = xr ^ st->p[17];
    *r = xl;
}

/* cyclic big-endian 4-byte word over a byte string */
static inline uint32_t next_word(const uint8_t *k, size_t klen, size_t *j)
{
    uint32_t d = 0;
    for (int i = 0; i < 4; i++) {
        d = d << 8 | k[*j];
        *j = (*j + 1) % klen;
    }
    return d;
}

/* ExpandKey(source): P ^= cyclic source, then one pass of encryptions
 * through P and through every S-box. Instantiated per lane count so the N
 * independent enc1 chains stay inline and interleave. */
#define EXPAND_KEY(N)                                                            \
    static void expand_key_##N(lane_t *ln, const uint8_t *srcs[N], size_t sl[N]) \
    {                                                                            \
        bf_t *sts[N];                                                            \
        uint32_t l[N], r[N];                                                     \
        for (int k = 0; k < N; k++) {                                            \
            size_t j = 0;                                                        \
            for (int i = 0; i < 18; i++)                                         \
                ln[k].st.p[i] ^= next_word(srcs[k], sl[k], &j);                  \
            sts[k] = &ln[k].st;                                                  \
            l[k] = 0;                                                            \
            r[k] = 0;                                                            \
        }                                                                        \
        for (int i = 0; i < 18; i += 2) {                                        \
            for (int k = 0; k < N; k++) enc1(sts[k], &l[k], &r[k]);              \
            for (int k = 0; k < N; k++) {                                        \
                sts[k]->p[i] = l[k];                                             \
                sts[k]->p[i + 1] = r[k];                                         \
            }                                                                    \
        }                                                                        \
        for (int box = 0; box < 4; box++) {                                      \
            for (int i = 0; i < 256; i += 2) {                                   \
                for (int k = 0; k < N; k++) enc1(sts[k], &l[k], &r[k]);          \
                for (int k = 0; k < N; k++) {                                    \
                    sts[k]->s[box][i] = l[k];                                    \
                    sts[k]->s[box][i + 1] = r[k];                                \
                }                                                                \
            }                                                                    \
        }                                                                        \
    }

EXPAND_KEY(1)
EXPAND_KEY(2)
EXPAND_KEY(3)
EXPAND_KEY(4)

/* NewSaltedCipher: P ^= cyclic key, then the salted pass (salt words mixed
 * into the l/r chain through P and S). */
#define EXPAND_SALTED(N)                                                         \
    static void expand_salted_##N(lane_t *ln)                                    \
    {                                                                            \
        bf_t *sts[N];                                                            \
        uint32_t l[N], r[N];                                                     \
        size_t j[N];                                                             \
        for (int k = 0; k < N; k++) {                                            \
            size_t kj = 0;                                                       \
            for (int i = 0; i < 18; i++)                                         \
                ln[k].st.p[i] ^= next_word(ln[k].key, ln[k].klen, &kj);          \
            sts[k] = &ln[k].st;                                                  \
            l[k] = 0;                                                            \
            r[k] = 0;                                                            \
            j[k] = 0;                                                            \
        }                                                                        \
        for (int i = 0; i < 18; i += 2) {                                        \
            for (int k = 0; k < N; k++) {                                        \
                l[k] ^= next_word(ln[k].salt, 16, &j[k]);                        \
                r[k] ^= next_word(ln[k].salt, 16, &j[k]);                        \
            }                                                                    \
            for (int k = 0; k < N; k++) enc1(sts[k], &l[k], &r[k]);              \
            for (int k = 0; k < N; k++) {                                        \
                sts[k]->p[i] = l[k];                                             \
                sts[k]->p[i + 1] = r[k];                                         \
            }                                                                    \
        }                                                                        \
        for (int box = 0; box < 4; box++) {                                      \
            for (int i = 0; i < 256; i += 2) {                                   \
                for (int k = 0; k < N; k++) {                                    \
                    l[k] ^= next_word(ln[k].salt, 16, &j[k]);                    \
                    r[k] ^= next_word(ln[k].salt, 16, &j[k]);                    \
                }                                                                \
                for (int k = 0; k < N; k++) enc1(sts[k], &l[k], &r[k]);          \
                for (int k = 0; k < N; k++) {                                    \
                    sts[k]->s[box][i] = l[k];                                    \
                    sts[k]->s[box][i + 1] = r[k];                                \
                }                                                                \
            }                                                                    \
        }                                                                        \
    }

EXPAND_SALTED(1)
EXPAND_SALTED(2)
EXPAND_SALTED(3)
EXPAND_SALTED(4)

#define RUN(N)                                                                   \
    static void run_##N(lane_t *ln, int cost)                                    \
    {                                                                            \
        for (int k = 0; k < N; k++) {                                            \
            memcpy(ln[k].st.p, bf_p, sizeof bf_p);                               \
            memcpy(ln[k].st.s, bf_s, sizeof bf_s);                               \
        }                                                                        \
        expand_salted_##N(ln);                                                   \
        const uint8_t *salt[N], *key[N];                                         \
        size_t sl[N], kl[N];                                                     \
        for (int k = 0; k < N; k++) {                                            \
            salt[k] = ln[k].salt; sl[k] = 16;                                    \
            key[k] = ln[k].key; kl[k] = ln[k].klen;                              \
        }                                                                        \
        for (uint32_t i = 0; i < (1u << cost); i++) {                            \
            expand_key_##N(ln, key, kl);                                         \
            expand_key_##N(ln, salt, sl);                                        \
        }                                                                        \
        static const char magic[] = "OrpheanBeholderScryDoubt";                  \
        for (int k = 0; k < N; k++) {                                            \
            uint8_t ct[24];                                                      \
            memcpy(ct, magic, 24);                                               \
            for (int b = 0; b < 3; b++) {                                        \
                uint32_t l = ((uint32_t)ct[b * 8] << 24) | ((uint32_t)ct[b * 8 + 1] << 16) |  \
                             ((uint32_t)ct[b * 8 + 2] << 8) | ct[b * 8 + 3];         \
                uint32_t r = ((uint32_t)ct[b * 8 + 4] << 24) | ((uint32_t)ct[b * 8 + 5] << 16) |  \
                             ((uint32_t)ct[b * 8 + 6] << 8) | ct[b * 8 + 7];         \
                for (int j = 0; j < 64; j++)                                     \
                    enc1(&ln[k].st, &l, &r);                                     \
                ct[b * 8] = l >> 24; ct[b * 8 + 1] = l >> 16;                    \
                ct[b * 8 + 2] = l >> 8; ct[b * 8 + 3] = l;                       \
                ct[b * 8 + 4] = r >> 24; ct[b * 8 + 5] = r >> 16;                \
                ct[b * 8 + 6] = r >> 8; ct[b * 8 + 7] = r;                       \
            }                                                                    \
            memcpy(ln[k].out, ct, 23);                                           \
        }                                                                        \
    }

RUN(1)
RUN(2)
RUN(3)
RUN(4)

/* ---------------------------------------------------------------- bcrypt b64 */

static const char B64T[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

static void b64_bcrypt(const uint8_t *in, size_t n, char *out, int *olen)
{
    int o = 0;
    size_t i = 0;
    for (; i + 3 <= n; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16 | (uint32_t)in[i + 1] << 8 | in[i + 2];
        out[o++] = B64T[v >> 18 & 63]; out[o++] = B64T[v >> 12 & 63];
        out[o++] = B64T[v >> 6 & 63]; out[o++] = B64T[v & 63];
    }
    size_t rem = n - i;
    if (rem == 1) {
        uint32_t v = (uint32_t)in[i] << 16;
        out[o++] = B64T[v >> 18 & 63]; out[o++] = B64T[v >> 12 & 63];
    } else if (rem == 2) {
        uint32_t v = (uint32_t)in[i] << 16 | (uint32_t)in[i + 1] << 8;
        out[o++] = B64T[v >> 18 & 63]; out[o++] = B64T[v >> 12 & 63]; out[o++] = B64T[v >> 6 & 63];
    }
    *olen = o;
}

static int b64_val(char c)
{
    if (c == '.') return 0;
    if (c == '/') return 1;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 2;
    if (c >= 'a' && c <= 'z') return c - 'a' + 28;
    if (c >= '0' && c <= '9') return c - '0' + 54;
    return -1;
}

/* 22 salt chars -> 16 bytes */
static int b64_decode_salt(const char *s, size_t n, uint8_t out[16])
{
    uint32_t acc = 0;
    int bits = 0, o = 0;
    for (size_t i = 0; i < n; i++) {
        int v = b64_val(s[i]);
        if (v < 0) return -1;
        acc = acc << 6 | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o >= 16) return -1;
            out[o++] = (uint8_t)(acc >> bits);
        }
    }
    return o == 16 ? 0 : -1;
}

int bcrypt_parse_hash(const char *hash, int *cost, uint8_t salt[16])
{
    if (strncmp(hash, "$2", 2)) return -1;
    char ver = hash[2];
    if (ver != 'a' && ver != 'b' && ver != 'y') return -1;
    if (hash[3] != '$' || hash[4] < '0' || hash[4] > '3' || hash[5] < '0' || hash[5] > '9' || hash[6] != '$')
        return -1;
    int c = (hash[4] - '0') * 10 + (hash[5] - '0');
    if (c < 4 || c > 31) return -1;
    if (b64_decode_salt(hash + 7, 22, salt)) return -1;
    *cost = c;
    return 0;
}

/* ---------------------------------------------------------------- run */

static void key_of(bcrypt_job_t *j, uint8_t kbuf[73], const uint8_t **key, size_t *klen)
{
    size_t n = j->pwlen < 72 ? j->pwlen : 72;
    memcpy(kbuf, j->pw, n);
    kbuf[n] = 0;
    *key = kbuf;
    *klen = n + 1;
}

void bcrypt_run_jobs(bcrypt_job_t **jobs, int n)
{
    int cost = jobs[0]->cost;
    lane_t ln[BCRYPT_MAX_LANES];
    uint8_t kbufs[BCRYPT_MAX_LANES][73];
    uint8_t salts[BCRYPT_MAX_LANES][16];

    for (int k = 0; k < n; k++) {
        bcrypt_job_t *j = jobs[k];
        const uint8_t *key;
        size_t klen;
        key_of(j, kbufs[k], &key, &klen);
        ln[k].key = kbufs[k];
        ln[k].klen = klen;
        if (j->mode == BCRYPT_HASH)
            memcpy(salts[k], j->saltbin, 16);
        else
            memcpy(salts[k], j->saltbin, 16); /* verify: submitter pre-parsed */
        ln[k].salt = salts[k];
    }

    switch (n) {
    case 1: run_1(ln, cost); break;
    case 2: run_2(ln, cost); break;
    case 3: run_3(ln, cost); break;
    default: run_4(ln, cost); break;
    }

    for (int k = 0; k < n; k++) {
        bcrypt_job_t *j = jobs[k];
        if (j->mode == BCRYPT_HASH) {
            char enc[32];
            int elen;
            b64_bcrypt(salts[k], 16, enc, &elen);
            char henc[48];
            int hlen;
            b64_bcrypt(ln[k].out, 23, henc, &hlen);
            snprintf(j->hash, sizeof j->hash, "$2a$%02d$%.*s%.*s", cost, elen, enc, hlen, henc);
        } else {
            char enc[32];
            int elen;
            b64_bcrypt(ln[k].out, 23, enc, &elen);
            size_t hl = strlen(j->hash);
            j->verified = (elen == 31 && hl == BCRYPT_HASHLEN &&
                           memcmp(j->hash + BCRYPT_HASHLEN - 31, enc, 31) == 0);
        }
    }
}

/* ---------------------------------------------------------------- libxcrypt */

/* Runs on a bcrypt thread: 32 KB crypt_data on the heap once per thread. */
static __thread struct crypt_data *cd;

static void fallback_run(bcrypt_job_t *j)
{
    if (!cd) {
        cd = calloc(1, sizeof *cd);
        if (!cd) { if (j->mode == BCRYPT_VERIFY) j->verified = 0; return; }
    }
    cd->initialized = 0;
    if (j->mode == BCRYPT_VERIFY) {
        char *r = crypt_rn(j->pw, j->hash, cd, sizeof *cd);
        size_t n = r ? strlen(r) : 0;
        j->verified = (n == BCRYPT_HASHLEN && memcmp(r, j->hash, BCRYPT_HASHLEN) == 0);
    } else {
        char setting[64];
        snprintf(setting, sizeof setting, "$2b$%02d$", j->cost);
        char *salt = crypt_gensalt_rn(setting, 0, NULL, 0, setting, sizeof setting);
        if (!salt) return;
        char *r = crypt_rn(j->pw, salt, cd, sizeof *cd);
        if (r && strlen(r) == BCRYPT_HASHLEN)
            memcpy(j->hash, r, BCRYPT_HASHLEN + 1);
    }
}

/* ---------------------------------------------------------------- pool */

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static bcrypt_job_t *g_q[BCRYPT_QUEUE];
static int g_qn, g_qhead;

static void push_front(bcrypt_job_t *j)
{
    g_qhead = (g_qhead + BCRYPT_QUEUE - 1) % BCRYPT_QUEUE;
    g_q[g_qhead] = j;
    g_qn++;
}

void bcrypt_submit(bcrypt_job_t *j)
{
    pthread_mutex_lock(&g_mu);
    while (g_qn == BCRYPT_QUEUE) {
        pthread_mutex_unlock(&g_mu);
        usleep(200);
        pthread_mutex_lock(&g_mu);
    }
    g_q[(g_qhead + g_qn) % BCRYPT_QUEUE] = j;
    g_qn++;
    pthread_cond_broadcast(&g_cv);
    pthread_mutex_unlock(&g_mu);
}

static bcrypt_job_t *take_one(void)
{
    if (!g_qn) return NULL;
    bcrypt_job_t *j = g_q[g_qhead];
    g_qhead = (g_qhead + 1) % BCRYPT_QUEUE;
    g_qn--;
    return j;
}

static void deliver(bcrypt_job_t *j)
{
    req_t *r = j->req;
    worker_t *w = r->w;
    pthread_mutex_lock(&w->mu);
    j->next = w->done;
    w->done = j;
    pthread_mutex_unlock(&w->mu);
    uint64_t one = 1;
    if (write(w->evfd, &one, sizeof one) != sizeof one) { /* loop will still poll */ }
}

static void *bcrypt_main(void *arg)
{
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&g_mu);
        while (!g_qn) pthread_cond_wait(&g_cv, &g_mu);
        bcrypt_job_t *first = take_one();
        bcrypt_job_t *batch[BCRYPT_MAX_LANES] = { first };
        int n = 1;

        if (first->fallback) {
            pthread_mutex_unlock(&g_mu);
            fallback_run(first);
            deliver(first);
            continue;
        }

        /* a lone job with nothing queued runs immediately: no added latency */
        if (!g_qn) {
            pthread_mutex_unlock(&g_mu);
            bcrypt_run_jobs(batch, 1);
            deliver(first);
            continue;
        }

        /* gather same-cost lanes; a different-cost job goes back to the head */
        while (n < cfg.bcrypt_lanes && g_qn) {
            bcrypt_job_t *j = take_one();
            if (j->cost == first->cost && !j->fallback) {
                batch[n++] = j;
            } else {
                push_front(j);
                break;
            }
        }
        pthread_mutex_unlock(&g_mu);

        for (int k = 0; k < n; k++)
            if (batch[k]->fallback) {
                fallback_run(batch[k]);
                batch[k] = batch[--n]; /* replace with nothing; shrink */
                k--;
            }
        if (n) bcrypt_run_jobs(batch, n);
        for (int k = 0; k < n; k++) deliver(batch[k]);
    }
    return NULL;
}

void bcrypt_pool_start(int threads)
{
    for (int i = 0; i < threads; i++) {
        pthread_t t;
        if (pthread_create(&t, NULL, bcrypt_main, NULL)) {
            if (i == 0) { /* cannot run without any hasher */ exit(1); }
            break;
        }
        pthread_detach(t);
    }
}

/* ---------------------------------------------------------------- selftest */

static uint64_t rng_state = 0x9e3779b97f4a7c15ULL;

static uint32_t rnd(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return (uint32_t)(rng_state >> 32);
}

int bcrypt_selftest(void)
{
    /* the seed's own hash must verify */
    bcrypt_job_t v = { .mode = BCRYPT_VERIFY, .cost = 10,
                       .hash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq" };
    strcpy(v.pw, "password123");
    v.pwlen = 11;
    int cost;
    uint8_t salt[16];
    if (bcrypt_parse_hash(v.hash, &cost, salt)) return 6;
    v.cost = cost;
    memcpy(v.saltbin, salt, 16);
    bcrypt_run_jobs((bcrypt_job_t *[]){ &v }, 1);
    if (!v.verified) return 1;

    /* and must reject a wrong password */
    strcpy(v.pw, "password124");
    bcrypt_run_jobs((bcrypt_job_t *[]){ &v }, 1);
    if (v.verified) return 2;

    /* random ASCII passwords: our hash == libxcrypt's verdict */
    rng_state = 0x123456789abcdefULL ^ (uint64_t)getpid();
    for (int i = 0; i < 24; i++) {
        char pw[80];
        size_t n = 1 + rnd() % 72;
        for (size_t k = 0; k < n; k++) pw[k] = (char)(0x21 + rnd() % 0x5e);
        bcrypt_job_t h = { .mode = BCRYPT_HASH, .cost = 5, .pwlen = n };
        memcpy(h.pw, pw, n);
        for (int k = 0; k < 16; k++) h.saltbin[k] = (uint8_t)rnd();
        bcrypt_run_jobs((bcrypt_job_t *[]){ &h }, 1);

        cd = NULL;
        struct crypt_data d;
        memset(&d, 0, sizeof d);
        char *r = crypt_rn(h.pw, h.hash, &d, sizeof d);
        if (!r || strlen(r) != BCRYPT_HASHLEN || memcmp(r, h.hash, BCRYPT_HASHLEN)) return 3;

        /* and a libxcrypt-generated hash verifies with ours */
        bcrypt_job_t w2 = { .mode = BCRYPT_VERIFY, .cost = 5, .pwlen = n };
        memcpy(w2.pw, pw, n);
        strcpy(w2.hash, r);
        int c;
        uint8_t salt[16];
        if (bcrypt_parse_hash(w2.hash, &c, salt)) return 4;
        w2.cost = c;
        memcpy(w2.saltbin, salt, 16);
        bcrypt_run_jobs((bcrypt_job_t *[]){ &w2 }, 1);
        if (!w2.verified) return 5;
    }
    cd = NULL;
    return 0;
}
