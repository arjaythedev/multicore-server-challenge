// 6-lane interleaved OpenBSD 2b EksBlowfish bcrypt (cost 10) with SCHED_BATCH worker priority
// and startup self-test against libxcrypt.
#include "conduit.h"
#include "bf_pi.h"
#include <crypt.h>
#include <sched.h>
#include <sys/random.h>
#include <time.h>
#include <unistd.h>

#define BC_LANES 6
#define BC_WAIT_MS 120

typedef struct {
    uint32_t P[18];
    uint32_t S[4][256];
} bf_t;

#define F(st, x) \
    ((((st)->S[0][(x) >> 24] + (st)->S[1][((x) >> 16) & 0xff]) ^ (st)->S[2][((x) >> 8) & 0xff]) + (st)->S[3][(x) & 0xff])

static inline __attribute__((always_inline)) void enc(int N, bf_t *st, uint32_t *L, uint32_t *R) {
    for (int l = 0; l < N; l++) L[l] ^= st[l].P[0];
    for (int r = 1; r < 17; r += 2) {
        for (int l = 0; l < N; l++) R[l] ^= F(&st[l], L[l]) ^ st[l].P[r];
        for (int l = 0; l < N; l++) L[l] ^= F(&st[l], R[l]) ^ st[l].P[r + 1];
    }
    for (int l = 0; l < N; l++) {
        uint32_t t = L[l];
        L[l] = R[l] ^ st[l].P[17];
        R[l] = t;
    }
}

static inline __attribute__((always_inline)) void expand(int N, bf_t *st, const uint32_t (*kw)[18],
                                                         const uint32_t (*sw)[4]) {
    uint32_t L[N], R[N];
    for (int l = 0; l < N; l++) {
        for (int i = 0; i < 18; i++) st[l].P[i] ^= kw[l][i];
        L[l] = R[l] = 0;
    }
    for (int i = 0; i < 18; i += 2) {
        if (sw)
            for (int l = 0; l < N; l++) L[l] ^= sw[l][i & 3], R[l] ^= sw[l][(i + 1) & 3];
        enc(N, st, L, R);
        for (int l = 0; l < N; l++) st[l].P[i] = L[l], st[l].P[i + 1] = R[l];
    }
    for (int b = 0; b < 4; b++)
        for (int i = 0; i < 256; i += 2) {
            if (sw) {
                int w = 18 + b * 256 + i;
                for (int l = 0; l < N; l++) L[l] ^= sw[l][w & 3], R[l] ^= sw[l][(w + 1) & 3];
            }
            enc(N, st, L, R);
            for (int l = 0; l < N; l++) st[l].S[b][i] = L[l], st[l].S[b][i + 1] = R[l];
        }
}

static inline __attribute__((always_inline)) void eks(int N, const uint32_t (*kw)[18], const uint32_t (*sw)[4],
                                                      int cost, uint8_t (*out)[24]) {
    alignas(64) bf_t st[N];
    uint32_t ss[N][18], c[N][6];
    for (int l = 0; l < N; l++) {
        memcpy(st[l].P, BF_P0, sizeof BF_P0);
        memcpy(st[l].S, BF_S0, sizeof BF_S0);
        for (int i = 0; i < 18; i++) ss[l][i] = sw[l][i & 3];
    }
    expand(N, st, kw, sw);
    for (uint64_t r = 0; r < (1ull << cost); r++) {
        expand(N, st, kw, NULL);
        expand(N, st, (const uint32_t(*)[18])ss, NULL);
    }
    static const uint32_t ORPHEAN[6] = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
    for (int l = 0; l < N; l++) memcpy(c[l], ORPHEAN, sizeof ORPHEAN);
    for (int k = 0; k < 64; k++)
        for (int j = 0; j < 6; j += 2) {
            uint32_t L[N], R[N];
            for (int l = 0; l < N; l++) L[l] = c[l][j], R[l] = c[l][j + 1];
            enc(N, st, L, R);
            for (int l = 0; l < N; l++) c[l][j] = L[l], c[l][j + 1] = R[l];
        }
    for (int l = 0; l < N; l++)
        for (int j = 0; j < 6; j++) {
            out[l][4 * j] = (uint8_t)(c[l][j] >> 24);
            out[l][4 * j + 1] = (uint8_t)(c[l][j] >> 16);
            out[l][4 * j + 2] = (uint8_t)(c[l][j] >> 8);
            out[l][4 * j + 3] = (uint8_t)c[l][j];
        }
}

