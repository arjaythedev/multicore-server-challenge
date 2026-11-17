/* Independently authored C version of all 19 application operations.
 * The shared header contains SQL DATA, not generated Nelua application code. */
#include "app_c.h"
#include "sql_shared.h"

static bool check(nc_request *r,nc_result *result)
{
    if (nc_db_ok(result)) return true;
    nc_error(r,nc_db_unique(result)?422:500);
    nc_result_free(result);
    return false;
}
static const char *required(nc_json *object,const char *key)
{
    nc_json *field=nc_field(object,key);
    if (nc_kind(field)!=3) return NULL;
    const char *value=nc_string(field);
    return value && nc_length(value)>0?value:NULL;
}
static bool optional(nc_json *object,const char *key,bool nonempty,const char **out)
{
    nc_json *field=nc_field(object,key);
    *out=NULL;
    int kind=nc_kind(field);
    if (!kind) return true;
    if (kind!=3) return false;
    *out=nc_string(field);
    return *out && (!nonempty || nc_length(*out)>0);
}
static nc_result *query(nc_db *db,int id,int count,const char *const *values)
{ return nc_db_query(db,id,nc_sql[id],count,values); }

static void tags(nc_request *r,nc_db *db)
{
    nc_result *result=query(db,0,0,NULL);
    if (!check(r,result)) return;
    nc_buffer *b=nc_begin(r,200);
    W(b,"{\"tags\":[");
    for (int row=0;row<nc_rows(result);++row) {
        if (row) nc_putc(b,',');
        s_text(b,result,row,0);
    }
    W(b,"]}"); nc_result_free(result);
}
static void profile(nc_request *r,nc_db *db,int64_t viewer,const char *username)
{
    const char *params[]={nc_decimal(r,viewer),username};
    nc_result *result=query(db,1,2,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,404); return; }
    nc_buffer *b=nc_begin(r,200);
    W(b,"{\"profile\":"); s_profile(b,result,0,0); nc_putc(b,'}');
    nc_result_free(result);
}
static void article(nc_request *r,nc_db *db,int64_t viewer,const char *key,bool byid,int status)
{
    const char *params[]={nc_decimal(r,viewer),key};
    nc_result *result=query(db,byid?3:2,2,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,404); return; }
    nc_buffer *b=nc_begin(r,status);
    W(b,"{\"article\":"); s_article(b,result,0,true); nc_putc(b,'}');
    nc_result_free(result);
}
static void list(nc_request *r,nc_db *db,int64_t viewer,bool feed)
{
    const char *raw_limit=nc_query(r,"limit"),*raw_offset=nc_query(r,"offset");
    int64_t limit=raw_limit?nc_parse_uint(raw_limit):20;
    int64_t offset=raw_offset?nc_parse_uint(raw_offset):0;
    if (limit<1 || limit>100 || offset<0) { nc_error(r,422); return; }
    int id=feed?8:4,count=3;
    const char *filter=NULL;
    if (!feed) {
        const char *tag=nc_query(r,"tag"),*author=nc_query(r,"author"),*favorite=nc_query(r,"favorited");
        if (tag && nc_length(tag)) { id=5; filter=tag; }
        else if (author && nc_length(author)) { id=6; filter=author; }
        else if (favorite && nc_length(favorite)) { id=7; filter=favorite; }
        if (filter) count=4;
    }
    const char *params[]={nc_decimal(r,viewer),nc_decimal(r,limit),nc_decimal(r,offset),filter};
    nc_result *result=query(db,id,count,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,500); return; }
    nc_buffer *b=nc_begin(r,200);
    W(b,"{\"articles\":[");
    bool first=true;
    for (int row=0;row<nc_rows(result);++row) if (!nc_null(result,row,0)) {
        if (!first) nc_putc(b,',');
        first=false;
        s_article(b,result,row,false);
    }
    W(b,"],\"articlesCount\":"); nc_json_int64(b,nc_integer(result,0,12)); nc_putc(b,'}');
    nc_result_free(result);
}
static void comments(nc_request *r,nc_db *db,int64_t viewer,const char *slug)
{
    const char *params[]={nc_decimal(r,viewer),slug};
    nc_result *result=query(db,9,2,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,404); return; }
    nc_buffer *b=nc_begin(r,200);
    W(b,"{\"comments\":[");
    bool first=true;
    for (int row=0;row<nc_rows(result);++row) if (!nc_null(result,row,0)) {
        if (!first) nc_putc(b,',');
        first=false;
        s_comment(b,result,row);
    }
    W(b,"]}"); nc_result_free(result);
}

