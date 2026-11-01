#!/usr/bin/env bash
# Runs the server in the foreground; HOST, PORT, DATABASE_URL and JWT_SECRET come from the environment.
set -euo pipefail
cd "$(dirname "$0")"
if [ -f bin/app/conduit.dll ]; then
  # JIT fallback: no debugger or diagnostics IPC threads
  export DOTNET_EnableDiagnostics=0
  exec dotnet bin/app/conduit.dll
fi
exec bin/app/conduit
