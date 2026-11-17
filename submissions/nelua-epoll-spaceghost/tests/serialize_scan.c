/* Independent scalar oracle plus ASan boundaries for the Nelua word scanner. */
#include "native.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static unsigned long long state=0xd827ec109aULL;
static volatile size_t benchmark_checksum;
static unsigned random_byte(void)
{
    state^=state<<13; state^=state>>7; state^=state<<17;
    return (unsigned)(state&255);
}
static size_t reference(char *out,const unsigned char *in,size_t n)
{
    static const char hex[]="0123456789abcdef";
    size_t w=0; out[w++]='"';
    for (size_t i=0;i<n;++i) {
        unsigned c=in[i];
        if (c<32) {
            memcpy(out+w,"\\u00",4); w+=4;
            out[w++]=hex[c/16]; out[w++]=hex[c%16];
        } else {
            if (c=='"' || c=='\\') out[w++]='\\';
            out[w++]=(char)c;
        }
    }
    out[w++]='"'; return w;
}
static void check(const unsigned char *data,size_t n)
{
    static const char wire[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
    nc_request *r=nc_request_create(wire,sizeof(wire)-1);
    assert(r);
    char *want=malloc(6*n+2); assert(want);
    size_t expected=reference(want,data,n), length;
    nc_json_string(nc_begin(r,200),(unsigned char *)data,n);
    const char *body=nc_response_data(r,&length);
    assert(nc_status(r)==200 && length==expected && !memcmp(body,want,length));
    free(want); nc_request_free(r);
}
static void check_integer(int64_t value)
{
    static const char wire[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
    nc_request *r=nc_request_create(wire,sizeof(wire)-1);
    assert(r);
    char expected[32];
    int n=snprintf(expected,sizeof(expected),"%" PRId64,value);
    assert(n>0 && (size_t)n<sizeof(expected));
    nc_json_int64(nc_begin(r,200),value);
    size_t length=0;
    const char *body=nc_response_data(r,&length);
    assert(length==(size_t)n && !memcmp(body,expected,length));
    nc_request_free(r);
}
int main(int argc,char **argv)
{
    assert(nc_json_scan_init());
    if (argc>1) {
        unsigned loops=(unsigned)strtoul(argv[1],NULL,10);
        static const char wire[]="GET /api/tags HTTP/1.1\r\nHost: test\r\n\r\n";
        nc_request *r=nc_request_create(wire,sizeof(wire)-1); assert(r);
        unsigned char text[4096];
        static const size_t lengths[]={12,64,128,1024,4096};
        for (unsigned kind=0;kind<3;++kind) {
            memset(text,'x',sizeof(text));
            if (kind==1) for (unsigned i=0;i<sizeof(text);i+=43) text[i]='\n';
            if (kind==2) for (unsigned i=0;i+2<sizeof(text);i+=3) {
                text[i]=0xe9; text[i+1]=0x9b; text[i+2]=0xaa;
            }
            for (size_t sample=0;sample<sizeof(lengths)/sizeof(*lengths);++sample) {
            size_t length=lengths[sample];
            struct timespec begin,end;
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&begin);
            for (unsigned i=0;i<loops;++i) {
                nc_json_string(nc_begin(r,200),text,length);
                size_t output_length;
                const unsigned char *output=(const unsigned char *)nc_response_data(r,&output_length);
                assert(output && output_length>=2);
                benchmark_checksum+=(size_t)output[i%output_length]+output_length;
            }
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&end);
            double elapsed=(double)(end.tv_sec-begin.tv_sec)+(double)(end.tv_nsec-begin.tv_nsec)/1e9;
            printf("BENCH kind=%u length=%zu loops=%u cpu_seconds=%.6f ns_per_string=%.3f MiB_per_second=%.2f\n",
                   kind,length,loops,elapsed,elapsed*1e9/loops,(double)loops*length/1048576/elapsed);
            }
        }
        nc_request_free(r);
        fflush(stdout);
        fprintf(stderr,"checksum=%zu\n",benchmark_checksum);
        return 0;
    }
    /* Every byte at every position across several word/tail boundaries. */
    const int64_t integers[]={INT64_MIN,INT64_MAX,-1000000000000000000LL,-10,-1,0,1,9,10,1000000000000000000LL};
    for (size_t i=0;i<sizeof(integers)/sizeof(*integers);++i) check_integer(integers[i]);
    unsigned char input[72];
    for (unsigned n=0;n<sizeof(input);++n) {
        for (unsigned pos=0;pos<n;++pos) for (unsigned c=0;c<256;++c) {
            memset(input,'x',n); input[pos]=(unsigned char)c;
            check(input,n);
        }
    }
    /* malloc's exact trailing ASan boundary catches any final-word overread;
     * prefix offsets exercise each possible input alignment. */
    for (unsigned n=0;n<2048;n+=7) for (unsigned alignment=0;alignment<8;++alignment) {
        unsigned char *allocation=malloc(n+alignment+1); assert(allocation);
        unsigned char *data=allocation+alignment+1;
        for (unsigned i=0;i<n;++i) data[i]=(unsigned char)random_byte();
        check(data,n); free(allocation);
    }
    puts("PASS: all 256 byte values at every position, tails, unaligned ranges and exact allocation boundaries");
    return 0;
}
