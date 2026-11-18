#ifndef NC_OWNED_MEMORY_H
#define NC_OWNED_MEMORY_H
/* Include after system headers. Only this application's owned allocations and
 * copies use these private names. libpq/OpenSSL keep their original host ABI. */
#ifdef NC_MEMORY_NELIBC
#include <stddef.h>
void *nc_nelibc_nelibc_malloc(size_t size) __attribute__((malloc,alloc_size(1)));
void *nc_nelibc_nelibc_calloc(size_t count,size_t size) __attribute__((malloc,alloc_size(1,2)));
void *nc_nelibc_nelibc_realloc(void *pointer,size_t size) __attribute__((alloc_size(2)));
void nc_nelibc_nelibc_free(void *pointer);
void *nc_nelibc_memcpy(void *restrict destination,const void *restrict source,size_t length);
void *nc_nelibc_memmove(void *destination,const void *source,size_t length);
static inline void *nc_owned_copy(void *restrict destination,const void *restrict source,size_t length)
{
    /* Preserve fixed-width loads/stores in binary decoders and literal writes.
     * Dynamic copies remain an explicit Nelibc experiment. */
    if (__builtin_constant_p(length) && length<=64)
        return __builtin_memcpy(destination,source,length);
    return nc_nelibc_memcpy(destination,source,length);
}
#define malloc nc_nelibc_nelibc_malloc
#define calloc nc_nelibc_nelibc_calloc
#define realloc nc_nelibc_nelibc_realloc
#define free nc_nelibc_nelibc_free
#define memcpy nc_owned_copy
#define memmove nc_nelibc_memmove
#endif
#endif
