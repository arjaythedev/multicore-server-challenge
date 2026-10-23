#!/usr/bin/env bash
# C backend (-z: gcc optimizer) with threadsafe runtime (-t).
set -euo pipefail
cd "$(dirname "$0")"
export PUREBASIC_HOME=/opt/purebasic
mkdir -p bin
"$PUREBASIC_HOME/compilers/pbcompilerc" --thread --optimizer --quiet conduit.pb --output bin/conduit
