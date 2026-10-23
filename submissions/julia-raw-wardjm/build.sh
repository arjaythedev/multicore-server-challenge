#!/usr/bin/env bash
# Precompiles the Conduit package into ./depot (native code cache, so start.sh is quick). Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
JULIA="${JULIA:-/opt/julia-1.13.2/bin/julia}"
[ -x "$JULIA" ] || JULIA=julia
export JULIA_DEPOT_PATH="$PWD/depot:"
"$JULIA" --project=. --startup-file=no -O3 -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(); using Conduit'
echo "built Conduit ($("$JULIA" --version))"
