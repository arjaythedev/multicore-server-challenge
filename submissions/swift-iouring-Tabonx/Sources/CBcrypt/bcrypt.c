// bcrypt (Provos and Mazieres, 1999). The cost is memory-hard table lookups on one chain, so a single
// hash leaves most of a modern core idle. Running five independent hashes in lockstep on one thread
// keeps the load ports busy: five lanes take about as long as two run one after the other.
#define _GNU_SOURCE
#include "bcrypt.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define COST 10
#define LANES 5
#define WORDS (18 + 1024)

// 4,224 bytes: one lane's tables never 4K-alias the next lane's. expand0.S relies on this size.
typedef struct {
    uint32_t P[18];
    uint32_t S[1024];
    uint32_t pad[14];
} bf_state;
_Static_assert(sizeof(bf_state) == 4224, "expand0.S");

static const uint32_t pi_words[WORDS] = {
#include "pi.inc"
};

#define F(st, x)                                                                                     \
    ((((st)->S[(x) >> 24] + (st)->S[256 + (((x) >> 16) & 255)]) ^ (st)->S[512 + (((x) >> 8) & 255)]) \
     + (st)->S[768 + ((x) & 255)])

static inline void encrypt_one(const bf_state *st, uint32_t *lp, uint32_t *rp) {
    uint32_t l = *lp ^ st->P[0], r = *rp;
    for (int i = 1; i <= 16; i += 2) {
        r ^= F(st, l) ^ st->P[i];
        l ^= F(st, r) ^ st->P[i + 1];
    }
    *lp = r ^ st->P[17];
    *rp = l;
}

// One encryption in every lane, interleaved round by round.
#define ROUND5(a, b, i)                                  \
    a##0 ^= F(st + 0, b##0) ^ st[0].P[i];                \
    a##1 ^= F(st + 1, b##1) ^ st[1].P[i];                \
    a##2 ^= F(st + 2, b##2) ^ st[2].P[i];                \
    a##3 ^= F(st + 3, b##3) ^ st[3].P[i];                \
    a##4 ^= F(st + 4, b##4) ^ st[4].P[i];

#define ENCRYPT5                                                                                  \
    do {                                                                                          \
        l0 ^= st[0].P[0]; l1 ^= st[1].P[0]; l2 ^= st[2].P[0]; l3 ^= st[3].P[0]; l4 ^= st[4].P[0]; \
        ROUND5(r, l, 1) ROUND5(l, r, 2) ROUND5(r, l, 3) ROUND5(l, r, 4)                           \
        ROUND5(r, l, 5) ROUND5(l, r, 6) ROUND5(r, l, 7) ROUND5(l, r, 8)                           \
        ROUND5(r, l, 9) ROUND5(l, r, 10) ROUND5(r, l, 11) ROUND5(l, r, 12)                        \
        ROUND5(r, l, 13) ROUND5(l, r, 14) ROUND5(r, l, 15) ROUND5(l, r, 16)                       \
        uint32_t t;                                                                               \
        t = r0 ^ st[0].P[17]; r0 = l0; l0 = t;                                                    \
        t = r1 ^ st[1].P[17]; r1 = l1; l1 = t;                                                    \
        t = r2 ^ st[2].P[17]; r2 = l2; l2 = t;                                                    \
        t = r3 ^ st[3].P[17]; r3 = l3; l3 = t;                                                    \
        t = r4 ^ st[4].P[17]; r4 = l4; l4 = t;                                                    \
    } while (0)

#if defined(__x86_64__) && defined(__linux__) && !defined(BC_NO_KERNEL)
#define BC_HAVE_KERNEL 1
void bc_expand0_5(bf_state *states); // expand0.S
static int use_kernel;
__attribute__((constructor)) static void pick_kernel(void) { use_kernel = __builtin_cpu_supports("bmi2"); }
#else
#define BC_HAVE_KERNEL 0
#endif

