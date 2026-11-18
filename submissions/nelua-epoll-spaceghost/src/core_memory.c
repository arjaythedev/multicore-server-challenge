/* Compiler-emitted aggregate copies in the freestanding core resolve through
 * private Nelibc. --wrap changes references from linked objects, not calls made
 * inside dynamically loaded libpq/OpenSSL. No allocator symbols are wrapped. */
#include <stddef.h>
void *nc_nelibc_memcpy(void *,const void *,size_t);
void *nc_nelibc_memmove(void *,const void *,size_t);
void *nc_nelibc_memset(void *,int,size_t);
void *__wrap_memcpy(void *destination,const void *source,size_t length)
{ return nc_nelibc_memcpy(destination,source,length); }
void *__wrap_memmove(void *destination,const void *source,size_t length)
{ return nc_nelibc_memmove(destination,source,length); }
void *__wrap_memset(void *destination,int value,size_t length)
{ return nc_nelibc_memset(destination,value,length); }