#define EKS_N(n) \
    static __attribute__((noinline)) void eks##n(const uint32_t (*kw)[18], const uint32_t (*sw)[4], int cost, \
                                                 uint8_t (*out)[24]) { eks(n, kw, sw, cost, out); }
EKS_N(1)
EKS_N(2)
EKS_N(3)
EKS_N(4)
EKS_N(5)
EKS_N(6)

static const char BB64[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

static void bb64_enc(char *o, const uint8_t *p, size_t n) {
    const uint8_t *e = p + n;
    while (p < e) {
        unsigned c1 = *p++;
        *o++ = BB64[c1 >> 2];
        c1 = (c1 & 3) << 4;
        if (p >= e) { *o++ = BB64[c1]; break; }
        unsigned c2 = *p++;
        *o++ = BB64[c1 | c2 >> 4];
        c1 = (c2 & 15) << 2;
        if (p >= e) { *o++ = BB64[c1]; break; }
        c2 = *p++;
        *o++ = BB64[c1 | c2 >> 6];
        *o++ = BB64[c2 & 63];
    }
    *o = 0;
}

static inline int bb64v(char c) {
    unsigned char u = (unsigned char)c;
    if (__builtin_expect(u >= 'A' && u <= 'Z', 1)) return (int)(u - 'A' + 2);
    if (__builtin_expect(u >= 'a' && u <= 'z', 1)) return (int)(u - 'a' + 28);
    if (__builtin_expect(u >= '0' && u <= '9', 1)) return (int)(u - '0' + 54);
    if (u == '.') return 0;
    if (u == '/') return 1;
    return -1;
}

static bool bb64_dec16(uint8_t out[16], const char *s) {
    int o = 0;
    for (int i = 0; i < 22 && o < 16; i += 4) {
        int c1 = bb64v(s[i]), c2 = bb64v(s[i + 1]);
        if (c1 < 0 || c2 < 0) return false;
        out[o++] = (uint8_t)(c1 << 2 | c2 >> 4);
        if (o == 16) break;
        int c3 = bb64v(s[i + 2]);
        if (c3 < 0) return false;
        out[o++] = (uint8_t)((c2 & 15) << 4 | c3 >> 2);
        int c4 = bb64v(s[i + 3]);
        if (c4 < 0) return false;
        out[o++] = (uint8_t)((c3 & 3) << 6 | c4);
    }
    return true;
}

static bool parse_setting(const char *s, int *cost, uint32_t sw[4]) {
    if (!s || s[0] != '$' || s[1] != '2' || (s[2] != 'a' && s[2] != 'b' && s[2] != 'y') || s[3] != '$') return false;
    if (s[4] < '0' || s[4] > '3' || s[5] < '0' || s[5] > '9' || s[6] != '$') return false;
    *cost = (s[4] - '0') * 10 + (s[5] - '0');
    if (*cost < 4 || *cost > 31 || strnlen(s + 7, 22) < 22) return false;
    uint8_t salt[16];
    if (!bb64_dec16(salt, s + 7)) return false;
    for (int i = 0; i < 4; i++)
        sw[i] = (uint32_t)salt[4 * i] << 24 | (uint32_t)salt[4 * i + 1] << 16 | (uint32_t)salt[4 * i + 2] << 8 | salt[4 * i + 3];
    return true;
}

static void key_words(const char *pw, uint32_t kw[18]) {
    size_t n = strlen(pw);
    if (n > 72) n = 72;
    size_t klen = n + 1, j = 0;
    for (int i = 0; i < 18; i++) {
        uint32_t w = 0;
        for (int k = 0; k < 4; k++) {
            uint8_t ch = j < n ? (uint8_t)pw[j] : 0;
            w = w << 8 | ch;
            j = j + 1 == klen ? 0 : j + 1;
        }
        kw[i] = w;
    }
}

static void bcrypt_batch(job_t **jobs, int n, int cost) {
    uint32_t kw[BC_LANES][18], sw[BC_LANES][4];
    uint8_t ct[BC_LANES][24];
    for (int l = 0; l < n; l++) {
        int c = cost;
        parse_setting(jobs[l]->setting, &c, sw[l]);
        key_words(jobs[l]->pw, kw[l]);
    }
    switch (n) {
    case 1: eks1((const uint32_t(*)[18])kw, (const uint32_t(*)[4])sw, cost, ct); break;
    case 2: eks2((const uint32_t(*)[18])kw, (const uint32_t(*)[4])sw, cost, ct); break;
    case 3: eks3((const uint32_t(*)[18])kw, (const uint32_t(*)[4])sw, cost, ct); break;
    case 4: eks4((const uint32_t(*)[18])kw, (const uint32_t(*)[4])sw, cost, ct); break;
    case 5: eks5((const uint32_t(*)[18])kw, (const uint32_t(*)[4])sw, cost, ct); break;
    default: eks6((const uint32_t(*)[18])kw, (const uint32_t(*)[4])sw, cost, ct); break;
    }
    for (int l = 0; l < n; l++) {
        memcpy(jobs[l]->out, jobs[l]->setting, 29);
        bb64_enc(jobs[l]->out + 29, ct[l], 23);
        if (jobs[l]->hash) {
            jobs[l]->ok = true;
        } else {
            const char *expect = jobs[l]->setting;
            size_t elen = strlen(expect);
            uint8_t diff = (uint8_t)(elen ^ 60);
            for (size_t i = 0; i < 60 && i < elen; i++) diff |= (uint8_t)(jobs[l]->out[i] ^ expect[i]);
            jobs[l]->ok = (diff == 0);
        }
    }
}

static void bcrypt_fallback(job_t *j) {
    struct crypt_data cd;
    memset(&cd, 0, sizeof cd);
    if (j->hash) {
        char *s = crypt_gensalt_rn("$2b$", 10, NULL, 0, cd.setting, sizeof cd.setting);
        char *h = s ? crypt_rn(j->pw, s, &cd, sizeof cd) : NULL;
        if (h && h[0] == '$') {
            snprintf(j->out, sizeof j->out, "%s", h);
            j->ok = true;
        }
    } else if (j->setting && j->setting[0] == '$') {
        char *h = crypt_rn(j->pw, j->setting, &cd, sizeof cd);
        if (h) {
            size_t a = strlen(h), b = strlen(j->setting);
            uint8_t diff = (uint8_t)(a ^ b);
            for (size_t i = 0; i < a && i < b; i++) diff |= (uint8_t)(h[i] ^ j->setting[i]);
            j->ok = (diff == 0);
        }
    }
}

static bool prepare_job(job_t *j, char gen_setting[30], int *cost_out) {
    if (j->hash) {
        uint8_t raw[16];
        if (getrandom(raw, sizeof raw, 0) != (ssize_t)sizeof raw) return false;
        memcpy(gen_setting, "$2b$10$", 7);
        bb64_enc(gen_setting + 7, raw, 16);
        j->setting = gen_setting;
        *cost_out = 10;
        return true;
    }
    uint32_t sw[4];
    return parse_setting(j->setting, cost_out, sw);
}

static pthread_mutex_t q_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t q_cv;
static job_t *q_head, *q_tail;

void submit_job(job_t *j) {
    if (__builtin_expect(STATS_ON, 0)) j->t_enq = stats_now();
    j->next = NULL;
    pthread_mutex_lock(&q_mu);
    if (q_tail) q_tail->next = j;
    else q_head = j;
    q_tail = j;
    pthread_cond_signal(&q_cv);
    pthread_mutex_unlock(&q_mu);
}

static void complete_job(job_t *j) {
    worker_t *w = j->r->w;
    pthread_mutex_lock(&w->done_mu);
    j->done_next = w->done_head;
    w->done_head = j;
    pthread_mutex_unlock(&w->done_mu);
    uint64_t one = 1;
    if (write(w->evfd, &one, 8) < 0) {}
}

static void *bcrypt_worker(void *arg) {
    intptr_t thread_idx = (intptr_t)arg;
    int cpus = count_cpus();
    if (cpus > 4) {
        cpu_set_t cpuset;
        CPU_ZERO(&cpuset);
        int target_core = 4 + (int)(thread_idx % (cpus - 4));
        CPU_SET(target_core, &cpuset);
        pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
    }
    struct sched_param sp = {.sched_priority = 0};
    if (pthread_setschedparam(pthread_self(), SCHED_BATCH, &sp) != 0) {
        if (nice(10) < 0) {}
    }

    job_t *batch[BC_LANES];
    char gen[BC_LANES][30];

    for (;;) {
        pthread_mutex_lock(&q_mu);
        while (!q_head) pthread_cond_wait(&q_cv, &q_mu);

        struct timespec dl;
        clock_gettime(CLOCK_MONOTONIC, &dl);
        dl.tv_nsec += (long)BC_WAIT_MS * 1000000L;
        if (dl.tv_nsec >= 1000000000L) { dl.tv_sec++; dl.tv_nsec -= 1000000000L; }

        int n = 0, batch_cost = -1;
        while (n < BC_LANES) {
            if (!q_head) {
                if (pthread_cond_timedwait(&q_cv, &q_mu, &dl) != 0 || !q_head) break;
            }
            job_t *j = q_head;
            int c = 0;
            bool ok = prepare_job(j, gen[n], &c);
            if (!ok) {
                if (n > 0) break;
                q_head = j->next;
                if (!q_head) q_tail = NULL;
                pthread_mutex_unlock(&q_mu);
                bcrypt_fallback(j);
                complete_job(j);
                goto next_iter;
            }
            if (batch_cost < 0) batch_cost = c;
            else if (c != batch_cost) break;
            q_head = j->next;
            if (!q_head) q_tail = NULL;
            batch[n++] = j;
        }
        if (q_head) pthread_cond_signal(&q_cv);
        pthread_mutex_unlock(&q_mu);

        bcrypt_batch(batch, n, batch_cost);
        for (int k = 0; k < n; k++) complete_job(batch[k]);
    next_iter:;
    }
    return NULL;
}

void bcrypt_pool_init(int nthreads) {
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&q_cv, &ca);
    pthread_condattr_destroy(&ca);

    for (int i = 0; i < nthreads; i++) {
        pthread_t t;
        if (pthread_create(&t, NULL, bcrypt_worker, (void *)(intptr_t)i) != 0) die("pthread_create bcrypt");
        pthread_detach(t);
    }
}