// The key schedule of all lanes: XOR `key` into P, then replace P and the S-boxes with a chain of
// encryptions, mixing in `salt` when it isn't NULL.
static void expand5(bf_state *restrict st, const uint32_t key[LANES][18], const uint32_t salt[LANES][4]) {
    for (int k = 0; k < LANES; k++)
        for (int i = 0; i < 18; i++) st[k].P[i] ^= key[k][i];
#if BC_HAVE_KERNEL
    if (!salt && use_kernel) {
        bc_expand0_5(st);
        return;
    }
#endif
    uint32_t l0 = 0, l1 = 0, l2 = 0, l3 = 0, l4 = 0, r0 = 0, r1 = 0, r2 = 0, r3 = 0, r4 = 0;
    int s = 0;
#define MIX                                                                     \
    if (salt) {                                                                 \
        l0 ^= salt[0][s]; l1 ^= salt[1][s]; l2 ^= salt[2][s]; l3 ^= salt[3][s]; l4 ^= salt[4][s]; \
        r0 ^= salt[0][s + 1]; r1 ^= salt[1][s + 1]; r2 ^= salt[2][s + 1];       \
        r3 ^= salt[3][s + 1]; r4 ^= salt[4][s + 1];                             \
        s ^= 2;                                                                 \
    }
    for (int i = 0; i < 18; i += 2) {
        MIX
        ENCRYPT5;
        st[0].P[i] = l0; st[0].P[i + 1] = r0;
        st[1].P[i] = l1; st[1].P[i + 1] = r1;
        st[2].P[i] = l2; st[2].P[i + 1] = r2;
        st[3].P[i] = l3; st[3].P[i + 1] = r3;
        st[4].P[i] = l4; st[4].P[i + 1] = r4;
    }
    for (int i = 0; i < 1024; i += 2) {
        MIX
        ENCRYPT5;
        st[0].S[i] = l0; st[0].S[i + 1] = r0;
        st[1].S[i] = l1; st[1].S[i + 1] = r1;
        st[2].S[i] = l2; st[2].S[i + 1] = r2;
        st[3].S[i] = l3; st[3].S[i + 1] = r3;
        st[4].S[i] = l4; st[4].S[i + 1] = r4;
    }
}

// Cycles `bytes` through 18 big-endian words, as the key schedule reads a key.
static void cycle_words(const uint8_t *bytes, int n, uint32_t out[18]) {
    int j = 0;
    for (int i = 0; i < 18; i++) {
        uint32_t w = 0;
        for (int k = 0; k < 4; k++) {
            w = w << 8 | bytes[j];
            j = (j + 1) % n;
        }
        out[i] = w;
    }
}

