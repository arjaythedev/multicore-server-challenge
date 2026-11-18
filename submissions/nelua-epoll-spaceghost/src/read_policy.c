#define _GNU_SOURCE
#include "read_policy.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void nc_read_policy_init(nc_read_policy *p,unsigned maximum)
{
    *p=(nc_read_policy){.maximum=maximum,.limit=maximum<4?maximum:4};
    p->minimum_limit=p->limit;
}
void nc_read_policy_complete(nc_read_policy *p,unsigned requests,uint64_t service_us)
{
    p->completed+=requests;
    p->service_us=p->service_us?(p->service_us*7+service_us)/8:service_us;
}
void nc_read_policy_update(nc_read_policy *p,uint64_t now,size_t queued,uint64_t oldest,nc_pressure pressure)
{
    p->last_cpu_busy=pressure.cpu_busy;
    p->last_cpu_stall=pressure.cpu_stall;
    p->last_io_stall=pressure.io_stall;
    p->last_memory_stall=pressure.memory_stall;
    p->last_application_memory_high=pressure.application_memory_high;
    /* I/O pressure alone can be unrelated to our reads. Require observed slow
     * service and a waiting queue before reducing DB admission for that signal. */
    p->pressured=pressure.application_memory_high || (pressure.valid && (pressure.cpu_busy>=900 || pressure.cpu_stall>=200 ||
        pressure.memory_stall>=50 || (pressure.io_stall>=150 && p->service_us>=5000 && oldest>=10000)));
    /* Latency and an old queue alone do not identify resource pressure: they
     * also occur when more concurrent I/O would help. In particular, reducing
     * admission for slow batches can lock a healthy CPU into one read lane.
     * Missing PSI therefore leaves that resource unknown, not inferred busy. */
    if (!queued) { p->window_us=0; return; }
    if (!p->adjusted_at || now-p->adjusted_at>=250000) {
        if (p->pressured && p->limit>1) {
            --p->limit; ++p->reductions;
            if (p->limit<p->minimum_limit) p->minimum_limit=p->limit;
        } else if (!p->pressured && p->limit<p->maximum && oldest>=2000 && queued>=p->limit*2U) {
            ++p->limit;
            ++p->recoveries;
        }
        p->adjusted_at=now;
    }
    /* Slow database work benefits from denser frozen groups even without a
     * trustworthy resource-pressure signal. Change collection, not admission. */
    if (p->pressured || p->service_us>=2000) {
        uint64_t window=p->service_us/4;
        if (window<250) window=250;
        if (window>8000) window=8000;
        p->window_us=(unsigned)window;
    } else p->window_us=queued>=16?250:0;
}
unsigned nc_read_policy_window(const nc_read_policy *p,size_t queued,unsigned active)
{
    /* Never hold the first request of an idle DB lane. Saturated lanes already
     * gather arrivals naturally while waiting for their existing work. */
    if (!active || queued>=128 || (!p->pressured && p->service_us<2000 && queued<16)) return 0;
    return p->window_us;
}

static bool read_text(const char *path,char *buffer,size_t capacity)
{
#ifdef NC_PRESSURE_TESTING
    char redirected[4096];
    const char *root=getenv("NC_PRESSURE_TEST_ROOT");
    if (root) {
        int size=snprintf(redirected,sizeof(redirected),"%s%s",root,path);
        if (size<0 || (size_t)size>=sizeof(redirected)) return false;
        path=redirected;
    }
#endif
    int fd=open(path,O_RDONLY|O_CLOEXEC);
    if (fd<0) return false;
    ssize_t size=read(fd,buffer,capacity-1);
    close(fd);
    if (size<=0) return false;
    buffer[size]=0;
    return true;
}
static uint64_t stall_total(const char *path)
{
    char text[512];
    if (!read_text(path,text,sizeof(text))) return 0;
    /* The first line is SOME; FULL is not a useful system-wide CPU metric. */
    char *line_end=strchr(text,'\n');
    if (line_end) *line_end=0;
    const char *value=strstr(text,"total=");
    return value?strtoull(value+6,NULL,10):0;
}
static unsigned permille(uint64_t current,uint64_t previous,uint64_t span)
{
    if (!span || current<previous) return 0;
    uint64_t difference=current-previous;
    return difference>=span?1000:(unsigned)(difference*1000/span);
}
static uint64_t maximum(uint64_t left,uint64_t right) { return left>right?left:right; }

