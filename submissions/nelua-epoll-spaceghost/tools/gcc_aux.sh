#!/usr/bin/env bash
# Nelibc's GCC archive shares two .S objects and one C ABI adapter with its Zig
# profiles. For this source build, compile those auxiliaries with GCC too.
# This driver accepts only the upstream recipe's `cc` subcommand; ZIGFLAGS must
# be empty. No Zig compiler or modified Nelibc source is used.
set -euo pipefail
if [ "${1:-}" != cc ]; then echo 'GCC auxiliary driver expects cc' >&2; exit 2; fi
shift
exec "${NC_AUX_GCC:-gcc}" "$@"
