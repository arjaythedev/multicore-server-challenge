#!/usr/bin/env bash
# Runs the server in the foreground. Configured by DATABASE_URL, JWT_SECRET,
# HOST and PORT; README.md lists the optional tuning variables.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# One descriptor per keep-alive connection, as many as the service allows.
ulimit -n "$(ulimit -Hn)"
# The bcrypt width build.sh measured on this machine, unless one is given.
if [ -z "${BCRYPT_WIDTH:-}" ] && [ -f "$DIR/bin/bcrypt-width.txt" ]; then
  BCRYPT_WIDTH="$(cat "$DIR/bin/bcrypt-width.txt")"
  export BCRYPT_WIDTH
fi
exec "$DIR/bin/conduit"
