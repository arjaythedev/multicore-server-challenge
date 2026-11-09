/* Native read-pipeline boundary tests. Run against a local test server. Tests
 * read literal values, change their own timeout, and terminate their own backend.
 *
 * gcc -std=gnu11 -O1 -g -ffunction-sections -fdata-sections -Isrc \
 *   -I"$(pg_config --includedir)" src/db.c /path/to/pipeline-test.c \
 *   -L"$(pg_config --libdir)" -Wl,-rpath,"$(pg_config --libdir)" \
 *   -Wl,--gc-sections -Wl,--wrap=PQclear -lpq -o /tmp/pipeline-test
 * /tmp/pipeline-test "$DATABASE_URL"
 * No URL or connection credentials are printed.
 */
#define _POSIX_C_SOURCE 200809L
#include "native.h"
#include <libpq-fe.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, clears;
void __real_PQclear(PGresult *result);
void __wrap_PQclear(PGresult *result)
{
    if (result) ++clears;
    __real_PQclear(result);
}

static const char q_pair[] = "SELECT $1::bigint, $2::text";
static const char q_large[] = "SELECT repeat($1::text, $2::int)";
static const char q_error[] = "SELECT $1::bigint / $2::bigint";
static const char q_after[] = "SELECT $1::text";
static const char q_sleep[] = "SELECT pg_sleep(0.100), $1::bigint";
static const char q_sum[] =
    "SELECT $1::bigint+$2::bigint+$3::bigint+$4::bigint+"
    "$5::bigint+$6::bigint+$7::bigint+$8::bigint+"
    "$9::bigint+$10::bigint+$11::bigint+$12::bigint+"
    "$13::bigint+$14::bigint+$15::bigint+$16::bigint";

static void passed(const char *label)
{
    printf("ok %u: %s\n",++checks,label);
    fflush(stdout);
}

static void pair_result(nc_result *result,const char *label)
{
    assert(result && nc_db_ok(result));
    assert(nc_rows(result)==1);
    assert(nc_integer(result,0,0)==42);
    assert(nc_value_length(result,0,1)==12);
    assert(memcmp(nc_value(result,0,1),"pipeline-\xE9\x9B\xAA",12)==0);
    nc_result_free(result);
    passed(label);
}

static void pair_batch(nc_db *db,const char *label)
{
    const char *parameters[]={"42","pipeline-\xE9\x9B\xAA"};
    assert(nc_db_pipeline_begin(db));
    assert(nc_db_pipeline_staging(db));
    assert(nc_db_query(db,90,q_pair,2,parameters)==NULL);
    assert(nc_db_pipeline_flush(db));
    assert(!nc_db_pipeline_staging(db));
    pair_result(nc_db_query(db,90,q_pair,2,parameters),label);
    assert(nc_db_query(db,90,q_pair,2,parameters)==NULL);
    nc_db_pipeline_end(db);
}

