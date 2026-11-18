#!/usr/bin/env bash
# Runs the server in the foreground. DATABASE_URL, JWT_SECRET, HOST and PORT come from the box.
set -euo pipefail
cd "$(dirname "$0")"
# Each user holds a connection open. Started from a shell, the soft limit may be 1024 descriptors, so raise it to
# the hard limit. The box's service already sets both to 200000.
ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
# The app host finds the .NET runtime through DOTNET_ROOT; the service environment does not set it.
export DOTNET_ROOT=/usr/local/lib/dotnet-sdk-10.0.303
exec ./out/conduit
