#!/usr/bin/env bash
# Official correctness suite on the dev seed, under development resource limits.
# This is not the official performance configuration and never runs the loadgen.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == --http ]]; then
    check_log="$2/server.log"
    target/debug/conduit > "$check_log" 2>&1 &
    check_pid=$!
    trap 'kill "$check_pid" 2>/dev/null || true; wait "$check_pid" 2>/dev/null || true' EXIT
    for _ in $(seq 1 60); do
        kill -0 "$check_pid" 2>/dev/null || { cat "$check_log"; exit 1; }
        if rg -q '\[server\] listening' "$check_log"; then
            exec_status=0
            "$2/conformance" -base "http://127.0.0.1:$PORT" -secret "$JWT_SECRET" -q || exec_status=$?
            [[ "$exec_status" == 0 ]] || cat "$check_log"
            exit "$exec_status"
        fi
        sleep 1
    done
    cat "$check_log"
    exit 1
fi

repo_root="$(cd ../.. && pwd)"
image=postgres@sha256:edb0c08dc33befd0262ab3b5cf1c4f3f8cfd8b09e88c05b45adee29d6761ddb6
docker image inspect "$image" >/dev/null
bash tools/bounded-check.sh cargo build --offline --locked --bin conduit
mkdir -p .local
fixture_dir="$(mktemp -d "$PWD/.local/conformance-fixture.XXXXXX")"
fixture="nouredeen-api-check-$$"
created=0
cleanup() {
    if [[ "$created" == 1 ]]; then
        docker inspect --format 'fixture memory limit={{.HostConfig.Memory}} bytes, CPU quota={{.HostConfig.NanoCpus}} nanocpus' "$fixture" || true
        docker stop --time 2 "$fixture" >/dev/null || true
    fi
    rm -rf "$fixture_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
(
    cd "$repo_root/bench"
    bash "$repo_root/submissions/rust-tokio-nouredeen06/tools/bounded-check.sh" \
        env GOMAXPROCS=1 GOTOOLCHAIN=local GOPROXY=off \
        go build -p 1 -o "$fixture_dir/conformance" ./cmd/conformance
)
mkdir -p "$fixture_dir/seed" "$fixture_dir/bin"
# Use the unchanged upstream loader, with its generated files confined here.
cp "$repo_root/seed/make-seed.sh" "$fixture_dir/seed/make-seed.sh"
ln -s "$repo_root/bench" "$fixture_dir/bench"
ln -s "$repo_root/schema.sql" "$fixture_dir/schema.sql"
printf '#!/usr/bin/env bash\nexec docker exec -i %q psql -h /var/run/postgresql -U postgres "$@"\n' \
    "$fixture" > "$fixture_dir/bin/psql"
chmod +x "$fixture_dir/bin/psql"
docker run --detach --rm --name "$fixture" \
    --cpus=0.25 --memory=768m --memory-swap=768m --pids-limit=64 --shm-size=32m \
    --tmpfs /var/lib/postgresql:rw,size=384m \
    --mount "type=bind,src=$repo_root,dst=$repo_root,readonly" \
    -p 127.0.0.1::5432 -e POSTGRES_PASSWORD=api-fixture-only \
    "$image" \
    -c shared_buffers=16MB -c max_connections=20 -c max_worker_processes=0 \
    -c max_parallel_workers=0 -c max_wal_size=64MB -c min_wal_size=32MB \
    -c wal_buffers=512kB -c fsync=on -c synchronous_commit=on >/dev/null
created=1
fixture_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "5432/tcp") 0).HostPort}}' "$fixture")"
ready=0
for _ in $(seq 1 60); do
    if docker exec "$fixture" pg_isready -q -h 127.0.0.1 -U postgres; then
        ready=1
        break
    fi
    sleep 1
done
if [[ "$ready" != 1 ]]; then
    docker logs --tail 30 "$fixture" >&2
    exit 1
fi
bash tools/bounded-check.sh env "PATH=$fixture_dir/bin:$PATH" \
    GOMAXPROCS=1 GOTOOLCHAIN=local GOPROXY=off GOFLAGS='-p=1' \
    bash "$fixture_dir/seed/make-seed.sh" --dev
bash tools/bounded-check.sh env \
    "DATABASE_URL=postgres://conduit:conduit@127.0.0.1:$fixture_port/conduit_dev" \
    HOST=127.0.0.1 PORT=3114 JWT_SECRET=multicore-server-challenge \
    APP_THREADS=1 DB_CONNS=2 DB_WRITE_CONNS=1 BCRYPT_THREADS=1 GOMAXPROCS=1 \
    READ_TAG_ROUTE=1 READ_COMMENT_SET=1 READ_TAG_BATCH=1 \
    bash tools/check-conformance.sh --http "$fixture_dir"
