#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: uv 0.13.0 -> /usr/local/bin, CPython 3.15.0 -> /opt/uv/python
# (the version the performance work was measured on; Ubuntu's own python3 is 3.12), and the C toolchain + libpq
# headers that psycopg-c compiles against.
set -euo pipefail
apt-get update -q
apt-get install -y -q --no-install-recommends curl ca-certificates build-essential libpq-dev
curl -fsSL https://astral.sh/uv/0.13.0/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
UV_PYTHON_INSTALL_DIR=/opt/uv/python /usr/local/bin/uv python install 3.15.0
chmod -R a+rX /opt/uv
/usr/local/bin/uv --version