static void user_response(nc_request *r,nc_result *result,int status,const char *token)
{
    if (!token) { nc_result_free(result); nc_error(r,500); return; }
    nc_buffer *b=nc_begin(r,status);
    W(b,"{\"user\":"); s_user(b,result,0,token); nc_putc(b,'}');
    nc_result_free(result);
}
static void register_user(nc_request *r,nc_db *db)
{
    nc_json *object=nc_body(r,"user");
    if (!object) { nc_error(r,422); return; }
    const char *username=required(object,"username"),*email=required(object,"email"),*password=required(object,"password");
    if (!username || !email || !password) { nc_error(r,422); return; }
    const char *hash=nc_hash(r,password);
    if (!hash) { nc_error(r,422); return; }
    const char *params[]={username,email,hash};
    nc_result *result=query(db,40,3,params);
    if (!check(r,result)) return;
    user_response(r,result,201,nc_issue_token(r,nc_integer(result,0,0)));
}
static void login(nc_request *r,nc_db *db)
{
    nc_json *object=nc_body(r,"user");
    if (!object) { nc_error(r,422); return; }
    const char *email=required(object,"email"),*password=required(object,"password");
    if (!email || !password) { nc_error(r,422); return; }
    const char *params[]={email};
    nc_result *result=query(db,41,1,params);
    if (!check(r,result)) return;
    if (!nc_rows(result) || !nc_verify(password,nc_value(result,0,5))) {
        nc_result_free(result); nc_error(r,401); return;
    }
    user_response(r,result,200,nc_issue_token(r,nc_integer(result,0,0)));
}
static void current(nc_request *r,nc_db *db,int64_t viewer)
{
    const char *params[]={nc_decimal(r,viewer)};
    nc_result *result=query(db,42,1,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,401); return; }
    user_response(r,result,200,nc_token(r));
}
static void update_user(nc_request *r,nc_db *db,int64_t viewer)
{
    nc_json *object=nc_body(r,"user");
    if (!object) { nc_error(r,422); return; }
    const char *email,*username,*password,*bio,*image;
    if (!optional(object,"email",true,&email) || !optional(object,"username",true,&username) ||
        !optional(object,"password",true,&password) || !optional(object,"bio",false,&bio) ||
        !optional(object,"image",false,&image)) { nc_error(r,422); return; }
    const char *hash=password?nc_hash(r,password):NULL;
    if (password && !hash) { nc_error(r,422); return; }
    const char *params[]={nc_decimal(r,viewer),email,username,hash,bio,image};
    nc_result *result=query(db,43,6,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,401); return; }
    user_response(r,result,200,nc_token(r));
}
static void follow(nc_request *r,nc_db *db,int64_t viewer,const char *username,bool active)
{
    const char *params[]={nc_decimal(r,viewer),username};
    nc_result *result=query(db,active?44:45,2,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,404); return; }
    nc_buffer *b=nc_begin(r,200);
    W(b,"{\"profile\":"); s_profile(b,result,0,0); nc_putc(b,'}');
    nc_result_free(result);
}
static void create_article(nc_request *r,nc_db *db,int64_t viewer)
{
    nc_json *object=nc_body(r,"article");
    if (!object) { nc_error(r,422); return; }
    const char *title=required(object,"title"),*description=required(object,"description"),*body=required(object,"body");
    if (!title || !description || !body) { nc_error(r,422); return; }
    nc_json *tag_list=nc_field(object,"tagList");
    int tag_count=0;
    const char *tag_value=NULL;
    if (nc_kind(tag_list)) {
        if (nc_kind(tag_list)!=2) { nc_error(r,422); return; }
        tag_count=nc_array_length(tag_list);
        for (int i=0;i<tag_count;++i) {
            nc_json *item=nc_array_item(tag_list,i);
            const char *value=nc_string(item);
            if (nc_kind(item)!=3 || !value || !nc_length(value)) { nc_error(r,422); return; }
        }
        if (tag_count) {
            tag_value=nc_tag_array(r,tag_list);
            if (!tag_value) { nc_error(r,500); return; }
        }
    }
    if (!nc_tx(db,"BEGIN")) { nc_error(r,500); return; }
    const char *params[]={nc_decimal(r,viewer),title,description,body};
    nc_result *result=query(db,46,4,params);
    if (!check(r,result)) { nc_tx(db,"ROLLBACK"); return; }
    const char *article_id=nc_decimal(r,nc_integer(result,0,0));
    nc_result_free(result);
    if (tag_count) {
        const char *tag_params[]={tag_value};
        result=query(db,47,1,tag_params);
        if (!check(r,result)) { nc_tx(db,"ROLLBACK"); return; }
        nc_result_free(result);
        const char *link_params[]={article_id,tag_value};
        result=query(db,48,2,link_params);
        if (!check(r,result)) { nc_tx(db,"ROLLBACK"); return; }
        nc_result_free(result);
    }
    if (!nc_tx(db,"COMMIT")) { nc_tx(db,"ROLLBACK"); nc_error(r,500); return; }
    article(r,db,viewer,article_id,true,201);
}
static void update_article(nc_request *r,nc_db *db,int64_t viewer,const char *slug)
{
    nc_json *object=nc_body(r,"article");
    if (!object) { nc_error(r,422); return; }
    const char *title,*description,*body;
    if (!optional(object,"title",true,&title) || !optional(object,"description",true,&description) ||
        !optional(object,"body",true,&body)) { nc_error(r,422); return; }
    const char *params[]={nc_decimal(r,viewer),slug,title,description,body};
    nc_result *result=query(db,49,5,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,404); return; }
    if (nc_integer(result,0,1)!=viewer) { nc_result_free(result); nc_error(r,403); return; }
    const char *article_id=nc_decimal(r,nc_integer(result,0,0));
    nc_result_free(result);
    article(r,db,viewer,article_id,true,200);
}
static void delete_article(nc_request *r,nc_db *db,int64_t viewer,const char *slug)
{
    const char *params[]={nc_decimal(r,viewer),slug};
    nc_result *result=query(db,50,2,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,404); return; }
    if (nc_integer(result,0,0)!=viewer) { nc_result_free(result); nc_error(r,403); return; }
    nc_result_free(result); nc_begin(r,204);
}
static void favorite(nc_request *r,nc_db *db,int64_t viewer,const char *slug,bool active)
{
    const char *params[]={nc_decimal(r,viewer),slug};
    nc_result *result=query(db,active?51:52,2,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,404); return; }
    const char *article_id=nc_decimal(r,nc_integer(result,0,0));
    nc_result_free(result);
    article(r,db,viewer,article_id,true,200);
}
static void create_comment(nc_request *r,nc_db *db,int64_t viewer,const char *slug)
{
    nc_json *object=nc_body(r,"comment");
    if (!object) { nc_error(r,422); return; }
    const char *body=required(object,"body");
    if (!body) { nc_error(r,422); return; }
    const char *params[]={nc_decimal(r,viewer),slug,body};
    nc_result *result=query(db,53,3,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,404); return; }
    nc_buffer *b=nc_begin(r,201);
    W(b,"{\"comment\":"); s_comment(b,result,0); nc_putc(b,'}');
    nc_result_free(result);
}
static void delete_comment(nc_request *r,nc_db *db,int64_t viewer,const char *slug,const char *id_string)
{
    int64_t id=nc_parse_uint(id_string);
    if (id<0) { nc_error(r,404); return; }
    const char *params[]={nc_decimal(r,viewer),slug,nc_decimal(r,id)};
    nc_result *result=query(db,54,3,params);
    if (!check(r,result)) return;
    if (!nc_rows(result)) { nc_result_free(result); nc_error(r,404); return; }
    if (nc_integer(result,0,0)!=viewer) { nc_result_free(result); nc_error(r,403); return; }
    nc_result_free(result); nc_begin(r,204);
}

