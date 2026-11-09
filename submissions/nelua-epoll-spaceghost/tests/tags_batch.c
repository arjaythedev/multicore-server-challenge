/* Real Nelua batch dispatch/rendering with fresh, in-memory libpq tag results. */
#include "native.h"
#include <libpq-fe.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { MAX_REQUESTS=128, MAX_TAGS=200 };
static const char wire[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
static const char *values[MAX_TAGS];
static char tag_names[MAX_TAGS][16];
static unsigned queries, reads, rows, allocation_failures;
static bool query_error, fail_next_realloc, baseline;

char *__real_PQgetvalue(const PGresult *,int,int);
char *__wrap_PQgetvalue(const PGresult *r,int row,int col)
{ ++reads; return __real_PQgetvalue(r,row,col); }
void *__real_realloc(void *,size_t);
void *__wrap_realloc(void *p,size_t n)
{
    if (fail_next_realloc) {
        fail_next_realloc=false; ++allocation_failures; errno=ENOMEM; return NULL;
    }
    return __real_realloc(p,n);
}
nc_result *__wrap_nc_db_query(nc_db *db,int id,const char *sql,int count,
                              const char *const *parameters)
{
    assert(!db && id==90 && sql && !count && !parameters);
    assert(!strcmp(sql,"SELECT name FROM public.tags ORDER BY name"));
    ++queries;
    if (query_error) return NULL;
    PGresult *r=PQmakeEmptyPGresult(NULL,PGRES_TUPLES_OK);
    PGresAttDesc attribute={.name="name",.format=1,.typid=25,.typlen=-1,.atttypmod=-1};
    assert(r && PQsetResultAttrs(r,1,&attribute));
    for (unsigned i=0;i<rows;++i)
        assert(PQsetvalue(r,(int)i,0,(char *)values[i],(int)strlen(values[i])));
    return r;
}
static void make_requests(nc_request **requests,unsigned count)
{
    for (unsigned i=0;i<count;++i) {
        requests[i]=nc_request_create(wire,sizeof(wire)-1);
        assert(requests[i]);
    }
}
static void check(nc_request *r,int status,const char *expected)
{
    size_t length;
    const char *body=nc_response_data(r,&length);
    assert(nc_status(r)==status && length==strlen(expected));
    assert(!memcmp(body,expected,length));
}
static void run_case(unsigned count,const char *expected,bool next_batch)
{
    nc_request *requests[MAX_REQUESTS];
    make_requests(requests,count); queries=reads=0;
    conduit_batch(requests,(int)count,NULL);
    assert(queries==1 && reads==rows*(baseline?count:1));
    for (unsigned i=0;i<count;++i) check(requests[i],200,expected);
    if (count>1) {
        size_t length;
        const char *first=nc_response_data(requests[0],&length);
        for (unsigned i=1;i<count;++i)
            assert(nc_response_data(requests[i],&length)!=first);
    }
    nc_request_free(requests[0]);
    if (next_batch) {
        nc_request *later; make_requests(&later,1);
        rows=1; values[0]="changed";
        conduit_batch(&later,1,NULL);
        check(later,200,"{\"tags\":[\"changed\"]}");
        nc_request_free(later);
    }
    /* Sender zero and a later PGresult can die before the remaining senders. */
    for (unsigned i=1;i<count;++i) {
        check(requests[i],200,expected); nc_request_free(requests[i]);
    }
}
static void errors(void)
{
    nc_request *requests[MAX_REQUESTS];
    query_error=true; make_requests(requests,MAX_REQUESTS); queries=reads=0;
    conduit_batch(requests,MAX_REQUESTS,NULL);
    assert(queries==1 && !reads);
    for (unsigned i=0;i<MAX_REQUESTS;++i) {
        check(requests[i],500,"{\"errors\":{\"body\":[\"request failed\"]}}");
        nc_request_free(requests[i]);
    }
    query_error=false;
    if (baseline) return;
    make_requests(requests,MAX_REQUESTS);
    rows=1; values[0]="allocated"; fail_next_realloc=true;
    conduit_batch(requests,MAX_REQUESTS,NULL);
    assert(allocation_failures==1 && !fail_next_realloc);
    for (unsigned i=0;i<MAX_REQUESTS;++i) {
        check(requests[i],500,"{\"errors\":{\"body\":[\"internal error\"]}}");
        nc_request_free(requests[i]);
    }
}
int main(int argc,char **argv)
{
    unsigned loops=argc>1?(unsigned)strtoul(argv[1],NULL,10):0;
    baseline=argc>2 && atoi(argv[2]);
    rows=0; run_case(1,"{\"tags\":[]}",false);
    run_case(MAX_REQUESTS,"{\"tags\":[]}",false);
    rows=5; values[0]="a"; values[1]="q\"\\\n";
    values[2]="\xe9\x9b\xaa"; values[3]="\1"; values[4]="";
    run_case(MAX_REQUESTS,"{\"tags\":[\"a\",\"q\\\"\\\\\\u000a\",\"\xe9\x9b\xaa\",\"\\u0001\",\"\"]}",true);
    errors();
    char expected[4096]; size_t used=(size_t)sprintf(expected,"{\"tags\":[");
    for (unsigned i=0;i<MAX_TAGS;++i) {
        snprintf(tag_names[i],sizeof(tag_names[i]),"tag-%03u",i); values[i]=tag_names[i];
        used+=(size_t)sprintf(expected+used,"%s\"%s\"",i?",":"",values[i]);
    }
    sprintf(expected+used,"]}"); rows=MAX_TAGS;
    run_case(MAX_REQUESTS,expected,false);
    if (loops) {
        struct timespec start,end; uint64_t bytes=0;
        assert(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&start));
        for (unsigned j=0;j<loops;++j) {
            nc_request *requests[MAX_REQUESTS]; make_requests(requests,MAX_REQUESTS);
            conduit_batch(requests,MAX_REQUESTS,NULL);
            for (unsigned i=0;i<MAX_REQUESTS;++i) {
                size_t n; nc_response_data(requests[i],&n); bytes+=n; nc_request_free(requests[i]);
            }
        }
        assert(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&end));
        double seconds=end.tv_sec-start.tv_sec+(end.tv_nsec-start.tv_nsec)*1e-9;
        printf("{\"baseline\":%s,\"requests\":%u,\"cpu_seconds\":%.9f,\"response_bytes\":%llu}\n",
               baseline?"true":"false",loops*MAX_REQUESTS,seconds,(unsigned long long)bytes);
    } else puts(baseline ? "PASS: baseline tag batch output, ownership and query errors" :
                "PASS: tag batch escaping, independent ownership, fresh results, errors and allocation failure");
    return 0;
}
