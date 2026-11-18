#include "native.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned state=0x923;
static unsigned next_random(void) { state=state*1664525U+1013904223U; return state; }
static nc_request *make_request(const unsigned char *body,size_t length)
{
    char *wire=malloc(length+256);
    assert(wire);
    int prefix=snprintf(wire,length+256,"POST /api/users HTTP/1.1\r\nContent-Length: %zu\r\n\r\n",length);
    memcpy(wire+prefix,body,length);
    nc_request *request=nc_request_create(wire,(size_t)prefix+length);
    free(wire);
    assert(request);
    return request;
}
int main(void)
{
    assert(setenv("JWT_SECRET","sanitizer-only-test",1)==0);
    for (unsigned iteration=0;iteration<20000;++iteration) {
        unsigned char raw[1024];
        size_t length=next_random()%sizeof(raw);
        for (size_t i=0;i<length;++i) raw[i]=(unsigned char)next_random();
        (void)nc_request_size((const char *)raw,length);
        nc_request *request=make_request(raw,length);
        (void)nc_body(request,"user");
        nc_request_free(request);
    }
    const char *samples[]={
      "{\"user\":{\"name\":\"\\uD83D\\uDE00 \\u96ea\",\"array\":[\"a\",\"b\"]}}",
      "{\"user\":{\"name\":\"雪 😀\",\"array\":[\"a\\\\\\\"b\",\"c\"]}}",
      "{\"user\":{\"x\":-1.2e+34,\"null\":null,\"b\":true}}",
      "{\"user\":{\"x\":\"\\ud800\"}}", "{\"user\":{\"x\":\"\\u0000\"}}"
    };
    for (size_t i=0;i<sizeof(samples)/sizeof(samples[0]);++i) {
        nc_request *request=make_request((const unsigned char *)samples[i],strlen(samples[i]));
        nc_json *user=nc_body(request,"user");
        (void)nc_kind(user);
        (void)nc_array_length(nc_field(user,"array"));
        (void)nc_tag_array(request,nc_field(user,"array"));
        const char *token=nc_issue_token(request,42);
        assert(token);
        nc_request_free(request);
    }
    unsigned char deep[4096];
    memset(deep,'[',2048); memset(deep+2048,']',2048);
    nc_request *request=make_request(deep,sizeof(deep));
    assert(!nc_body(request,"user"));
    nc_request_free(request);
    puts("PASS: request parser ASan/UBSan stress");
    return 0;
}
