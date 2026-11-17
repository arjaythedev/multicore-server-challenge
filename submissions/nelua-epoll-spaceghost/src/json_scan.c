/* Independent C implementations for the same-work C/Nelua shootout. */
#include "json_scan.h"

size_t nc_json_prefix_scalar_c(unsigned char *p,size_t n)
{
    size_t i=0;
    while (i<n && p[i]>=32 && p[i]!='"' && p[i]!='\\') ++i;
    return i;
}

size_t nc_json_prefix_word_c(unsigned char *p,size_t n)
{
    size_t i=0;
    while (n-i>=8) {
        uint64_t word;
        __builtin_memcpy(&word,p+i,8);
        uint64_t quotes=word^UINT64_C(0x2222222222222222);
        uint64_t slashes=word^UINT64_C(0x5c5c5c5c5c5c5c5c);
        uint64_t controls=(word-UINT64_C(0x2020202020202020))&~word;
        uint64_t matches=((quotes-UINT64_C(0x0101010101010101))&~quotes)|
                         ((slashes-UINT64_C(0x0101010101010101))&~slashes)|controls;
        if (matches&UINT64_C(0x8080808080808080)) break;
        i+=8;
    }
    return i+nc_json_prefix_scalar_c(p+i,n-i);
}

__attribute__((target("avx2")))
size_t nc_json_prefix_avx2_c(unsigned char *p,size_t n)
{
    size_t i=0;
    while (n-i>=32) {
        uint32_t mask=nc_json_mask32(p+i);
        if (mask) return i+(unsigned)__builtin_ctz(mask);
        i+=32;
    }
    return i+nc_json_prefix_word_c(p+i,n-i);
}

__attribute__((target("avx512f,avx512bw")))
size_t nc_json_prefix_avx512_c(unsigned char *p,size_t n)
{
    size_t i=0;
    while (n-i>=64) {
        uint64_t mask=nc_json_mask64(p+i);
        if (mask) return i+(unsigned)__builtin_ctzll(mask);
        i+=64;
    }
    if (n-i>=32) {
        uint32_t mask=nc_json_mask32(p+i);
        if (mask) return i+(unsigned)__builtin_ctz(mask);
        i+=32;
    }
    return i+nc_json_prefix_word_c(p+i,n-i);
}
