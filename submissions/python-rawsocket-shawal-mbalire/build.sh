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
# ALT_ADAPTERS=1: the dependencies of the non-default adapters in registry.py, for local A/B runs (the default
# adapters don't import them)
if [ "${ALT_ADAPTERS:-0}" = 1 ]; then
  "$UV" pip install --python .venv/bin/python --no-cache -c constraints.txt msgspec uvloop asyncpg ujson python-rapidjson yyjson pydantic
fi
.venv/bin/python -c 'import sys, psycopg; assert psycopg.pq.__impl__ == "c", psycopg.pq.__impl__; print("python build ok:", sys.version.split()[0], "psycopg", psycopg.__version__, psycopg.pq.__impl__)'
# Multi-lane bcrypt (native/bcrypt_lanes.c, called through ctypes): Blowfish's initial tables are generated from pi
N=conduit_server/adapters/outbound/native
.venv/bin/python $N/gen_pi.py $N/bf_init.h
gcc -O3 -march=x86-64-v2 -fPIC -shared -Wall -o $N/libbcrypt_lanes.so $N/bcrypt_lanes.c
# HS256 verification of our own tokens (native/jwt_verify.c): a CPython extension, SHA-NI when the CPU has it
PYINC=$(.venv/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
EXT=$(.venv/bin/python -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')
gcc -O3 -march=x86-64-v2 -fPIC -shared -Wall -I"$PYINC" -o "$N/_jwt_verify$EXT" $N/jwt_verify.c
.venv/bin/python -c "import sys; sys.path.insert(0, '$N'); import _jwt_verify; print('jwt backend:', _jwt_verify.backend())"
echo "native build ok: $N/libbcrypt_lanes.so $N/_jwt_verify$EXT"
