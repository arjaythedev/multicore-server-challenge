#define _GNU_SOURCE
#include "bcrypt.h"
#include <assert.h>
#include <crypt.h>
#include <openssl/crypto.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t random_state=0x9231234567ULL;
static unsigned next_random(void)
{
    random_state^=random_state<<13;
    random_state^=random_state>>7;
    random_state^=random_state<<17;
    return (unsigned)random_state;
}
static double cpu_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&ts);
    return ts.tv_sec+ts.tv_nsec*1e-9;
}

typedef struct {
    char password[73], setting[61], expected[61];
    bool mismatch;
} thread_case;
static pthread_barrier_t barrier;
static void *thread_test(void *argument)
{
    thread_case *test=argument;
    char actual[61];
    pthread_barrier_wait(&barrier);
    assert(nc_bcrypt_hash(test->password,test->setting,actual));
    assert((CRYPTO_memcmp(actual,test->expected,60)!=0)==test->mismatch);
    return NULL;
}

int main(void)
{
    struct crypt_data reference={0};
    unsigned checked=0;
    static const char minors[]="aby";
    for (int repeat=0;repeat<3;++repeat) {
        for (int count=1;count<=BC_MAXLANES;++count) {
            bc_req_t jobs[BC_MAXLANES];
            char passwords[BC_MAXLANES][73];
            char settings[BC_MAXLANES][CRYPT_GENSALT_OUTPUT_SIZE];
            for (int i=0;i<count;++i) {
                unsigned char entropy[16];
                size_t length=(i+repeat)%3==0?72:next_random()%73;
                char prefix[]="$2b$";
                prefix[2]=minors[(i+repeat)%3];
                for (size_t j=0;j<length;++j) {
                    unsigned c=1+next_random()%255;
                    if (prefix[2]=='a') c=32+next_random()%95;
                    passwords[i][j]=(char)c;
                }
                passwords[i][length]=0;
                for (int j=0;j<16;++j) entropy[j]=(unsigned char)next_random();
                assert(crypt_gensalt_rn(prefix,10,(const char *)entropy,sizeof(entropy),settings[i],sizeof(settings[i])));
                assert(bc_prepare(&jobs[i],passwords[i],settings[i])==0);
            }
            bc_compute(jobs,count);
            for (int i=0;i<count;++i) {
                char *expected=crypt_r(passwords[i],settings[i],&reference);
                assert(expected && !strcmp(expected,jobs[i].out));
                ++checked;
            }
        }
    }
    bc_req_t rejected;
    assert(bc_prepare(&rejected,"x","$2")<0);
    assert(bc_prepare(&rejected,"\xff\xa3","$2a$10$abcdefghijklmnopqrstuu")<0);
    char output[61];
    assert(!nc_bcrypt_hash("\xff\xa3","$2a$10$abcdefghijklmnopqrstuu",output));
    assert(!nc_bcrypt_hash("x","$2b$04$abcdefghijklmnopqrstuu",output));
    assert(!nc_bcrypt_hash("x","$6$unrelated",output));
    assert(!nc_bcrypt_hash("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","$2b$10$abcdefghijklmnopqrstuu",output));
    enum { THREADS=16 };
    thread_case tests[THREADS];
    pthread_t threads[THREADS];
    for (int i=0;i<THREADS;++i) {
        char *hash=crypt_r("password123","$2b$10$abcdefghijklmnopqrstuu",&reference);
        assert(hash);
        strcpy(tests[i].password,i%2?"wrong-password":"password123");
        strcpy(tests[i].setting,hash);
        strcpy(tests[i].expected,hash);
        tests[i].mismatch=i%2;
    }
    assert(pthread_barrier_init(&barrier,NULL,THREADS)==0);
    for (int i=0;i<THREADS;++i) assert(pthread_create(&threads[i],NULL,thread_test,&tests[i])==0);
    for (int i=0;i<THREADS;++i) assert(pthread_join(threads[i],NULL)==0);
    pthread_barrier_destroy(&barrier);
    /* CPU timing includes exactly the same number of full cost-10 hashes. */
    bc_req_t jobs[BC_MAXLANES];
    for (int i=0;i<BC_MAXLANES;++i) assert(bc_prepare(&jobs[i],"password123","$2b$10$abcdefghijklmnopqrstuu")==0);
    double start=cpu_seconds();
    for (int i=0;i<BC_MAXLANES;++i) assert(crypt_r("password123","$2b$10$abcdefghijklmnopqrstuu",&reference));
    double slow=cpu_seconds()-start;
    start=cpu_seconds();
    bc_compute(jobs,BC_MAXLANES);
    double fast=cpu_seconds()-start;
    printf("PASS: %u independent cost10 lane1..8 vectors, 16 concurrent coordinator jobs, unsupported/countermeasure fallback\n",checked);
    printf("cost10 CPU: libxcrypt %.2fms/hash; interleaved8 %.2fms/hash; %.2fx throughput per CPU\n",slow/BC_MAXLANES*1000,fast/BC_MAXLANES*1000,slow/fast);
    return 0;
}
