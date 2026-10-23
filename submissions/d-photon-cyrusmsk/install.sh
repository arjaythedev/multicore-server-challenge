#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the D toolchain (LDC 1.41.0 with its
# own dub) into /usr/local/ldc, plus the two system libraries the app links.
#
# Pinned: the LDC tarball is checksum-verified, and every DUB package version is
# recorded in dub.selections.json.
set -euo pipefail

LDC_VERSION=1.41.0
case "$(uname -m)" in
  x86_64)         LDC_TRIPLE=linux-x86_64
                  LDC_SHA256=4a439457f0fe59e69d02fd6b57549fc3c87ad0f55ad9fb9e42507b6f8e327c8f ;;
  aarch64|arm64)  LDC_TRIPLE=linux-aarch64
                  LDC_SHA256=1c4b950a13d53379ed4f564366c27ec56d6261e21686880d70c7486b3e8c7ba8 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
LDC_URL="https://github.com/ldc-developers/ldc/releases/download/v${LDC_VERSION}/ldc2-${LDC_VERSION}-${LDC_TRIPLE}.tar.xz"

apt-get update -qq
# curl for the tarball, gcc because LDC links through it, git because dpq2
# pins one of its own dependencies (derelict-pq) by commit, libbsd for the
# bcrypt package's arc4random_buf, libssl for JWT (jwtlited:openssl), and zlib
# because photon's I/O layer links it.
apt-get install -y -qq curl ca-certificates gnupg gcc git xz-utils libbsd-dev libssl-dev zlib1g-dev libmimalloc-dev

# libpq 17 or newer: the Postgres driver binds the libpq-17 API (pipelines),
# which Ubuntu 24.04's own libpq (16) does not have. The benchmark box gets it
# from PGDG together with Postgres 18, so do the same everywhere.
if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --yes -o /usr/share/keyrings/pgdg.gpg
  . /etc/os-release
  echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
fi
apt-get install -y -qq libpq-dev
pg_config --version

curl -fsSLo /tmp/ldc2.tar.xz "$LDC_URL"
echo "${LDC_SHA256}  /tmp/ldc2.tar.xz" | sha256sum -c -
rm -rf /usr/local/ldc
tar -C /usr/local -xJf /tmp/ldc2.tar.xz
mv "/usr/local/ldc2-${LDC_VERSION}-${LDC_TRIPLE}" /usr/local/ldc
chmod -R a+rX /usr/local/ldc
rm -f /tmp/ldc2.tar.xz

/usr/local/ldc/bin/ldc2 --version
/usr/local/ldc/bin/dub --version
