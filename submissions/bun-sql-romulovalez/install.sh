#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C compiler (build.sh compiles the bcrypt library from native/) and
# Bun, installed to /opt/bun-v$BUN_VERSION. The ahead-of-time compiler (`bun compile`) is only in canary builds so
# far; npm publishes each one under a fixed, dated version (@oven/bun-<platform>), pinned here by version and SHA-256.
# This one is revision da867c60b.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
BUN_VERSION=1.4.4-canary.20261031.1

apt-get update
apt-get install -y --no-install-recommends build-essential curl ca-certificates

case "$(uname -m)" in
  x86_64)  pkg=bun-linux-x64;     sha=64af6a7f7cf2c380e2f13785abece0d7c01bede384a8b8460d9299cbd1c0895c ;;
  aarch64) pkg=bun-linux-aarch64; sha=9e33404945243df7cb8b98ad13dc2d4cb83b0676369b6108c3f63f5165c91de6 ;;
  *) echo "unsupported architecture $(uname -m)"; exit 1 ;;
esac
tmp="$(mktemp -d)"
curl -fsSL "https://registry.npmjs.org/@oven/$pkg/-/$pkg-$BUN_VERSION.tgz" -o "$tmp/$pkg.tgz"
echo "$sha  $tmp/$pkg.tgz" | sha256sum -c -
tar -xzf "$tmp/$pkg.tgz" -C "$tmp"
rm -rf "/opt/bun-v$BUN_VERSION" && mkdir -p "/opt/bun-v$BUN_VERSION/bin"
install -m 0755 "$tmp/package/bin/bun" "/opt/bun-v$BUN_VERSION/bin/bun"
rm -rf "$tmp"
"/opt/bun-v$BUN_VERSION/bin/bun" --version
