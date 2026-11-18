# csharp-epoll-jit-gichamba

Front: direct

The C# server of [`csharp-epoll-aot-gichamba`](../csharp-epoll-aot-gichamba), built for the .NET JIT instead of
Native AOT. The source is identical; only the build differs. On our rig the two builds held the same load, so this
entry lets the benchmark decide which one is faster.

| | |
|---|---|
| Language | C# 14, .NET 10 (SDK 10.0.303, pinned by `global.json`), JIT with tiered PGO |
| HTTP | our own HTTP/1.1 server on edge-triggered epoll, keep-alive and pipelining |
| Postgres | our own client for protocol 3.0: extended query, binary results, pipelined, SCRAM-SHA-256 |
| bcrypt | Openwall crypt_blowfish 1.3, built from source, with our interleaved multi-password loop |
| Packages | none beyond the .NET SDK |

## Why a JIT build

Native AOT starts fast and carries no JIT, but its code is fixed at build time. The JIT recompiles the hot paths with
the profile it gathers while running (tiered PGO), so after warm-up it can produce better code for the paths this
workload uses. Which wins depends on the box, so both are submitted.

## Measured

On our own rig (an 8-vCPU Hyper-V VM with Postgres on tmpfs, and load from four VMs on the same host), 5-minute holds
at 136,000 users, one run each:

| | p95 | p99 |
|---|---:|---:|
| this entry (JIT) | 316 ms | 452 ms |
| `csharp-epoll-aot-gichamba` (Native AOT) | 253 ms | 395 ms |
| `rust-epoll-WorriedArrow` | 293 ms | 398 ms |

All three passed. At 145,000 the load VMs fell behind, so the rig could not find the ceiling. Only comparisons within
the same round mean anything; these are not challenge scores. The holds ran on an earlier build. Later changes to the
shared source were checked on the Native AOT build in interleaved runs at a lower load, and did not move latency beyond
run-to-run noise.

## Design, rules, settings and credits

All as in [`csharp-epoll-aot-gichamba`](../csharp-epoll-aot-gichamba/README.md): how a request flows, how each rule
is met, the latency trade-offs, behaviour under overload, the settings and the credits to other entries.

## Build

- `install.sh` (root, once): gcc, ICU and OpenSSL from apt, and the .NET SDK 10.0.303 from Microsoft's tarball, checked
  against its published SHA-512, into `/usr/local/lib/dotnet-sdk-10.0.303`. It waits for the apt lock, retries
  downloads, and is quick and safe to run again.
- `build.sh` (normal user): builds `libconduit_bcrypt.so` with gcc, then publishes the server to `out/` for the .NET
  runtime installed with the SDK.
- `start.sh`: raises the soft descriptor limit to the hard one, points `DOTNET_ROOT` at that runtime and runs
  `out/conduit` in the foreground.
