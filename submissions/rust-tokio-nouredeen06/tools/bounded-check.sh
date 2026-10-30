#!/usr/bin/env bash
# Development checks only. Never used by the submitted server or official build.
# Requires a user systemd manager with delegated cgroup v2 CPU/memory controllers.
set -euo pipefail

if [[ "${1:-}" == --inside-budget ]]; then
    shift
    check_cgroup="/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)"
    [[ "$(cat "$check_cgroup/cpu.max")" == '50000 100000' &&
       "$(cat "$check_cgroup/memory.max")" == 1610612736 &&
       "$(cat "$check_cgroup/memory.swap.max")" == 0 &&
       "$(cat "$check_cgroup/memory.oom.group")" == 1 &&
       "$(cat "$check_cgroup/pids.max")" == 64 ]] || {
        echo 'Resource limits were not applied; refusing to run.' >&2
        exit 1
    }
    set +e
    env CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1 "$@"
    check_status=$?
    printf '\n[budget] peak memory bytes: '
    cat "$check_cgroup/memory.peak"
    printf '[budget] CPU accounting: '
    tr '\n' ' ' < "$check_cgroup/cpu.stat"
    printf '\n'
    exit "$check_status"
fi

[[ $# -gt 0 ]] || { echo "usage: bash $0 command [args...]" >&2; exit 2; }
available_kib="$(awk '$1 == "MemAvailable:" {print $2}' /proc/meminfo)"
[[ "$available_kib" =~ ^[0-9]+$ && "$available_kib" -ge 8388608 ]] || {
    echo 'Less than 8 GiB available memory; refusing to run.' >&2
    exit 1
}
awk '/^some / {split($2,a,"="); if (a[2] >= 1) exit 1}' /proc/pressure/memory || {
    echo 'Memory pressure is elevated; refusing to run.' >&2
    exit 1
}
check_script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
exec systemd-run --user --quiet --wait --pipe --collect \
    --unit="nouredeen-check-$$" --working-directory="$PWD" \
    -p CPUQuota=50% -p CPUQuotaPeriodSec=100ms \
    -p MemoryHigh=1G -p MemoryMax=1536M -p MemorySwapMax=0 \
    -p OOMPolicy=kill -p TasksMax=64 -p RuntimeMaxSec=600 \
    -p Nice=15 -p IOWeight=10 \
    /usr/bin/env "PATH=$PATH" /bin/bash "$check_script" --inside-budget "$@"
