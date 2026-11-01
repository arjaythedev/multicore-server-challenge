#!/usr/bin/env bash
# Runs a batch of submissions one after another, unattended. Run ON the load generator (it has an ssh key into the
# target), under nohup. The submission folders must already be on the target in /opt/challenge/subs/<name>
# (score/push.sh).
#
#   nohup bash chain.sh batch.txt > /root/results/chain.out 2>&1 &
#
# batch.txt: one submission folder name per line ('#' comments ok). Per submission: prepare.sh (install + build) on
# the target, then `conduit-loadgen search` (switch with conformance on the full seed, warm-up, probes, holds).
# A name with results/<name>/SUMMARY.txt already is skipped, so re-launching resumes the batch.
# Progress: /root/results/chain.log, one line per step.
set -u
LIST="${1:?usage: chain.sh <batch.txt>}"
TARGET="${TARGET:-root@167.17.74.133}"
URLS="${URLS:-http://167.17.74.133,http://167.17.74.134,http://167.17.74.135,http://167.17.74.136}"
MAX="${MAX:-250000}"
START="${START:-2000}"
OUT=/root/results
LOG="$OUT/chain.log"
export CONDUIT_JWT_SECRET=multicore-server-challenge
mkdir -p "$OUT"
say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }
# monitor.sh (started on the target by conduit-loadgen over ssh) outlives a run that crashed or was stopped, and each
# one keeps a psql session open: four of them used up Postgres's free connection slots on 2026-10-29. Kill any left
# over before and after every submission. ([m] keeps the pattern from matching this ssh command's own shell.)
reap_monitors() {
  ssh -n -o BatchMode=yes "$TARGET" 'for p in $(pgrep -f "^bash /opt/conduit-tools/[m]onitor.sh"); do pkill -P $p; kill $p; done' >/dev/null 2>&1
}

grep -v '^\s*#' "$LIST" | awk 'NF{print $1}' | while read -r name; do
  if [ -s "$OUT/$name/SUMMARY.txt" ]; then say "$name: already scored, skipping"; continue; fi
  reap_monitors
  say "$name: prepare"
  if ! ssh -n -o BatchMode=yes "$TARGET" "/opt/conduit-tools/prepare.sh '$name'" > "$OUT/$name.prepare.log" 2>&1; then
    say "$name: PREPARE FAILED (see $name.prepare.log)"; continue
  fi
  say "$name: search"
  # -restart: a phase that wedged the app (often the overload probe at -max) or got Postgres OOM-killed would fail
  # every later phase at 100% errors; the search restarts both before a phase whose health check fails
  conduit-loadgen search -target-ssh "$TARGET" -target-url "$URLS" -boxes "${BOXES:-local=1}" -lang "$name" -label "$name" \
    -restart "systemctl start postgresql@18-main; systemctl restart challenge.service" \
    -start "$START" -max "$MAX" -outdir "$OUT/$name" < /dev/null > "$OUT/$name.out" 2>&1 &
  pid=$!
  # Watchdog: the search doesn't notice a dead server (it keeps stepping holds down). Once the switch is done,
  # two checks in a row with challenge.service not active = crashed: stop the search.
  down=0; crashed=0
  while kill -0 $pid 2>/dev/null; do
    sleep 60
    grep -q 'switch ok' "$OUT/$name.out" 2>/dev/null || continue
    if ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" 'systemctl is-active -q challenge.service'; then down=0; else down=$((down + 1)); fi
    if [ $down -ge 2 ]; then crashed=1; kill $pid; sleep 5; pkill -f '^/usr/local/bin/[c]onduit-loadgen run'; break; fi
  done
  wait $pid; rc=$?
  if [ $crashed = 1 ]; then
    say "$name: CRASHED during the search: $(ssh -n "$TARGET" 'journalctl -u challenge.service -n 3 --no-pager -o cat' | tr '\n' ' ' | cut -c1-250)"
    continue
  fi
  if [ -s "$OUT/$name/SUMMARY.txt" ]; then
    say "$name: done rc=$rc: $(grep -m1 '^SCORE' "$OUT/$name/SUMMARY.txt")"
  else
    say "$name: SEARCH FAILED rc=$rc: $(grep -m1 -iE 'fail|error' "$OUT/$name.out" | cut -c1-200)"
  fi
  ssh -n -o BatchMode=yes "$TARGET" 'systemctl stop challenge.service' >/dev/null 2>&1
  reap_monitors
done
say "batch done"
