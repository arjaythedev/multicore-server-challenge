/* Cross-thread request ownership and byte-exact storage reuse under a hard
 * retention bound. Works with host malloc or the private Nelibc provider. */
#define _GNU_SOURCE
#include "native.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef NC_BUFFER_CACHE
#define NC_BUFFER_CACHE 0
#endif
#define COUNT 1152U
static nc_request *requests[COUNT];
static unsigned phase;

static char expected(unsigned request,size_t index)
{ return (char)('a'+(request+index+phase)%26); }

static void *produce(void *argument)
{
    unsigned worker=*(unsigned *)argument;
    char body[40000];
    static const char wire[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
    for (unsigned i=worker;i<COUNT;i+=4) {
        size_t size=i<768?20000:40000;
        for (size_t at=0;at<size;++at) body[at]=expected(i,at);
        requests[i]=nc_request_create(wire,sizeof(wire)-1);
        assert(requests[i]);
        /* Incremental growth also exercises copying and releasing an active
         * cached buffer while growing into another class. */
        nc_buffer *b=nc_begin(requests[i],200);
        for (size_t at=0;at<size;) {
            size_t part=size-at<997?size-at:997;
            nc_write_n(b,body+at,part);
            at+=part;
        }
        assert(nc_status(requests[i])==200);
    }
    return NULL;
}

int main(void)
{
    for (phase=0;phase<4;++phase) {
        pthread_t workers[4];unsigned ids[]={0,1,2,3};
        for (unsigned i=0;i<4;++i) assert(pthread_create(&workers[i],NULL,produce,&ids[i])==0);
        for (unsigned i=0;i<4;++i) assert(pthread_join(workers[i],NULL)==0);
        for (unsigned i=0;i<COUNT;++i) {
            size_t size=0,wanted=i<768?20000:40000;
            const char *body=nc_response_data(requests[i],&size);
            assert(size==wanted);
            for (size_t at=0;at<size;++at) assert(body[at]==expected(i,at));
            nc_request_free(requests[i]);requests[i]=NULL;
        }
        size_t retained=nc_buffer_cached_bytes();
        assert(retained<=32U*1024U*1024U);
        assert(NC_BUFFER_CACHE?retained>0:retained==0);
    }
    nc_buffer_cache_trim();
    assert(nc_buffer_cached_bytes()==0);
    assert(nc_request_memory_used()==0);
    nc_request_pool_trim();assert(nc_request_pool_cached_bytes()==0);
    puts("PASS: 4608 requests produced on four threads and verified/freed on another; "
         "incremental growth, changing contents, <=32 MiB retained and complete trim");
}
