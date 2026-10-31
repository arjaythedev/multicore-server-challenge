/* Native libpq bridge: business queries and rendering live in Nelua. */
#include "native.h"
#include <libpq-fe.h>
#include <arpa/inet.h>
#include <endian.h>
#include <inttypes.h>
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { NC_PIPELINE_OFF, NC_PIPELINE_STAGING, NC_PIPELINE_RESULTS };
struct nc_pipeline_op { int id; bool prepare; };
struct nc_db {
    PGconn *connection;
    bool prepared[128];
    bool pipeline_enabled, reset_needed, pipeline_failed;
    int pipeline_state, pipeline_count;
    struct nc_pipeline_op pipeline_ops[18];
    bool pipeline_queued[9];
    PGresult *pipeline_results[9];
};

static bool nc_db_session(nc_db *db)
{
    PGresult *r = PQexec(db->connection,
        "SET jit=off; SET max_parallel_workers_per_gather=0; "
        "SET statement_timeout='10s'; SET TimeZone='UTC'; "
        "SET plan_cache_mode=force_generic_plan; SET enable_memoize=off");
    bool good = r && PQresultStatus(r)==PGRES_COMMAND_OK;
    PQclear(r);
    return good;
}

/* A failed read pipeline is never replayed. Reconnect before the next operation
 * because a failed implicit transaction can also roll back prepared statements. */
static bool nc_db_ready(nc_db *db)
{
    if (!db || db->pipeline_state!=NC_PIPELINE_OFF) return false;
    if (!db->reset_needed) return true;
    PQreset(db->connection);
    memset(db->prepared,0,sizeof(db->prepared));
    if (PQstatus(db->connection)!=CONNECTION_OK ||
        PQsetnonblocking(db->connection,0)!=0 || !nc_db_session(db)) return false;
    db->reset_needed=false;
    return true;
}

static void nc_db_log_error(int id,PGresult *r)
{
    if (r && PQresultStatus(r)==PGRES_FATAL_ERROR) {
        const char *state=PQresultErrorField(r,PG_DIAG_SQLSTATE);
        /* SQLSTATE only: never log input, tokens, passwords or SQL parameters. */
        if (!state || strcmp(state,"23505"))
            fprintf(stderr,"query %d failed (SQLSTATE %s)\n",id,state?state:"unknown");
    }
}

nc_db *nc_db_open(const char *url)
{
    nc_db *db = calloc(1,sizeof(*db));
    if (!db) return NULL;
    const char *pipeline=getenv("READ_PIPELINE");
    if (pipeline && *pipeline && strcmp(pipeline,"0") && strcmp(pipeline,"1")) {
        fprintf(stderr,"READ_PIPELINE must be 0 or 1\n");
        free(db); return NULL;
    }
    db->pipeline_enabled=!pipeline || !*pipeline || !strcmp(pipeline,"1");
    /* Avoid TLS CPU on loopback, preserving an explicit URL TLS policy. */
    char *parse_error=NULL;
    PQconninfoOption *options=PQconninfoParse(url,&parse_error);
    bool local=false, explicit_tls=false;
    if (!options) { PQfreemem(parse_error); free(db); return NULL; }
    for (PQconninfoOption *p=options;p->keyword;++p) {
        if (!strcmp(p->keyword,"host") && p->val)
            local=!strcmp(p->val,"127.0.0.1") || !strcmp(p->val,"::1") ||
                  !strcmp(p->val,"localhost") || p->val[0]=='/';
        if (!strcmp(p->keyword,"sslmode") && p->val) explicit_tls=true;
    }
    PQconninfoFree(options);
    const char *keys[] = {"dbname","application_name","connect_timeout","sslmode",NULL};
    const char *values[] = {url,"nelua-conduit","5",local&&!explicit_tls?"disable":NULL,NULL};
    db->connection = PQconnectdbParams(keys,values,1);
    if (PQstatus(db->connection) != CONNECTION_OK) {
        fprintf(stderr,"database connection failed\n");
        nc_db_close(db); return NULL;
    }
    if (!nc_db_session(db)) { nc_db_close(db); return NULL; }
    return db;
}
void nc_db_close(nc_db *db)
{
    if (db) {
        for (int i=0;i<9;++i) PQclear(db->pipeline_results[i]);
        if (db->connection) PQfinish(db->connection);
        free(db);
    }
}
nc_result *nc_db_query(nc_db *db,int id,const char *sql,int count,const char *const *parameters)
{
    if (!db || id<0 || id>=128 || count<0 || count>16) return NULL;
    if (db->pipeline_state==NC_PIPELINE_RESULTS) {
        if (id<90 || id>98) return NULL;
        PGresult *r=db->pipeline_results[id-90];
        db->pipeline_results[id-90]=NULL;
        return r;
    }
    char name[16];
    snprintf(name,sizeof(name),"n%d",id);
    if (db->pipeline_state==NC_PIPELINE_STAGING) {
        /* Only the nine batch read families can enter this path. In particular,
         * writes keep the synchronous transaction/commit response contract. */
        if (id<90 || id>98 || db->pipeline_queued[id-90] || !sql) {
            db->pipeline_failed=true; return NULL;
        }
        db->pipeline_queued[id-90]=true;
        if (db->pipeline_failed) return NULL;
        if (!db->prepared[id]) {
            if (!PQsendPrepare(db->connection,name,sql,count,NULL)) {
                db->pipeline_failed=true; return NULL;
            }
            db->pipeline_ops[db->pipeline_count++]=(struct nc_pipeline_op){id,true};
        }
        if (!PQsendQueryPrepared(db->connection,name,count,parameters,NULL,NULL,1)) {
            db->pipeline_failed=true; return NULL;
        }
        db->pipeline_ops[db->pipeline_count++]=(struct nc_pipeline_op){id,false};
        return NULL;
    }
    if (!nc_db_ready(db)) return NULL;
    if (!db->prepared[id]) {
        PGresult *r = PQprepare(db->connection,name,sql,count,NULL);
        if (!r || PQresultStatus(r)!=PGRES_COMMAND_OK) return r;
        PQclear(r); db->prepared[id]=true;
    }
    PGresult *r = PQexecPrepared(db->connection,name,count,parameters,NULL,NULL,1);
    nc_db_log_error(id,r);
    return r;
}

