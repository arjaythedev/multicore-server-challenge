#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (SPEC.md).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# the runtime install.sh put in /usr/local/dotnet (a preset DOTNET_ROOT may point at an older runtime)
if [ -x /usr/local/dotnet/dotnet ]; then export DOTNET_ROOT=/usr/local/dotnet
elif [ -z "${DOTNET_ROOT:-}" ]; then export DOTNET_ROOT="$(dirname "$(readlink -f "$(command -v dotnet)")")"; fi
# Socket completions run inline on the epoll threads instead of hopping to the thread pool: a request is parsed and
# queued for Postgres on the thread that received it. W^X off: cheaper JIT/stub patching.
export DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS="${DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS:-1}"
export DOTNET_EnableWriteXorExecute="${DOTNET_EnableWriteXorExecute:-0}"
export DOTNET_TieredPGO=1
# idle thread-pool workers sleep instead of spinning (the pool only runs timers here)
export DOTNET_ThreadPool_UnfairSemaphoreSpinLimit="${DOTNET_ThreadPool_UnfairSemaphoreSpinLimit:-0}"
exec "$HERE/out/conduit"
