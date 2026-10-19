#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
case "${CONDUIT_VARIANT:-ordinary}" in
  ordinary) exec ./bin/conduit ;;
  diagnostic) exec ./bin/conduit-diagnostic ;;
  *) echo "CONDUIT_VARIANT must be ordinary or diagnostic" >&2; exit 2 ;;
esac
