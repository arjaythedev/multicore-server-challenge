#ifndef NC_JSON_SCAN_H
#define NC_JSON_SCAN_H
#include <stddef.h>
#include <stdint.h>
#include <immintrin.h>

/* These are instruction bindings, shared by the C and Nelua loop bodies.
 * Loads are unaligned; callers must prove 32/64 readable bytes first. */
static inline __attribute__((always_inline,target("avx2")))
uint32_t nc_json_mask32(unsigned char *p)
{
    __m256i v=_mm256_loadu_si256((const __m256i *)p);
    __m256i controls=_mm256_cmpeq_epi8(_mm256_min_epu8(v,_mm256_set1_epi8(31)),v);
    __m256i quotes=_mm256_cmpeq_epi8(v,_mm256_set1_epi8('"'));
    __m256i slashes=_mm256_cmpeq_epi8(v,_mm256_set1_epi8('\\'));
    return (uint32_t)_mm256_movemask_epi8(_mm256_or_si256(controls,_mm256_or_si256(quotes,slashes)));
}

static inline __attribute__((always_inline,target("avx512f,avx512bw")))
uint64_t nc_json_mask64(unsigned char *p)
{
    __m512i v=_mm512_loadu_si512((const void *)p);
    return _mm512_cmplt_epu8_mask(v,_mm512_set1_epi8(32)) |
           _mm512_cmpeq_epi8_mask(v,_mm512_set1_epi8('"')) |
           _mm512_cmpeq_epi8_mask(v,_mm512_set1_epi8('\\'));
}

/* Return the exact safe prefix, never a conservative approximate offset. */
#define NC_JSON_SCAN_DECLARE(suffix) \
size_t nc_json_prefix_scalar_##suffix(unsigned char *,size_t); \
size_t nc_json_prefix_word_##suffix(unsigned char *,size_t); \
size_t nc_json_prefix_avx2_##suffix(unsigned char *,size_t); \
size_t nc_json_prefix_avx512_##suffix(unsigned char *,size_t)
NC_JSON_SCAN_DECLARE(c);
NC_JSON_SCAN_DECLARE(nelua);
#undef NC_JSON_SCAN_DECLARE
#endif
