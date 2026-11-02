// A small gzip encoder for JSON responses: greedy LZ77 with one hash probe, then one deflate block using a Huffman table
// fixed at startup from typical JSON symbol counts (gz_table.h). Nothing carries over between responses.
#include <stdio.h>

#include "common.h"
#include "gz_table.h"
#if defined(__x86_64__)
#include <immintrin.h>
#endif

#define NLIT 286
#define NDIST 30
static uint16_t lit_code[NLIT], dist_code[NDIST];
static uint8_t lit_len[NLIT], dist_len[NDIST];
static uint8_t hdr[320];
static int hdr_bits;
static uint32_t crc_tab[8][256];

static const uint16_t LEN_BASE[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
static const uint8_t LEN_EXTRA[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
static const uint16_t DIST_BASE[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
static const uint8_t DIST_EXTRA[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};
static uint8_t len_sym[259];   // match length -> index into LEN_*
static uint8_t dist_sym[512];  // small distances direct, large via >> 7

// Huffman lengths limited to maxl, by repeated flattening of the counts.
static void build_lengths(const uint32_t *freq, int n, uint8_t *len, int maxl) {
  uint64_t f[300];
  for (int i = 0; i < n; i++) f[i] = freq[i] ? freq[i] : 1;
  for (;;) {
    int parent[600], m = n;
    uint64_t w[600];
    bool used[600] = {0};
    for (int i = 0; i < n; i++) w[i] = f[i];
    for (int k = 0; k < n - 1; k++) {
      int a = -1, b = -1;
      for (int i = 0; i < m; i++) {
        if (used[i]) continue;
        if (a < 0 || w[i] < w[a]) { b = a; a = i; }
        else if (b < 0 || w[i] < w[b]) b = i;
      }
      used[a] = used[b] = true;
      w[m] = w[a] + w[b];
      parent[a] = parent[b] = m;
      m++;
    }
    int top = 0;
    for (int i = 0; i < n; i++) {
      int d = 0;
      for (int x = i; x != m - 1; x = parent[x]) d++;
      if (!d) d = 1;
      len[i] = d;
      if (d > top) top = d;
    }
    if (top <= maxl) return;
    for (int i = 0; i < n; i++) f[i] = f[i] / 2 + 1;
  }
}
static uint32_t rev_bits(uint32_t c, int n) {
  uint32_t r = 0;
  for (int i = 0; i < n; i++) r |= ((c >> i) & 1) << (n - 1 - i);
  return r;
}
static void canon(const uint8_t *len, int n, uint16_t *code) {
  int bl[16] = {0}, next[16] = {0}, c = 0;
  for (int i = 0; i < n; i++) bl[len[i]]++;
  bl[0] = 0;
  for (int b = 1; b < 16; b++) {
    c = (c + bl[b - 1]) << 1;
    next[b] = c;
  }
  for (int i = 0; i < n; i++)
    if (len[i]) code[i] = rev_bits(next[len[i]]++, len[i]);
}
static void hp(uint32_t v, int n) {
  for (int i = 0; i < n; i++, hdr_bits++)
    if ((v >> i) & 1) hdr[hdr_bits >> 3] |= 1 << (hdr_bits & 7);
}

void gz_init(void) {
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
    crc_tab[0][i] = c;
  }
  for (uint32_t i = 0; i < 256; i++)
    for (int t = 1; t < 8; t++) crc_tab[t][i] = (crc_tab[t - 1][i] >> 8) ^ crc_tab[0][crc_tab[t - 1][i] & 255];
  for (int i = 0; i < 29; i++) {
    int top = i < 28 ? LEN_BASE[i + 1] : 259;
    for (int l = LEN_BASE[i]; l < top && l < 259; l++) len_sym[l] = i;
  }
  len_sym[258] = 28;
  for (int d = 0; d < 30; d++) {
    int top = d < 29 ? DIST_BASE[d + 1] : 32769;
    for (int x = DIST_BASE[d]; x < top; x++) {
      if (x <= 256) dist_sym[x - 1] = d;
      else dist_sym[256 + ((x - 1) >> 7)] = d;
    }
  }
  build_lengths(GZ_LIT_FREQ, NLIT, lit_len, 15);
  build_lengths(GZ_DIST_FREQ, NDIST, dist_len, 15);
  canon(lit_len, NLIT, lit_code);
  canon(dist_len, NDIST, dist_code);
  // The block header: dynamic block, code lengths sent plainly (symbols 0-15 only, no repeats).
  hdr_bits = 0;
  memset(hdr, 0, sizeof hdr);
  hp(1, 1);  // BFINAL
  hp(2, 2);  // dynamic
  hp(NLIT - 257, 5);
  hp(NDIST - 1, 5);
  static const uint8_t ORDER[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
  uint32_t cf[19] = {0};
  for (int i = 0; i < NLIT; i++) cf[lit_len[i]]++;
  for (int i = 0; i < NDIST; i++) cf[dist_len[i]]++;
  uint8_t cl[19] = {0};
  uint16_t cc[19] = {0};
  uint32_t cfu[16];
  for (int i = 0; i < 16; i++) cfu[i] = cf[i];
  uint8_t cl16[16];
  build_lengths(cfu, 16, cl16, 7);
  for (int i = 0; i < 16; i++) cl[i] = cl16[i];
  canon(cl, 19, cc);
  hp(19 - 4, 4);
  for (int i = 0; i < 19; i++) hp(cl[ORDER[i]], 3);
  for (int i = 0; i < NLIT; i++) hp(cc[lit_len[i]], cl[lit_len[i]]);
  for (int i = 0; i < NDIST; i++) hp(cc[dist_len[i]], cl[dist_len[i]]);
}

static uint32_t crc32_of(const uint8_t *p, size_t n) {
  uint32_t c = 0xFFFFFFFFu;
  while (n >= 8) {
    uint64_t v;
    memcpy(&v, p, 8);
    v ^= c;
    c = crc_tab[7][v & 255] ^ crc_tab[6][(v >> 8) & 255] ^ crc_tab[5][(v >> 16) & 255] ^ crc_tab[4][(v >> 24) & 255] ^
        crc_tab[3][(v >> 32) & 255] ^ crc_tab[2][(v >> 40) & 255] ^ crc_tab[1][(v >> 48) & 255] ^ crc_tab[0][v >> 56];
    p += 8;
    n -= 8;
  }
  while (n--) c = crc_tab[0][(c ^ *p++) & 255] ^ (c >> 8);
  return ~c;
}

#define HBITS 12
#define HSIZE (1 << HBITS)
typedef struct {
  uint32_t t[HSIZE];
  uint32_t base;  // positions stored are base + offset, so a new response needs no clearing
} gz_state;

#define PUT(v, nb)                                  \
  do {                                              \
    acc |= (uint64_t)(v) << nacc;                   \
    nacc += (nb);                                   \
    if (nacc >= 32) {                               \
      memcpy(o, &acc, 4);                           \
      o += 4;                                       \
      acc >>= 32;                                   \
      nacc -= 32;                                   \
    }                                               \
  } while (0)

static inline uint32_t ld32(const uint8_t *p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return v;
}

// out needs n + 512 bytes; returns the size, or 0 when the result would not be smaller.
size_t gz_encode(const uint8_t *in, size_t n, uint8_t *out, size_t limit) {
  static __thread gz_state *st;
  if (!st) st = calloc(1, sizeof *st);
  if (n < 64 || n > (1 << 24)) return 0;
  if (st->base > 0xF0000000u) {
    memset(st->t, 0, sizeof st->t);
    st->base = 0;
  }
  uint32_t base = st->base + 65536;
  st->base = base + (uint32_t)n;  // here, because a response too big for the limit returns early
  uint8_t *o = out;
  static const uint8_t HEAD[10] = {0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255};
  memcpy(o, HEAD, 10);
  o += 10;
  memcpy(o, hdr, (hdr_bits + 7) / 8);
  o += hdr_bits / 8;
  uint64_t acc = hdr[hdr_bits / 8] & ((1u << (hdr_bits & 7)) - 1);
  int nacc = hdr_bits & 7;
  uint8_t *stop = out + limit;
  size_t i = 0, end = n - 8;
  while (i < end) {
    if (unlikely(o + 16 > stop)) return 0;
    uint32_t v = ld32(in + i);
    uint32_t h = (v * 2654435761u) >> (32 - HBITS);
    uint32_t cand = st->t[h];
    st->t[h] = base + (uint32_t)i;
    if (cand >= base && i - (cand - base) <= 32768 && ld32(in + (cand - base)) == v) {
      size_t m = cand - base, l = 4, maxl = n - i < 258 ? n - i : 258;
      while (l + 8 <= maxl) {
        uint64_t a, b;
        memcpy(&a, in + i + l, 8);
        memcpy(&b, in + m + l, 8);
        if (a != b) {
          l += (size_t)__builtin_ctzll(a ^ b) >> 3;
          break;
        }
        l += 8;
      }
      if (l > maxl) l = maxl;
      while (l < maxl && in[i + l] == in[m + l]) l++;
      int ls = len_sym[l];
      PUT(lit_code[257 + ls], lit_len[257 + ls]);
      if (LEN_EXTRA[ls]) PUT(l - LEN_BASE[ls], LEN_EXTRA[ls]);
      uint32_t d = i - m;
      int ds = d <= 256 ? dist_sym[d - 1] : dist_sym[256 + ((d - 1) >> 7)];
      PUT(dist_code[ds], dist_len[ds]);
      if (DIST_EXTRA[ds]) PUT(d - DIST_BASE[ds], DIST_EXTRA[ds]);
      if (i + 1 < end) {
        // A little of the match enters the table, for the next repeat.
        uint32_t v2 = ld32(in + i + l - 2 < in + end ? in + i + l - 2 : in + i);
        if (i + l - 2 < end) st->t[(v2 * 2654435761u) >> (32 - HBITS)] = base + (uint32_t)(i + l - 2);
      }
      i += l;
      continue;
    }
    PUT(lit_code[in[i]], lit_len[in[i]]);
    i++;
  }
  while (i < n) {
    if (unlikely(o + 16 > stop)) return 0;
    PUT(lit_code[in[i]], lit_len[in[i]]);
    i++;
  }
  PUT(lit_code[256], lit_len[256]);
  while (nacc > 0) {
    *o++ = (uint8_t)acc;
    acc >>= 8;
    nacc -= 8;
  }
  uint32_t c = crc32_of(in, n), sz = (uint32_t)n;
  memcpy(o, &c, 4);
  memcpy(o + 4, &sz, 4);
  o += 8;
  return (size_t)(o - out);
}
