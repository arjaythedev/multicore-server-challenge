#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/scripts/local-server.sh"

BENCH_USERS="${BENCH_USERS-500 1000 2000}"
BENCH_REPEATS="${BENCH_REPEATS-3}"
BENCH_WARMUP="${BENCH_WARMUP-120s}"
BENCH_RAMP="${BENCH_RAMP-30s}"
BENCH_MEASURE="${BENCH_MEASURE-60s}"
BENCH_TAIL="${BENCH_TAIL-5s}"
BENCH_PROFILE="${BENCH_PROFILE-0}"
BENCH_PAUSE="${BENCH_PAUSE-30}"
BENCH_STOP_ON_FAIL="${BENCH_STOP_ON_FAIL-0}"

fail() { echo "benchmark: $*" >&2; exit 1; }
positive_integer() { [[ "$1" =~ ^[1-9][0-9]{0,17}$ ]]; }
duration() {
    # Match Go's composite duration notation, without accepting negative/overflow durations.
    perl -e '
        my $s = shift; my $total = 0;
        my %unit = (h=>3600, m=>60, s=>1, ms=>0.001, us=>0.000001, ns=>0.000000001);
        while ($s =~ s/^([0-9]+(?:\.[0-9]+)?|\.[0-9]+)(ms|us|ns|h|m|s)//) {
            $total += $1 * $unit{$2};
        }
        exit !($s eq "" && $total > 0 && $total < 9223372036);
    ' "$1"
}

command -v perl >/dev/null || fail "Missing command: perl"
[[ "$BENCH_PROFILE" == 0 || "$BENCH_PROFILE" == 1 ]] || fail "BENCH_PROFILE must be 0 or 1"
[[ "$BENCH_STOP_ON_FAIL" == 0 || "$BENCH_STOP_ON_FAIL" == 1 ]] || fail "BENCH_STOP_ON_FAIL must be 0 or 1"
[[ "$BENCH_PAUSE" =~ ^(0|[1-9][0-9]{0,8})$ ]] || fail "BENCH_PAUSE must be a nonnegative number of seconds"
positive_integer "$BENCH_REPEATS" || fail "BENCH_REPEATS must be a positive integer (no leading zeroes)"
USERS=()
previous=0
# Disable pathname expansion: configuration is a whitespace-separated list, never a glob.
set -f
for users in $BENCH_USERS; do
    positive_integer "$users" || fail "BENCH_USERS must contain positive integers (no leading zeroes)"
    (( users > previous )) || fail "BENCH_USERS must be strictly increasing"
    USERS+=("$users")
    previous=$users
