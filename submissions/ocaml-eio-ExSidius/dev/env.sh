# Shared settings for the dev scripts. The target (server + Postgres) gets 8 hardware threads on 4 physical cores,
# like the 8 vCPU box; the load generator gets the other CCD, so it never competes with the target.
export BENCH_HOME="${BENCH_HOME:-$HOME/.local/share/multicore-bench}"
export PGDATA="$BENCH_HOME/pg18"
export PGHOST=127.0.0.1 PGPORT="${PGPORT:-55432}" PGUSER=postgres PGPASSWORD=postgres
export TARGET_CPUS="${TARGET_CPUS:-0-3,16-19}" LOADGEN_CPUS="${LOADGEN_CPUS:-8-15,24-31}"
DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$(dirname "$DEV_DIR")"
ROOT_DIR="$(cd "$SUB_DIR/../.." && pwd)"
export DEV_DIR SUB_DIR ROOT_DIR
