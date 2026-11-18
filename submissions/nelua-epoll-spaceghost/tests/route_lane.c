#define _POSIX_C_SOURCE 200809L
#include "native.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int conduit_lane(nc_request *request);
int main(void)
{
    const size_t nodes=20000;
    char *body=malloc(nodes*2+128),*at=body;
    assert(body);at+=sprintf(at,"{\"user\":{\"bio\":[");
    for (size_t i=0;i<nodes;++i) at+=sprintf(at,i?",0":"0");
    at+=sprintf(at,"]}}");
    size_t length=(size_t)(at-body);
    char *wire=malloc(length+256);assert(wire);
    int header=sprintf(wire,"PUT /api/user HTTP/1.1\r\nHost: test\r\nContent-Length: %zu\r\n\r\n",length);
    memcpy(wire+header,body,length);
    nc_request *request=nc_request_create(wire,(size_t)header+length);assert(request);
    size_t before=nc_request_memory_used();
    assert(conduit_lane(request)==2);
    assert(nc_request_memory_used()==before); /* No JSON nodes on socket owner. */
    nc_request_free(request);nc_request_pool_trim();
    assert(nc_request_memory_used()==0);free(wire);free(body);
    puts("PASS: user update routes without allocating/parsing a 20,000-node unauthenticated body on the network thread");
}
