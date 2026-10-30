#!/usr/bin/env bash
# Build: a project-local virtualenv on CPython 3.15 (3.15.0 on the box, installed by install.sh) with exactly-pinned deps.
# constraints.txt locks every package (transitives included); start.sh runs that venv.
# psycopg[c] compiles psycopg-c from source against libpq-dev (install.sh), so no prebuilt binaries.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /usr/local/bin/uv ]; then
  UV=/usr/local/bin/uv
  export UV_PYTHON_INSTALL_DIR=/opt/uv/python
else
  UV="$(command -v uv)"  # local development: uv on PATH
  "$UV" python install 3.15
fi
"$UV" venv --python 3.15 --managed-python --clear .venv
"$UV" pip install --python .venv/bin/python --no-cache -c constraints.txt 'psycopg[c]' psycopg_pool bcrypt pyjwt orjson
.venv/bin/python -c 'import sys, psycopg; assert psycopg.pq.__impl__ == "c", psycopg.pq.__impl__; print("python build ok:", sys.version.split()[0], "psycopg", psycopg.__version__, psycopg.pq.__impl__)'
