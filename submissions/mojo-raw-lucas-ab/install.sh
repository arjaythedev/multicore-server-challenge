#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the Mojo 1.2.0 compiler from PyPI (Modular's official wheels), pinned by
# version and SHA-256 in mojo-requirements.txt, into a venv at /opt/mojo. The server binary links Mojo's runtime
# libraries from there, so /opt/mojo stays installed and readable by the `challenge` user.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates python3 python3-venv
rm -rf /opt/mojo
python3 -m venv /opt/mojo
/opt/mojo/bin/pip install --quiet --disable-pip-version-check --no-deps --require-hashes \
  -r "$HERE/mojo-requirements.txt"
chmod -R a+rX /opt/mojo
/opt/mojo/bin/mojo --version
