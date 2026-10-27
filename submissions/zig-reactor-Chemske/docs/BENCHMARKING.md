# From Mac measurements to an Ubuntu benchmark

## What the Mac tests establish

My development machine is an Apple A18 Pro with two performance cores, four efficiency cores and 8 GiB RAM. It runs the application, PostgreSQL and generator together. The official target is Ubuntu 24.04 x86_64 with eight dedicated vCPUs and 16 GB, with PostgreSQL on the target and generators on separate machines. The published resource contract does not identify an exact CPU model or disk, so matching vCPU/RAM alone cannot reproduce the same machine.

The socket check opens 8,000 actual connections and replaces 4,000. This establishes socket/lifetime behaviour, not 8,000 browsing users or a 100,000-user score. The initial full-seed five-minute stress hold uses 512 users with think/session times multiplied by 0.005. It records 8,561.8 requests/s, p95 61.631 ms, p99 96.063 ms and 403 errors out of 2,568,539 requests. These are the earlier sixteen-job password-queue results; later selected-build measurements are recorded separately in PERFORMANCE.md.

The generator's `-think-scale` is explicitly a testing switch. Scaling its clocks does not scale request service times, PostgreSQL work, socket counts or the number of simultaneously browsing identities. Therefore `512 / 0.005 = 102400` must not be reported as an official user count.

The final 64-job build adds two later full-seed five-minute results:

| Test | Actual virtual users | Think/session scale | Requests/s | p95 ms | p99 ms | Errors / requests |
|---|---:|---:|---:|---:|---:|---:|
| Normal-clock browsing | 8,000 | 1 | 2,123.1 | 1.251 | 3.659 | 0 / 636,920 |
| Accelerated stress | 512 | 0.005 | 9,390.8 | 52.351 | 78.079 | 12 / 2,817,230 |

The first establishes at least 8,000 actual users in a native co-located Mac hold. It is not a searched maximum. Its observed rate is 0.265383 requests/s/user. Applying that traffic rate to the accelerated throughput gives about 35,386 normal users' request traffic. This does not reproduce that many sockets, their full normal session model, or an Ubuntu capacity score.

## A useful calculation, with limits

The official model has a mean seven-second think time and roughly 1.8–1.9 API calls per page. At modest page latency this is approximately 0.25–0.27 requests per second per user. A throughput-equivalent browsing population is therefore:

`browsing-equivalent users ≈ measured requests/s / (0.25 to 0.27)`

For the initial 8,561.8 requests/s hold, that is about 31,700–34,200 users' browsing traffic. It is a demand conversion, not a tested population, capacity ceiling or prediction of Ubuntu performance. That many actual sockets were not opened on the Mac.

Authentication tells a different story. The same hold attempts 8,376 logins and 159 registrations over 300 seconds: 28.45 bcrypt requests/s. In the normal model, 25% of session starts require bcrypt and the mean session is 900 seconds. Ignoring the smaller closed-model session-overrun effects, that rate resembles `28.45 × 900 / 0.25 = 102420` normal users' authentication demand. The accelerated test combines about 32,000 users' browsing throughput with about 100,000 users' password-attempt rate. There is no single conversion factor for the whole test. Accepted work and rejected attempts must also remain distinct.

Conditional scenarios help plan a real test:

| Sustained Ubuntu throughput, if measured | Approximate normal browsing demand at 0.25–0.27 requests/s/user |
|---:|---:|
| 9,400 requests/s | 35,000–38,000 users |
| 12,000 requests/s | 44,000–48,000 users |
| 18,000 requests/s | 67,000–72,000 users |
| 26,300 requests/s | 97,000–105,000 users |

These are scenarios, not predicted speedups. The official leading 100,000-user run reports 26,279 requests/s, p95 119 ms and p99 185 ms. Reaching that scale would require about 2.8 times the final accelerated Mac throughput plus the actual connection count, correct normal workload and passing five-minute latency/error verdict. The maximum sustainable user count has not been searched on the Mac.

Neither multiplying by `8/6` nor doubling for `16/8 GB` is valid. Apple performance/efficiency cores differ from x86 execution threads, and the Mac generator consumes part of the same CPU budget. The full seed is about 2.3 GiB and already benefits from the Mac's filesystem cache, so extra RAM is not an automatic twofold speedup. The official PostgreSQL buffer/work-memory settings differ. x86 bcrypt/SHA code, epoll versus kqueue, disk/WAL commit latency and network RTT also differ. Tail latency rises nonlinearly near saturation; p95/p99 cannot be divided by a core-count ratio.

## Practical Ubuntu options

