#define _GNU_SOURCE
#include "json_fast.h"
#include <openssl/hmac.h>
#include <openssl/evp.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

#pragma pack(push, 1)
typedef struct { uint32_t events; uint64_t data; } GooseEpollEvent;
typedef struct { GooseEpollEvent *data; int64_t len; } GooseEpollSlice;
#pragma pack(pop)
int64_t native_sys_read(int32_t, mutable_bytes);
int64_t native_sys_write(int32_t, bytes);
int64_t native_sys_recv(int32_t, mutable_bytes, int32_t);
int64_t native_sys_send(int32_t, bytes, int32_t);
int64_t native_sys_getrandom(mutable_bytes, uint32_t);
int32_t native_sys_epoll_ctl(int32_t, int32_t, int32_t, GooseEpollEvent *);
int32_t native_sys_epoll_wait(int32_t, GooseEpollSlice, int32_t);
static int fail_update;
int __real_EVP_MAC_update(EVP_MAC_CTX *, const unsigned char *, size_t);
int __wrap_EVP_MAC_update(EVP_MAC_CTX *c, const unsigned char *p, size_t n) {
    return fail_update ? 0 : __real_EVP_MAC_update(c,p,n);
}
static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static void vector(const uint8_t *key,size_t kn,const uint8_t *msg,size_t mn,const char *hex) {
    uint8_t result[32]; char actual[65];
    CHECK(native_hmac_sha256((bytes){key,(int64_t)kn},(bytes){msg,(int64_t)mn},(mutable_bytes){result,32})==1);
    for(int i=0;i<32;++i) sprintf(actual+2*i,"%02x",result[i]);
    CHECK(!strcmp(actual,hex));
}
static atomic_int thread_errors;
static void *threaded(void *arg) {
    uintptr_t id=(uintptr_t)arg;
    for(unsigned round=0;round<400;++round) {
        uint8_t key[140],msg[320],out[32],ref[32]; unsigned n=32;
        size_t kn=(round*17+id)%sizeof(key),mn=(round*31+id)%sizeof(msg);
        for(size_t i=0;i<kn;++i) key[i]=(uint8_t)(i+round+id);
        for(size_t i=0;i<mn;++i) msg[i]=(uint8_t)(i*13+round*7+id);
        HMAC(EVP_sha256(),key,(int)kn,msg,mn,ref,&n);
        if(native_hmac_sha256((bytes){key,(int64_t)kn},(bytes){msg,(int64_t)mn},(mutable_bytes){out,32})!=1 || memcmp(ref,out,32)) atomic_fetch_add(&thread_errors,1);
        /* Repeat the same key/message: fresh contexts must still return the exact MAC. */
        if(native_hmac_sha256((bytes){key,(int64_t)kn},(bytes){msg,(int64_t)mn},(mutable_bytes){out,32})!=1 || memcmp(ref,out,32)) atomic_fetch_add(&thread_errors,1);
    }
    return NULL;
}
static size_t reference(const uint8_t *in,size_t n,uint8_t *out) {
    const char *hex="0123456789abcdef"; size_t at=0; out[at++]='"';
    for(size_t i=0;i<n;++i) {
        uint8_t c=in[i];
        if(c=='"'||c=='\\') {out[at++]='\\';out[at++]=c;}
        else if(c=='\n'||c=='\r'||c=='\t'||c=='\b'||c=='\f') {out[at++]='\\';out[at++]=c=='\n'?'n':c=='\r'?'r':c=='\t'?'t':c=='\b'?'b':'f';}
        else if(c<32) {out[at++]='\\';out[at++]='u';out[at++]='0';out[at++]='0';out[at++]=hex[c>>4];out[at++]=hex[c&15];}
        else out[at++]=c;
    }
    out[at++]='"'; return at;
}
static void json_checks(void) {
    uint8_t input[1024],output[8192],ref[8192];
    for(size_t n=0;n<=1024;++n) {
        for(size_t i=0;i<n;++i) input[i]=(uint8_t)(i*31+n*17);
        gs_rhdr hdr={output,0};gs_stack stack={output};
        json_append_string((bytes){input,(int64_t)n},(gs_rref){&hdr,&stack});
        size_t rn=reference(input,n,ref);
        CHECK(hdr.len==(int64_t)rn && stack.top==output+rn && !memcmp(output,ref,rn));
    }
    for(size_t n=0;n<=1024;++n) {
        memset(input,'a',n);CHECK(json_plain_prefix((bytes){input,(int64_t)n})==(int64_t)n);
        if(n) for(size_t i=0;i<n;i+=7) {
            input[i]='\\';CHECK(json_plain_prefix((bytes){input,(int64_t)n})==(int64_t)i);input[i]='a';
            input[i]='"';CHECK(json_plain_prefix((bytes){input,(int64_t)n})==(int64_t)i);input[i]='a';
            input[i]=(uint8_t)(i%32);CHECK(json_plain_prefix((bytes){input,(int64_t)n})==(int64_t)i);input[i]='a';
        }
    }
}
static void syscall_checks(void) {
    int ep=epoll_create1(EPOLL_CLOEXEC),a[2],b[2];CHECK(ep>=0);CHECK(!pipe(a));CHECK(!pipe(b));
    GooseEpollEvent ea={EPOLLIN,UINT64_C(0xa101020304050607)},eb={EPOLLIN,UINT64_C(0xb807060504030201)};
    CHECK(!native_sys_epoll_ctl(ep,EPOLL_CTL_ADD,a[0],&ea));CHECK(!native_sys_epoll_ctl(ep,EPOLL_CTL_ADD,b[0],&eb));
    const uint8_t msg[]="portable slice";
    CHECK(native_sys_write(a[1],(bytes){msg,sizeof(msg)})==(int64_t)sizeof(msg));
    CHECK(native_sys_write(b[1],(bytes){msg,sizeof(msg)})==(int64_t)sizeof(msg));
    uint8_t guarded[8+2*sizeof(GooseEpollEvent)+8];memset(guarded,0xa5,sizeof(guarded));
    GooseEpollEvent *events=(GooseEpollEvent *)(void *)(guarded+8);
    CHECK(native_sys_epoll_wait(ep,(GooseEpollSlice){events,2},1000)==2);
    CHECK((events[0].data==ea.data && events[1].data==eb.data)||(events[0].data==eb.data && events[1].data==ea.data));
    CHECK((events[0].events&EPOLLIN)&&(events[1].events&EPOLLIN));
    for(int i=0;i<8;++i)CHECK(guarded[i]==0xa5 && guarded[sizeof(guarded)-1-i]==0xa5);
    uint8_t out[64];CHECK(native_sys_read(a[0],(mutable_bytes){out,sizeof(out)})==(int64_t)sizeof(msg));CHECK(!memcmp(out,msg,sizeof(msg)));
    ea.data=UINT64_C(0xc0010000000000ff);CHECK(!native_sys_epoll_ctl(ep,EPOLL_CTL_MOD,b[0],&ea));
    CHECK(native_sys_epoll_wait(ep,(GooseEpollSlice){events,2},1000)==1);CHECK(events[0].data==ea.data);
    CHECK(native_sys_read(b[0],(mutable_bytes){out,sizeof(out)})==(int64_t)sizeof(msg));
    CHECK(!native_sys_epoll_ctl(ep,EPOLL_CTL_DEL,b[0],NULL));
    int sp[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,sp));
    CHECK(native_sys_send(sp[0],(bytes){msg,sizeof(msg)},MSG_NOSIGNAL)==(int64_t)sizeof(msg));
    CHECK(native_sys_recv(sp[1],(mutable_bytes){out,sizeof(out)},0)==(int64_t)sizeof(msg));CHECK(!memcmp(out,msg,sizeof(msg)));
    CHECK(native_sys_getrandom((mutable_bytes){out,32},0)==32);
    close(sp[0]);close(sp[1]);close(a[0]);close(a[1]);close(b[0]);close(b[1]);close(ep);
}
int main(void) {
    uint8_t k[131],m[50];memset(k,0x0b,20);
    vector(k,20,(const uint8_t *)"Hi There",8,"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    vector((const uint8_t *)"Jefe",4,(const uint8_t *)"what do ya want for nothing?",28,"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    memset(k,0xaa,20);memset(m,0xdd,50);
    vector(k,20,m,50,"773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe");
    memset(k,0xaa,131);const char *longmsg="Test Using Larger Than Block-Size Key - Hash Key First";
    vector(k,131,(const uint8_t *)longmsg,strlen(longmsg),"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
    vector((const uint8_t *)"",0,(const uint8_t *)"",0,"b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad");
    uint8_t out[32];memset(out,0xa5,32);fail_update=1;
    CHECK(native_hmac_sha256((bytes){k,131},(bytes){m,50},(mutable_bytes){out,32})==0);
    for(int i=0;i<32;++i) { CHECK(out[i]==0); }
    fail_update=0;
    vector((const uint8_t *)"Jefe",4,(const uint8_t *)"what do ya want for nothing?",28,"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    CHECK(native_hmac_sha256((bytes){k,-1},(bytes){m,50},(mutable_bytes){out,32})==0);
    CHECK(native_hmac_sha256((bytes){k,131},(bytes){m,50},(mutable_bytes){out,31})==0);
    pthread_t t[8];for(uintptr_t i=0;i<8;++i)CHECK(!pthread_create(&t[i],NULL,threaded,(void *)i));
    for(int i=0;i<8;++i) { CHECK(!pthread_join(t[i],NULL)); }
    CHECK(!atomic_load(&thread_errors));
    json_checks();syscall_checks();
    printf("{\"status\":\"PASS\",\"checks\":%u,\"hmac_vectors\":5,\"hmac_thread_calls\":6400,\"threads\":8,\"json_lengths\":1025,\"epoll_native_size\":%zu}\n",checks,sizeof(struct epoll_event));
    return 0;
}
