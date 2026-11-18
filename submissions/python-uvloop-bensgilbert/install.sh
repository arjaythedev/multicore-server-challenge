#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04. Puts uv (release tarball, checked against its SHA-256) in /usr/local/bin
# and CPython 3.14.6 (python-build-standalone, fetched by uv) in /opt/uv/python.
set -euo pipefail
UV_VERSION=0.11.32
UV_SHA256=aab924fd522efd06f1c5f3b93a243864fc453132c94b2dc49f1371b528a4b967

apt-get update -q && apt-get install -y -q curl ca-certificates
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/uv.tar.gz" "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz"
echo "$UV_SHA256  $tmp/uv.tar.gz" | sha256sum -c -
tar -xzf "$tmp/uv.tar.gz" --strip-components=1 -C /usr/local/bin uv-x86_64-unknown-linux-gnu/uv uv-x86_64-unknown-linux-gnu/uvx
UV_PYTHON_INSTALL_DIR=/opt/uv/python /usr/local/bin/uv python install --no-bin 3.14.6
chmod -R a+rX /opt/uv
/usr/local/bin/uv --version
