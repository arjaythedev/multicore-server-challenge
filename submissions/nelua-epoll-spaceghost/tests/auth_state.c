/* Exercise the actual request API, plus OpenSSL failure cleanup and TLS lifetime. */
#define _GNU_SOURCE
#include "native.h"
#include <assert.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static _Thread_local int fail_api;
static atomic_uint allocated, released;

EVP_MAC_CTX *__real_EVP_MAC_CTX_new(EVP_MAC *mac);
void __real_EVP_MAC_CTX_free(EVP_MAC_CTX *context);
int __real_EVP_MAC_init(EVP_MAC_CTX *context,const unsigned char *key,size_t length,const OSSL_PARAM parameters[]);
int __real_EVP_MAC_update(EVP_MAC_CTX *context,const unsigned char *data,size_t length);
int __real_EVP_MAC_final(EVP_MAC_CTX *context,unsigned char *digest,size_t *length,size_t capacity);

EVP_MAC_CTX *__wrap_EVP_MAC_CTX_new(EVP_MAC *mac)
{
    if (fail_api==4) { fail_api=0; return NULL; }
    EVP_MAC_CTX *context=__real_EVP_MAC_CTX_new(mac);
    if (context) atomic_fetch_add(&allocated,1);
    return context;
}
void __wrap_EVP_MAC_CTX_free(EVP_MAC_CTX *context)
{
    if (context) atomic_fetch_add(&released,1);
    __real_EVP_MAC_CTX_free(context);
}
int __wrap_EVP_MAC_init(EVP_MAC_CTX *context,const unsigned char *key,size_t length,const OSSL_PARAM parameters[])
{
    if (fail_api==1) { fail_api=0; return 0; }
    return __real_EVP_MAC_init(context,key,length,parameters);
}
int __wrap_EVP_MAC_update(EVP_MAC_CTX *context,const unsigned char *data,size_t length)
{
    if (fail_api==2) { fail_api=0; return 0; }
    return __real_EVP_MAC_update(context,data,length);
}
int __wrap_EVP_MAC_final(EVP_MAC_CTX *context,unsigned char *digest,size_t *length,size_t capacity)
{
    if (fail_api==3) { fail_api=0; return 0; }
    return __real_EVP_MAC_final(context,digest,length,capacity);
}

static nc_request *request(const char *token)
{
    char wire[4096];
    int length=snprintf(wire,sizeof(wire),
        "GET /api/user HTTP/1.1\r\nHost: test\r\nAuthorization: Token %s\r\n\r\n",token);
    assert(length>0 && (size_t)length<sizeof(wire));
    nc_request *result=nc_request_create(wire,(size_t)length);
    assert(result);
    return result;
}

static void check(unsigned id)
{
    static const char empty[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
    nc_request *issuer=nc_request_create(empty,sizeof(empty)-1);
    assert(issuer);
    char *token=nc_issue_token(issuer,id);
    assert(token);
    char *signature=strrchr(token,'.');
    assert(signature && strlen(signature+1)==43);
    unsigned char digest[32], encoded[45];
    unsigned length=0;
    const char *secret=getenv("JWT_SECRET");
    assert(HMAC(EVP_sha256(),secret,(int)strlen(secret),(unsigned char *)token,
        (size_t)(signature-token),digest,&length) && length==32);
    assert(EVP_EncodeBlock(encoded,digest,32)==44);
    for (int i=0;i<43;++i) {
        if (encoded[i]=='+') encoded[i]='-';
        else if (encoded[i]=='/') encoded[i]='_';
    }
    assert(CRYPTO_memcmp(signature+1,encoded,43)==0);
    nc_request *verified=request(token);
    assert(nc_auth(verified)==id);
    assert(nc_auth(verified)==id); /* Signature is recomputed on repeated calls. */
    nc_request_free(verified);
    signature[1]=signature[1]=='A'?'B':'A';
    verified=request(token);
    assert(nc_auth(verified)==-1);
    nc_request_free(verified);
    nc_request_free(issuer);
}

static void *rotation(void *unused)
{
    (void)unused;
    char secret[4097];
    const unsigned lengths[]={1,31,32,63,64,65,128,1024,4096,32};
    for (unsigned i=0;i<sizeof(lengths)/sizeof(lengths[0]);++i) {
        memset(secret,'a'+(int)i,lengths[i]); secret[lengths[i]]=0;
        assert(setenv("JWT_SECRET",secret,1)==0);
        for (unsigned j=0;j<8;++j) check(i*8+j+1);
    }
    static const char empty[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
    nc_request *issuer=nc_request_create(empty,sizeof(empty)-1);
    assert(issuer);
    char *token=nc_issue_token(issuer,42);
    assert(token);
    nc_request *verified=request(token);
    assert(nc_auth(verified)==42);
    fail_api=1;
    assert(nc_auth(verified)==-1); /* A prior verdict cannot bypass fresh HMAC. */
    assert(fail_api==0 && nc_auth(verified)==42);
    nc_request_free(verified);
    /* Fail initialization, update and finalization; each next operation recovers. */
    for (int operation=1;operation<=3;++operation) {
        fail_api=operation;
        assert(!nc_issue_token(issuer,42));
        assert(fail_api==0);
        check(42);
    }
    /* Failure while replacing a key must not leave the old key usable. */
    assert(setenv("JWT_SECRET","rotated-after-failure",1)==0);
    fail_api=1;
    assert(!nc_issue_token(issuer,42));
    fail_api=4;
    assert(!nc_issue_token(issuer,42));
    assert(fail_api==0);
    check(42);
    assert(setenv("JWT_SECRET","",1)==0);
    assert(!nc_issue_token(issuer,42));
    assert(setenv("JWT_SECRET","restored",1)==0);
    check(42);
    nc_request_free(issuer);
    return NULL;
}

static void *parallel(void *argument)
{
    unsigned base=(unsigned)(uintptr_t)argument;
    for (unsigned i=0;i<256;++i) check(base+i+1);
    return NULL;
}

int main(void)
{
    pthread_t thread;
    assert(pthread_create(&thread,NULL,rotation,NULL)==0);
    assert(pthread_join(thread,NULL)==0);
    assert(atomic_load(&allocated)==atomic_load(&released));
    assert(setenv("JWT_SECRET","parallel-thread-key",1)==0);
    pthread_t threads[8];
    for (unsigned i=0;i<8;++i)
        assert(pthread_create(&threads[i],NULL,parallel,(void *)(uintptr_t)(i*1000))==0);
    for (unsigned i=0;i<8;++i) assert(pthread_join(threads[i],NULL)==0);
    assert(atomic_load(&allocated)==atomic_load(&released));
    puts("PASS: HMAC key lengths/rotation, independent signatures, TLS concurrency/lifetime, OpenSSL failure recovery");
    return 0;
}
