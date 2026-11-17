#define _GNU_SOURCE
#include "native.h"
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define THREADS 40U
#define GROUP 128U
#define SPARE_LIMIT (32U*128U*4032U)
static const char wire[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
static pthread_barrier_t allocated,freed,leave;

static nc_request *make(void)
{
    nc_request *r=nc_request_create(wire,sizeof(wire)-1);
    assert(r && nc_auth(r)==0 && nc_segments(r)==2 && nc_eq(nc_segment(r,1),"tags"));
    return r;
}
static void *worker(void *unused)
{
    (void)unused;
    nc_request_pool_warm();
    nc_request *requests[GROUP];
    for (unsigned i=0;i<GROUP;++i) requests[i]=make();
    pthread_barrier_wait(&allocated);
    for (unsigned i=0;i<GROUP;++i) nc_request_free(requests[i]);
    pthread_barrier_wait(&freed);
    pthread_barrier_wait(&leave);
    return NULL;
}
static void *return_elsewhere(void *request)
{ nc_request_free(request);return NULL; }

int main(void)
{
    nc_request_pool_warm();
    assert(nc_request_memory_used()==0);
    assert(nc_request_pool_cached_bytes()<=SPARE_LIMIT);
    nc_request *held=make();
    char payload[16384];memset(payload,'q',sizeof(payload));
    nc_buffer *b=nc_begin(held,200);
    assert(nc_reserve_json(b,sizeof(payload)));
    size_t length=99;
    nc_response_data(held,&length);assert(length==0); /* Reservation never emits bytes. */
    nc_write_n(b,payload,sizeof(payload));
    for (unsigned i=0;i<1000;++i) {
        nc_request *r=make();
        nc_write(nc_begin(r,200),"different response");
        nc_request_free(r);
    }
    const char *body=nc_response_data(held,&length);
    assert(length==sizeof(payload) && !memcmp(body,payload,length));
    pthread_t remote;
    assert(pthread_create(&remote,NULL,return_elsewhere,held)==0);
    assert(pthread_join(remote,NULL)==0);
    assert(nc_request_memory_used()==0);
    nc_request_pool_warm();
    /* More live owners than registry slots must fall back to the provider. */
    pthread_t workers[THREADS];
    assert(pthread_barrier_init(&allocated,NULL,THREADS+1)==0);
    assert(pthread_barrier_init(&freed,NULL,THREADS+1)==0);
    assert(pthread_barrier_init(&leave,NULL,THREADS+1)==0);
    for (unsigned i=0;i<THREADS;++i) assert(pthread_create(&workers[i],NULL,worker,NULL)==0);
    pthread_barrier_wait(&allocated);
    assert(nc_request_memory_used()<=nc_request_memory_limit());
    pthread_barrier_wait(&freed);
    assert(nc_request_memory_used()==0 && nc_request_pool_cached_bytes()<=SPARE_LIMIT);
#if NC_REQUEST_POOL
    assert(nc_request_pool_cached_bytes()==SPARE_LIMIT);
#endif
    pthread_barrier_wait(&leave);
    for (unsigned i=0;i<THREADS;++i) assert(pthread_join(workers[i],NULL)==0);
    nc_request_pool_trim();nc_buffer_cache_trim();
    assert(nc_request_pool_cached_bytes()==0 && nc_buffer_cached_bytes()==0);
#if NC_OUTPUT_RESERVE
    held=make();b=nc_begin(held,200);
    assert(!nc_reserve_json(b,SIZE_MAX) && nc_status(held)==500);
    nc_request_free(held);nc_request_pool_trim();
#endif
    pthread_barrier_destroy(&allocated);pthread_barrier_destroy(&freed);pthread_barrier_destroy(&leave);
    puts("PASS: bounded owner caches, 40-owner overflow, cross-thread returns, live response isolation, reservation bounds and thread-exit reclamation");
}
