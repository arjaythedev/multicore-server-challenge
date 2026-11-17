#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
case "${APP_IMPL:-nelua}" in
  nelua) binary=bin/conduit ;;
  c) binary=bin/conduit-c ;;
  *) echo "APP_IMPL must be c or nelua" >&2; exit 1 ;;
esac
case "${MEMORY_IMPL:-nelibc}" in
  host) ;;
  nelibc) binary+="-nelibc" ;;
  *) echo "MEMORY_IMPL must be host or nelibc" >&2; exit 1 ;;
esac
case "${CORE_PROFILE:-freestanding}" in
  host) ;;
  freestanding) binary+="-freestanding" ;;
  *) echo "CORE_PROFILE must be host or freestanding" >&2; exit 1 ;;
esac
exec "$binary"
