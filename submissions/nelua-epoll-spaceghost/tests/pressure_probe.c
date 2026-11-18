/* Run in an owned cgroup with CPUQuota=25%, then return it to idle. This test
 * only reads kernel observations; the external harness owns resource limits. */
#define _GNU_SOURCE
#include "read_policy.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <time.h>

static uint64_t now(void)
{
    struct timespec t;
    assert(clock_gettime(CLOCK_MONOTONIC,&t)==0);
    return (uint64_t)t.tv_sec*1000000U+(uint64_t)t.tv_nsec/1000U;
}
int main(void)
{
    nc_pressure_probe probe={0};
    nc_read_policy policy;
    nc_read_policy_init(&policy,4);
    uint64_t start=now(),next=start+250000,end=start+2500000;
    nc_pressure_read(&probe,start);
    volatile uint64_t checksum=1;
    unsigned max_busy=0,max_stall=0;
    while (now()<end) {
        for (unsigned i=0;i<10000;++i) checksum=checksum*6364136223846793005ULL+1;
        uint64_t at=now();
        if (at<next) continue;
        nc_pressure value=nc_pressure_read(&probe,at);
        nc_read_policy_update(&policy,at,64,20000,value);
        if (value.cpu_busy>max_busy) max_busy=value.cpu_busy;
        if (value.cpu_stall>max_stall) max_stall=value.cpu_stall;
        printf("quota sample: busy=%u stall=%u limit=%u\n",value.cpu_busy,value.cpu_stall,policy.limit);
        next=at+250000;
    }
    assert(checksum && probe.group_throttled && max_busy>=850 && max_stall>=200);
    assert(policy.reductions>0);
    const struct timespec idle={.tv_sec=1};
    /* Discard the transition interval, then observe a wholly idle interval. */
    nanosleep(&idle,NULL);
    nc_pressure_read(&probe,now());
    uint64_t throttled=probe.group_throttled;
    nanosleep(&idle,NULL);
    nc_pressure value=nc_pressure_read(&probe,now());
    assert(probe.group_throttled==throttled && value.cpu_stall<200);
    nc_read_policy_update(&policy,now(),64,20000,value);
    assert(!policy.pressured && policy.recoveries>0);
    printf("PASS: actual quota saturation detected without PSI; idle recovery; maximum busy=%u stall=%u\n",
           max_busy,max_stall);
}
