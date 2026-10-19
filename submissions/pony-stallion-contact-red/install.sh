#!/usr/bin/env bash
set -euo pipefail
apt-get update -q
apt-get install -y -q build-essential curl ca-certificates git libpq-dev libssl-dev xz-utils
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cd "$stage"

pony_base=https://github.com/ponylang/ponyc/releases/download/0.77.0
pony_archive=ponyc-x86-64-unknown-linux-ubuntu24.04.tar.gz
curl -fsSLO "$pony_base/$pony_archive"
curl -fsSLO "$pony_base/$pony_archive.sha512"
pony_sha=$(awk 'NR==1 {print $1}' "$pony_archive.sha512")
printf '%s  %s\n' "$pony_sha" "$pony_archive" | sha512sum -c -
mkdir -p /opt/conduit-ponyc-0.77.0
tar -xzf "$pony_archive" -C /opt/conduit-ponyc-0.77.0 --strip-components=1
ln -sf /opt/conduit-ponyc-0.77.0/bin/ponyc /usr/local/bin/ponyc

corral_base=https://github.com/ponylang/corral/releases/download/0.9.2
corral_archive=corral-x86-64-unknown-linux.tar.gz
curl -fsSLO "$corral_base/$corral_archive"
curl -fsSLO "$corral_base/$corral_archive.sha512"
corral_sha=$(awk 'NR==1 {print $1}' "$corral_archive.sha512")
printf '%s  %s\n' "$corral_sha" "$corral_archive" | sha512sum -c -
mkdir corral
tar -xzf "$corral_archive" -C corral
corral_binary=$(find corral -type f -name corral -print -quit)
install -m 755 "$corral_binary" /usr/local/bin/corral
