#!/usr/bin/env bash
# Builds the app as a normal user: ./.venv with CPython 3.14.6 and the versions pinned in requirements.txt (made with
# `uv pip compile requirements.in --python-version 3.14 --universal`).
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /usr/local/bin/uv ]; then
  UV=/usr/local/bin/uv
  export UV_PYTHON_INSTALL_DIR=/opt/uv/python
else
  UV="$(command -v uv)"   # not on the box: use whatever uv is on PATH
  "$UV" python install 3.14.6
fi
"$UV" venv --python 3.14.6 --managed-python --clear .venv
"$UV" pip sync --python .venv/bin/python --strict --compile-bytecode requirements.txt
.venv/bin/python -m compileall -q conduit
.venv/bin/python -c 'import sys, asyncpg, uvloop, httptools, orjson, bcrypt; print("python build ok:", sys.version.split()[0], "asyncpg", asyncpg.__version__, "uvloop", uvloop.__version__, "orjson", orjson.__version__)'
