#ifndef NC_APP_C_H
#define NC_APP_C_H
#include "native.h"

/* Independent C application/rendering counterpart. Transport, crypto, libpq
 * and the statement DATA are intentionally shared with the Nelua entry. */
#define W(buffer,literal) nc_write_n((buffer),(literal),sizeof(literal)-1)
void s_text(nc_buffer *b,nc_result *r,int row,int col);
void s_boolean(nc_buffer *b,bool value);
void s_profile(nc_buffer *b,nc_result *r,int row,int base);
void s_article(nc_buffer *b,nc_result *r,int row,bool full);
void s_user(nc_buffer *b,nc_result *r,int row,const char *token);
void s_comment(nc_buffer *b,nc_result *r,int row);

typedef struct c_fragments {
    nc_request *request;
    const char *slug;
    size_t prefix_offset,prefix_length,author_offset,author_length;
} c_fragments;
void s_article_shared(nc_buffer *b,nc_request *req,nc_result *r,int row,c_fragments cache[256]);
#endif
