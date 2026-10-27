#!/usr/bin/env bash
# Source this file in a terminal; all generated files stay in the workspace.
if [ -n "${BASH_VERSION:-}" ]; then
    challenge_env_file="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
    challenge_env_file="${(%):-%x}"
else
    echo 'Source dev/env.sh from Bash or Zsh.' >&2
    return 1
fi
CHALLENGE_SUBMISSION="$(cd "$(dirname "$challenge_env_file")/.." && pwd)"
CHALLENGE_REPO="$(cd "$CHALLENGE_SUBMISSION/../.." && pwd)"
CHALLENGE_WORK="${CHALLENGE_WORK:-$(cd "$CHALLENGE_REPO/.." && pwd)/work}"
export CHALLENGE_SUBMISSION CHALLENGE_REPO CHALLENGE_WORK
export PGROOT="$CHALLENGE_WORK/tools/postgresql-18.6"
export PATH="$PGROOT/bin:$CHALLENGE_WORK/tools/go/bin:$CHALLENGE_WORK/tools/gh_2.103.2_macOS_arm64/bin:$PATH"
export GOCACHE="$CHALLENGE_WORK/cache/go-build" GOMODCACHE="$CHALLENGE_WORK/cache/go-mod"
export GOPATH="$CHALLENGE_WORK/cache/go-path" GOTOOLCHAIN=local
export ZIG_GLOBAL_CACHE_DIR="$CHALLENGE_WORK/cache/zig-global"
export ZIG_LOCAL_CACHE_DIR="$CHALLENGE_WORK/cache/zig-local"
export TMPDIR="$CHALLENGE_WORK/tmp" PSQL_HISTORY="$CHALLENGE_WORK/runtime/psql_history"
export PYTHONDONTWRITEBYTECODE=1
export PGDATA="$CHALLENGE_WORK/runtime/postgres-18"
export PGHOST=127.0.0.1 PGPORT=55432 PGUSER=challenge_admin PGDATABASE=postgres
# Disposable local development credentials; never used outside this cluster.
export PGPASSWORD=challenge-local-admin
export DATABASE_URL="${DATABASE_URL:-postgres://conduit:conduit@127.0.0.1:55432/conduit_local}"
export JWT_SECRET="${JWT_SECRET:-local-development-only}" HOST="${CHALLENGE_HOST:-127.0.0.1}" PORT="${CHALLENGE_PORT:-3000}"
mkdir -p "$GOCACHE" "$GOMODCACHE" "$GOPATH" "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR" "$TMPDIR" "$CHALLENGE_WORK/runtime" "$CHALLENGE_WORK/logs"
unset challenge_env_file