int bcrypt_selftest(void) {
    static const char *pws[BC_LANES] = {
        "password123", "", "a-72-byte-ish-password-with-UTF8-\xc3\xa9-and-symbols-!@#$%^&*()", "conduit",
        "bench-lane-5", "bench-lane-6-extra",
    };
    static const char *salts[BC_LANES] = {
        "$2b$10$N9qo8uLOickgx2ZMRZoMye", "$2a$06$abcdefghijklmnopqrstuu",
        "$2b$08$0123456789abcdef01234u", "$2y$10$usesomesillystringfore",
        "$2b$10$abcdefghijklmnopqrstuu", "$2b$10$0123456789abcdef01234u",
    };
    for (int lanes = 1; lanes <= BC_LANES; lanes++) {
        job_t jobs[BC_LANES] = {0};
        job_t *ptrs[BC_LANES];
        for (int k = 0; k < lanes; k++) {
            jobs[k].hash = true;
            jobs[k].pw = pws[k];
            jobs[k].setting = salts[0];
            ptrs[k] = &jobs[k];
        }
        bcrypt_batch(ptrs, lanes, 10);
        for (int k = 0; k < lanes; k++) {
            struct crypt_data cd;
            memset(&cd, 0, sizeof cd);
            char *ref = crypt_rn(pws[k], salts[0], &cd, sizeof cd);
            if (!ref || strcmp(jobs[k].out, ref) != 0) {
                fprintf(stderr, "FAIL lane=%d/%d got=%s want=%s\n", k, lanes, jobs[k].out, ref ? ref : "NULL");
                return 1;
            }
        }
    }
    for (int k = 0; k < BC_LANES; k++) {
        int cost = 0;
        uint32_t sw[4];
        parse_setting(salts[k], &cost, sw);
        job_t j = {.hash = true, .pw = pws[k], .setting = salts[k]};
        job_t *p = &j;
        bcrypt_batch(&p, 1, cost);
        struct crypt_data cd;
        memset(&cd, 0, sizeof cd);
        char *ref = crypt_rn(pws[k], salts[k], &cd, sizeof cd);
        if (!ref || strcmp(j.out, ref) != 0) {
            fprintf(stderr, "FAIL single k=%d got=%s want=%s\n", k, j.out, ref ? ref : "NULL");
            return 1;
        }
    }
    printf("bcrypt self-test ok (1..%d lanes match libxcrypt)\n", BC_LANES);
    return 0;
}
