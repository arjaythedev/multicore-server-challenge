#!/usr/bin/env bash
# Installs the pinned eggs into ./eggs and compiles conduit.scm -> bin/conduit. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
PREFIX="${CHICKEN_PREFIX:-/opt/chicken}"
export PATH="$PREFIX/bin:$PATH"
SYSREPO="$(env -u CHICKEN_INSTALL_REPOSITORY chicken-install -repository)"
# Eggs go in ./eggs; the prefix also covers files some eggs put in share/ (the CHICKEN prefix is root-owned).
export CHICKEN_INSTALL_REPOSITORY="$PWD/eggs" CHICKEN_INSTALL_PREFIX="$PWD/eggs"
export CHICKEN_REPOSITORY_PATH="$PWD/eggs:$SYSREPO"
mkdir -p eggs bin
EGGS=(
  srfi-1:0.5.1 srfi-13:0.3.4 srfi-14:0.2.1 srfi-18:0.1.7 srfi-69:0.4.3 matchable:1.2
  spiffy:6.5.2 intarweb:2.1.0 uri-common:2.0 uri-generic:3.3
  postgresql:4.1.6 sql-null:2.0 medea:4 crypt:1.0.1 hmac:7.2.0 sha2:4.2.6 base64:1.0
)
# chicken-install checks the egg server even for eggs it already has, so skip it once they are in.
STAMP="eggs/.installed-$(echo "${EGGS[*]}" | sha256sum | cut -c1-16)"
if [ ! -f "$STAMP" ]; then
  chicken-install "${EGGS[@]}"
  touch "$STAMP"
fi
csc -O3 conduit.scm -o bin/conduit
echo "built bin/conduit ($(csi -release))"