bool nc_db_pipeline_begin(nc_db *db)
{
    if (!db || !db->pipeline_enabled || !nc_db_ready(db)) return false;
    if (PQsetnonblocking(db->connection,1)!=0) return false;
    if (!PQenterPipelineMode(db->connection)) {
        if (PQsetnonblocking(db->connection,0)!=0) db->reset_needed=true;
        return false;
    }
    db->pipeline_failed=false;
    db->pipeline_count=0;
    memset(db->pipeline_queued,0,sizeof(db->pipeline_queued));
    db->pipeline_state=NC_PIPELINE_STAGING;
    return true;
}

bool nc_db_pipeline_staging(nc_db *db)
{ return db && db->pipeline_state==NC_PIPELINE_STAGING; }

static int64_t nc_db_milliseconds(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC,&ts)!=0) return -1;
    return (int64_t)ts.tv_sec*1000+ts.tv_nsec/1000000;
}

bool nc_db_pipeline_flush(nc_db *db)
{
    if (!db || db->pipeline_state!=NC_PIPELINE_STAGING) return false;
    db->pipeline_state=NC_PIPELINE_RESULTS;
    if (!PQpipelineSync(db->connection)) goto failed;
    int next=0;
    bool synced=false;
    int64_t now=nc_db_milliseconds();
    if (now<0) goto failed;
    /* Bound the complete read batch, including a broken socket's wait. */
    const int64_t deadline=now+10000;
    while (!synced) {
        int pending=PQflush(db->connection);
        if (pending<0 || !PQconsumeInput(db->connection)) goto failed;
        while (!PQisBusy(db->connection)) {
            now=nc_db_milliseconds();
            if (PQstatus(db->connection)!=CONNECTION_OK || now<0 || now>=deadline)
                goto failed;
            PGresult *r=PQgetResult(db->connection);
            /* Each command has a NULL boundary; it is not the pipeline end. */
            if (!r) continue;
            ExecStatusType status=PQresultStatus(r);
            if (status==PGRES_PIPELINE_SYNC) {
                PQclear(r);
                if (next!=db->pipeline_count) goto failed;
                synced=true; break;
            }
            if (next>=db->pipeline_count ||
                (status!=PGRES_COMMAND_OK && status!=PGRES_TUPLES_OK &&
                 status!=PGRES_FATAL_ERROR && status!=PGRES_PIPELINE_ABORTED)) {
                PQclear(r); goto failed;
            }
            struct nc_pipeline_op op=db->pipeline_ops[next++];
            if (status==PGRES_FATAL_ERROR || status==PGRES_PIPELINE_ABORTED) {
                nc_db_log_error(op.id,r);
                db->reset_needed=true;
            }
            if (op.prepare) {
                if (status==PGRES_COMMAND_OK) db->prepared[op.id]=true;
                else db->reset_needed=true;
                PQclear(r);
            } else {
                db->pipeline_results[op.id-90]=r;
            }
        }
        if (synced) break;
        now=nc_db_milliseconds();
        int64_t remaining=deadline-now;
        if (now<0 || remaining<=0) goto failed;
        struct pollfd socket={PQsocket(db->connection),POLLIN|(pending?POLLOUT:0),0};
        int ready=poll(&socket,1,(int)remaining);
        if (ready<0 && errno==EINTR) continue;
        if (ready<=0 || (socket.revents&(POLLERR|POLLNVAL)) ||
            ((socket.revents&POLLHUP) && !(socket.revents&POLLIN))) goto failed;
    }
    if (!PQexitPipelineMode(db->connection) || PQsetnonblocking(db->connection,0)!=0)
        goto failed;
    return !db->pipeline_failed;
failed:
    db->reset_needed=true;
    return false;
}