done
set +f
(( ${#USERS[@]} > 0 )) || fail "BENCH_USERS must not be empty"
BENCH_WARMUP_USERS="${BENCH_WARMUP_USERS-${USERS[0]}}"
positive_integer "$BENCH_WARMUP_USERS" || fail "BENCH_WARMUP_USERS must be a positive integer (no leading zeroes)"
for name in BENCH_WARMUP BENCH_RAMP BENCH_MEASURE BENCH_TAIL; do
    duration "${!name}" || fail "$name must be a positive Go duration (h/m/s/ms/us/ns), below 292 years"
done
local_preflight
local_workspace benchmark
JWT_SECRET=multicore-server-challenge-benchmark

(
    echo "started_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then echo "dirty=true"; else echo "dirty=false"; fi
    docker info --format 'docker_host={{.OSType}}/{{.Architecture}} cpus={{.NCPU}} memory_bytes={{.MemTotal}}'
    echo "go_image=golang:1.27.1-bookworm"
    echo "postgres_image=postgres:18.6-bookworm"
    echo "fsync=on"
    echo "users=$BENCH_USERS repeats=$BENCH_REPEATS"
    echo "warmup=$BENCH_WARMUP warmup_users=$BENCH_WARMUP_USERS ramp=$BENCH_RAMP measure=$BENCH_MEASURE tail=$BENCH_TAIL"
    echo "articles=10000 think_scale=1 profile=$BENCH_PROFILE"
    echo "pause_seconds=$BENCH_PAUSE stop_on_fail=$BENCH_STOP_ON_FAIL"
    echo "fixture=deterministic-devseed-scale-0.02; shared across warmup and measured repeats"
    echo "topology=app, PostgreSQL and loadgen share a private Linux Docker network; no published ports (not an official isolated-host score)"
    benchmark_compose run --rm --no-deps --entrypoint java app -version 2>&1
) > "$WORK/metadata.log"
perl -MDigest::SHA -e '
    for my $path (@ARGV) {
        open my $file, "<", $path or die "$path: $!";
        binmode $file;
        print Digest::SHA->new(256)->addfile($file)->hexdigest, "  $path\n";
    }
' "$HERE"/build/install/conduit/lib/*.jar > "$WORK/distribution.sha256"

local_build_tools loadgen
local_database
if [[ "$BENCH_PROFILE" == 1 ]]; then
    echo "WARNING: JFR profile recording enabled; this run is slower and NOT baseline-comparable."
    # Gradle's standard launcher parses JAVA_OPTS with xargs; quote the entire option.
    jfr_option="-XX:StartFlightRecording=name=benchmark,settings=profile,dumponexit=true,filename=$WORK/profile.jfr"
    jfr_option="${jfr_option//\\/\\\\}"
    jfr_option="${jfr_option//\"/\\\"}"
    export JAVA_OPTS="${JAVA_OPTS:-} \"$jfr_option\""
fi
local_start_server
app_ip="$(benchmark_compose run --rm --no-deps --entrypoint getent loadgen \
    ahostsv4 app | awk 'NR == 1 { print $1 }')"
[[ "$app_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Could not resolve the app's private IPv4 address"
TARGET="http://$app_ip:3000"
benchmark_compose config --format json > "$WORK/compose.json"
benchmark_compose images --format json > "$WORK/images.json"
docker image inspect golang:1.27.1-bookworm \
    --format '{{.Id}} {{json .RepoDigests}}' > "$WORK/loadgen-image.log"
echo "loadgen_target=$TARGET" >> "$WORK/metadata.log"

loadgen() {
    benchmark_compose run --rm --no-deps loadgen "$@"
}

snapshot() {
    psql -Atc "SELECT row_to_json(s) FROM pg_stat_database s WHERE datname = current_database()" > "$1"
}

phase() {
    local name="$1" users="$2" measure="$3" dir="$WORK/$1" rc=0
    lg_limited=0
    mkdir -p "$dir"
    echo "== $name: $users users, ramp $BENCH_RAMP + measure $measure + tail $BENCH_TAIL"
    local_server_alive || fail "Server exited; see $WORK/server.log"
    snapshot "$dir/pg-before.json"
    loadgen run -target "$TARGET" -users "$users" \
        -ramp "$BENCH_RAMP" -measure "$measure" -tail "$BENCH_TAIL" \
        -articles 10000 -think-scale 1 -secret "$JWT_SECRET" \
        -run-id "$(basename "$WORK")-$name" -out "$dir/loadgen.json" -q \
        > "$dir/loadgen.log" 2>&1 || rc=$?
    echo "$rc" > "$dir/loadgen.exit"
    if [[ "$rc" != 0 ]]; then
        cat "$dir/loadgen.log"
        fail "loadgen operational failure ($rc) in $name; see $dir"
    fi
    snapshot "$dir/pg-after.json"
    loadgen merge -o "$dir/merged.json" "$dir/loadgen.json" \
        > "$dir/merged.txt" 2>&1 || rc=$?
    echo "$rc" > "$dir/merge.exit"
    cat "$dir/merged.txt"
    if grep -Eq '"lg_limited"[[:space:]]*:[[:space:]]*true' "$dir/merged.json"; then
        lg_limited=1
        echo "WARNING: $name is load-generator limited (lg_limited=true), independent of verdict/exit status; do NOT interpret this as server capacity. See merged.json reasons."
    fi
    case "$rc" in
        0) ;;
        3)
            if [[ "$name" == warmup ]]; then
                echo "WARNING: warmup verdict failed; retained for diagnosis, not counted as a measured verdict."
            else
                overall=3
            fi ;;
        *) fail "merge operational failure ($rc) in $name; see $dir" ;;
    esac
    local_server_alive || fail "Server exited; see $WORK/server.log"
}

overall=0
phase warmup "$BENCH_WARMUP_USERS" "$BENCH_WARMUP"
for users in "${USERS[@]}"; do
    for ((repeat=1; repeat<=BENCH_REPEATS; repeat++)); do
        echo "== allow sockets to drain for $BENCH_PAUSE seconds"
        sleep "$BENCH_PAUSE"
        phase "users-$users-repeat-$repeat" "$users" "$BENCH_MEASURE"
        if [[ "$BENCH_STOP_ON_FAIL" == 1 ]]; then
            if [[ "$lg_limited" == 1 ]]; then
                echo "== stopped: load-generator limited; server capacity is unresolved"
                exit 4
            fi
            if [[ "$overall" == 3 ]]; then
                echo "== stopped: measured latency/error thresholds failed at $users users"
                exit 3
            fi
        fi
    done
done
echo "== benchmark completed: measured verdict exit $overall (0=pass, 3=one or more failed)"
exit "$overall"
