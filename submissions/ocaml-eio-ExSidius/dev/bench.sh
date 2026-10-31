#!/usr/bin/env bash
# Repeatable local load tests. Every run gets a directory under dev/results/ and one line per measurement in
# dev/history.tsv, so a change can be compared with what came before it.
#
#   dev/tools.sh dev/bench.sh smoke                # ~1 min: dev seed, 3,000 users at 5x speed. Does it hold up at all?
#   dev/tools.sh dev/bench.sh probe 20000 40000    # full seed, one 60 s ramp + 60 s measure per user count
#   dev/tools.sh dev/bench.sh search               # ~30 min: warm-up, doubling, bisection to 5%, 5-minute hold
#
# Options come from the environment: LABEL, WORKERS, BCRYPT_THREADS, PG_CONNECTIONS, VUS_PER_BOX, START_USERS, THINK_SCALE (probes only, to compare with older runs).
#
# How this differs from the official score, and why local numbers are only comparable with each other: one machine,
# with the target pinned to 8 hardware threads and the load generators to the other CCD. The CPU is not the benchmark
# box's, and loopback replaces the network.
#
# Every user holds a real connection. This machine has about 28k ephemeral ports per target address, and the sysctl
# that widens that needs root, so one load generator runs per VUS_PER_BOX users, each against its own 127.0.0.x.
set -euo pipefail
. "$(dirname "$0")/env.sh"

VUS_PER_BOX="${VUS_PER_BOX:-20000}"
JWT_SECRET=multicore-server-challenge
PORT="${PORT:-3180}"
RESULTS="$DEV_DIR/results"
HISTORY="$DEV_DIR/history.tsv"
SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
[ -z "$(git -C "$ROOT_DIR" status --porcelain -- "$SUB_DIR/src")" ] || SHA="$SHA+dirty"
HISTORY_HEADER="time	commit	label	seed	phase	workers	pg_conns	users	boxes	think_scale	req_s	p50_ms	p95_ms	p99_ms	errors_pct	verdict	lg_limited	app_cpu_pct	pg_cpu_pct	app_rss_mb	dir"

