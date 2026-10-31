#include <stdint.h>
#include <string.h>
/* The standalone core passes byte pointers to these unaligned loads. */
static inline uint32_t le32_to_cpu(const void *p) {
    uint32_t v;
    memcpy(&v, p, sizeof(v));
#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    v = __builtin_bswap32(v);
#endif
    return v;
}
static inline uint32_t be32_to_cpu(const void *p) {
    uint32_t v;
    memcpy(&v, p, sizeof(v));
#if __BYTE_ORDER__ != __ORDER_BIG_ENDIAN__
    v = __builtin_bswap32(v);
#endif
    return v;
}
