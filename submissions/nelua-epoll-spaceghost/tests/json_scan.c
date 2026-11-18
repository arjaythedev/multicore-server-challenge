#define _GNU_SOURCE
#include "json_scan.h"
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

typedef size_t (*scan_fn)(unsigned char *,size_t);
typedef struct scanner { const char *name; scan_fn scan; int isa; } scanner;
static scanner scanners[]={
    {"c-scalar",nc_json_prefix_scalar_c,0}, {"nelua-scalar",nc_json_prefix_scalar_nelua,0},
    {"c-word",nc_json_prefix_word_c,0}, {"nelua-word",nc_json_prefix_word_nelua,0},
    {"c-avx2",nc_json_prefix_avx2_c,2}, {"nelua-avx2",nc_json_prefix_avx2_nelua,2},
    {"c-avx512",nc_json_prefix_avx512_c,5}, {"nelua-avx512",nc_json_prefix_avx512_nelua,5}
};
static bool supported(int isa)
{
    return isa==0 || (isa==2 && __builtin_cpu_supports("avx2")) ||
           (isa==5 && __builtin_cpu_supports("avx2") &&
            __builtin_cpu_supports("avx512f") && __builtin_cpu_supports("avx512bw"));
}
static void check(unsigned char *p,size_t n)
{
    size_t want=0;
    while (want<n) {
        unsigned byte=p[want];
        if (byte<0x20 || byte==0x22 || byte==0x5c) break;
        ++want;
    }
    for (size_t j=0;j<sizeof(scanners)/sizeof(*scanners);++j) {
        if (!supported(scanners[j].isa)) continue;
        size_t got=scanners[j].scan(p,n);
        if (got!=want) {
            fprintf(stderr,"FAIL %s length=%zu got=%zu want=%zu\n",scanners[j].name,n,got,want);
            abort();
        }
    }
}
static void correctness(void)
{
    unsigned char text[130];
    for (size_t n=0;n<sizeof(text);++n) {
        for (size_t pos=0;pos<n;++pos) for (unsigned byte=0;byte<256;++byte) {
            memset(text,'x',n); text[pos]=(unsigned char)byte; check(text,n);
        }
    }
    long page=sysconf(_SC_PAGESIZE);
    assert(page>=4096);
    unsigned char *mapping=mmap(NULL,(size_t)page*3,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    assert(mapping!=MAP_FAILED);
    assert(mprotect(mapping+page,(size_t)page,PROT_READ|PROT_WRITE)==0);
    unsigned char *end=mapping+2*page;
    for (size_t n=0;n<=4096;++n) {
        unsigned char *p=end-n;
        memset(p,'x',n); check(p,n);
        memset(p,0xe9,n); check(p,n);
        if (n) {
            p[n-1]='"'; check(p,n);
            p[n-1]='\\'; check(p,n);
            p[n-1]=0; check(p,n);
        }
    }
    assert(munmap(mapping,(size_t)page*3)==0);
    for (size_t j=0;j<sizeof(scanners)/sizeof(*scanners);++j)
        printf("%s %s\n",supported(scanners[j].isa)?"PASS":"SKIP unsupported ISA",scanners[j].name);
    puts("PASS: exhaustive byte/position oracle and inaccessible trailing-page boundaries");
}
static double cpu_seconds(void)
{
    struct timespec ts;
    assert(clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&ts)==0);
    return (double)ts.tv_sec+(double)ts.tv_nsec/1e9;
}
static void benchmark(unsigned rounds)
{
    /* The call order is rotated per repetition. Every loop consumes distinct
     * input addresses; a volatile checksum prevents dead-code elimination. */
    unsigned char data[64][4096];
    static const size_t lengths[]={12,32,64,128,1024,4096};
    volatile size_t checksum=0;
    for (unsigned repetition=0;repetition<rounds;++repetition) {
        for (unsigned kind=0;kind<3;++kind) {
            for (size_t d=0;d<64;++d) {
                memset(data[d],kind==2?0xe9:'x',sizeof(data[d]));
                if (kind==1) for (size_t k=43+d%7;k<sizeof(data[d]);k+=43) data[d][k]='\n';
            }
            for (size_t len=0;len<sizeof(lengths)/sizeof(*lengths);++len) {
                size_t n=lengths[len];
                const unsigned loops=200000;
                for (size_t order=0;order<sizeof(scanners)/sizeof(*scanners);++order) {
                    size_t j=(order+repetition)%(sizeof(scanners)/sizeof(*scanners));
                    if (!supported(scanners[j].isa)) continue;
                    double started=cpu_seconds();
                    size_t sum=0;
                    for (unsigned iteration=0;iteration<loops;++iteration) {
                        unsigned char *p=data[iteration%64];
                        size_t offset=0;
                        while (offset<n) {
                            size_t prefix=scanners[j].scan(p+offset,n-offset);
                            sum+=prefix;
                            offset+=prefix;
                            if (offset<n) ++offset;
                        }
                    }
                    double elapsed=cpu_seconds()-started;
                    checksum+=sum;
                    printf("BENCH %s repetition=%u kind=%u length=%zu ns_per_string=%.3f MiB_per_second=%.2f\n",
                           scanners[j].name,repetition,kind,n,elapsed*1e9/loops,
                           (double)n*loops/1048576/elapsed);
                }
            }
        }
    }
    fflush(stdout);
    fprintf(stderr,"checksum=%zu\n",checksum);
}
int main(int argc,char **argv)
{
    __builtin_cpu_init();
    if (argc==2) benchmark((unsigned)strtoul(argv[1],NULL,10));
    else correctness();
}