1. **Challenge GitHub CI:** best first installation/correctness gate. The existing workflow uses Ubuntu 24.04 and PostgreSQL 18, installs the submission and runs the unchanged development-seed conformance suite. It does not establish official capacity. No local Linux VM is needed.
2. **Short-lived Oracle Cloud x86 test:** useful for full-data performance and Linux runtime validation. Choose Ubuntu 24.04 x86_64 with VM.Standard.E5.Flex or E6.Flex, four OCPUs and 16 GB RAM. On these AMD x86 shapes one OCPU is two vCPUs, so four OCPUs provide eight vCPUs. This matches the resource profile, not necessarily the organiser's CPU/disk performance.
3. **An existing Ubuntu x86 machine with sufficient resources:** useful if available, while recording its real CPU, storage and isolation. An ARM Ubuntu machine can test Linux behaviour but cannot validate the current x86-only installer or stand in for the official x86 target.

Oracle's free AMD micro shape has only 1 GB RAM and limited CPU; it cannot reproduce this target. The free Ampere A1 shape is ARM, so it is not the final x86 benchmark choice. A paid test may use account trial credits if eligible, but availability and credits must be checked in the user's console. No cloud resource has been created by this research.

## Small Oracle test layout

Use one temporary target with eight vCPUs/16 GB and a normal SSD boot/block volume, plus separate generators in the same region/private network. Start with one generator for lower-load probes; for 100,000-plus direct connections use two generators with distinct source addresses, or explicitly configure multiple target addresses. One source/destination IP/port tuple cannot supply 100,000 simultaneous TCP source ports. The upstream tools support split generators and multiple target URLs.

A simple starting layout is one E5/E6 target (4 OCPU, 16 GB) and two small E5/E6 generators (1 OCPU, 4 GB each). Each generator must remain below the upstream CPU/lag thresholds; add capacity if flagged. More generator capacity does not count against the target's eight-vCPU budget. Only the target runs PostgreSQL and the application.

Using Oracle's published E5/E6 list rates of $0.03/OCPU-hour and $0.002/GB-hour, the target is about $0.152/hour for CPU/RAM; that example three-VM layout is about $0.228/hour. These are indicative USD compute/memory arithmetic, not a quote or spending cap. Storage, performance tiers, network, taxes, region availability and the current console estimate must be checked before provisioning. Stop/delete the dedicated instances and their unused volumes after preserving evidence. No local Oracle CLI or virtualisation software is required: the console and the Mac's existing SSH suffice.

## Reproduce the challenge before measuring

On a fresh temporary target, use the unchanged `box/setup-box.sh` rather than inventing database/kernel tuning. It installs PostgreSQL 18, the official derived PostgreSQL settings, limits, service account and foreground service with `Restart=no`. Nginx is stopped for this direct submission. Provision enough disk for the seed, one clone, temporary generation files, toolchain and WAL; 50–64 GB is ample for this project layout, subject to the image's minimum volume size.

Install the pinned benchmark Go toolchain required by `bench/go.mod`; the submission's installer installs Zig/libpq, not the benchmark generator. Then use the unchanged seed/fingerprint checks, `score/install-tools.sh`, `score/prepare.sh` and `score/switch.sh`. The latter runs full-seed conformance, resets the benchmark database, restarts PostgreSQL and clears page cache before the normal warm-up. The setup's printed versions record the real CPU model, kernel, database and memory. Keep SSH/admin access and test HTTP restricted to the intended management/generator addresses; PostgreSQL stays on target loopback.

Use the unchanged `loadgen search` at `-think-scale=1` with separate generators: three-minute warm-up, doubling probes, narrowing to 5%, then a five-minute hold and 5% step-down if necessary. Keep every failure and generator-limit flag. Record application/PostgreSQL CPU separately, CPU steal, process/host memory, descriptor counts and latency histograms. A generator-limited run is not a server capacity result.

To improve transfer to the organiser's unknown hardware, run the unchanged leading Rust submission on the same temporary cloud target as a calibration control. Compare sustainable scores with identical setup and fresh seeds. A provisional ratio `100000 × (our cloud score / Rust cloud score)` is more informative than a raw core-count multiplier, but still assumes similar hardware sensitivity and cannot guarantee an official score. Repeat the decisive holds to assess noise. The organiser's own benchmark remains authoritative.

## Primary sources

- [Challenge rules and scoring](https://github.com/arjaythedev/multicore-server-challenge/blob/main/README.md)
- [Workload and normal think/session times](https://github.com/arjaythedev/multicore-server-challenge/blob/main/WORKLOAD.md)
- [Official leaderboard](https://github.com/arjaythedev/multicore-server-challenge/blob/main/LEADERBOARD.md)
- [Generator and search instructions](https://github.com/arjaythedev/multicore-server-challenge/blob/main/bench/README.md)
- [Oracle compute shapes and OCPU/vCPU mapping](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm)
- [Oracle Ubuntu images](https://docs.oracle.com/en-us/iaas/Content/Compute/References/images.htm)
- [Oracle Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
- [Oracle E5/E6 published rates](https://blogs.oracle.com/cloud-infrastructure/oci-launches-e6-standard-compute-powered-by-amd)

Sources checked on 25 October 2026. No paid resource is provisioned, and no score prediction is presented as a measurement.
