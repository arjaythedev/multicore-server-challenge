#define _POSIX_C_SOURCE 200809L
#include "read_policy.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *root;
static void put(const char *name,const char *value)
{
    char path[2048];int n=snprintf(path,sizeof(path),"%s%s",root,name);
    assert(n>0 && (size_t)n<sizeof(path));
    FILE *f=fopen(path,"w");assert(f);assert(fputs(value,f)>=0);assert(fclose(f)==0);
}
int main(int argc,char **argv)
{
    assert(argc==2);root=argv[1];assert(setenv("NC_PRESSURE_TEST_ROOT",root,1)==0);
    put("/proc/self/cgroup","0::/service/worker\n");
    put("/proc/stat","cpu 100 0 100 800 0 0 0 0\n");
    put("/sys/fs/cgroup/cpu.max","max 100000\n");
    put("/sys/fs/cgroup/cpu.stat","usage_usec 10000000\nthrottled_usec 0\n");
    put("/sys/fs/cgroup/service/cpu.max","10000 100000\n");
    put("/sys/fs/cgroup/service/cpu.stat","usage_usec 10000\nthrottled_usec 0\n");
    put("/sys/fs/cgroup/service/worker/cpu.max","max 100000\n");
    put("/sys/fs/cgroup/service/worker/cpu.stat","usage_usec 1\nthrottled_usec 0\n");
    nc_pressure_probe probe={0};nc_pressure_read(&probe,1000000);
    put("/proc/stat","cpu 110 0 110 1780 0 0 0 0\n");
    put("/sys/fs/cgroup/service/cpu.stat","usage_usec 35000\nthrottled_usec 250000\n");
    nc_pressure value=nc_pressure_read(&probe,1250000);
    assert(value.valid && value.cpu_busy==1000 && value.cpu_stall==1000);
    assert(!strcmp(probe.cpu_scope,"/service"));
    nc_read_policy policy;nc_read_policy_init(&policy,4);
    nc_read_policy_update(&policy,1250000,64,20000,value);
    assert(policy.limit==3 && policy.pressured);
    /* A tighter grandparent overrides the parent, with no false jump from
     * its unrelated cumulative counter when the selected scope changes. */
    put("/sys/fs/cgroup/cpu.max","5000 100000\n");
    put("/proc/stat","cpu 120 0 120 2760 0 0 0 0\n");
    value=nc_pressure_read(&probe,1500000);
    assert(!strcmp(probe.cpu_scope,"") && value.cpu_busy==20 && value.cpu_stall==0);
    put("/proc/stat","cpu 130 0 130 3740 0 0 0 0\n");
    put("/sys/fs/cgroup/cpu.stat","usage_usec 10012500\nthrottled_usec 0\n");
    value=nc_pressure_read(&probe,1750000);
    assert(value.cpu_busy==1000);
    put("/sys/fs/cgroup/cpu.max","max 100000\n");
    put("/sys/fs/cgroup/service/cpu.max","max 100000\n");
    put("/proc/stat","cpu 140 0 140 4720 0 0 0 0\n");
    value=nc_pressure_read(&probe,2000000);
    assert(!strcmp(probe.cpu_scope,"/service/worker") && value.cpu_busy==20 && value.cpu_stall==0);
    nc_read_policy_update(&policy,2000000,64,20000,value);
    assert(policy.limit==4 && !policy.pressured);
    puts("PASS: unlimited leaf detects saturated ancestor without PSI; tightest quota wins, scope switches reset counters, admission recovers");
}
