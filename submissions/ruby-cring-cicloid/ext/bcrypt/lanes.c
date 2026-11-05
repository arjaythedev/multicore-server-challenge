// bcrypt for Ruby, several hashes at once. The core is Solar Designer's public-domain Openwall bcrypt
// (crypt-bcrypt.c, unmodified from libxcrypt 4.4.36); bcrypt-batch-impl.h interleaves independent Blowfish
// states round by round (from PR #7, rust-tokio-Scooter1337, MIT). Those files, crypt-port.h and byteorder.h
// are as vendored by node-uwebsockets-zahidcakici; this file is this submission's own Ruby binding.
//
// One bcrypt is a long chain of dependent S-box loads; independent chains interleaved let the core overlap
// them. Every hash runs all 2^cost rounds with its own salt; nothing is shared between hashes.
//
//   BcryptLanes.run(passwords, settings) -> [hash or nil, ...]   1..6 entries, one cost; GVL released
//   BcryptLanes.salt(random16)           -> "$2b$10$<22 chars>"
//   BcryptLanes.self_test                -> true when every lane count matches the single-hash code
//   BcryptLanes.calibrate(lanes)         -> seconds per hash of a cost-6 run with that many lanes
#include <ruby.h>
#include <ruby/thread.h>
#include <time.h>
#include "crypt-bcrypt.c"

static inline BF_word batch_f(const BF_ctx *s, BF_word x) {
  return ((s->S[0][x >> 24] + s->S[1][(x >> 16) & 255]) ^ s->S[2][(x >> 8) & 255]) + s->S[3][x & 255];
}
#define JOIN_(a, b) a##b
#define JOIN(a, b) JOIN_(a, b)
#define LANES 2
#include "bcrypt-batch-impl.h"
#undef LANES
#define LANES 3
#include "bcrypt-batch-impl.h"
#undef LANES
#define LANES 4
#include "bcrypt-batch-impl.h"
#undef LANES
#define LANES 5
#include "bcrypt-batch-impl.h"
#undef LANES
#define LANES 6
#include "bcrypt-batch-impl.h"
#undef LANES
#define MAX_LANES 6

// One hash with the original code; 1 on success.
static int single(const char *key, const char *setting, unsigned char out[61]) {
  unsigned char buf[CRYPT_OUTPUT_SIZE];
  unsigned char scratch[ALG_SPECIFIC_SIZE];
  buf[0] = 0;
  crypt_bcrypt_rn(key, strlen(key), setting, strlen(setting), buf, sizeof buf, scratch, sizeof scratch);
  if (buf[0] != '$' || strlen((const char *)buf) != 60) return 0;
  memcpy(out, buf, 61);
  return 1;
}

static int run(const char *const *keys, const char *const *settings, unsigned char (*out)[61], unsigned n) {
  switch (n) {
  case 1: return single(keys[0], settings[0], out[0]);
  case 2: return batch_run2(keys, settings, out);
  case 3: return batch_run3(keys, settings, out);
  case 4: return batch_run4(keys, settings, out);
  case 5: return batch_run5(keys, settings, out);
  case 6: return batch_run6(keys, settings, out);
  default: return 0;
  }
}

typedef struct {
  char keys[MAX_LANES][73];
  char settings[MAX_LANES][64];
  const char *kp[MAX_LANES], *sp[MAX_LANES];
  unsigned char out[MAX_LANES][61];
  unsigned n;
  int ok;
} job_t;

static void *run_job(void *arg) {
  job_t *job = arg;
  job->ok = run(job->kp, job->sp, job->out, job->n);
  return NULL;
}