static const char alphabet[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

static void encode64(const uint8_t *in, int n, char *out) {
    int i = 0;
    while (i < n) {
        uint32_t c1 = in[i++];
        *out++ = alphabet[c1 >> 2];
        c1 = (c1 & 3) << 4;
        if (i >= n) {
            *out++ = alphabet[c1];
            break;
        }
        uint32_t c2 = in[i++];
        c1 |= c2 >> 4;
        *out++ = alphabet[c1];
        c1 = (c2 & 15) << 2;
        if (i >= n) {
            *out++ = alphabet[c1];
            break;
        }
        c2 = in[i++];
        c1 |= c2 >> 6;
        *out++ = alphabet[c1];
        *out++ = alphabet[c2 & 63];
    }
    *out = 0;
}

static int decode_value(char c) {
    if (c == '.') return 0;
    if (c == '/') return 1;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 2;
    if (c >= 'a' && c <= 'z') return c - 'a' + 28;
    if (c >= '0' && c <= '9') return c - '0' + 54;
    return -1;
}

static int decode64(const char *in, int n, uint8_t *out) {
    uint32_t bits = 0;
    int have = 0, written = 0;
    for (int i = 0; written < n; i++) {
        int v = decode_value(in[i]);
        if (v < 0) return 0;
        bits = bits << 6 | (uint32_t)v;
        have += 6;
        if (have >= 8) {
            have -= 8;
            out[written++] = (uint8_t)(bits >> have);
        }
    }
    return 1;
}

// Hashes `count` (1 to 5) passwords with their 16-byte salts. Unused lanes repeat lane 0.
static void hash_lanes(const uint8_t *const passwords[LANES], const int lens[LANES], const uint8_t salts[LANES][16],
                       uint8_t digests[LANES][24]) {
    static _Thread_local bf_state *st;
    if (!st && posix_memalign((void **)&st, 64, sizeof(bf_state) * LANES) != 0) abort();
    uint32_t key[LANES][18], salt_key[LANES][18], salt[LANES][4];
    for (int k = 0; k < LANES; k++) {
        memcpy(&st[k], pi_words, sizeof pi_words);
        uint8_t bytes[73];
        int n = lens[k] > 72 ? 72 : lens[k];
        memcpy(bytes, passwords[k], (size_t)n);
        bytes[n] = 0; // the key includes the terminating NUL
        cycle_words(bytes, n < 72 ? n + 1 : 72, key[k]);
        cycle_words(salts[k], 16, salt_key[k]);
        memcpy(salt[k], salt_key[k], sizeof salt[k]);
    }
    expand5(st, key, salt);
    for (uint32_t i = 0; i < (1u << COST); i++) {
        expand5(st, key, NULL);
        expand5(st, salt_key, NULL);
    }
    for (int k = 0; k < LANES; k++) {
        static const char magic[] = "OrpheanBeholderScryDoubt";
        uint32_t block[6];
        for (int i = 0; i < 6; i++) {
            const uint8_t *m = (const uint8_t *)magic + i * 4;
            block[i] = (uint32_t)m[0] << 24 | (uint32_t)m[1] << 16 | (uint32_t)m[2] << 8 | m[3];
        }
        for (int round = 0; round < 64; round++)
            for (int i = 0; i < 6; i += 2) encrypt_one(&st[k], &block[i], &block[i + 1]);
        for (int i = 0; i < 6; i++) {
            digests[k][i * 4] = (uint8_t)(block[i] >> 24);
            digests[k][i * 4 + 1] = (uint8_t)(block[i] >> 16);
            digests[k][i * 4 + 2] = (uint8_t)(block[i] >> 8);
            digests[k][i * 4 + 3] = (uint8_t)block[i];
        }
    }
}

// Parses "$2a$10$<22 salt chars><31 hash chars>". Only cost 10 is ever stored.
static int parse_hash(const char *hash, uint8_t salt[16]) {
    if (strlen(hash) != 60 || hash[0] != '$' || hash[1] != '2' || hash[3] != '$' || hash[4] != '1' ||
        hash[5] != '0' || hash[6] != '$')
        return 0;
    return decode64(hash + 7, 16, salt);
}

static void format_hash(char *out, const uint8_t salt[16], const uint8_t digest[24]) {
    memcpy(out, "$2a$10$", 7);
    encode64(salt, 16, out + 7);
    encode64(digest, 23, out + 29);
}

// Runs up to five jobs in one lockstep pass.
static void run_jobs(bc_job *const *jobs, int n) {
    const uint8_t *passwords[LANES];
    int lens[LANES];
    uint8_t salts[LANES][16], digests[LANES][24];
    int valid[LANES];
    for (int k = 0; k < LANES; k++) {
        bc_job *job = jobs[k < n ? k : 0];
        passwords[k] = job->password;
        lens[k] = job->password_len;
        valid[k] = 1;
        if (job->verify) {
            valid[k] = parse_hash(job->hash, salts[k]);
            if (!valid[k]) memset(salts[k], 0, 16);
        } else if (getrandom(salts[k], 16, 0) != 16) {
            valid[k] = 0;
        }
    }
    hash_lanes(passwords, lens, salts, digests);
    for (int k = 0; k < n; k++) {
        bc_job *job = jobs[k];
        char made[61];
        format_hash(made, salts[k], digests[k]);
        if (job->verify) {
            unsigned diff = !valid[k];
            for (int i = 7; i < 60; i++) diff |= (unsigned)(made[i] ^ job->hash[i]);
            job->matched = diff == 0;
        } else {
            memcpy(job->hash, made, 61);
            job->matched = valid[k];
        }
    }
}

int bc_check(const uint8_t *password, int len, const char *hash) {
    bc_job job;
    memset(&job, 0, sizeof job);
    job.verify = 1;
    job.password_len = len > 72 ? 72 : len;
    memcpy(job.password, password, (size_t)job.password_len);
    strncpy(job.hash, hash, 60);
    bc_job *list[1] = {&job};
    run_jobs(list, 1);
    return job.matched;
}

static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t queue_ready = PTHREAD_COND_INITIALIZER;
static bc_job *queue_head, *queue_tail;
static int queue_count;

typedef struct {
    pthread_mutex_t lock;
    bc_job *head;
    atomic_int ready;
    char pad[64];
} done_list;
static done_list *done;

// A lockstep pass costs the same with one job or five, so jobs wait this long for company.
#define GATHER_NS 200000000L

static void add_ns(struct timespec *t, long ns) {
    t->tv_nsec += ns;
    while (t->tv_nsec >= 1000000000L) {
        t->tv_nsec -= 1000000000L;
        t->tv_sec++;
    }
}

static void *hash_thread(void *arg) {
    setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), (int)(intptr_t)arg);
    for (;;) {
        bc_job *jobs[LANES];
        int n = 0;
        pthread_mutex_lock(&queue_lock);
        while (!queue_head) pthread_cond_wait(&queue_ready, &queue_lock);
        if (queue_count < LANES) {
            struct timespec until;
            clock_gettime(CLOCK_REALTIME, &until);
            add_ns(&until, GATHER_NS);
            while (queue_count < LANES) {
                if (pthread_cond_timedwait(&queue_ready, &queue_lock, &until) != 0) break;
            }
        }
        while (queue_head && n < LANES) {
            jobs[n++] = queue_head;
            queue_head = queue_head->next;
            queue_count--;
        }
        if (!queue_head) queue_tail = NULL;
        pthread_mutex_unlock(&queue_lock);
        if (n == 0) continue;
        run_jobs(jobs, n);
        for (int k = 0; k < n; k++) {
            done_list *d = &done[jobs[k]->owner];
            pthread_mutex_lock(&d->lock);
            jobs[k]->next = d->head;
            d->head = jobs[k];
            atomic_store_explicit(&d->ready, 1, memory_order_release);
            pthread_mutex_unlock(&d->lock);
        }
    }
    return 0;
}

