#include "read_policy.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
    nc_read_policy p;
    nc_read_policy_init(&p,4);
    assert(p.limit==4);
    nc_pressure spare={.valid=true,.cpu_busy=300};
    nc_read_policy_update(&p,1000000,1,0,spare);
    assert(nc_read_policy_window(&p,1,0)==0);
    assert(nc_read_policy_window(&p,1,1)==0);
    nc_read_policy_complete(&p,32,8000);
    nc_pressure busy={.valid=true,.cpu_busy=950};
    nc_read_policy_update(&p,1250000,64,10000,busy);
    assert(p.limit==3 && p.pressured && p.window_us==2000);
    assert(nc_read_policy_window(&p,1,0)==0); /* no idle-lane latency floor */
    assert(nc_read_policy_window(&p,128,2)==0); /* full batch runs now */
    assert(nc_read_policy_window(&p,64,2)==2000);
    nc_read_policy_update(&p,1250001,64,10000,busy);
    assert(p.limit==3); /* bounded adjustment rate */
    nc_read_policy_update(&p,1500000,64,10000,busy);
    nc_read_policy_update(&p,1750000,64,10000,busy);
    nc_read_policy_update(&p,2000000,64,10000,busy);
    assert(p.limit==1);
    for (unsigned i=0;i<8;++i)
        nc_read_policy_update(&p,2250000+(uint64_t)i*250000,64,10000,spare);
    assert(p.limit==4 && !p.pressured && p.window_us==2000);
    nc_pressure io={.valid=true,.cpu_busy=200,.io_stall=800};
    nc_read_policy_init(&p,4);
    nc_read_policy_complete(&p,1,1000);
    nc_read_policy_update(&p,1000000,64,20000,io);
    assert(!p.pressured && p.limit==4); /* unrelated I/O does not throttle fast reads */
    nc_read_policy_complete(&p,1,100000);
    nc_read_policy_update(&p,1250000,64,20000,io);
    assert(p.pressured && p.limit==3 && p.window_us<=8000);
    nc_read_policy_update(&p,1500000,64,20000,(nc_pressure){0});
    assert(!p.pressured); /* absent probe data is not invented pressure */
    nc_read_policy_init(&p,1);
    for (unsigned i=1;i<20;++i)
        nc_read_policy_update(&p,(uint64_t)i*250000,4096,100000,busy);
    assert(p.limit==1 && p.window_us<=8000);
    nc_read_policy_update(&p,6000000,0,0,busy);
    assert(p.window_us==0);
    nc_read_policy_init(&p,4);
    nc_read_policy_complete(&p,128,1000000);
    nc_read_policy_update(&p,1000000,128,200000,(nc_pressure){0});
    assert(!p.pressured && p.limit==4 && p.minimum_limit==4 && p.reductions==0);
    assert(p.window_us==8000 && nc_read_policy_window(&p,1,1)==8000);
    assert(nc_read_policy_window(&p,1,0)==0 && nc_read_policy_window(&p,128,1)==0);
    for (unsigned i=0;i<64;++i) nc_read_policy_complete(&p,128,1000);
    nc_read_policy_update(&p,1250000,128,200000,(nc_pressure){0});
    assert(!p.pressured && p.limit==4 && p.recoveries==0);
    nc_read_policy_update(&p,1500000,128,200000,(nc_pressure){0});
    assert(p.recoveries==0 && p.minimum_limit==4);
    nc_read_policy_init(&p,4);
    nc_read_policy_update(&p,1000000,32,10000,(nc_pressure){.application_memory_high=true});
    assert(p.pressured && p.limit==3 && p.last_application_memory_high);
    nc_read_policy_update(&p,1250000,32,10000,(nc_pressure){0});
    assert(!p.pressured && p.limit==4 && !p.last_application_memory_high);
    puts("PASS: idle immediacy, bounded pressure response, rate limiting, recovery, I/O discrimination, missing metrics and one-slot bounds");
}
