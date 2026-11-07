#!/usr/bin/env bash
# Runs as root on the box (score/prepare.sh). Installs the pinned Zig, then builds the engine against the Postgres 18
# server headers and installs it where an unprivileged role may load it: $libdir/plugins (local_preload_libraries
# loads only from there for a role that is not superuser).
set -euo pipefail
cd "$(dirname "$0")"
bash engine/install-zig.sh
# CI only: no local Postgres server, Postgres in a postgres:18 container (README "CI").
if C=$(bash ci.sh container); then exec bash ci.sh install "$C"; fi
# The headers only, of exactly the installed server: postgresql-server-dev-18 at postgresql-18's version, from the
# PGDG repo box/setup-box.sh adds, unpacked into a temporary folder. Installing the package would also pull in
# clang-19 and llvm-19-dev, which the build doesn't use.
PG=$(dpkg-query -W -f='${Version}' postgresql-18)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
apt-get -q update >/dev/null
(cd "$TMP" && apt-get -q download "postgresql-server-dev-18=$PG" >/dev/null 2>&1)
dpkg-deb -x "$TMP"/postgresql-server-dev-18_*.deb "$TMP/dev"
(cd engine && ZIG=/usr/local/bin/zig PG_INCLUDE="$TMP/dev/usr/include/postgresql/18/server" \
  PKGLIBDIR=/usr/lib/postgresql/18/lib bash build.sh install)
