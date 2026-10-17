#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: GnuCOBOL 3.2 from the GNU release tarball (Ubuntu ships 3.1.2),
# with GMP for its decimal arithmetic, and OpenSSL's libcrypto for SCRAM-SHA-256 at login.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential curl xz-utils libgmp-dev libssl-dev
command -v cobc >/dev/null && cobc --version | grep -q '3\.2\.0' && exit 0
T=$(mktemp -d)
cd "$T"
curl -fsSLO https://ftp.gnu.org/gnu/gnucobol/gnucobol-3.2.tar.xz
echo "3bb48af46ced4779facf41fdc2ee60e4ccb86eaa99d010b36685315df39c2ee2  gnucobol-3.2.tar.xz" | sha256sum -c -
tar xf gnucobol-3.2.tar.xz
cd gnucobol-3.2
./configure --prefix=/usr/local --without-db --without-curses --without-xml2 --without-json
make -j"$(nproc)"
make install
ldconfig
rm -rf "$T"
