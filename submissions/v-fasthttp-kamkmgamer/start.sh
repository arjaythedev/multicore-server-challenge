#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# fasthttp has one synchronous event loop per online CPU. Database calls block
# those loops, so a small number of processes can provide additional loops while
# SO_REUSEPORT distributes connections across them.
server_procs="${SERVER_PROCS:-4}"
total_db_conns="${DB_CONNS_TOTAL:-${DB_CONNS:-32}}"
if [[ ! "$server_procs" =~ ^[1-4]$ ]]; then
	echo "SERVER_PROCS must be between 1 and 4" >&2
	exit 2
fi
if [[ ! "$total_db_conns" =~ ^[1-9][0-9]?$ ]] || (( total_db_conns > 90 )); then
	echo "DB_CONNS_TOTAL must be between 1 and 90" >&2
	exit 2
fi
if (( total_db_conns < server_procs )); then
	echo "DB_CONNS_TOTAL must be at least SERVER_PROCS" >&2
	exit 2
fi

declare -a pids=()
shutdown() {
	trap - TERM INT EXIT
	for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
	for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap shutdown TERM INT EXIT

base_conns=$((total_db_conns / server_procs))
extra_conns=$((total_db_conns % server_procs))
for ((i = 0; i < server_procs; i++)); do
	proc_conns="$base_conns"
	if (( i < extra_conns )); then proc_conns=$((proc_conns + 1)); fi
	DB_CONNS="$proc_conns" "$HERE/bin/conduit" </dev/null &
	pids+=("$!")
done

# Keep the systemd service alive and stop all siblings if any server exits.
wait -n "${pids[@]}"
