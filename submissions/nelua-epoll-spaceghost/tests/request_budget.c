/* Exhaustion must fail cleanly, preserve prior allocations and recover fully,
 * including concurrent writes and storage retained by the optional cache. */
#define _GNU_SOURCE
#include "native.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIMIT (1024U*1024U)
static const char wire[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
static char payload[600000];
static pthread_barrier_t allocated,released;
static atomic_uint successes,rejections;

static nc_request *make(void) { return nc_request_create(wire,sizeof(wire)-1); }
static void check(nc_request *r,size_t expected)
{
    size_t length=0;
    const char *data=nc_response_data(r,&length);
    if (nc_status(r)==200) {
        assert(length==expected && memcmp(data,payload,length)==0);
        atomic_fetch_add(&successes,1);
    } else {
        assert(nc_status(r)==503 && length>10 && !memcmp(data,"{\"errors\":",10));
        atomic_fetch_add(&rejections,1);
    }
}
static void *worker(void *unused)
{
    (void)unused;
    for (unsigned round=0;round<100;++round) {
        nc_request *r=make();
        if (r) nc_write_n(nc_begin(r,200),payload,100000);
        else { assert(errno==ENOMEM);atomic_fetch_add(&rejections,1); }
        pthread_barrier_wait(&allocated);
        assert(nc_request_memory_used()<=LIMIT);
        if (r) { check(r,100000);nc_request_free(r); }
        pthread_barrier_wait(&released);
    }
    return NULL;
}

int main(int argc,char **argv)
{
    if (argc>1) {
        assert(!strcmp(argv[1],"invalid") && !nc_request_memory_ready());
        assert(nc_request_memory_used()==0);
        puts("PASS: invalid request budget rejected before allocation");
        return 0;
    }
    assert(nc_request_memory_ready() && nc_request_memory_limit()==LIMIT);
    memset(payload,'q',sizeof(payload));
    nc_request *r=make();assert(r);
    size_t baseline=nc_request_memory_used();
    nc_write_n(nc_begin(r,200),payload,sizeof(payload));
    assert(nc_status(r)==503 && nc_request_memory_used()==baseline);
    /* A later error render cannot erase a previous allocation failure. */
    nc_error(r,500);assert(nc_status(r)==503);
    nc_request_free(r);assert(nc_request_memory_used()==0);

    nc_request *many[4096];unsigned count=0;
    for (;count<4096;++count) {
        many[count]=make();
        if (!many[count]) { assert(errno==ENOMEM);break; }
    }
    assert(count>100 && count<4096 && nc_request_memory_used()<=LIMIT);
    for (unsigned i=0;i<count;++i) nc_request_free(many[i]);
    assert(nc_request_memory_used()==0);
    for (unsigned i=0;i<1000;++i) {
        r=make();assert(r);
        nc_write_n(nc_begin(r,200),payload,20000);
        assert(nc_status(r)==200);check(r,20000);
        nc_request_free(r);assert(nc_request_memory_used()==0);
    }
    assert(pthread_barrier_init(&allocated,NULL,16)==0);
    assert(pthread_barrier_init(&released,NULL,16)==0);
    pthread_t workers[16];
    for (int i=0;i<16;++i) assert(pthread_create(&workers[i],NULL,worker,NULL)==0);
    for (int i=0;i<16;++i) assert(pthread_join(workers[i],NULL)==0);
    assert(atomic_load(&successes)>0 && atomic_load(&rejections)>0);
    assert(nc_request_memory_used()==0);
    nc_buffer_cache_trim();assert(nc_buffer_cached_bytes()==0);
    pthread_barrier_destroy(&allocated);pthread_barrier_destroy(&released);
    puts("PASS: 1 MiB live budget, 503 fallback, failed-growth preservation, sticky failure, "
         "cache reuse, concurrent exhaustion and complete recovery");
}
