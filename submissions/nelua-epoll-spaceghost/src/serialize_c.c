#include "app_c.h"
#include <string.h>

void nc_json_string(nc_buffer *b,unsigned char *data,size_t length)
{
    if (length>=128 && !nc_reserve_json(b,length)) return;
    nc_putc(b,'"');
    size_t first=0,i=0;
    bool accelerated=nc_json_scan_enabled();
    while (i<length) {
        if (accelerated) i+=nc_json_scan_prefix(data+i,length-i);
        else while (length-i>=8) {
            uint64_t word;
            __builtin_memcpy(&word,data+i,8);
            uint64_t quotes=word^UINT64_C(0x2222222222222222);
            uint64_t slashes=word^UINT64_C(0x5c5c5c5c5c5c5c5c);
            uint64_t controls=(word-UINT64_C(0x2020202020202020))&~word;
            uint64_t matches=((quotes-UINT64_C(0x0101010101010101))&~quotes)|
                             ((slashes-UINT64_C(0x0101010101010101))&~slashes)|controls;
            if (matches&UINT64_C(0x8080808080808080)) break;
            i+=8;
        }
        if (i==length) break;
        unsigned char value=data[i];
        if (value<32 || value=='"' || value=='\\') {
            if (i>first) nc_write_n(b,(const char *)data+first,i-first);
            if (value=='"' || value=='\\') {
                nc_putc(b,'\\'); nc_putc(b,(char)value);
            } else {
                static const char hex[]="0123456789abcdef";
                char escape[6]={'\\','u','0','0',hex[value>>4],hex[value&15]};
                nc_write_n(b,escape,6);
            }
            first=i+1;
        }
        ++i;
    }
    if (length>first) nc_write_n(b,(const char *)data+first,length-first);
    nc_putc(b,'"');
}

void nc_json_int64(nc_buffer *b,int64_t value)
{
    char digits[20];
    uint64_t magnitude;
    if (value<0) { nc_putc(b,'-'); magnitude=(uint64_t)(-(value+1))+1; }
    else magnitude=(uint64_t)value;
    size_t first=20;
    do { digits[--first]=(char)('0'+magnitude%10); magnitude/=10; } while (magnitude);
    nc_write_n(b,digits+first,20-first);
}

static void s_string(nc_buffer *b,const char *value)
{
    if (!value) W(b,"null");
    else nc_json_string(b,(unsigned char *)value,nc_length(value));
}
void s_text(nc_buffer *b,nc_result *r,int row,int col)
{
    if (nc_null(r,row,col)) W(b,"null");
    else nc_json_string(b,(unsigned char *)nc_value(r,row,col),nc_value_length(r,row,col));
}
void s_boolean(nc_buffer *b,bool value)
{ if (value) W(b,"true"); else W(b,"false"); }

static void profile_prefix(nc_buffer *b,nc_result *r,int row,int base)
{
    W(b,"{\"username\":"); s_text(b,r,row,base);
    W(b,",\"bio\":"); s_text(b,r,row,base+1);
    W(b,",\"image\":"); s_text(b,r,row,base+2);
    W(b,",\"following\":");
}
void s_profile(nc_buffer *b,nc_result *r,int row,int base)
{
    profile_prefix(b,r,row,base);
    s_boolean(b,nc_boolean(r,row,base+3)); nc_putc(b,'}');
}
static int article_prefix(nc_buffer *b,nc_result *r,int row,bool full)
{
    W(b,"{\"slug\":"); s_text(b,r,row,0);
    W(b,",\"title\":"); s_text(b,r,row,1);
    W(b,",\"description\":"); s_text(b,r,row,2);
    int base=3;
    if (full) { W(b,",\"body\":"); s_text(b,r,row,3); base=4; }
    W(b,",\"createdAt\":"); nc_timestamp(b,r,row,base);
    W(b,",\"updatedAt\":"); nc_timestamp(b,r,row,base+1);
    W(b,",\"tagList\":"); nc_text_array(b,r,row,base+2);
    W(b,",\"favoritesCount\":"); nc_json_int64(b,nc_integer(r,row,base+3));
    W(b,",\"favorited\":");
    return base;
}
void s_article(nc_buffer *b,nc_result *r,int row,bool full)
{
    int base=article_prefix(b,r,row,full);
    s_boolean(b,nc_boolean(r,row,base+4));
    W(b,",\"author\":"); s_profile(b,r,row,base+5); nc_putc(b,'}');
}

void s_article_shared(nc_buffer *b,nc_request *req,nc_result *r,int row,c_fragments cache[256])
{
    const char *slug=nc_value(r,row,0);
    size_t length=nc_value_length(r,row,0);
    uint64_t hash=UINT64_C(14695981039346656037);
    for (size_t i=0;i<length;++i) hash=(hash^(unsigned char)slug[i])*UINT64_C(1099511628211);
    size_t slot=(size_t)(hash&255);
    c_fragments *entry=NULL;
    for (int probes=0;probes<16;++probes) {
        c_fragments *candidate=&cache[slot];
        if (!candidate->request) { entry=candidate; break; }
        if (nc_eq(candidate->slug,slug)) {
            entry=candidate;
            if (candidate->request!=req && nc_status(candidate->request)==200) {
                size_t size=0;
                const char *source=nc_response_data(candidate->request,&size);
                if (candidate->prefix_offset<=size && candidate->prefix_length<=size-candidate->prefix_offset &&
                    candidate->author_offset<=size && candidate->author_length<=size-candidate->author_offset) {
                    nc_write_n(b,source+candidate->prefix_offset,candidate->prefix_length);
                    s_boolean(b,nc_boolean(r,row,7));
                    nc_write_n(b,source+candidate->author_offset,candidate->author_length);
                    s_boolean(b,nc_boolean(r,row,11)); W(b,"}}"); return;
                }
            }
            break;
        }
        slot=(slot+1)&255;
    }
    size_t prefix_offset=0,prefix_end=0,author_offset=0,author_end=0;
    nc_response_data(req,&prefix_offset);
    article_prefix(b,r,row,false);
    nc_response_data(req,&prefix_end);
    s_boolean(b,nc_boolean(r,row,7));
    nc_response_data(req,&author_offset);
    W(b,",\"author\":"); profile_prefix(b,r,row,8);
    nc_response_data(req,&author_end);
    s_boolean(b,nc_boolean(r,row,11)); W(b,"}}");
    if (entry && nc_status(req)==200)
        *entry=(c_fragments){req,slug,prefix_offset,prefix_end-prefix_offset,author_offset,author_end-author_offset};
}
void s_user(nc_buffer *b,nc_result *r,int row,const char *token)
{
    W(b,"{\"email\":"); s_text(b,r,row,2);
    W(b,",\"token\":"); s_string(b,token);
    W(b,",\"username\":"); s_text(b,r,row,1);
    W(b,",\"bio\":"); s_text(b,r,row,3);
    W(b,",\"image\":"); s_text(b,r,row,4); nc_putc(b,'}');
}
void s_comment(nc_buffer *b,nc_result *r,int row)
{
    W(b,"{\"id\":"); nc_json_int64(b,nc_integer(r,row,0));
    W(b,",\"body\":"); s_text(b,r,row,1);
    W(b,",\"createdAt\":"); nc_timestamp(b,r,row,2);
    W(b,",\"updatedAt\":"); nc_timestamp(b,r,row,3);
    W(b,",\"author\":"); s_profile(b,r,row,4); nc_putc(b,'}');
}
