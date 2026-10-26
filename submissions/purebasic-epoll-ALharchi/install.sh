#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the C toolchain the PureBasic C backend compiles with, libpq and
# libcrypto (linked directly), and PureBasic 6.41 Free from purebasic.com, checked against its sha256.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q curl ca-certificates gcc libc6-dev libpq-dev libssl-dev

# purebasic.com serves the current Free version at an unversioned URL; this is 6.41 (published 2026-08-10).
# If the checksum no longer matches, the vendor has replaced the file with a newer version.
URL=https://www.purebasic.com/download/purebasic3-demo_x64.tgz
SHA256=002c1a9958ac116ad0e00b08c03afaf43096bf4f697a75a54da683218fbbfd7c
TMP="$(mktemp -d)"
curl -fsSL -o "$TMP/pb.tgz" "$URL"
echo "$SHA256  $TMP/pb.tgz" | sha256sum -c -
rm -rf /opt/purebasic
mkdir -p /opt/purebasic
tar -C /opt/purebasic -xzf "$TMP/pb.tgz" --strip-components=1
rm -rf "$TMP"
# (pbcompilerc --version prints the version but exits with status 1)
/opt/purebasic/compilers/pbcompilerc --version || true
test -x /opt/purebasic/compilers/pbcompilerc
