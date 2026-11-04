// The byte work of HS256 verification, in C: split "Token <header>.<claims>.<signature>", base64url-decode
// the signature, check it with libsodium's HMAC-SHA256 (constant-time compare) and decode the claims.
// Ruby (auth.rb) still parses the claims and checks sub and exp, and handles any header other than the one
// this server issues.
//
//   FastJWT.claims(authorization, header, key32) -> claims JSON, nil (invalid) or false (other header)
#include <ruby.h>
#include <sodium.h>
#include <string.h>

static signed char B64[256];

// base64url without padding; returns the decoded length, or -1.
static long decode(const char *in, long n, unsigned char *out, long cap) {
  if (n % 4 == 1) return -1;
  long o = 0;
  unsigned int acc = 0;
  int bits = 0;
  for (long i = 0; i < n; i++) {
    int v = B64[(unsigned char)in[i]];
    if (v < 0) return -1;
    acc = (acc << 6) | (unsigned)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      if (o >= cap) return -1;
      out[o++] = (unsigned char)(acc >> bits);
    }
  }
  return o;
}

static VALUE jwt_claims(VALUE self, VALUE authorization, VALUE header, VALUE key) {
  StringValue(authorization);
  StringValue(header);
  StringValue(key);
  if (RSTRING_LEN(key) != crypto_auth_hmacsha256_KEYBYTES) rb_raise(rb_eArgError, "32-byte key");
  const char *p = RSTRING_PTR(authorization);
  long n = RSTRING_LEN(authorization);
  if (n < 6 || memcmp(p, "Token ", 6) != 0) return Qnil;
  p += 6;
  n -= 6;
  const char *dot1 = memchr(p, '.', n);
  if (!dot1) return Qnil;
  const char *dot2 = memchr(dot1 + 1, '.', n - (dot1 + 1 - p));
  if (!dot2 || memchr(dot2 + 1, '.', n - (dot2 + 1 - p))) return Qnil;
  long header_len = dot1 - p;
  if (header_len != RSTRING_LEN(header) || memcmp(p, RSTRING_PTR(header), header_len) != 0) return Qfalse;

  unsigned char signature[64], mac[crypto_auth_hmacsha256_BYTES];
  long sig_len = decode(dot2 + 1, n - (dot2 + 1 - p), signature, sizeof signature);
  if (sig_len != crypto_auth_hmacsha256_BYTES) return Qnil;
  crypto_auth_hmacsha256(mac, (const unsigned char *)p, (unsigned long long)(dot2 - p),
                         (const unsigned char *)RSTRING_PTR(key));
  if (sodium_memcmp(mac, signature, sizeof mac) != 0) return Qnil;

  long claims_len = dot2 - (dot1 + 1);
  if (claims_len <= 0 || claims_len > 4096) return Qnil;
  unsigned char claims[3072];
  long out = decode(dot1 + 1, claims_len, claims, sizeof claims);
  if (out <= 0) return Qnil;
  return rb_utf8_str_new((const char *)claims, out);
}

void Init_fast_jwt(void) {
  if (sodium_init() < 0) rb_raise(rb_eRuntimeError, "sodium_init failed");
  memset(B64, -1, sizeof B64);
  const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  for (int i = 0; i < 64; i++) B64[(unsigned char)alphabet[i]] = (signed char)i;
  VALUE module = rb_define_module("FastJWT");
  rb_define_singleton_method(module, "claims", jwt_claims, 3);
}
