#ifndef NC_READ_POLICY_H
#define NC_READ_POLICY_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct nc_pressure {
    bool valid, application_memory_high;
    unsigned cpu_busy, cpu_stall, io_stall, memory_stall; /* permille */
} nc_pressure;

typedef struct nc_pressure_probe {
    uint64_t sampled_at, cpu_total, cpu_idle, cpu_stall, io_stall, memory_stall;
    uint64_t group_stall[3];
    uint64_t group_cpu_usage, group_throttled;
    char cgroup[1024], cpu_scope[1024];
    bool initialized, baseline;
    nc_pressure value;
} nc_pressure_probe;

typedef struct nc_read_policy {
    unsigned maximum, limit, minimum_limit, window_us;
    uint64_t adjusted_at, service_us, completed, reductions, recoveries;
    unsigned last_cpu_busy, last_cpu_stall, last_io_stall, last_memory_stall;
    bool pressured, last_application_memory_high;
} nc_read_policy;

void nc_read_policy_init(nc_read_policy *policy,unsigned maximum);
void nc_read_policy_complete(nc_read_policy *policy,unsigned requests,uint64_t service_us);
void nc_read_policy_update(nc_read_policy *policy,uint64_t now_us,size_t queued,
                           uint64_t oldest_us,nc_pressure pressure);
unsigned nc_read_policy_window(const nc_read_policy *policy,size_t queued,unsigned active);
/* Read-only kernel observations, sampled at most four times per second.
 * No SQL probes, sysctls, scheduler changes or writes to /proc or cgroupfs. */
nc_pressure nc_pressure_read(nc_pressure_probe *probe,uint64_t now_us);
#endif
