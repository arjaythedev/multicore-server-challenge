/* Independent C batching/validation/rendering, using the same SQL DATA and
 * batch boundaries as batch.nelua. Nothing survives into a later batch. */
#include "app_c.h"
#include "sql_shared.h"

static void fail_group(nc_request **requests,int count,nc_db *db)
{
    int status=nc_db_result_exhausted(db)?503:500;
    for (int i=0;i<count;++i) if (nc_status(requests[i])==503) { status=503;break; }
    for (int i=0;i<count;++i) nc_error(requests[i],status);
}

static void tags(nc_request **requests,int count,nc_db *db)
{
    nc_result *result=nc_db_query(db,90,nc_sql[90],0,NULL);
    if (nc_db_pipeline_staging(db)) return;
    if (!nc_db_ok(result)) { fail_group(requests,count,db); nc_result_free(result); return; }
    nc_buffer *b=nc_begin(requests[0],200);
    W(b,"{\"tags\":[");
    for (int row=0;row<nc_rows(result);++row) {
        if (row) nc_putc(b,',');
        s_text(b,result,row,0);
    }
    W(b,"]}");
    size_t length=0;
    const char *data=nc_response_data(requests[0],&length);
    int status=nc_status(requests[0]);
    for (int i=1;i<count;++i) nc_write_n(nc_begin(requests[i],status),data,length);
    nc_result_free(result);
}
static void lookup(nc_request **requests,const char **keys,int64_t *viewers,int count,nc_db *db,int kind,bool submit)
{
    const char *params[2]={NULL,NULL};
    if (submit) {
        params[0]=nc_text_vector(requests[0],keys,count);
        params[1]=nc_int_vector(requests[0],viewers,count);
        if (!params[0] || !params[1]) { fail_group(requests,count,db); return; }
    }
    int id=kind==2?91:92,ordinal=kind==2?4:13;
    nc_result *result=nc_db_query(db,id,nc_sql[id],2,params);
    if (nc_db_pipeline_staging(db)) return;
    if (!nc_db_ok(result)) { fail_group(requests,count,db); nc_result_free(result); return; }
    for (int row=0;row<count;++row) {
        if (row>=nc_rows(result) || nc_integer(result,row,ordinal)!=(int64_t)row+1)
            nc_error(requests[row],500);
        else if (nc_null(result,row,0)) nc_error(requests[row],404);
        else {
            nc_buffer *b=nc_begin(requests[row],200);
            if (kind==2) { W(b,"{\"profile\":"); s_profile(b,result,row,0); }
            else { W(b,"{\"article\":"); s_article(b,result,row,true); }
            nc_putc(b,'}');
        }
    }
    nc_result_free(result);
}
static void comments(nc_request **requests,const char **keys,int64_t *viewers,int count,nc_db *db,bool submit)
{
    const char *params[2]={NULL,NULL};
    if (submit) {
        params[0]=nc_text_vector(requests[0],keys,count);
        params[1]=nc_int_vector(requests[0],viewers,count);
        if (!params[0] || !params[1]) { fail_group(requests,count,db); return; }
    }
    nc_result *result=nc_db_query(db,93,nc_sql[93],2,params);
    if (nc_db_pipeline_staging(db)) return;
    if (!nc_db_ok(result)) { fail_group(requests,count,db); nc_result_free(result); return; }
    int row=0;
    for (int request=0;request<count;++request) {
        if (row>=nc_rows(result) || nc_integer(result,row,8)!=(int64_t)request+1)
            nc_error(requests[request],500);
        else if (nc_null(result,row,9)) { nc_error(requests[request],404); ++row; }
        else {
            nc_buffer *b=nc_begin(requests[request],200);
            W(b,"{\"comments\":[");
            bool first=true;
            while (row<nc_rows(result) && nc_integer(result,row,8)==(int64_t)request+1) {
                if (!nc_null(result,row,0)) {
                    if (!first) nc_putc(b,',');
                    first=false; s_comment(b,result,row);
                }
                ++row;
            }
            W(b,"]}");
        }
    }
    nc_result_free(result);
}
static void pages(nc_request **requests,const char **keys,int64_t *viewers,int64_t *limits,
                  int64_t *offsets,int count,nc_db *db,int kind,bool shared,bool submit)
{
    const char *params[4]={NULL,NULL,NULL,NULL};
    if (submit) {
        params[0]=nc_text_vector(requests[0],keys,count);
        params[1]=nc_int_vector(requests[0],viewers,count);
        params[2]=nc_int_vector(requests[0],limits,count);
        params[3]=nc_int_vector(requests[0],offsets,count);
        if (!params[0] || !params[1] || !params[2] || !params[3]) { fail_group(requests,count,db); return; }
    }
    int id=89+kind;
    nc_result *result=nc_db_query(db,id,nc_sql[id],4,params);
    if (nc_db_pipeline_staging(db)) return;
    if (!nc_db_ok(result)) { fail_group(requests,count,db); nc_result_free(result); return; }
    c_fragments fragments[256]={0};
    int row=0;
    for (int request=0;request<count;++request) {
        if (row>=nc_rows(result) || nc_integer(result,row,13)!=(int64_t)request+1)
            nc_error(requests[request],500);
        else {
            int64_t total=nc_integer(result,row,12);
            nc_buffer *b=nc_begin(requests[request],200);
            W(b,"{\"articles\":[");
            bool first=true;
            while (row<nc_rows(result) && nc_integer(result,row,13)==(int64_t)request+1) {
                if (!nc_null(result,row,0)) {
                    if (!first) nc_putc(b,',');
                    first=false;
                    if (shared && count>1) s_article_shared(b,requests[request],result,row,fragments);
                    else s_article(b,result,row,false);
                }
                ++row;
            }
            W(b,"],\"articlesCount\":"); nc_json_int64(b,total); nc_putc(b,'}');
        }
    }
    nc_result_free(result);
}

