#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"

mkdir -p "$BUILD/config"
cp -a "$DIR/config/." "$BUILD/config/"

cd "$BUILD"
exec ./multicore