static int route(nc_request *r)
{
    int count=nc_segments(r);
    if (count<2 || !nc_eq(nc_segment(r,0),"api")) return 0;
    const char *method=nc_method(r),*resource=nc_segment(r,1);
    if (nc_eq(resource,"users")) {
        if (nc_eq(method,"POST")) {
            if (count==2) return 1;
            if (count==3 && nc_eq(nc_segment(r,2),"login")) return 2;
        }
    } else if (nc_eq(resource,"user") && count==2) {
        if (nc_eq(method,"GET")) return 3;
        if (nc_eq(method,"PUT")) return 4;
    } else if (nc_eq(resource,"profiles")) {
        if (count==3 && nc_eq(method,"GET")) return 5;
        if (count==4 && nc_eq(nc_segment(r,3),"follow")) {
            if (nc_eq(method,"POST")) return 6;
            if (nc_eq(method,"DELETE")) return 7;
        }
    } else if (nc_eq(resource,"articles")) {
        if (count==2) {
            if (nc_eq(method,"GET")) return 8;
            if (nc_eq(method,"POST")) return 10;
        } else if (count==3) {
            if (nc_eq(method,"GET")) return nc_eq(nc_segment(r,2),"feed")?9:11;
            if (nc_eq(method,"PUT")) return 12;
            if (nc_eq(method,"DELETE")) return 13;
        } else if (count==4) {
            if (nc_eq(nc_segment(r,3),"favorite")) {
                if (nc_eq(method,"POST")) return 14;
                if (nc_eq(method,"DELETE")) return 15;
            } else if (nc_eq(nc_segment(r,3),"comments")) {
                if (nc_eq(method,"GET")) return 16;
                if (nc_eq(method,"POST")) return 17;
            }
        } else if (count==5 && nc_eq(nc_segment(r,3),"comments") && nc_eq(method,"DELETE")) return 18;
    } else if (count==2 && nc_eq(resource,"tags") && nc_eq(method,"GET")) return 19;
    return 0;
}
int conduit_lane(nc_request *r)
{
    int operation=route(r);
    if (operation==1 || operation==2) return 2;
    if (operation==4) {
        nc_json *password=nc_field(nc_body(r,"user"),"password");
        return nc_kind(password)==3 && nc_length(nc_string(password))>0?2:1;
    }
    return operation==6 || operation==7 || operation==10 || operation==12 || operation==13 ||
           operation==14 || operation==15 || operation==17 || operation==18?1:0;
}
void conduit_handle(nc_request *r,nc_db *db)
{
    int operation=route(r);
    if (!operation) { nc_error(r,404); return; }
    if (operation==1) { register_user(r,db); return; }
    if (operation==2) { login(r,db); return; }
    if (operation==19) { tags(r,db); return; }
    int64_t viewer=nc_auth(r);
    bool auth_optional=operation==5 || operation==8 || operation==11 || operation==16;
    if (viewer<0 || (!viewer && !auth_optional)) { nc_error(r,401); return; }
    const char *key=nc_segment(r,2);
    switch (operation) {
    case 3: current(r,db,viewer); break;
    case 4: update_user(r,db,viewer); break;
    case 5: profile(r,db,viewer,key); break;
    case 6: case 7: follow(r,db,viewer,key,operation==6); break;
    case 8: case 9: list(r,db,viewer,operation==9); break;
    case 10: create_article(r,db,viewer); break;
    case 11: article(r,db,viewer,key,false,200); break;
    case 12: update_article(r,db,viewer,key); break;
    case 13: delete_article(r,db,viewer,key); break;
    case 14: case 15: favorite(r,db,viewer,key,operation==14); break;
    case 16: comments(r,db,viewer,key); break;
    case 17: create_comment(r,db,viewer,key); break;
    case 18: delete_comment(r,db,viewer,key,nc_segment(r,4)); break;
    }
}