nc_pressure nc_pressure_read(nc_pressure_probe *p,uint64_t now)
{
    if (p->sampled_at && now-p->sampled_at<250000) return p->value;
    char text[1024];
    if (!p->initialized) {
        p->initialized=true;
        if (read_text("/proc/self/cgroup",text,sizeof(text))) {
            char *v=strstr(text,"0::/");
            if (v) {
                v+=3;
                char *end=strchr(v,'\n');
                if (end) *end=0;
                if (!strstr(v,"..") && strlen(v)<sizeof(p->cgroup))
                    memcpy(p->cgroup,v,strlen(v)+1);
            }
        }
    }
    unsigned long long user,nice,system,idle,iowait,irq,softirq,steal;
    if (!read_text("/proc/stat",text,sizeof(text)) ||
        sscanf(text,"cpu %llu %llu %llu %llu %llu %llu %llu %llu",
               &user,&nice,&system,&idle,&iowait,&irq,&softirq,&steal)!=8) {
        p->value.valid=false;
        p->baseline=false;
        p->sampled_at=now;
        return p->value;
    }
    uint64_t total=user+nice+system+idle+iowait+irq+softirq+steal;
    uint64_t idle_total=idle+iowait;
    const char *resources[]={"cpu","io","memory"};
    uint64_t global[3],group[3]={0};
    for (int i=0;i<3;++i) {
        char path[1200];
        snprintf(path,sizeof(path),"/proc/pressure/%s",resources[i]);
        global[i]=stall_total(path);
        if (*p->cgroup) {
            snprintf(path,sizeof(path),"/sys/fs/cgroup%s/%s.pressure",p->cgroup,resources[i]);
            group[i]=stall_total(path);
        }
    }
    uint64_t group_usage=0,throttled=0,quota=0,period=0;
    if (*p->cgroup) {
        char scope[1024],selected[1024],path[1200];
        memcpy(scope,p->cgroup,strlen(p->cgroup)+1);
        memcpy(selected,scope,strlen(scope)+1);
        /* A leaf may be unlimited while an ancestor throttles both the app
         * and local database. Compare quota/period ratios without rounding. */
        for (;;) {
            snprintf(path,sizeof(path),"/sys/fs/cgroup%s/cpu.max",scope);
            unsigned long long q=0,t=0;
            if (read_text(path,text,sizeof(text)) && sscanf(text,"%llu %llu",&q,&t)==2 && q && t &&
                (!quota || (__uint128_t)q*period<(__uint128_t)quota*t)) {
                quota=q; period=t;
                memcpy(selected,scope,strlen(scope)+1);
            }
            char *slash=strrchr(scope,'/');
            if (!slash) break;
            *slash=0;
        }
        snprintf(path,sizeof(path),"/sys/fs/cgroup%s/cpu.stat",selected);
        if (read_text(path,text,sizeof(text))) {
            const char *usage=strstr(text,"usage_usec "), *stall=strstr(text,"throttled_usec ");
            if (usage) group_usage=strtoull(usage+11,NULL,10);
            if (stall) throttled=strtoull(stall+15,NULL,10);
        }
        /* Cumulative counters from different ancestors cannot be differenced. */
        if (strcmp(selected,p->cpu_scope)) {
            memcpy(p->cpu_scope,selected,strlen(selected)+1);
            p->group_cpu_usage=group_usage;
            p->group_throttled=throttled;
        }
    }
    /* Keep totals for both scopes separately: choosing the larger cumulative
     * counter before differencing would produce false pressure on a scope swap. */
    if (p->baseline && now>p->sampled_at && total>p->cpu_total && idle_total>=p->cpu_idle) {
        uint64_t span=now-p->sampled_at, ticks=total-p->cpu_total;
        unsigned idle_share=permille(idle_total,p->cpu_idle,ticks);
        p->value=(nc_pressure){.valid=true,.cpu_busy=1000-idle_share,
            .cpu_stall=(unsigned)maximum(permille(global[0],p->cpu_stall,span),permille(group[0],p->group_stall[0],span)),
            .io_stall=(unsigned)maximum(permille(global[1],p->io_stall,span),permille(group[1],p->group_stall[1],span)),
            .memory_stall=(unsigned)maximum(permille(global[2],p->memory_stall,span),permille(group[2],p->group_stall[2],span))};
        /* A capped service can saturate while the larger host stays idle.
         * Observe actual quota consumption/throttling, including descendant
         * database processes when the harness puts them in this cgroup. */
        if (quota && period && group_usage>=p->group_cpu_usage) {
            __uint128_t denominator=(__uint128_t)span*quota;
            __uint128_t numerator=(__uint128_t)(group_usage-p->group_cpu_usage)*period*1000U;
            __uint128_t share=numerator/denominator;
            unsigned busy=share>=1000U?1000:(unsigned)share;
            if (busy>p->value.cpu_busy) p->value.cpu_busy=busy;
        }
        unsigned quota_stall=permille(throttled,p->group_throttled,span);
        if (quota_stall>p->value.cpu_stall) p->value.cpu_stall=quota_stall;
    }
    p->group_cpu_usage=group_usage;p->group_throttled=throttled;
    memcpy(p->group_stall,group,sizeof(group));
    p->baseline=true;
    p->sampled_at=now; p->cpu_total=total; p->cpu_idle=idle_total;
    p->cpu_stall=global[0]; p->io_stall=global[1]; p->memory_stall=global[2];
    return p->value;
}
