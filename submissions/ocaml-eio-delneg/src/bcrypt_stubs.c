/* bcrypt through libxcrypt's crypt_r, with the OCaml runtime released while it runs,
   so a 50 ms hash never stalls the domain's event loop or a stop-the-world GC. */
#define _GNU_SOURCE
#include <crypt.h>
#include <stdlib.h>
#include <string.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/signals.h>

static char *dup_ml(value s) {
  size_t n = caml_string_length(s);
  char *p = malloc(n + 1);
  if (!p) caml_raise_out_of_memory();
  memcpy(p, String_val(s), n);
  p[n] = 0;
  return p;
}

value mc_bcrypt_verify(value pw, value hash) {
  CAMLparam2(pw, hash);
  char *p = dup_ml(pw), *h = dup_ml(hash);
  size_t hl = caml_string_length(hash);
  struct crypt_data *cd = calloc(1, sizeof *cd);
  int ok = 0;
  caml_enter_blocking_section();
  if (cd) {
    char *r = crypt_r(p, h, cd);
    if (r && r[0] != '*' && strlen(r) == hl) {
      unsigned char d = 0;
      for (size_t i = 0; i < hl; i++) d |= (unsigned char)(r[i] ^ h[i]);
      ok = d == 0;
    }
  }
  caml_leave_blocking_section();
  free(cd); free(p); free(h);
  CAMLreturn(Val_bool(ok));
}

value mc_bcrypt_hash(value pw, value cost) {
  CAMLparam2(pw, cost);
  CAMLlocal1(res);
  char *p = dup_ml(pw);
  char salt[CRYPT_GENSALT_OUTPUT_SIZE], out[128];
  struct crypt_data *cd = calloc(1, sizeof *cd);
  int ok = 0;
  caml_enter_blocking_section();
  if (cd && crypt_gensalt_rn("$2b$", Int_val(cost), NULL, 0, salt, sizeof salt)) {
    char *r = crypt_r(p, salt, cd);
    if (r && r[0] != '*' && strlen(r) < sizeof out) { strcpy(out, r); ok = 1; }
  }
  caml_leave_blocking_section();
  free(cd); free(p);
  if (!ok) caml_failwith("bcrypt hash failed");
  res = caml_copy_string(out);
  CAMLreturn(res);
}
