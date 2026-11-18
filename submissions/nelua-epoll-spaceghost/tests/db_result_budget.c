#define _POSIX_C_SOURCE 200809L
#include "native.h"
#include <libpq-fe.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char rows[]="SELECT i::bigint, repeat($1::text,65536), NULL::text FROM generate_series(1,$2::int) i";
static nc_result *query(nc_db *db,int id,const char *count)
{
    const char *params[]={"x",count};
    return nc_db_query(db,id,rows,2,params);
}
int main(int argc,char **argv)
{
    assert(argc==2);
    assert(setenv("DB_RESULT_MEMORY_MB","1",1)==0);
    assert(setenv("READ_PIPELINE","0",1)==0);
    nc_db *db=nc_db_open(argv[1]);assert(db);
    assert(!query(db,90,"200") && nc_db_result_exhausted(db));
    assert(nc_db_result_memory_used()==0);
    nc_result *held=query(db,90,"6");
    assert(nc_db_ok(held) && nc_rows(held)==6 && nc_integer(held,5,0)==6);
    assert(nc_value_length(held,0,1)==65536 && nc_null(held,0,2));
    size_t live=nc_db_result_memory_used();
    assert(live>0 && live<=nc_db_result_memory_limit());
    nc_db *other=nc_db_open(argv[1]);assert(other);
    assert(!query(other,90,"1") && nc_db_result_exhausted(other));
    assert(nc_db_result_memory_used()==live);
    nc_db_close(db); /* Result credits/lifetime are independent of PGconn. */
    assert(nc_integer(held,0,0)==1 && nc_value(held,0,1)[65535]=='x');
    nc_result_free(held);
    assert(nc_db_result_memory_used()==0);
    held=query(other,90,"1");assert(nc_db_ok(held));nc_result_free(held);
    nc_db_close(other);
    assert(nc_db_result_memory_used()==0);

    assert(setenv("READ_PIPELINE","1",1)==0);
    db=nc_db_open(argv[1]);assert(db && nc_db_pipeline_begin(db));
    assert(!query(db,90,"2") && !query(db,91,"200"));
    assert(!nc_db_pipeline_flush(db) && nc_db_result_exhausted(db));
    assert(nc_db_result_memory_used()==0);
    nc_db_pipeline_end(db);
    assert(nc_db_pipeline_begin(db));
    assert(!query(db,90,"1"));
    assert(nc_db_pipeline_flush(db));
    held=nc_db_query(db,90,NULL,0,NULL);
    assert(nc_db_ok(held) && nc_integer(held,0,0)==1);
    nc_result_free(held);nc_db_pipeline_end(db);
    assert(nc_db_result_memory_used()==0);

    assert(nc_db_pipeline_begin(db));
    assert(!nc_db_query(db,92,"SELECT 10/(4-i)::bigint FROM generate_series(1,8) i",0,NULL));
    assert(nc_db_pipeline_flush(db));
    held=nc_db_query(db,92,NULL,0,NULL);
    assert(held && PQresultStatus(held)==PGRES_FATAL_ERROR);
    assert(!strcmp(PQresultErrorField(held,PG_DIAG_SQLSTATE),"22012"));
    assert(nc_rows(held)==0 && nc_db_result_memory_used()==0);
    nc_result_free(held);nc_db_pipeline_end(db);nc_db_close(db);
    assert(nc_db_result_memory_used()==0);
    puts("PASS: streamed oversized results rejected before accumulation; shared 1 MiB cap, cross-connection pressure, binary/null preservation, PGconn-independent lifetime, pipeline cleanup/recovery and SQL errors after partial rows");
}
