//! Worker thread initialization and scheduling configuration.
//! Supports dynamic CPU core pinning based on physical core topology,
//! SCHED_BATCH (reactor/db), and SCHED_IDLE (bcrypt kdf).

use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SchedPolicy {
    Normal,
    Batch,
    Idle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct CpuInfo {
    pub package_id: usize,
    pub core_id: usize,
    pub cpu_id: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PhysicalCore {
    pub package_id: usize,
    pub core_id: usize,
    pub cpus: Vec<usize>,
}

/// Reads the CPU topology from /sys/devices/system/cpu.
pub fn read_system_topology() -> Vec<CpuInfo> {
    let mut cpus = Vec::new();
    let Ok(entries) = std::fs::read_dir("/sys/devices/system/cpu") else {
        return cpus;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if let Some(id_str) = name_str.strip_prefix("cpu") {
            if let Ok(cpu_id) = id_str.parse::<usize>() {
                let pkg_path = format!(
                    "/sys/devices/system/cpu/cpu{}/topology/physical_package_id",
                    cpu_id
                );
                let core_path = format!(
                    "/sys/devices/system/cpu/cpu{}/topology/core_id",
                    cpu_id
                );

                let package_id = std::fs::read_to_string(&pkg_path)
                    .ok()
                    .and_then(|s| s.trim().parse::<usize>().ok())
                    .unwrap_or(0);

                let core_id = std::fs::read_to_string(&core_path)
                    .ok()
                    .and_then(|s| s.trim().parse::<usize>().ok())
                    .unwrap_or(cpu_id);

                cpus.push(CpuInfo {
                    package_id,
                    core_id,
                    cpu_id,
                });
            }
        }
    }
    cpus.sort_by_key(|c| c.cpu_id);
    cpus
}

/// Reads the allowed CPU set for the current process using sched_getaffinity.
pub fn get_allowed_cpus() -> Vec<usize> {
    let mut allowed = Vec::new();
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        let rc = libc::sched_getaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &mut set);
        if rc == 0 {
            for i in 0..libc::CPU_SETSIZE as usize {
                if libc::CPU_ISSET(i, &set) {
                    allowed.push(i);
                }
            }
        }
    }
    if allowed.is_empty() {
        let n = std::thread::available_parallelism()
            .map(|p| p.get())
            .unwrap_or(1);
        allowed = (0..n).collect();
    }
    allowed.sort_unstable();
    allowed
}

/// Groups allowed CPUs by physical core (package_id, core_id).
pub fn group_cpus_by_core(topology: &[CpuInfo], allowed_cpus: &[usize]) -> Vec<PhysicalCore> {
    let allowed_set: BTreeSet<usize> = allowed_cpus.iter().copied().collect();
    let mut core_map: BTreeMap<(usize, usize), Vec<usize>> = BTreeMap::new();
    let mut matched = BTreeSet::new();

    for cpu in topology {
        if allowed_set.contains(&cpu.cpu_id) {
            core_map
                .entry((cpu.package_id, cpu.core_id))
                .or_default()
                .push(cpu.cpu_id);
            matched.insert(cpu.cpu_id);
        }
    }

    // For any allowed CPU not found in topology, treat it as its own core
    for &cpu_id in allowed_cpus {
        if !matched.contains(&cpu_id) {
            core_map.entry((0, cpu_id)).or_default().push(cpu_id);
        }
    }

    let mut cores: Vec<PhysicalCore> = core_map
        .into_iter()
        .map(|((package_id, core_id), mut cpus)| {
            cpus.sort_unstable();
            PhysicalCore {
                package_id,
                core_id,
                cpus,
            }
        })
        .collect();

    // Sort cores by their lowest CPU id for deterministic ordering
    cores.sort_by_key(|c| c.cpus.first().copied().unwrap_or(usize::MAX));
    cores
}

