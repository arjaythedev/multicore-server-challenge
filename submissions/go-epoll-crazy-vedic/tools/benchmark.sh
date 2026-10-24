#!/usr/bin/env bash
# Local comparison harness. Same-host runs are exploratory, not official scores.
#   bash tools/benchmark.sh candidate my-run
#   bash tools/benchmark.sh baseline control-run
#   bash tools/benchmark.sh unshared no-sql-coalescing
#   BENCH_SOURCE=/path/to/snapshot bash tools/benchmark.sh snapshot snapshot-run
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VARIANT="${1:-candidate}"
LABEL="${2:-$VARIANT-$(date +%Y%m%d-%H%M%S)}"
[[ "$LABEL" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "invalid run label" >&2; exit 2; }
case "$VARIANT" in
  control) SOURCE="$HERE/.bench/optimization-control/source" ;;
  baseline) SOURCE="$ROOT/submissions/go-epoll-o7livetype" ;;
  snapshot) SOURCE="${BENCH_SOURCE:?snapshot variant requires BENCH_SOURCE}" ;;
  candidate|unshared) SOURCE="$HERE" ;;
  *) echo "usage: $0 control|baseline|snapshot|candidate|unshared [label]" >&2; exit 2 ;;
esac
TEMPLATE="${TEMPLATE:-conduit_seed}"
[[ "$TEMPLATE" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]] || { echo "invalid TEMPLATE" >&2; exit 2; }
OUT="$HERE/.bench/$LABEL"
mkdir -p "$HERE/.bench"
mkdir "$OUT" # refuse to overwrite prior evidence
mkdir "$OUT/source"
cp -a "$SOURCE/src" "$SOURCE/go.mod" "$SOURCE/go.sum" "$SOURCE/build.sh" "$OUT/source/"
SOURCE="$OUT/source"
export GOTOOLCHAIN=go1.27.2 CGO_ENABLED="${CGO_ENABLED:-1}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:--O3 -DNDEBUG -march=native}"
(cd "$SOURCE" && go build -trimpath -buildvcs=false -pgo="${PGO_PROFILE:-auto}" -o "$OUT/server" ./src)
(cd "$ROOT/bench" && go build -o "$OUT/loadgen" ./cmd/loadgen)
(cd "$SOURCE" && rg --files -g '*.go' -g '*.cc' -g '*.cpp' -g '*.h' -g '*.hpp' -g '*.mod' -g '*.sum' -g '*.sh' -g '*.pgo' | sort | xargs sha256sum) > "$OUT/sources.sha256"
git -C "$ROOT" rev-parse HEAD > "$OUT/base-commit.txt"
go version > "$OUT/toolchain.txt"
export GOMAXPROCS="${GOMAXPROCS:-4}" DB_READ_CONNS="${DB_READ_CONNS:-4}" DB_WRITE_CONNS="${DB_WRITE_CONNS:-2}"
export PIPELINE_DEPTH="${PIPELINE_DEPTH:-2}" READ_BATCH="${READ_BATCH:-32}" WRITE_BATCH="${WRITE_BATCH:-128}"
export MAX_CONNECTIONS="${MAX_CONNECTIONS:-190000}" STATS_INTERVAL=5s
if [ "$VARIANT" = unshared ]; then export READ_SQL_BATCH=0 READ_AFFINITY=0; fi
export HOST=127.0.0.1 PORT="${PORT:-3121}" JWT_SECRET=zenith-local-benchmark
export CPU_PROFILE="$OUT/cpu.pprof"
export MEMORY_PROFILE_DIR="$OUT/memory"
DB="zenith_bench_$$"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d postgres)
PID=""; MONITOR=""; LOADGEN_PID=""
cleanup() {
  if [ -n "$LOADGEN_PID" ]; then kill -TERM "$LOADGEN_PID" 2>/dev/null || true; wait "$LOADGEN_PID" 2>/dev/null || true; fi
  if [ -n "$PID" ]; then kill -TERM "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  if [ -n "$MONITOR" ]; then kill "$MONITOR" 2>/dev/null || true; wait "$MONITOR" 2>/dev/null || true; fi
  "${PSQL[@]}" -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"${PSQL[@]}" -c "CREATE DATABASE $DB TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
case "${PGHOST:-}" in ""|/*) DBHOST=127.0.0.1 ;; *) DBHOST="$PGHOST" ;; esac
export DATABASE_URL="postgres://conduit:conduit@$DBHOST:${PGPORT:-5432}/$DB"
python3 - "$VARIANT" "$TEMPLATE" > "$OUT/config.json" <<'PY'
import json, os, sys
keys = ('GOMAXPROCS','DB_READ_CONNS','DB_WRITE_CONNS','PIPELINE_DEPTH','READ_BATCH','WRITE_BATCH',
        'READ_SQL_BATCH','READ_AFFINITY','READ_LINGER','READ_ROUTE_SLACK','WRITE_LINGER','WRITE_FLUSH_INTERVAL','BCRYPT_WAIT','BCRYPT_WORKERS','CGO_ENABLED','SQL_METADATA_BATCH','FEED_RECENT_SCAN','FEED_SCAN_WINDOW','PG_FAVORITE_MODE','PG_PLAN_MODE','PG_LOCAL_TLS','PGO_PROFILE','GOGC','GOMEMLIMIT','USERS','THINK_SCALE','RAMP','WARMUP','MEASURE','TAIL')
json.dump(dict(variant=sys.argv[1],template=sys.argv[2],env={k:os.environ[k] for k in keys if k in os.environ}),sys.stdout,indent=2)
PY
"$OUT/server" > "$OUT/server.log" 2>&1 & PID=$!
for _ in $(seq 60); do
  if curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags"; then break; fi
  if ! kill -0 "$PID" 2>/dev/null; then cat "$OUT/server.log" >&2; exit 1; fi
  sleep 1
done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags"
python3 "$HERE/tools/monitor.py" "$PID" "$DB" "$OUT/database-waits.jsonl" > "$OUT/monitor.csv" & MONITOR=$!
ARTICLES=500000
if [ "$TEMPLATE" = conduit_dev ]; then ARTICLES=10000; fi
ARTICLES="${SEEDED_ARTICLES:-$ARTICLES}"
common=(-target "http://127.0.0.1:$PORT" -users "${USERS:-4000}" -secret "$JWT_SECRET" -articles "$ARTICLES" -think-scale "${THINK_SCALE:-1}")
"$OUT/loadgen" run "${common[@]}" -run-id "$LABEL-warm" -ramp "${RAMP:-10s}" -measure "${WARMUP:-30s}" -tail 2s -out "$OUT/warmup.json" & LOADGEN_PID=$!
wait "$LOADGEN_PID"
LOADGEN_PID=""
"$OUT/loadgen" run "${common[@]}" -run-id "$LABEL-measure" -ramp "${RAMP:-10s}" -measure "${MEASURE:-60s}" -tail "${TAIL:-5s}" -out "$OUT/box.json" & LOADGEN_PID=$!
wait "$LOADGEN_PID"
LOADGEN_PID=""
status=0
"$OUT/loadgen" merge -o "$OUT/merged.json" "$OUT/box.json" > "$OUT/merged.txt" 2>&1 || status=$?
cat "$OUT/merged.txt"
echo "Artifacts: $OUT"
exit "$status"
