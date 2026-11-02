// Shared types of the server: jobs, per-thread arenas, wire client, event loops.
#pragma once
#include <setjmp.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define likely(x) __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)

static inline int64_t now_us(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000000LL + t.tv_nsec / 1000;
}

// ---- growable bytes
typedef struct {
  char *p;
  size_t n, cap;
} buf_t;
void buf_grow(buf_t *b, size_t need);
static inline void buf_need(buf_t *b, size_t add) {
  if (unlikely(b->n + add > b->cap)) buf_grow(b, b->n + add);
}
static inline void buf_put(buf_t *b, const void *s, size_t l) {
  buf_need(b, l);
  memcpy(b->p + b->n, s, l);
  b->n += l;
}
#define buf_lit(b, s) buf_put((b), (s), sizeof(s) - 1)
static inline void buf_ch(buf_t *b, char c) {
  buf_need(b, 1);
  b->p[b->n++] = c;
}
void buf_i64(buf_t *b, int64_t v);
void buf_json(buf_t *b, const char *s, size_t l);  // escaped, no quotes
void buf_ts(buf_t *b, int64_t pg_us);              // quoted RFC 3339 from Postgres microseconds

// ---- per-thread arena: bump allocation reset per batch; overflow fails the batch through longjmp
typedef struct {
  char *base;
  size_t off, size;
  jmp_buf *fail;
} arena_t;
void arena_init(arena_t *a, size_t size);
static inline void *arena_alloc(arena_t *a, size_t n);
void arena_overflow(arena_t *a);
static inline void *arena_alloc(arena_t *a, size_t n) {
  n = (n + 15) & ~(size_t)15;
  if (unlikely(a->off + n > a->size)) arena_overflow(a);
  void *p = a->base + a->off;
  a->off += n;
  return p;
}

// Scheduling of the calling thread. policy: "batch", "idle" or "" for the default.
void thread_sched(const char *policy, int nice);

// ---- crypto
void sha256_init_cpu(void);
void hmac_jwt_init(const char *secret, size_t len);
bool jwt_verify(const char *tok, size_t len, int64_t *sub);
size_t jwt_issue(int64_t uid, char *out);  // out >= 256 bytes
void sha256(const void *d, size_t n, uint8_t out[32]);
void hmac_sha256(const void *k, size_t kl, const void *d, size_t n, uint8_t out[32]);
void pbkdf2_sha256(const void *pw, size_t pl, const void *salt, size_t sl, int iters, uint8_t out[32]);
size_t b64_std_encode(const uint8_t *in, size_t n, char *out);
int b64_std_decode(const char *in, size_t n, uint8_t *out);

// ---- bcrypt: a job is one password + either an encoded hash to verify or a salt to hash with
#define BCRYPT_LEN 60
void bcrypt_gen_salt(char out[30]);  // "$2a$10$" + 22 chars
// Runs n <= BCRYPT_MAX_LANES bcrypts in lockstep; settings are 29+ chars hash prefixes; out gets 60-char hashes
// (out[i][0] = 0 when the setting is unusable).
#define BCRYPT_MAX_LANES 8
void bcrypt_lanes(int n, const char *const pw[], const size_t pl[], const char *const setting[], char out[][BCRYPT_LEN + 1]);
void bcrypt_selftest(void);
bool ct_eq(const char *a, const char *b, size_t n);

// ---- gzip
void gz_init(void);
size_t gz_encode(const uint8_t *in, size_t n, uint8_t *out, size_t limit);

// ---- request jobs
enum {
  K_TAGS,
  K_USER,
  K_LOGIN,
  K_PROFILE,
  K_LIST_ALL,
  K_LIST_TAG,
  K_LIST_AUTHOR,
  K_LIST_FAV,
  K_FEED,
  K_ARTICLE_SLUG,
  K_ARTICLE_ID,
  K_COMMENTS,
  W_REGISTER,
  W_USER,
  W_FOLLOW,
  W_UNFOLLOW,
  W_FAV,
  W_UNFAV,
  W_ARTICLE,
  W_ARTICLE_PUT,
  W_ARTICLE_DEL,
  W_COMMENT,
  W_COMMENT_DEL,
};

typedef struct job {
  struct job *next;
  uint8_t kind, close, gzip, attempts;
  uint16_t loop, status_hint;
  int32_t fd;
  uint32_t gen;
  int64_t viewer, lim, off, id;
  int64_t t_in;
  const char *s1, *s2, *s3, *s4, *s5, *s6;  // text parameters, inside extra; NULL = absent
  uint32_t l1, l2, l3, l4, l5, l6;
  const char *token;  // presented token, echoed by /api/user
  uint32_t token_len;
  const char **tags;  // tagList of POST /api/articles
  uint32_t *tag_lens;
  int32_t ntags;
  char *resp;  // final bytes (head + body), malloc'd; sent and freed by the owning loop
  size_t resp_len;
  void *b;  // per-batch scratch of the read engine
  char extra[];
} job;

job *job_new(size_t extra);
// Finishes the job with a JSON body: builds the head and hands it to its loop.
void job_reply(job *j, int status, const char *body, size_t n);
void job_error(job *j, int status, const char *msg);

// loops
void loop_post(job *j);  // any thread: deliver j (resp set) to its loop
void loops_start(int n, const char *host, int port);
bool conn_alive(const job *j);

// engines
void reads_start(int n);
void read_enqueue(job *j);
void writes_start(int n);
void write_enqueue(job *j);
void hashers_start(int n);
void hash_enqueue_verify(job *j, const char *stored, size_t sl);
void hash_enqueue_new(job *j);

// JSON bodies of the small objects (shared by the read and write engines)
void render_user(buf_t *b, const char *user, size_t ul, const char *email, size_t el, const char *bio, int32_t bl,
                 const char *image, int32_t il, const char *token, size_t tl);
void render_profile(buf_t *b, const char *user, size_t ul, const char *bio, int32_t bl, const char *image, int32_t il,
                    bool following);