/// Computes thread pinning placement:
/// 1. Assigns pinned threads one per physical core first (no two threads on SMT siblings
///    until every physical core has at least one pinned thread).
/// 2. Never assigns two pinned threads to the same logical CPU.
/// 3. If threads > allowed CPUs, falls back to unpinned (returns None for all).
pub fn compute_thread_placement(
    topology: &[CpuInfo],
    allowed_cpus: &[usize],
    num_threads: usize,
) -> Vec<Option<usize>> {
    if num_threads == 0 {
        return Vec::new();
    }

    let allowed_count = allowed_cpus.len();
    if allowed_count == 0 || num_threads > allowed_count {
        return vec![None; num_threads];
    }

    let cores = group_cpus_by_core(topology, allowed_cpus);
    if cores.is_empty() {
        return vec![None; num_threads];
    }

    let max_siblings = cores.iter().map(|c| c.cpus.len()).max().unwrap_or(0);
    let mut placement = Vec::with_capacity(num_threads);

    'outer: for sibling_idx in 0..max_siblings {
        for core in &cores {
            if let Some(&cpu) = core.cpus.get(sibling_idx) {
                placement.push(Some(cpu));
                if placement.len() == num_threads {
                    break 'outer;
                }
            }
        }
    }

    placement
}

/// Formats the final thread -> CPU map into a single log line.
pub fn format_affinity_map(
    net_pins: &[Option<usize>],
    pg_pins: &[Option<usize>],
    note: &str,
) -> String {
    let mut parts = Vec::new();
    for (i, pin) in net_pins.iter().enumerate() {
        match pin {
            Some(cpu) => parts.push(format!("net-reactor-{}->cpu{}", i, cpu)),
            None => parts.push(format!("net-reactor-{}->unpinned", i)),
        }
    }
    for (i, pin) in pg_pins.iter().enumerate() {
        match pin {
            Some(cpu) => parts.push(format!("pg-driver-{}->cpu{}", i, cpu)),
            None => parts.push(format!("pg-driver-{}->unpinned", i)),
        }
    }
    parts.push("kdf->unpinned".to_string());
    format!("Thread affinity map: {} ({})", parts.join(", "), note)
}

pub fn is_pin_enabled() -> bool {
    if std::env::var("NO_PIN").is_ok() {
        return false;
    }
    std::env::var("PIN").map(|v| v == "1").unwrap_or(false)
}

/// Builds the affinity assignments for net reactors and PG drivers.
pub fn build_affinity_map(
    net_threads: usize,
    pg_threads: usize,
) -> (Vec<Option<usize>>, Vec<Option<usize>>, String) {
    let total_pinned = net_threads + pg_threads;

    if !is_pin_enabled() {
        let net_pins = vec![None; net_threads];
        let pg_pins = vec![None; pg_threads];
        let note = if std::env::var("NO_PIN").is_ok() {
            "disabled via NO_PIN"
        } else {
            "pinning: off (set PIN=1 to enable)"
        };
        let log = format_affinity_map(&net_pins, &pg_pins, note);
        return (net_pins, pg_pins, log);
    }

    let allowed_cpus = get_allowed_cpus();
    let topology = read_system_topology();

    let placement = compute_thread_placement(&topology, &allowed_cpus, total_pinned);

    let net_pins: Vec<Option<usize>> = placement[..net_threads].to_vec();
    let pg_pins: Vec<Option<usize>> = placement[net_threads..total_pinned].to_vec();

    let note = if total_pinned > allowed_cpus.len() {
        format!("fallback: threads {} > allowed CPUs {}", total_pinned, allowed_cpus.len())
    } else {
        format!("pinned across {} allowed CPUs", allowed_cpus.len())
    };

    let log = format_affinity_map(&net_pins, &pg_pins, &note);
    (net_pins, pg_pins, log)
}

pub fn spawn_worker<F>(
    name: &str,
    cpu_id: Option<usize>,
    policy: SchedPolicy,
    f: F,
) -> std::io::Result<std::thread::JoinHandle<()>>
where
    F: FnOnce() + Send + 'static,
{
    std::thread::Builder::new().name(name.to_string()).spawn(move || {
        if let Some(cpu) = cpu_id {
            pin_current_thread(cpu);
        }

        apply_sched_policy(policy);
        f();
    })
}

pub fn pin_current_thread(cpu_id: usize) {
    if !is_pin_enabled() {
        return;
    }
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_SET(cpu_id, &mut set);
        libc::pthread_setaffinity_np(
            libc::pthread_self(),
            std::mem::size_of::<libc::cpu_set_t>(),
            &set,
        );
    }
}

