#!/usr/bin/env bash
# Small correctness fixture, not a throughput benchmark. No challenge seed needed.
set -euo pipefail
cd "$(dirname "$0")/.."
image=postgres@sha256:edb0c08dc33befd0262ab3b5cf1c4f3f8cfd8b09e88c05b45adee29d6761ddb6
docker image inspect "$image" >/dev/null
bash tools/bounded-check.sh true
# Compile before starting PostgreSQL. Only the named integration test runs below.
bash tools/bounded-check.sh cargo test --offline --locked --bin conduit --no-run
fixture="nouredeen-writer-check-$$"
created=0
cleanup() {
    if [[ "$created" == 1 ]]; then
        docker inspect --format 'fixture memory limit={{.HostConfig.Memory}} bytes, CPU quota={{.HostConfig.NanoCpus}} nanocpus' "$fixture" || true
        docker stop --time 2 "$fixture" >/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker run --detach --rm --name "$fixture" \
    --cpus=0.25 --memory=384m --memory-swap=384m --pids-limit=48 --shm-size=32m \
    --tmpfs /var/lib/postgresql:rw,size=128m \
    -p 127.0.0.1::5432 -e POSTGRES_PASSWORD=writer-fixture-only \
    "$image" \
    -c shared_buffers=16MB -c max_connections=10 -c max_worker_processes=0 \
    -c max_parallel_workers=0 -c max_wal_size=64MB -c min_wal_size=32MB \
    -c wal_buffers=512kB -c fsync=on -c synchronous_commit=on >/dev/null
created=1
fixture_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "5432/tcp") 0).HostPort}}' "$fixture")"
ready=0
for _ in $(seq 1 60); do
    # TCP readiness excludes the temporary Unix-socket-only initdb server.
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
bash tools/bounded-check.sh env \
    "WRITER_TEST_DATABASE_URL=postgres://postgres:writer-fixture-only@127.0.0.1:$fixture_port/postgres" \
    WRITE_BATCH_US=2000 BATCH_TRACE=1 \
    cargo test --offline --locked --bin conduit \
    writer::tests::packed_writes_preserve_commit_rollback_and_parameters \
    -- --ignored --nocapture --test-threads=1