void nc_db_pipeline_end(nc_db *db)
{
    if (!db) return;
    if (db->pipeline_state==NC_PIPELINE_STAGING) db->reset_needed=true;
    for (int i=0;i<9;++i) {
        PQclear(db->pipeline_results[i]);
        db->pipeline_results[i]=NULL;
    }
    db->pipeline_state=NC_PIPELINE_OFF;
}

bool nc_tx(nc_db *db,const char *command)
{
    if (!nc_db_ready(db)) return false;
    PGresult *r=PQexec(db->connection,command);
    bool good=nc_db_ok(r); PQclear(r); return good;
}
bool nc_db_ok(nc_result *r)
{
    return r && (PQresultStatus(r)==PGRES_TUPLES_OK || PQresultStatus(r)==PGRES_COMMAND_OK);
}
bool nc_db_unique(nc_result *r)
{
    const char *s=r?PQresultErrorField(r,PG_DIAG_SQLSTATE):NULL;
    return s && strcmp(s,"23505")==0;
}
void nc_result_free(nc_result *r) { PQclear(r); }
int nc_rows(nc_result *r) { return r?PQntuples(r):0; }
bool nc_null(nc_result *r,int row,int col) { return !r || PQgetisnull(r,row,col); }
const char *nc_value(nc_result *r,int row,int col)
{ return nc_null(r,row,col)?NULL:PQgetvalue(r,row,col); }
size_t nc_value_length(nc_result *r,int row,int col)
{ return nc_null(r,row,col)?0:(size_t)PQgetlength(r,row,col); }
int64_t nc_integer(nc_result *r,int row,int col)
{
    if (nc_null(r,row,col)) return 0;
    const void *p=PQgetvalue(r,row,col);
    if (PQgetlength(r,row,col)==8) { uint64_t x; memcpy(&x,p,8); return (int64_t)be64toh(x); }
    if (PQgetlength(r,row,col)==4) { uint32_t x; memcpy(&x,p,4); return (int32_t)ntohl(x); }
    if (PQgetlength(r,row,col)==2) { uint16_t x; memcpy(&x,p,2); return (int16_t)ntohs(x); }
    return 0;
}
bool nc_boolean(nc_result *r,int row,int col)
{ return !nc_null(r,row,col) && PQgetvalue(r,row,col)[0]!=0; }
void nc_timestamp(nc_buffer *b,nc_result *r,int row,int col)
{
    int64_t usec=nc_integer(r,row,col);
    int64_t seconds=usec/1000000, fraction=usec%1000000;
    if (fraction<0) { fraction+=1000000; --seconds; }
    time_t epoch=(time_t)(seconds+946684800LL);
    struct tm tm; char out[40];
    if (!gmtime_r(&epoch,&tm) || tm.tm_year< -1899 || tm.tm_year>8099) {
        nc_write(b,"null"); return;
    }
    int length=snprintf(out,sizeof(out),"\"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ\"",
        tm.tm_year+1900,tm.tm_mon+1,tm.tm_mday,tm.tm_hour,tm.tm_min,tm.tm_sec,(int)(fraction/1000));
    nc_write_n(b,out,(size_t)length);
}
static uint32_t get32(const unsigned char *p)
{ uint32_t v; memcpy(&v,p,4); return ntohl(v); }
void nc_text_array(nc_buffer *b,nc_result *r,int row,int col)
{
    nc_putc(b,'[');
    if (!nc_null(r,row,col)) {
        const unsigned char *p=(const unsigned char*)PQgetvalue(r,row,col);
        size_t length=(size_t)PQgetlength(r,row,col), pos=12;
        if (length>=12) {
            uint32_t dimensions=get32(p);
            if (dimensions==1 && length>=20) {
                uint32_t count=get32(p+12); pos=20;
                for (uint32_t i=0;i<count && pos+4<=length;++i) {
                    int32_t n=(int32_t)get32(p+pos); pos+=4;
                    if (i) nc_putc(b,',');
                    if (n<0) nc_write(b,"null");
                    else if ((size_t)n<=length-pos) {
                        nc_json_string(b,(unsigned char*)(p+pos),(size_t)n); pos+=(size_t)n;
                    } else break;
                }
            }
        }
    }
    nc_putc(b,']');
}