pub fn apply_sched_policy(policy: SchedPolicy) {
    if !is_pin_enabled() {
        return;
    }
    unsafe {
        match policy {
            SchedPolicy::Batch => {
                let param = libc::sched_param { sched_priority: 0 };
                libc::sched_setscheduler(0, libc::SCHED_BATCH, &param);
            }
            SchedPolicy::Idle => {
                let param = libc::sched_param { sched_priority: 0 };
                let rc = libc::sched_setscheduler(0, libc::SCHED_IDLE, &param);
                if rc != 0 {
                    // Fallback to nice 19 if SCHED_IDLE requires capabilities
                    libc::nice(19);
                }
            }
            SchedPolicy::Normal => {}
        }
    }
}

/// Block until `fd` (an eventfd) is readable or `timeout_ms` passes, then drain it. Safe on non-blocking eventfds.
pub fn wait_eventfd(fd: libc::c_int, timeout_ms: i32) {
    let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    unsafe {
        libc::poll(&mut pfd, 1, timeout_ms);
        let mut v: u64 = 0;
        libc::read(fd, &mut v as *mut u64 as *mut libc::c_void, 8);
    }
}

pub fn create_eventfd() -> std::io::Result<libc::c_int> {
    unsafe {
        let fd = libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC);
        if fd < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(fd)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_placement_4_cores_2_smt() {
        // 4 cores x 2 SMT siblings = 8 logical CPUs
        // Core 0: CPUs 0, 1
        // Core 1: CPUs 2, 3
        // Core 2: CPUs 4, 5
        // Core 3: CPUs 6, 7
        let topo = vec![
            CpuInfo { package_id: 0, core_id: 0, cpu_id: 0 },
            CpuInfo { package_id: 0, core_id: 0, cpu_id: 1 },
            CpuInfo { package_id: 0, core_id: 1, cpu_id: 2 },
            CpuInfo { package_id: 0, core_id: 1, cpu_id: 3 },
            CpuInfo { package_id: 0, core_id: 2, cpu_id: 4 },
            CpuInfo { package_id: 0, core_id: 2, cpu_id: 5 },
            CpuInfo { package_id: 0, core_id: 3, cpu_id: 6 },
            CpuInfo { package_id: 0, core_id: 3, cpu_id: 7 },
        ];
        let allowed = vec![0, 1, 2, 3, 4, 5, 6, 7];

        // 4 threads: must be assigned one per physical core
        let p4 = compute_thread_placement(&topo, &allowed, 4);
        assert_eq!(p4, vec![Some(0), Some(2), Some(4), Some(6)]);

        // 6 threads: 4 on distinct physical cores, next 2 on SMT siblings
        let p6 = compute_thread_placement(&topo, &allowed, 6);
        assert_eq!(p6, vec![Some(0), Some(2), Some(4), Some(6), Some(1), Some(3)]);

        // 8 threads: all 8 CPUs utilized with zero duplicates
        let p8 = compute_thread_placement(&topo, &allowed, 8);
        assert_eq!(p8, vec![Some(0), Some(2), Some(4), Some(6), Some(1), Some(3), Some(5), Some(7)]);
    }

    #[test]
    fn test_placement_8_cores_no_smt() {
        // 8 physical cores, 1 logical CPU per core
        let mut topo = Vec::new();
        for i in 0..8 {
            topo.push(CpuInfo { package_id: 0, core_id: i, cpu_id: i });
        }
        let allowed: Vec<usize> = (0..8).collect();

        let p4 = compute_thread_placement(&topo, &allowed, 4);
        assert_eq!(p4, vec![Some(0), Some(1), Some(2), Some(3)]);

        let p8 = compute_thread_placement(&topo, &allowed, 8);
        assert_eq!(p8, (0..8).map(Some).collect::<Vec<_>>());
    }

    #[test]
    fn test_placement_2_cpus_smt() {
        // 1 physical core, 2 SMT siblings
        let topo = vec![
            CpuInfo { package_id: 0, core_id: 0, cpu_id: 0 },
            CpuInfo { package_id: 0, core_id: 0, cpu_id: 1 },
        ];
        let allowed = vec![0, 1];

        let p1 = compute_thread_placement(&topo, &allowed, 1);
        assert_eq!(p1, vec![Some(0)]);

        let p2 = compute_thread_placement(&topo, &allowed, 2);
        assert_eq!(p2, vec![Some(0), Some(1)]);
    }

    #[test]
    fn test_placement_2_cpus_no_smt() {
        // 2 physical cores, 1 CPU each
        let topo = vec![
            CpuInfo { package_id: 0, core_id: 0, cpu_id: 0 },
            CpuInfo { package_id: 0, core_id: 1, cpu_id: 1 },
        ];
        let allowed = vec![0, 1];

        let p2 = compute_thread_placement(&topo, &allowed, 2);
        assert_eq!(p2, vec![Some(0), Some(1)]);
    }

    #[test]
    fn test_placement_fallback_when_threads_exceed_cpus() {
        // 4 allowed CPUs, 5 threads requested -> fall back to unpinned
        let topo = vec![
            CpuInfo { package_id: 0, core_id: 0, cpu_id: 0 },
            CpuInfo { package_id: 0, core_id: 1, cpu_id: 1 },
            CpuInfo { package_id: 0, core_id: 2, cpu_id: 2 },
            CpuInfo { package_id: 0, core_id: 3, cpu_id: 3 },
        ];
        let allowed = vec![0, 1, 2, 3];

        let p5 = compute_thread_placement(&topo, &allowed, 5);
        assert_eq!(p5, vec![None, None, None, None, None]);
    }

    #[test]
    fn test_placement_partial_affinity() {
        // 8 CPUs total, but taskset restricted to cpus 2, 3, 6, 7 (cores 1 and 3)
        let topo = vec![
            CpuInfo { package_id: 0, core_id: 0, cpu_id: 0 },
            CpuInfo { package_id: 0, core_id: 0, cpu_id: 1 },
            CpuInfo { package_id: 0, core_id: 1, cpu_id: 2 },
            CpuInfo { package_id: 0, core_id: 1, cpu_id: 3 },
            CpuInfo { package_id: 0, core_id: 2, cpu_id: 4 },
            CpuInfo { package_id: 0, core_id: 2, cpu_id: 5 },
            CpuInfo { package_id: 0, core_id: 3, cpu_id: 6 },
            CpuInfo { package_id: 0, core_id: 3, cpu_id: 7 },
        ];
        let allowed = vec![2, 3, 6, 7];

        // 2 threads: should pick 1 from core 1 (cpu2) and 1 from core 3 (cpu6)
        let p2 = compute_thread_placement(&topo, &allowed, 2);
        assert_eq!(p2, vec![Some(2), Some(6)]);

        // 3 threads: core 1 (cpu2), core 3 (cpu6), then core 1 sibling (cpu3)
        let p3 = compute_thread_placement(&topo, &allowed, 3);
        assert_eq!(p3, vec![Some(2), Some(6), Some(3)]);
    }

    #[test]
    fn test_format_affinity_map_output() {
        let net = vec![Some(0), Some(2)];
        let pg = vec![Some(4), Some(6)];
        let line = format_affinity_map(&net, &pg, "test");
        assert_eq!(
            line,
            "Thread affinity map: net-reactor-0->cpu0, net-reactor-1->cpu2, pg-driver-0->cpu4, pg-driver-1->cpu6, kdf->unpinned (test)"
        );
    }

    #[test]
    fn test_wait_eventfd() {
        let fd = create_eventfd().expect("create_eventfd");
        let start = std::time::Instant::now();
        let handle = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(20));
            let val: u64 = 1;
            unsafe {
                libc::write(fd, &val as *const u64 as *const libc::c_void, 8);
            }
        });

        wait_eventfd(fd, 1000);
        let elapsed = start.elapsed();
        handle.join().expect("join");
        assert!(
            elapsed < std::time::Duration::from_millis(200),
            "wait_eventfd should return in < 200 ms, took {:?}",
            elapsed
        );
        unsafe {
            libc::close(fd);
        }

        let fd2 = create_eventfd().expect("create_eventfd 2");
        let start2 = std::time::Instant::now();
        wait_eventfd(fd2, 30);
        let elapsed2 = start2.elapsed();
        assert!(
            elapsed2 >= std::time::Duration::from_millis(25)
                && elapsed2 < std::time::Duration::from_millis(150),
            "wait_eventfd on untouched fd should return after ~30 ms, took {:?}",
            elapsed2
        );
        unsafe {
            libc::close(fd2);
        }
    }

    #[test]
    fn test_pin_default_off() {
        std::env::remove_var("PIN");
        assert!(!is_pin_enabled());
        let (net, pg, log) = build_affinity_map(2, 2);
        assert_eq!(net, vec![None, None]);
        assert_eq!(pg, vec![None, None]);
        assert!(log.contains("pinning: off (set PIN=1 to enable)"));
    }
}
