#!/usr/bin/env bash
# Runs the server in the foreground: a native binary, no JVM. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
cd "$(dirname "$0")"
exec build/bin/linuxX64/releaseExecutable/conduit.kexe