void bc_start(int threads, int owners) {
    done = calloc((size_t)owners, sizeof *done);
    for (int i = 0; i < owners; i++) pthread_mutex_init(&done[i].lock, 0);
    for (int i = 0; i < threads; i++) {
        pthread_t t;
        pthread_attr_t a;
        pthread_attr_init(&a);
        pthread_attr_setstacksize(&a, 1 << 20);
        // The first keeps logins moving when the box is busy, the rest take what is left over.
        pthread_create(&t, &a, hash_thread, (void *)(intptr_t)(i == 0 ? 0 : 10));
        pthread_attr_destroy(&a);
    }
}

bc_job *bc_new(void) { return calloc(1, sizeof(bc_job)); }

void bc_free(bc_job *job) { free(job); }

void bc_submit(bc_job *job) {
    pthread_mutex_lock(&queue_lock);
    job->next = NULL;
    if (queue_tail) queue_tail->next = job;
    else queue_head = job;
    queue_tail = job;
    queue_count++;
    pthread_cond_broadcast(&queue_ready);
    pthread_mutex_unlock(&queue_lock);
}

bc_job *bc_collect(int owner) {
    done_list *d = &done[owner];
    if (!atomic_load_explicit(&d->ready, memory_order_acquire)) return NULL;
    pthread_mutex_lock(&d->lock);
    bc_job *list = d->head;
    d->head = NULL;
    atomic_store_explicit(&d->ready, 0, memory_order_release);
    pthread_mutex_unlock(&d->lock);
    return list;
}
