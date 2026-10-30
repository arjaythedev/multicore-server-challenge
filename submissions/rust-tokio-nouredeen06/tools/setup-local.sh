#!/usr/bin/env bash
# Isolated, optional local development infrastructure. Never used by start.sh.
# Existing databases, containers, host packages and host tuning are untouched.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LOCAL_DIR="${LOCAL_DIR:-/tmp/nouredeen-challenge}"
PG_CONTAINER="${PG_CONTAINER:-nouredeen-challenge-pg18}"
PG_VOLUME="${PG_VOLUME:-nouredeen-challenge-pg18}"
LOCAL_PGPORT="${LOCAL_PGPORT:-55432}"
PG_IMAGE=postgres@sha256:edb0c08dc33befd0262ab3b5cf1c4f3f8cfd8b09e88c05b45adee29d6761ddb6
MODE="${1:---all}"
case "$MODE" in --all|--dev|--full|--tools-only) ;; *) echo "usage: $0 [--all|--dev|--full|--tools-only]" >&2; exit 2 ;; esac
for tool in docker go; do command -v "$tool" >/dev/null || { echo "missing dependency: $tool" >&2; exit 1; }; done
[[ "$LOCAL_PGPORT" =~ ^[0-9]+$ ]] || { echo 'LOCAL_PGPORT must be numeric' >&2; exit 1; }
mkdir -p "$LOCAL_DIR/bin"
LOCAL_DIR="$(cd "$LOCAL_DIR" && pwd)"

# The official pgtune web formulas evaluated for 8 CPUs and 16 GB RAM.
cat > "$LOCAL_DIR/pg18.conf" <<'CONF'
listen_addresses = '*'
max_connections = 100
shared_buffers = 4GB
effective_cache_size = 12GB
maintenance_work_mem = 1GB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
work_mem = 9709kB
huge_pages = try
min_wal_size = 1GB
max_wal_size = 4GB
max_worker_processes = 8
max_parallel_workers = 8
max_parallel_workers_per_gather = 4
max_parallel_maintenance_workers = 4
CONF
if docker container inspect "$PG_CONTAINER" >/dev/null 2>&1; then
    image="$(docker inspect --format '{{.Config.Image}}' "$PG_CONTAINER")"
    volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Name}}{{end}}{{end}}' "$PG_CONTAINER")"
    repo="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "'"$ROOT"'"}}{{.Source}}{{end}}{{end}}' "$PG_CONTAINER")"
    binding="$(docker inspect --format '{{with (index .HostConfig.PortBindings "5432/tcp")}}{{(index . 0).HostIp}}:{{(index . 0).HostPort}}{{end}}' "$PG_CONTAINER")"
    if [[ "$image" != "$PG_IMAGE" || "$volume" != "$PG_VOLUME" || "$repo" != "$ROOT" || "$binding" != "127.0.0.1:$LOCAL_PGPORT" ]]; then
        echo "Existing container $PG_CONTAINER differs from this isolated setup; choose another PG_CONTAINER/PG_VOLUME/LOCAL_PGPORT." >&2
        exit 1
    fi
    docker start "$PG_CONTAINER" >/dev/null
else
    docker pull "$PG_IMAGE"
    docker run -d --name "$PG_CONTAINER" --shm-size=1g \
        -p "127.0.0.1:$LOCAL_PGPORT:5432" \
        -e POSTGRES_PASSWORD=challenge-local-only \
        -e POSTGRES_INITDB_ARGS='--locale=C.UTF-8 --encoding=UTF8' \
        --mount "type=volume,src=$PG_VOLUME,dst=/var/lib/postgresql" \
        --mount "type=bind,src=$ROOT,dst=$ROOT,readonly" \
        --mount "type=bind,src=$LOCAL_DIR/pg18.conf,dst=/etc/challenge-postgresql.conf,readonly" \
        "$PG_IMAGE" -c config_file=/etc/challenge-postgresql.conf
fi

{
    echo '#!/usr/bin/env bash'
    printf 'PG_CONTAINER=%q\n' "$PG_CONTAINER"
    cat <<'WRAPPER'
exec docker exec -i -e PGHOST=/var/run/postgresql -e PGPORT=5432 \
    -e PGUSER="${PGUSER:-postgres}" -e PGPASSWORD="${PGPASSWORD:-challenge-local-only}" \
    "$PG_CONTAINER" psql "$@"
WRAPPER
} > "$LOCAL_DIR/bin/psql"
chmod +x "$LOCAL_DIR/bin/psql"
{
    printf 'export PATH=%q:"$PATH"\n' "$LOCAL_DIR/bin"
    printf 'export PGHOST=127.0.0.1 PGPORT=%q PGUSER=postgres PGPASSWORD=challenge-local-only\n' "$LOCAL_PGPORT"
    echo 'export JWT_SECRET=multicore-server-challenge'
} > "$LOCAL_DIR/env.sh"
source "$LOCAL_DIR/env.sh"
for _ in $(seq 60); do
    docker exec "$PG_CONTAINER" pg_isready -q -U postgres && break
    sleep 1
done
psql -X -At -d postgres -c 'SELECT version()'
(
    cd "$ROOT/bench"
    go build -o "$LOCAL_DIR/conformance" ./cmd/conformance
    go build -o "$LOCAL_DIR/loadgen" ./cmd/loadgen
    go build -o "$LOCAL_DIR/seedgen" ./cmd/seedgen
)
seed() {
    local db="$1"
    shift
    if [[ "$(psql -X -At -d postgres -c "SELECT count(*) FROM pg_database WHERE datname='$db'")" == 1 ]]; then
        echo "$db already exists; preserving it."
    else
        (cd "$ROOT" && bash seed/make-seed.sh "$@") 2>&1 | tee "$LOCAL_DIR/$db-setup.log"
    fi
}
case "$MODE" in
    --all) seed conduit_dev --dev; seed conduit_seed ;;
    --dev) seed conduit_dev --dev ;;
    --full) seed conduit_seed ;;
esac
printf '\nReady. Source %q for psql/admin connection settings.\n' "$LOCAL_DIR/env.sh"
printf 'Database URL: postgres://conduit:conduit@127.0.0.1:%s/<database>\n' "$LOCAL_PGPORT"
printf 'Container: %s; persistent volume: %s.\n' "$PG_CONTAINER" "$PG_VOLUME"
