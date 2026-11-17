#include "native.h"
#include <libpq-fe.h>
#include <openssl/evp.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int nc_nelibc_nelibc_allocator_owns(const void *pointer);
static size_t private_frees;
void __real_nc_nelibc_nelibc_free(void *pointer);
void __wrap_nc_nelibc_nelibc_free(void *pointer)
{
    if (pointer) ++private_frees;
    __real_nc_nelibc_nelibc_free(pointer);
}

int main(void)
{
    static const char wire[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
    /* This driver's malloc keeps its hosted ABI. Only the application source
     * files include owned_memory.h; dynamic dependencies cannot see the archive. */
    void *host=malloc(128);
    assert(host);
    memset(host,0x42,128);
    assert(!nc_nelibc_nelibc_allocator_owns(host));
    nc_request *request=nc_request_create(wire,sizeof(wire)-1);
    assert(request && nc_nelibc_nelibc_allocator_owns(request));
    char input[4096]; memset(input,'x',sizeof(input));
    nc_write_n(nc_begin(request,200),input,sizeof(input));
    size_t length=0;
    const char *data=nc_response_data(request,&length);
    assert(data && length==sizeof(input) && !memcmp(data,input,length));
    assert(nc_nelibc_nelibc_allocator_owns(data));
    PGresult *result=PQmakeEmptyPGresult(NULL,PGRES_TUPLES_OK);
    assert(result && !nc_nelibc_nelibc_allocator_owns(result));
    EVP_MD_CTX *crypto=EVP_MD_CTX_new();
    assert(crypto && !nc_nelibc_nelibc_allocator_owns(crypto));
    size_t before_hosted=private_frees;
    EVP_MD_CTX_free(crypto);
    PQclear(result);
    assert(private_frees==before_hosted);
    size_t before_request=private_frees;
    nc_request_free(request);
    nc_request_pool_trim();
    /* owns() establishes arena provenance, not per-slot liveness: freed slab
     * slots remain mapped. Observe the actual owner free calls instead. */
    assert(private_frees>=before_request+2);
    for (int i=0;i<128;++i) assert(((unsigned char *)host)[i]==0x42);
    free(host);
    puts("PASS: request/buffer owned by private Nelibc; driver/libpq/OpenSSL stay host-owned; all freed through their owners");
}