server_pid=""
run_db=""
cleanup() {
  [ -z "$server_pid" ] || { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
  [ -z "$run_db" ] || psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $run_db WITH (FORCE)" || true
}
trap cleanup EXIT

prepare() { # template seed-label articles
  TEMPLATE="$1"; SEED="$2"; ARTICLES="$3"
  bash "$DEV_DIR/pg.sh" up >/dev/null
  [ "$(psql -X -Atd postgres -c "SELECT count(*) FROM pg_database WHERE datname = '$TEMPLATE'")" = 1 ] || {
    echo "no database $TEMPLATE: run dev/tools.sh bash seed/make-seed.sh"; exit 1; }
  (cd "$ROOT_DIR/bench" && go build -o "$BENCH_HOME/loadgen" ./cmd/loadgen)
  bash "$SUB_DIR/build.sh"
  RUN_ID="$(date +%Y%m%d-%H%M%S)-$SHA${LABEL:+-$LABEL}"
  RUN_DIR="$RESULTS/$RUN_ID"
  mkdir -p "$RUN_DIR"
  run_db="bench_$$"
  psql -X -q -d postgres -c "CREATE DATABASE $run_db TEMPLATE $TEMPLATE"
  psql -X -q -d "$run_db" -c "VACUUM ANALYZE" >/dev/null
  DATABASE_URL="postgres://conduit:conduit@127.0.0.1:$PGPORT/$run_db" JWT_SECRET="$JWT_SECRET" HOST=0.0.0.0 PORT="$PORT" \
    taskset -c "$TARGET_CPUS" bash "$SUB_DIR/start.sh" > "$RUN_DIR/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 60); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 1; done
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" || { echo "server didn't come up"; cat "$RUN_DIR/server.log"; exit 1; }
  { echo "commit $SHA"; echo "loadavg $(cat /proc/loadavg)"; echo "cpus target=$TARGET_CPUS loadgen=$LOADGEN_CPUS"
    env | command grep -E '^(WORKERS|BCRYPT_THREADS|PG_CONNECTIONS|OCAMLRUNPARAM)=' || true; } > "$RUN_DIR/meta.txt"
}

# Total CPU ticks of a set of pids.
ticks() { local t=0 p; for p in "$@"; do
    if [ -r "/proc/$p/stat" ]; then
      t=$(( t + $(awk '{sub(/^.*\) /,""); print $12 + $13}' "/proc/$p/stat" 2>/dev/null || echo 0) )); fi
  done; echo "$t"; }
app_pids() { echo "$server_pid" $(pgrep -P "$server_pid" 2>/dev/null || true); }
pg_pids() { local pm; pm=$(head -1 "$PGDATA/postmaster.pid"); echo "$pm" $(pgrep -P "$pm" 2>/dev/null || true); }
app_rss_mb() { local t=0 p; for p in $(app_pids); do
    t=$(( t + $(awk '/VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0) )); done; echo $(( t / 1024 )); }

# run <phase> <users> <ramp> <measure> [think-scale]. Sets LAST_PASS.
run() {
  local phase="$1" users="$2" ramp="$3" measure="$4" scale="${5:-${THINK_SCALE:-1}}"
  local boxes=$(( (users + VUS_PER_BOX - 1) / VUS_PER_BOX )) dir="$RUN_DIR/$phase-$users" start_at i pids=() files=()
  mkdir -p "$dir"
  start_at=$(( $(date +%s%3N) + 2000 ))
  for (( i = 0; i < boxes; i++ )); do
    local n=$(( i + 1 < boxes ? VUS_PER_BOX : users - i * VUS_PER_BOX ))
    taskset -c "$LOADGEN_CPUS" "$BENCH_HOME/loadgen" run -target "http://127.0.0.$(( i + 1 )):$PORT" -users "$n" \
      -box-index "$i" -id-offset "$(( i * VUS_PER_BOX ))" -ramp "${ramp}s" -measure "${measure}s" -tail 15s \
      -start-at "$start_at" -secret "$JWT_SECRET" -run-id "$(date +%s)" -articles "$ARTICLES" -think-scale "$scale" -q \
      -out "$dir/box$i.json" > "$dir/loadgen$i.log" 2>&1 &
    pids+=($!); files+=("$dir/box$i.json")
  done
  # loadgen starts its ramp 2 s after launch; CPU is sampled over the measured window only.
  sleep $(( ramp + 2 ))
  local a0 p0 t0 a1 p1 t1 rss
  a0=$(ticks $(app_pids)); p0=$(ticks $(pg_pids)); t0=$(date +%s.%N)
  sleep "$measure"
  a1=$(ticks $(app_pids)); p1=$(ticks $(pg_pids)); t1=$(date +%s.%N)
  rss=$(app_rss_mb)
  for i in "${pids[@]}"; do wait "$i" || { echo "loadgen failed:"; cat "$dir"/loadgen*.log; return 1; }; done
  kill -0 "$server_pid" 2>/dev/null || { echo "server died:"; tail -20 "$RUN_DIR/server.log"; return 1; }
  local rc=0
  "$BENCH_HOME/loadgen" merge -o "$dir/merged.json" "${files[@]}" > "$dir/merged.txt" 2>&1 || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { echo "merge failed ($rc)"; cat "$dir/merged.txt"; return 1; }
  LAST_PASS=$([ "$rc" = 0 ] && echo 1 || echo 0)
  local hz app_pct pg_pct line
  hz=$(getconf CLK_TCK)
  app_pct=$(awk "BEGIN{printf \"%.0f\", ($a1-$a0)/$hz/($t1-$t0)/8*100}")
  pg_pct=$(awk "BEGIN{printf \"%.0f\", ($p1-$p0)/$hz/($t1-$t0)/8*100}")
  line=$(jq -r '[(.overall.rps | round), .overall.p50_ms, .overall.p95_ms, .overall.p99_ms, (.overall.error_rate * 100), (if .verdict.pass then "PASS" else "FAIL" end), .verdict.lg_limited] | @tsv' "$dir/merged.json")
  [ -f "$HISTORY" ] || echo "$HISTORY_HEADER" > "$HISTORY"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$SHA" "${LABEL:-}" "$SEED" "$phase" \
    "${WORKERS:-6}+${BCRYPT_THREADS:-2}" "${PG_CONNECTIONS:-30}" "$users" "$boxes" "$scale" "$line" "$app_pct" "$pg_pct" "$rss" "$RUN_ID" >> "$HISTORY"
  printf '%-8s users=%-7s boxes=%-3s scale=%-4s | %s | app %s%% pg %s%% rss %sMB\n' "$phase" "$users" "$boxes" "$scale" "$(tr '\t' ' ' <<<"$line")" "$app_pct" "$pg_pct" "$rss" | tee -a "$RUN_DIR/summary.txt"
  if [ "$(jq -r .verdict.lg_limited "$dir/merged.json")" = true ]; then
    echo "load generator limited at $users: this result says nothing about the server" | tee -a "$RUN_DIR/summary.txt"; LG_LIMITED=1
  fi
  sleep 30
}

two_sig() { awk -v n="$1" 'BEGIN{ m=1; while (n/m >= 100) m*=10; printf "%d", int(n/m+0.5)*m }'; }

LG_LIMITED=0
case "${1:-}" in
  smoke)
    prepare conduit_dev dev 10000
    run smoke 3000 10 30 0.2 ;;
  probe)
    shift; [ $# -gt 0 ] || { echo "usage: bench.sh probe <users>..."; exit 2; }
    prepare conduit_seed full 500000
    run warmup 1000 30 60 1
    for u in "$@"; do run probe "$u" 60 60; done ;;
  search)
    prepare conduit_seed full 500000
    run warmup 500 60 120 1
    users="${START_USERS:-5000}"; pass=0; fail=0
    while :; do
      run probe "$users" 60 60; [ "$LG_LIMITED" = 0 ] || exit 1
      if [ "$LAST_PASS" = 1 ]; then pass=$users; users=$(two_sig $(( users * 2 )))
      else fail=$users; break; fi
    done
    while [ "$pass" -gt 0 ] && [ $(( (fail - pass) * 100 )) -gt $(( pass * 5 )) ]; do
      users=$(two_sig $(( (pass + fail) / 2 )))
      { [ "$users" -le "$pass" ] || [ "$users" -ge "$fail" ]; } && break
      run probe "$users" 60 60; [ "$LG_LIMITED" = 0 ] || exit 1
      if [ "$LAST_PASS" = 1 ]; then pass=$users; else fail=$users; fi
    done
    [ "$pass" -gt 0 ] || { echo "no probe passed" | tee -a "$RUN_DIR/summary.txt"; exit 1; }
    users=$pass
    while :; do
      run hold "$users" 60 300; [ "$LG_LIMITED" = 0 ] || exit 1
      if [ "$LAST_PASS" = 1 ]; then echo "LOCAL SCORE: $users users" | tee -a "$RUN_DIR/summary.txt"; break; fi
      users=$(two_sig $(( users * 95 / 100 )))
    done ;;
  *) sed -n 2,8p "$0"; exit 2 ;;
esac
echo "results: $RUN_DIR"
