/* Benchmark the real shared request/buffer/HMAC bridge, not allocator calls
 * divorced from their ownership and lifetime. No database or network is used. */
#define _GNU_SOURCE
#include "native.h"
#include <assert.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct task {
    const char *wire, *payload;
    size_t wire_size, payload_size, actions;
    unsigned group, mode;
    uint64_t checksum;
    pthread_barrier_t *ready, *go;
} task;

static uint64_t now(clockid_t clock)
{
    struct timespec value;
    assert(clock_gettime(clock,&value)==0);
    return (uint64_t)value.tv_sec*1000000000U+(uint64_t)value.tv_nsec;
}

static void cycle(task *t,size_t count)
{
    nc_request *requests[128];
    for (size_t base=0;base<count;base+=t->group) {
        size_t width=count-base<t->group?count-base:t->group;
        for (size_t index=0;index<width;++index) {
            nc_request *r=nc_request_create(t->wire,t->wire_size);
            assert(r);
            requests[index]=r;
            if (t->mode==1) {
                nc_json *object=nc_body(r,"user");
                const char *value=nc_string(nc_field(object,"username"));
                assert(value && value[0]=='x');
                t->checksum+=(unsigned char)value[(base+index)&1023];
            } else if (t->mode==2) assert(nc_auth(r)==42);
            size_t size=t->payload_size-((base+index)&63);
            nc_write_n(nc_begin(r,200),t->payload,size);
            size_t length;
            const char *output=nc_response_data(r,&length);
            assert(nc_status(r)==200 && length==size);
            t->checksum+=(unsigned char)output[(base+index)%length]+length;
        }
        for (size_t index=0;index<width;++index) nc_request_free(requests[index]);
    }
}

static void *worker(void *argument)
{
    task *t=argument;
    cycle(t,512);
    pthread_barrier_wait(t->ready);
    pthread_barrier_wait(t->go);
    cycle(t,t->actions);
    return NULL;
}

int main(int argc,char **argv)
{
    assert(argc==5);
    unsigned threads=(unsigned)strtoul(argv[1],NULL,10);
    unsigned group=(unsigned)strtoul(argv[2],NULL,10);
    unsigned mode=(unsigned)strtoul(argv[3],NULL,10);
    size_t actions=strtoull(argv[4],NULL,10);
    assert(threads>=1 && threads<=16 && group>=1 && group<=128 && mode<=2 && actions>=threads);
    assert(setenv("JWT_SECRET","request-memory-benchmark",1)==0);
    static const char empty[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
    nc_request *issuer=nc_request_create(empty,sizeof(empty)-1);
    assert(issuer);
    const char *token=nc_issue_token(issuer,42);
    assert(token);
    char body[4096], wire[8192], payload[16384];
    memset(body,'x',sizeof(body));
    memcpy(body,"{\"user\":{\"username\":\"",21);
    memcpy(body+2069,"\"}}",3);
    int length;
    if (mode==1) length=snprintf(wire,sizeof(wire),
        "POST /api/users HTTP/1.1\r\nHost: test\r\nContent-Length: 2072\r\n\r\n%.*s",2072,body);
    else if (mode==2) length=snprintf(wire,sizeof(wire),
        "GET /api/articles?limit=20 HTTP/1.1\r\nHost: test\r\nAuthorization: Token %s\r\n\r\n",token);
    else length=snprintf(wire,sizeof(wire),"%s",empty);
    assert(length>0 && (size_t)length<sizeof(wire));
    for (size_t i=0;i<sizeof(payload);++i) payload[i]=(char)('a'+i%26);
    pthread_barrier_t ready,go;
    assert(pthread_barrier_init(&ready,NULL,threads+1)==0);
    assert(pthread_barrier_init(&go,NULL,threads+1)==0);
    pthread_t workers[16]; task tasks[16];
    for (unsigned i=0;i<threads;++i) {
        tasks[i]=(task){.wire=wire,.wire_size=(size_t)length,.payload=payload,
            .payload_size=mode==2?16384:2048,.actions=actions/threads+(i<actions%threads),
            .group=group,.mode=mode,.ready=&ready,.go=&go};
        assert(pthread_create(&workers[i],NULL,worker,&tasks[i])==0);
    }
    pthread_barrier_wait(&ready);
    uint64_t wall=now(CLOCK_MONOTONIC),cpu=now(CLOCK_PROCESS_CPUTIME_ID);
    pthread_barrier_wait(&go);
    uint64_t checksum=0;
    for (unsigned i=0;i<threads;++i) {
        assert(pthread_join(workers[i],NULL)==0);
        checksum+=tasks[i].checksum;
    }
    cpu=now(CLOCK_PROCESS_CPUTIME_ID)-cpu;
    wall=now(CLOCK_MONOTONIC)-wall;
    assert(checksum);
    printf("{\"threads\":%u,\"group\":%u,\"mode\":%u,\"actions\":%zu,"
           "\"wall_ns\":%" PRIu64 ",\"cpu_ns\":%" PRIu64 ",\"checksum\":%" PRIu64 ",\"retained_bytes\":%zu}\n",
           threads,group,mode,actions,wall,cpu,checksum,nc_buffer_cached_bytes());
    nc_request_free(issuer);
    assert(nc_request_memory_used()==0);
    nc_request_pool_trim();assert(nc_request_pool_cached_bytes()==0);
    nc_buffer_cache_trim();
    assert(nc_buffer_cached_bytes()==0);
    pthread_barrier_destroy(&ready); pthread_barrier_destroy(&go);
}