void conduit_batch(nc_request **requests,int count,nc_db *db)
{
    if (count<1) return;
    if (count>128) { for (int i=0;i<count;++i) conduit_handle(requests[i],db); return; }
    int kinds[128],representatives[128];
    int64_t verified[128],validated_limits[128],validated_offsets[128];
    const char *filter_keys[128],*keys[128];
    nc_request *grouped[128];
    int64_t viewers[128],limits[128],offsets[128];
    bool coalesce=nc_db_read_coalesce(db),has_group=false;
    for (int i=0;i<count;++i) {
        nc_request *req=requests[i];
        int kind=0,segments=nc_segments(req);
        filter_keys[i]=""; validated_limits[i]=20; validated_offsets[i]=0;
        if (nc_eq(nc_method(req),"GET") && nc_eq(nc_segment(req,0),"api")) {
            if (segments==2 && nc_eq(nc_segment(req,1),"tags")) kind=1;
            else if (segments==3 && nc_eq(nc_segment(req,1),"profiles")) kind=2;
            else if (nc_eq(nc_segment(req,1),"articles")) {
                if (segments==2) {
                    kind=5;
                    const char *tag=nc_query(req,"tag"),*author=nc_query(req,"author"),*favorite=nc_query(req,"favorited");
                    if (tag && nc_length(tag)) { kind=6; filter_keys[i]=tag; }
                    else if (author && nc_length(author)) { kind=7; filter_keys[i]=author; }
                    else if (favorite && nc_length(favorite)) { kind=8; filter_keys[i]=favorite; }
                } else if (segments==3) kind=nc_eq(nc_segment(req,2),"feed")?9:3;
                else if (segments==4 && nc_eq(nc_segment(req,3),"comments")) kind=4;
            }
        }
        verified[i]=0;
        if (kind>1) {
            verified[i]=nc_auth(req);
            if (verified[i]<0 || (kind==9 && !verified[i])) { nc_error(req,401); kind=-1; }
        }
        if (kind>=5) {
            const char *raw_limit=nc_query(req,"limit"),*raw_offset=nc_query(req,"offset");
            if (raw_limit) validated_limits[i]=nc_parse_uint(raw_limit);
            if (raw_offset) validated_offsets[i]=nc_parse_uint(raw_offset);
            if (validated_limits[i]<1 || validated_limits[i]>100 || validated_offsets[i]<0) {
                nc_error(req,422); kind=-1;
            }
        }
        kinds[i]=kind;
        if (kind>0) has_group=true;
    }
    bool pipeline=has_group && nc_db_pipeline_begin(db);
    int passes=pipeline?2:1;
    for (int phase=1;phase<=passes;++phase) {
        for (int kind=1;kind<=9;++kind) {
            int used=0;
            for (int i=0;i<count;++i) if (kinds[i]==kind) {
                const char *key=kind>=5?filter_keys[i]:kind>=2?nc_segment(requests[i],2):"";
                int representative=used;
                if (coalesce) for (int j=0;j<used;++j) {
                    if (viewers[j]==verified[i] && limits[j]==validated_limits[i] &&
                        offsets[j]==validated_offsets[i] && nc_eq(keys[j],key)) { representative=j; break; }
                }
                representatives[i]=representative;
                if (representative==used) {
                    grouped[used]=requests[i]; viewers[used]=verified[i];
                    limits[used]=validated_limits[i]; offsets[used]=validated_offsets[i]; keys[used]=key;
                    ++used;
                }
            }
            if (!used) continue;
            if (kind==1) tags(grouped,used,db);
            else if (kind==4) comments(grouped,keys,viewers,used,db,phase==1);
            else if (kind>=5) pages(grouped,keys,viewers,limits,offsets,used,db,kind,coalesce,phase==1);
            else lookup(grouped,keys,viewers,used,db,kind,phase==1);
            if (!nc_db_pipeline_staging(db)) for (int i=0;i<count;++i) if (kinds[i]==kind) {
                nc_request *representative=grouped[representatives[i]];
                if (requests[i]!=representative) {
                    size_t length=0;
                    const char *data=nc_response_data(representative,&length);
                    nc_write_n(nc_begin(requests[i],nc_status(representative)),data,length);
                }
            }
        }
        if (pipeline && phase==1 && !nc_db_pipeline_flush(db)) {
            for (int i=0;i<count;++i) if (kinds[i]>0) nc_error(requests[i],nc_db_result_exhausted(db)?503:500);
            break;
        }
    }
    if (pipeline) nc_db_pipeline_end(db);
    for (int i=0;i<count;++i) if (!kinds[i]) conduit_handle(requests[i],db);
}