int main(int argc,char **argv)
{
    if (argc!=2) {
        fprintf(stderr,"usage: pipeline-test DATABASE_URL\n");
        return 2;
    }
    const char *parameters[]={"42","pipeline-\xE9\x9B\xAA"};

    /* Enablement is captured when each connection is opened. */
    assert(setenv("READ_PIPELINE","0",1)==0);
    nc_db *off=nc_db_open(argv[1]);
    assert(off);
    assert(!nc_db_pipeline_begin(off));
    assert(!nc_db_pipeline_staging(off));
    pair_result(nc_db_query(off,90,q_pair,2,parameters),"explicit-off synchronous query");
    assert(setenv("READ_PIPELINE","1",1)==0);
    assert(!nc_db_pipeline_begin(off));
    nc_db_pipeline_end(off);
    nc_db_close(off);
    passed("pipeline mode is cached at connection open");

    nc_db *db=nc_db_open(argv[1]);
    assert(db);
    assert(setenv("READ_PIPELINE","0",1)==0);
    pair_batch(db,"cold prepared query, UTF8 and binary bigint");
    pair_batch(db,"warm prepared query and exactly-once result claim");
    assert(setenv("READ_PIPELINE","1",1)==0);

    const char *large_parameters[]={"X","262144"};
    const char *sum_parameters[]={"1","2","3","4","5","6","7","8",
                                  "9","10","11","12","13","14","15","16"};
    assert(nc_db_pipeline_begin(db));
    assert(nc_db_query(db,90,q_pair,2,parameters)==NULL);
    assert(nc_db_query(db,91,q_large,2,large_parameters)==NULL);
    assert(nc_db_query(db,96,q_sum,16,sum_parameters)==NULL);
    assert(nc_db_pipeline_flush(db));
    nc_result *large=nc_db_query(db,91,q_large,2,large_parameters);
    assert(large && nc_db_ok(large) && nc_rows(large)==1);
    assert(nc_value_length(large,0,0)==262144);
    const unsigned char *bytes=(const unsigned char *)nc_value(large,0,0);
    for (size_t i=0;i<262144;++i) assert(bytes[i]=='X');
    nc_result_free(large);
    passed("256 KiB result survives partial socket reads and flushes");
    nc_result *sum=nc_db_query(db,96,q_sum,16,sum_parameters);
    assert(sum && nc_db_ok(sum) && nc_integer(sum,0,0)==136);
    nc_result_free(sum);
    passed("sixteen parameters retain correct prepared types");
    pair_result(nc_db_query(db,90,q_pair,2,parameters),"results can be claimed out of submission order");
    nc_db_pipeline_end(db);

    /* End must clear results the application did not claim. The PQclear wrap
     * counts only non-NULL results, so this is not satisfied by no-op cleanup. */
    assert(nc_db_pipeline_begin(db));
    assert(nc_db_query(db,90,q_pair,2,parameters)==NULL);
    assert(nc_db_query(db,91,q_large,2,large_parameters)==NULL);
    assert(nc_db_pipeline_flush(db));
    nc_result_free(nc_db_query(db,90,q_pair,2,parameters));
    unsigned before=clears;
    nc_db_pipeline_end(db);
    assert(clears>before);
    pair_batch(db,"unclaimed results are cleared before next batch");

    /* An execution error is a normal drained pipeline outcome. Later commands
     * are aborted until Sync; neither the reads nor any writes are replayed. */
    const char *zero_parameters[]={"1","0"};
    const char *after_parameters[]={"after-error"};
    assert(nc_db_pipeline_begin(db));
    assert(nc_db_query(db,92,q_error,2,zero_parameters)==NULL);
    assert(nc_db_query(db,93,q_after,1,after_parameters)==NULL);
    assert(nc_db_pipeline_flush(db));
    nc_result *error=nc_db_query(db,92,q_error,2,zero_parameters);
    assert(error && PQresultStatus(error)==PGRES_FATAL_ERROR);
    assert(strcmp(PQresultErrorField(error,PG_DIAG_SQLSTATE),"22012")==0);
    nc_result_free(error);
    nc_result *aborted=nc_db_query(db,93,q_after,1,after_parameters);
    assert(aborted && PQresultStatus(aborted)==PGRES_PIPELINE_ABORTED);
    nc_result_free(aborted);
    nc_db_pipeline_end(db);
    passed("SQL error preserves SQLSTATE and aborts following commands");
    pair_batch(db,"next batch reconnects and reprepares after SQL error");

    /* A cold PREPARE itself can fail. Its execution and following commands
     * must be consumed as aborted, without losing an earlier successful read. */
    assert(nc_db_pipeline_begin(db));
    assert(nc_db_query(db,90,q_pair,2,parameters)==NULL);
    assert(nc_db_query(db,95,"SELECT FROM",0,NULL)==NULL);
    assert(nc_db_query(db,93,q_after,1,after_parameters)==NULL);
    assert(nc_db_pipeline_flush(db));
    pair_result(nc_db_query(db,90,q_pair,2,parameters),
                "earlier results survive a later PREPARE error");
    aborted=nc_db_query(db,95,"SELECT FROM",0,NULL);
    assert(aborted && PQresultStatus(aborted)==PGRES_PIPELINE_ABORTED);
    nc_result_free(aborted);
    aborted=nc_db_query(db,93,q_after,1,after_parameters);
    assert(aborted && PQresultStatus(aborted)==PGRES_PIPELINE_ABORTED);
    nc_result_free(aborted);
    nc_db_pipeline_end(db);
    passed("failed cold PREPARE drains execution and following commands");
    assert(nc_db_pipeline_begin(db));
    assert(nc_db_query(db,95,q_after,1,after_parameters)==NULL);
    assert(nc_db_pipeline_flush(db));
    nc_result *reprepared=nc_db_query(db,95,q_after,1,after_parameters);
    assert(reprepared && nc_db_ok(reprepared));
    assert(nc_value_length(reprepared,0,0)==strlen(after_parameters[0]));
    assert(!memcmp(nc_value(reprepared,0,0),after_parameters[0],strlen(after_parameters[0])));
    nc_result_free(reprepared);
    nc_db_pipeline_end(db);
    passed("failed PREPARE is not cached in the next session");

    /* The timeout changes only this disposable connection's session. Reconnect
     * must reapply normal session parameters before another batch can proceed. */
    assert(nc_tx(db,"SET statement_timeout='20ms'"));
    const char *sleep_parameters[]={"7"};
    assert(nc_db_pipeline_begin(db));
    assert(nc_db_query(db,94,q_sleep,1,sleep_parameters)==NULL);
    assert(nc_db_query(db,93,q_after,1,after_parameters)==NULL);
    assert(nc_db_pipeline_flush(db));
    error=nc_db_query(db,94,q_sleep,1,sleep_parameters);
    assert(error && PQresultStatus(error)==PGRES_FATAL_ERROR);
    assert(strcmp(PQresultErrorField(error,PG_DIAG_SQLSTATE),"57014")==0);
    nc_result_free(error);
    aborted=nc_db_query(db,93,q_after,1,after_parameters);
    assert(aborted && PQresultStatus(aborted)==PGRES_PIPELINE_ABORTED);
    nc_result_free(aborted);
    nc_db_pipeline_end(db);
    passed("statement timeout drains through Sync and marks later work aborted");
    assert(nc_db_pipeline_begin(db));
    assert(nc_db_query(db,94,q_sleep,1,sleep_parameters)==NULL);
    assert(nc_db_pipeline_flush(db));
    nc_result *slept=nc_db_query(db,94,q_sleep,1,sleep_parameters);
    assert(slept && nc_db_ok(slept) && nc_integer(slept,0,1)==7);
    nc_result_free(slept);
    nc_db_pipeline_end(db);
    passed("timeout recovery reapplies normal session settings");

    assert(nc_db_pipeline_begin(db));
    /* ID40 is an application write ID. SELECT makes this negative test safe
     * even if a future buggy implementation accidentally sends the command. */
    assert(nc_db_query(db,40,"SELECT 1",0,NULL)==NULL);
    assert(!nc_db_pipeline_flush(db));
    nc_db_pipeline_end(db);
    pair_batch(db,"write IDs are rejected without poisoning following batches");

    assert(nc_db_pipeline_begin(db));
    assert(nc_db_query(db,90,q_pair,2,parameters)==NULL);
    assert(nc_db_query(db,90,q_pair,2,parameters)==NULL);
    assert(!nc_db_pipeline_flush(db));
    nc_db_pipeline_end(db);
    pair_batch(db,"duplicate staged IDs fail safely and preserve recovery");

    assert(nc_db_pipeline_begin(db));
    assert(nc_db_query(db,90,q_pair,2,parameters)==NULL);
    nc_db_pipeline_end(db);
    pair_batch(db,"abandoned staging is reset before new work");

    assert(nc_db_pipeline_begin(db));
    assert(nc_db_query(db,97,"SELECT pg_terminate_backend(pg_backend_pid())",0,NULL)==NULL);
    assert(!nc_db_pipeline_flush(db));
    nc_db_pipeline_end(db);
    passed("backend disconnect fails the batch without replay");
    pair_batch(db,"next batch reconnects after a real backend disconnect");

    nc_db_close(db);
    printf("PASS: %u native read-pipeline checks\n",checks);
    return 0;
}
