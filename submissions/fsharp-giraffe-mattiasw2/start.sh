#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (SPEC.md).
# Optional: READ_LANES / READ_BATCH (read-batching connections, default one per core; requests per
# batch, default 2048), READ_SHARE_MIN (a lane's fair share of what waits: at least this,
# default 64; 0 takes everything up to READ_BATCH), READ_GATHER_MS (how long a request may wait for batch-mates, default
# 25), DB_POOL_SIZE (multiplexed connections for cold reads, default cores / 2),
# WRITE_LANES / WRITE_GROUP (group-commit connections, default (cores + 2) / 4; writes per group, default 128),
# WRITE_GROUP_MIN / WRITE_GATHER_MS (a smaller group waits for company until its oldest write has waited
# that long; defaults 8 and 2, 0 never waits),
# BCRYPT_THREADS / BCRYPT_WIDTH / BCRYPT_KERNEL / BCRYPT_GATHER_MS (bcrypt threads, default (cores + 2) / 4; hashes each
# computes in lockstep, 1 to 6, default 0: the width this CPU hashes fastest at; the kernel, c, ah, bextr or shrx, by
# default the fastest, timed at startup; how long a login may wait for batch-mates, default 150), STATS_SECONDS (a
# diagnostic line on stderr every that many seconds: GC, connections, queues; default 0, off),
# PHASES_FILE (with STATS_SECONDS: where each request's time went, appended at every stats line),
# BATCH_LOG (a prefix: a 25 ms timeline of CPU, GC and queues, a log of every read batch and every GC pause, written at
# shutdown; BATCH_LOG_MS, BATCH_LOG_PG_CGROUP: Postgres's cgroup cpu.stat),
# PG_OPTIONS (replaces the Postgres session settings in src/Engine/Db.fs), SCHED_BATCH (0: run
# under the default scheduling policy). GC: DOTNET_gcServer=0 (workstation GC), DOTNET_gcConcurrent=0 or
# DOTNET_GCHeapCount=N override the GC settings in Web.fsproj.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export DOTNET_ROOT="${DOTNET_ROOT:-/usr/local/dotnet}" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
# Direct front: every user holds a keep-alive socket, so lift the soft descriptor limit to the hard one.
ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
# A 64 MB gen0 budget: each request allocates a few KB, and the default budget would run a gen0
# collection many times a second. The runtime reads this only from the environment.
export DOTNET_GCgen0size="${DOTNET_GCgen0size:-0x4000000}"
# Objects up to 1 MB (not 85 KB) go to gen0: ~5 MB/s of short-lived large objects otherwise fill the
# large-object heap, and only a full gen2 frees it (~500 ms, marking and compacting a 1.1 GB gen2).
export DOTNET_GCLOHThreshold="${DOTNET_GCLOHThreshold:-0x100000}"
# Idle thread-pool workers spin before they sleep (13% of the app's CPU in a profile). Postgres
# shares these cores, so a worker with nothing to do should sleep at once.
export DOTNET_ThreadPool_UnfairSemaphoreSpinLimit="${DOTNET_ThreadPool_UnfairSemaphoreSpinLimit:-0}"
DOTNET="$DOTNET_ROOT/dotnet"
[ -x "$DOTNET" ] || DOTNET=dotnet
# SCHED_BATCH (inherited by every thread; no privileges needed): our threads wake constantly, and
# under the default policy each wakeup may preempt a busy Postgres backend. As in
# java-raw-stohirov and kotlin-native-luben93. SCHED_BATCH=0 runs under the default policy.
if [ "${SCHED_BATCH:-1}" != 0 ] && command -v chrt >/dev/null; then
  exec chrt --batch 0 "$DOTNET" "$DIR/out/Web.dll"
fi
exec "$DOTNET" "$DIR/out/Web.dll"