static VALUE lanes_run(VALUE self, VALUE keys, VALUE settings) {
  Check_Type(keys, T_ARRAY);
  Check_Type(settings, T_ARRAY);
  long n = RARRAY_LEN(keys);
  if (n < 1 || n > MAX_LANES || n != RARRAY_LEN(settings)) rb_raise(rb_eArgError, "1 to %d hashes", MAX_LANES);
  job_t *job = ALLOC(job_t);
  job->n = (unsigned)n;
  for (long i = 0; i < n; i++) {
    VALUE k = rb_ary_entry(keys, i), s = rb_ary_entry(settings, i);
    StringValue(k);
    StringValue(s);
    long kl = RSTRING_LEN(k), sl = RSTRING_LEN(s);
    if (kl > 72 || memchr(RSTRING_PTR(k), 0, kl) || sl >= 64) {
      xfree(job);
      rb_raise(rb_eArgError, "password over 72 bytes or with NUL, or setting too long");
    }
    memcpy(job->keys[i], RSTRING_PTR(k), kl);
    job->keys[i][kl] = 0;
    memcpy(job->settings[i], RSTRING_PTR(s), sl);
    job->settings[i][sl] = 0;
    job->kp[i] = job->keys[i];
    job->sp[i] = job->settings[i];
  }
  rb_thread_call_without_gvl(run_job, job, RUBY_UBF_IO, NULL);
  VALUE result = rb_ary_new_capa(n);
  for (long i = 0; i < n; i++) rb_ary_push(result, job->ok ? rb_str_new((const char *)job->out[i], 60) : Qnil);
  volatile char *wipe = (volatile char *)job;
  for (size_t i = 0; i < sizeof *job; i++) wipe[i] = 0;
  xfree(job);
  return result;
}

static VALUE lanes_salt(VALUE self, VALUE random) {
  StringValue(random);
  if (RSTRING_LEN(random) < 16) rb_raise(rb_eArgError, "16 random bytes");
  uint8_t out[CRYPT_OUTPUT_SIZE];
  out[0] = 0;
  gensalt_bcrypt_rn(10, (const uint8_t *)RSTRING_PTR(random), 16, out, sizeof out);
  if (out[0] != '$') rb_raise(rb_eRuntimeError, "gensalt failed");
  return rb_str_new_cstr((const char *)out);
}

static const char *T_PW[MAX_LANES] = {"password123", "", "U*U*U*U", "a fairly long password, 0123456789 0123456789 012",
                                      "\xc3\xbc" "n" "\xc3\xaf" "c" "\xc3\xb6" "de",
                                      "72 bytes 72 bytes 72 bytes 72 bytes 72 bytes 72 bytes 72 bytes 72 bytes"};
static const char *T_ST[MAX_LANES] = {"$2a$05$CCCCCCCCCCCCCCCCCCCCC.", "$2b$05$abcdefghijklmnopqrstuu",
                                      "$2y$05$/OK.fbVrR/bpIqNJ5ianF.", "$2a$05$ZSfEoPvlcsj2XfvsSeK25e",
                                      "$2b$05$9a8b7c6d5e4f3g2h1i0jkO", "$2a$05$ABCDEFGHIJKLMNOPQRSTUu"};

static VALUE lanes_self_test(VALUE self) {
  unsigned char want[MAX_LANES][61], got[MAX_LANES][61];
  int ok = 1;
  for (int i = 0; i < MAX_LANES; i++) ok &= single(T_PW[i], T_ST[i], want[i]);
  for (unsigned n = 2; n <= MAX_LANES && ok; n++) {
    ok &= run(T_PW, T_ST, got, n);
    for (unsigned i = 0; i < n; i++) ok &= memcmp(want[i], got[i], 61) == 0;
  }
  return ok ? Qtrue : Qfalse;
}

static VALUE lanes_calibrate(VALUE self, VALUE vlanes) {
  unsigned n = NUM2UINT(vlanes);
  if (n < 1 || n > MAX_LANES) rb_raise(rb_eArgError, "1 to %d lanes", MAX_LANES);
  const char *st[MAX_LANES];
  for (unsigned i = 0; i < MAX_LANES; i++) st[i] = "$2b$06$abcdefghijklmnopqrstuu";
  unsigned char out[MAX_LANES][61];
  struct timespec a, b;
  clock_gettime(CLOCK_MONOTONIC, &a);
  for (int r = 0; r < 3; r++) run(T_PW, st, out, n);
  clock_gettime(CLOCK_MONOTONIC, &b);
  return DBL2NUM(((b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9) / 3.0 / n);
}

void Init_bcrypt_lanes(void) {
  VALUE module = rb_define_module("BcryptLanes");
  rb_define_singleton_method(module, "run", lanes_run, 2);
  rb_define_singleton_method(module, "salt", lanes_salt, 1);
  rb_define_singleton_method(module, "self_test", lanes_self_test, 0);
  rb_define_singleton_method(module, "calibrate", lanes_calibrate, 1);
}
