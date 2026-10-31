#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
# Defaults for this build's optional levers (each also documented where main.zig reads it): the bcrypt kernel pinned
# to asm_shrx at 5 lanes, MEGA with tags as text, one name lookup per list and its id set in id order, at most 4
# read drains in flight across the lanes, and the per-lane counters in the log. An environment value set before
# start.sh wins.
export ZIG_BCRYPT_KERNEL=${ZIG_BCRYPT_KERNEL-asm_shrx:5}
export ZIG_MEGA_TAG_TEXT=${ZIG_MEGA_TAG_TEXT-1} ZIG_MEGA_NAME_IDS=${ZIG_MEGA_NAME_IDS-1} ZIG_MEGA_SORTED_IDS=${ZIG_MEGA_SORTED_IDS-1}
export ZIG_READ_CAP=${ZIG_READ_CAP-4} ZIG_LANE_STATS=${ZIG_LANE_STATS-1}
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
