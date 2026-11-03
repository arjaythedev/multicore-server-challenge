#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (SPEC.md).
# Optional: READ_LANES / READ_BATCH (read-batching connections, default one per core; requests per
# batch, default 512), READ_GATHER_MS (how long a request may wait for batch-mates, default
# 25), DB_POOL_SIZE (multiplexed connections for cold reads, default cores / 2),
# WRITE_LANES / WRITE_GROUP (group-commit connections, default 2; writes per group, default 128),
# BCRYPT_THREADS / BCRYPT_WIDTH / BCRYPT_GATHER_MS (bcrypt threads, default 2; hashes each computes in
# lockstep, default 4; how long a login may wait for batch-mates, default 150), STATS_SECONDS (a
# diagnostic line on stderr every that many seconds: GC, connections, queues; default 0, off).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export DOTNET_ROOT="${DOTNET_ROOT:-/usr/local/dotnet}" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
# Direct front: every user holds a keep-alive socket, so lift the soft descriptor limit to the hard one.
ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
# A 64 MB gen0 budget: each request allocates a few KB, and the default budget would run a gen0
# collection many times a second. The runtime reads this only from the environment.
export DOTNET_GCgen0size="${DOTNET_GCgen0size:-0x4000000}"
# Idle thread-pool workers spin before they sleep (13% of the app's CPU in a profile). Postgres
# shares these cores, so a worker with nothing to do should sleep at once.
export DOTNET_ThreadPool_UnfairSemaphoreSpinLimit="${DOTNET_ThreadPool_UnfairSemaphoreSpinLimit:-0}"
DOTNET="$DOTNET_ROOT/dotnet"
[ -x "$DOTNET" ] || DOTNET=dotnet
exec "$DOTNET" "$DIR/out/Web.dll"
