#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Julia 1.13.2 (official tarball, sha256-checked) -> /opt/julia-1.13.2.
set -euo pipefail
JULIA_VERSION=1.13.2
SHA=2ecdfc9890ab0a565fdd92404c915ba2a04a933dbd5d292cc224d13819d17d07
apt-get update -q && apt-get install -y -q curl ca-certificates
curl -fsSLo /tmp/julia.tgz "https://julialang-s3.julialang.org/bin/linux/x64/1.13/julia-$JULIA_VERSION-linux-x86_64.tar.gz"
echo "$SHA  /tmp/julia.tgz" | sha256sum -c -
rm -rf "/opt/julia-$JULIA_VERSION" && tar -C /opt -xzf /tmp/julia.tgz && rm /tmp/julia.tgz
"/opt/julia-$JULIA_VERSION/bin/julia" --version
