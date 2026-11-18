#define _GNU_SOURCE
#include "reactor.h"
#include <libpq-fe.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/eventfd.h>
#include <unistd.h>

enum { TASKS=24 };
typedef struct test_state { int taken, done, running, peak, stop_after; bool started; int jobs[TASKS]; } test_state;
static test_state state;

static void *take(void *context,uint64_t *deadline)
{
    test_state *s=context;
    (void)deadline;
    if (s->taken==TASKS) return NULL;
    s->jobs[s->taken]=s->taken;
    return &s->jobs[s->taken++];
}

static void execute(void *work,nc_db *db)
{
    int job=*(int *)work;
    /* More than one scheduler's worth of purely synchronous work must drain
     * even when nobody writes another eventfd notification. */
    if (job>=16) return;
    ++state.running;
    if (state.running>state.peak) state.peak=state.running;
    if (job==0) {
        assert(nc_db_pipeline_begin(db));
        assert(!nc_db_query(db,98,"SELECT pg_terminate_backend(pg_backend_pid())",0,NULL));
        assert(!nc_db_pipeline_flush(db));
        nc_db_pipeline_end(db);
    }
    /* Includes recovery/reprepare on the terminated backend's connection. */
    const char *values[]={"42"};
    nc_result *r=nc_db_query(db,1,"SELECT $1::bigint, pg_sleep(0.025)",1,values);
    assert(nc_db_ok(r) && nc_integer(r,0,0)==42);
    nc_result_free(r);
    assert(nc_db_pipeline_begin(db));
    assert(!nc_db_query(db,90,"SELECT $1::bigint, pg_sleep(0.025)",1,values));
    assert(!nc_db_query(db,91,"SELECT repeat('x',262144)",0,NULL));
    assert(nc_db_pipeline_flush(db));
    r=nc_db_query(db,90,NULL,0,NULL);
    assert(nc_db_ok(r) && nc_integer(r,0,0)==42);
    nc_result_free(r);
    r=nc_db_query(db,91,NULL,0,NULL);
    assert(nc_db_ok(r) && nc_value_length(r,0,0)==262144);
    const char *bytes=nc_value(r,0,0);
    for (int i=0;i<262144;++i) assert(bytes[i]=='x');
    nc_result_free(r);
    nc_db_pipeline_end(db);
    /* Error in one connection's pipeline must not poison the other owners. */
    assert(nc_db_pipeline_begin(db));
    assert(!nc_db_query(db,92,"SELECT 1/0",0,NULL));
    assert(nc_db_pipeline_flush(db));
    r=nc_db_query(db,92,NULL,0,NULL);
    assert(r && PQresultStatus(r)==PGRES_FATAL_ERROR);
    nc_result_free(r);
    nc_db_pipeline_end(db);
    r=nc_db_query(db,1,"SELECT $1::bigint, pg_sleep(0.025)",1,values);
    assert(nc_db_ok(r) && nc_integer(r,0,0)==42);
    nc_result_free(r);
    --state.running;
}

static void complete(void *context,void *work)
{
    test_state *s=context;
    int job=*(int *)work;
    assert(job>=0 && job<TASKS && s->jobs[job]==job);
    s->jobs[job]=-1;
    ++s->done;
}
static bool stopping(void *context)
{
    test_state *s=context;
    return s->stop_after?s->taken>=s->stop_after:s->done==TASKS;
}
static void started(void *context,bool good)
{
    assert(good);
    ((test_state *)context)->started=true;
}

int main(int argc,char **argv)
{
    assert(argc==2);
    assert(setenv("READ_PIPELINE","1",1)==0);
    int wake=eventfd(0,EFD_NONBLOCK|EFD_CLOEXEC);
    assert(wake>=0);
    const nc_reactor_hooks hooks={take,execute,complete,stopping,started};
    nc_reactor_run(argv[1],4,wake,&hooks,&state);
    assert(state.started && state.done==TASKS && state.running==0);
    assert(state.peak==4);
    state=(test_state){.stop_after=4};
    nc_reactor_run(argv[1],4,wake,&hooks,&state);
    assert(state.started && state.taken==4 && state.done==4 && state.running==0);
    assert(state.peak==4);
    close(wake);
    puts("PASS: 24 tasks, 4 overlapping libpq sessions on one OS thread; binary results, large reads, pipeline errors, reconnects, inline completion and shutdown with active work");
}
