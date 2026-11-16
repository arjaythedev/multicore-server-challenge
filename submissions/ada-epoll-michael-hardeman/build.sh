#!/usr/bin/env bash
# Builds bin/conduit. Uses the toolchain install.sh put in /opt, or whatever gnat/gprbuild is on PATH.
set -euo pipefail
cd "$(dirname "$0")"
for d in /opt/gnat-x86_64-linux-15.2.0-1/bin /opt/gprbuild-x86_64-linux-25.0.0-1/bin; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH
gprbuild -q -p -P conduit.gpr -XCONDUIT_MODE="${CONDUIT_MODE:-release}" -j0
