#!/usr/bin/env bash
# CI only (README "CI"). The challenge's CI runs Postgres as a postgres:18 service container and installs no Postgres
# server on the runner. On the box, where Postgres 18 is installed locally, `ci.sh container` fails and nothing else
# here runs.
#   ci.sh container      -> prints the Postgres container's id; fails when Postgres 18 is installed locally
#   ci.sh install <id>   -> (root) builds the engine against the container's server headers and copies it in
#   ci.sh start <id>     -> runs the launcher in the container's mount namespace, on the runner's network
set -euo pipefail
cd "$(dirname "$0")"
case "$1" in
container)
  if dpkg-query -W postgresql-18 >/dev/null 2>&1; then
    echo "pgserve: Postgres 18 is installed locally: the box's own install and start" >&2
    exit 1
  fi
  C=$(docker ps -q --filter ancestor=postgres:18 2>/dev/null || true)
  [ "$(echo "$C" | wc -w)" = 1 ] || { echo "pgserve: no local Postgres 18 and no single postgres:18 container" >&2; exit 1; }
  echo "pgserve: CI mode: no local Postgres 18 server, Postgres in container $C (postgres:18)" >&2
  echo "$C" ;;
install)
  # The same headers install.sh unpacks on the box, at the container's own package version, fetched by the
  # container's apt (its PGDG repo).
  C=$2
  PG=$(docker exec "$C" dpkg-query -W -f='${Version}' postgresql-18)
  echo "pgserve: CI mode: building against $(docker exec "$C" postgres --version) ($PG)"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  docker exec "$C" sh -c "cd /tmp && apt-get -q update >/dev/null && apt-get -q download postgresql-server-dev-18=$PG \
    >/dev/null 2>&1 && cat postgresql-server-dev-18_*.deb && rm postgresql-server-dev-18_*.deb" > "$TMP/dev.deb"
  dpkg-deb -x "$TMP/dev.deb" "$TMP/dev"
  (cd engine && ZIG=/usr/local/bin/zig PG_INCLUDE="$TMP/dev/usr/include/postgresql/18/server" bash build.sh)
  DEST="$(docker exec "$C" pg_config --pkglibdir)/plugins"
  docker exec "$C" install -d -m 755 "$DEST"
  docker cp engine/zig-out/pgengine.so "$C:$DEST/pgengine.so"
  docker exec "$C" chmod 644 "$DEST/pgengine.so"
  echo "pgserve: CI mode: installed $DEST/pgengine.so in container $C" ;;
start)
  # The workers are the container's processes. The launcher joins only the container's mount namespace (nsenter
  # -m): its Unix socket in /tmp and /var/run/postgresql are the ones the workers see, and it stays on the runner's
  # network, so it binds HOST:PORT where test/run.sh connects and reaches Postgres through the published port.
  C=$2
  docker cp launcher "$C:/usr/local/bin/pgserve-launcher"
  echo "pgserve: CI mode: launcher in container $C's mount namespace, serving $HOST:$PORT" >&2
  exec sudo --preserve-env=HOST,PORT,JWT_SECRET,DATABASE_URL,PGSERVE_WORKERS,PGSERVE_HASH_NICE,PGSERVE_THIN_TO,PGSERVE_DWELL_US,PGSERVE_DWELL_CAP,PGSERVE_DWELL_MIN,PGSERVE_STATS_S,PGSERVE_SHED \
    nsenter -m -t "$(docker inspect -f '{{.State.Pid}}' "$C")" /usr/local/bin/pgserve-launcher ;;
esac
