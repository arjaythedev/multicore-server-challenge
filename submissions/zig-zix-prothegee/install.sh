#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 (x86_64 or arm64): Zig 0.17.0 from the official tarball
# (sha256-checked) in /usr/local/zig, with /usr/local/bin/zig. Matches build.zig.zon minimum_zig_version.
set -euo pipefail
ZIG_VERSION=0.17.0
case "$(uname -m)" in
  x86_64)  ZIG_TARGET=x86_64-linux ;;
  aarch64) ZIG_TARGET=aarch64-linux ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends curl git jq xz-utils ca-certificates

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

meta="$(curl -fsSL https://ziglang.org/download/index.json | jq -r --arg v "$ZIG_VERSION" --arg t "$ZIG_TARGET" '.[$v][$t] | "\(.tarball) \(.shasum)"')"
url="${meta%% *}"
sha="${meta##* }"
if [ -z "$url" ] || [ "$url" = "null" ]; then
  echo "no Zig $ZIG_VERSION tarball for $ZIG_TARGET"
  exit 1
fi

curl -fsSLo "$tmp/zig.tar.xz" "$url"
echo "$sha  $tmp/zig.tar.xz" | sha256sum -c -

rm -rf /usr/local/zig
mkdir -p /usr/local/zig
tar -xJf "$tmp/zig.tar.xz" -C /usr/local/zig --strip-components=1
ln -sf /usr/local/zig/zig /usr/local/bin/zig

zig version
