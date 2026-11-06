#!/usr/bin/env bash
# Source only: callers select WORK prefix, upstream tool and JWT_SECRET.

local_preflight() {
    local cmd
    export LC_ALL=C
    for cmd in docker tee; do
        command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; return 1; }
    done
    docker compose version >/dev/null
    docker info >/dev/null
    [[ -x "$HERE/build/install/conduit/bin/conduit" ]] || {
        echo "Build the submission first with ./build.sh; this script does not build Java." >&2; return 1;
    }
}

local_workspace() {
    mkdir -p "$HERE/.local"
    WORK="$(mktemp -d "$HERE/.local/$1.XXXXXXXX")"
    COMPOSE_PROJECT="conduit-$(basename "$WORK" | tr '[:upper:].' '[:lower:]-')"
    trap local_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    exec > >(tee "$WORK/run.log") 2>&1
}

local_cleanup() {
    local rc=$?
    trap - EXIT
    benchmark_compose stop -t 30 app >/dev/null 2>&1 || true
    benchmark_compose logs --no-color app > "$WORK/server.log" 2>&1 || true
    benchmark_compose logs --no-color db > "$WORK/postgres.log" 2>&1 || true
    benchmark_compose down --volumes >/dev/null 2>&1 || true
    echo "Exit $rc; logs, binaries, seed and results retained in $WORK"
    exit "$rc"
}

benchmark_compose() {
    WORK="$WORK" HERE="$HERE" JWT_SECRET="${JWT_SECRET:?JWT_SECRET is required}" \
        docker compose -f "$HERE/compose.benchmark.yaml" -p "$COMPOSE_PROJECT" "$@"
}

local_build_tools() {
    echo "== build upstream tools with Docker Go (no host Go/toolchain downloads)"
    docker run --rm \
        --mount "type=bind,source=$ROOT,target=/repo,readonly" \
        --mount "type=bind,source=$WORK,target=/out" \
        -w /repo/bench -e GOTOOLCHAIN=local -e CGO_ENABLED=0 \
        -e GOCACHE=/out/go-cache -e GOMODCACHE=/out/go-mod -e GOPATH=/out/go \
        -e "RUNNER=$1" \
        golang:1.27.1-bookworm sh -eu -c '
            go build -o /out/seedgen ./cmd/seedgen
            go build -o "/out/$RUNNER" "./cmd/$RUNNER"
            /out/seedgen -out /out/data -scale 0.02
        '
}

psql() {
    docker exec -i "$PG" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d conduit_dev "$@"
}

copy_in() {
    local table="$1" columns="$2" pattern="$3" file
    # C-locale glob expansion matches make-seed.sh's sorted file order.
    for file in "$WORK"/data/$pattern; do
        [[ -f "$file" ]] || { echo "Missing seed file: $file"; return 1; }
        psql -c "\\copy $table ($columns) FROM '/work/data/$(basename "$file")'"
    done
}

local_database() {
    local ready=0 i table count fingerprint got
    echo "== disposable PostgreSQL 18.6 (fsync on)"
    benchmark_compose up -d db
    PG="$(benchmark_compose ps -q db)"
    [[ -n "$PG" ]] || { echo "Compose database container not found"; return 1; }
    printf '%s\n' "$PG" > "$WORK/postgres.cid"
    for ((i=0; i<90; i++)); do
        if docker exec "$PG" pg_isready -h 127.0.0.1 -U postgres -d conduit_dev >/dev/null 2>&1; then
            ready=1; break
        fi
        sleep 1
    done
    [[ "$ready" == 1 ]] || { echo "Postgres not ready after 90 s"; return 1; }
    [[ "$(psql -Atc 'SHOW fsync')" == on ]] || { echo "fsync is not on"; return 1; }
    psql -c "CREATE ROLE conduit LOGIN PASSWORD 'conduit'"
    psql < "$ROOT/schema.sql"
    copy_in tags 'id, name' 'tags.tsv'
    copy_in users 'id, username, email, password_hash, bio, image, created_at' 'users.tsv'
    copy_in articles 'id, slug, author_id, title, description, body, created_at, updated_at' 'articles.*.tsv'
    copy_in article_tags 'article_id, tag_id' 'article_tags.*.tsv'
    copy_in favorites 'user_id, article_id, created_at' 'favorites.*.tsv'
    copy_in comments 'article_id, author_id, body, created_at, updated_at' 'comments.*.tsv'
    copy_in follows 'follower_id, followee_id, created_at' 'follows.*.tsv'
    psql > "$WORK/grants.log" <<'SQL'
SELECT setval(pg_get_serial_sequence('users', 'id'), (SELECT max(id) FROM users));
SELECT setval(pg_get_serial_sequence('articles', 'id'), (SELECT max(id) FROM articles));
SELECT setval(pg_get_serial_sequence('tags', 'id'), (SELECT max(id) FROM tags));
SELECT setval(pg_get_serial_sequence('comments', 'id'), (SELECT max(id) FROM comments));
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO conduit;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO conduit;
VACUUM (FREEZE, ANALYZE);
SQL
    echo "== verify upstream dev-seed row counts and fingerprints (UTC)"
    while read -r table count fingerprint; do
        got="$(psql -AtF ' ' -c "SET TimeZone = 'UTC'" \
            -c "SELECT count(*), coalesce(sum(('x' || substr(md5(x::text), 1, 15))::bit(60)::bigint), 0) FROM $table x" < /dev/null)"
        echo "$table $got"
        [[ "$got" == "$count $fingerprint" ]] || {
            echo "Seed mismatch: expected $table $count $fingerprint"; return 1;
        }
    done <<'EXPECTED'
users 100000 57740453955909066846182
follows 39982 23042985450407282099700
articles 10000 5796775799610747246130
tags 200 107424899296369204925
article_tags 25048 14470473432458360801269
favorites 99911 57559556224651163688069
comments 49287 28499591671886831555647
EXPECTED
}

local_start_server() {
    BASE=http://app:3000
    echo "== start existing submission on $BASE (private Compose network)"
    benchmark_compose up -d --no-deps app
    if ! benchmark_compose run --rm --no-deps --entrypoint curl loadgen \
        --retry 60 --retry-delay 1 --retry-connrefused --retry-all-errors \
        --retry-max-time 60 --max-time 2 -sf -o /dev/null "$BASE/api/tags"; then
        benchmark_compose logs --no-color app
        echo "GET /api/tags not 200 after startup wait"
        return 1
    fi
    local_server_alive
}

local_server_alive() {
    local app
    app="$(benchmark_compose ps -a -q app)"
    [[ -n "$app" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$app")" == true ]]
}
