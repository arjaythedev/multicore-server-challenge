#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
# Defaults for this build's optional levers (each also documented where main.zig reads it): the bcrypt kernel pinned
# to asm_shrx at 5 lanes, the event loops at nice 5, MEGA with tags as text and one name lookup per list and its id
# set in id order, comments reading only the followees among each thread's authors, the per-lane counters in the
# log, a freed read connection going to the lane whose oldest read has waited longest, at most 6 read drains at
# once, and the io_uring plumbing set (buffer returns in runs, sockets as fixed files, poll-first Postgres receives,
# no quick-ACK reset for replies within 15 ms). An environment value set before start.sh wins.
export ZIG_BCRYPT_KERNEL=${ZIG_BCRYPT_KERNEL-asm_shrx:5} ZIG_LOOP_NICE=${ZIG_LOOP_NICE-5}
export ZIG_MEGA_TAG_TEXT=${ZIG_MEGA_TAG_TEXT-1} ZIG_MEGA_NAME_IDS=${ZIG_MEGA_NAME_IDS-1} ZIG_MEGA_SORTED_IDS=${ZIG_MEGA_SORTED_IDS-1}
export ZIG_COMMENTS_FW=${ZIG_COMMENTS_FW-1} ZIG_COMMENT_AUTHORS_ONCE=${ZIG_COMMENT_AUTHORS_ONCE-1} ZIG_LANE_STATS=${ZIG_LANE_STATS-1}
export ZIG_FEED3_QWAIT=${ZIG_FEED3_QWAIT-120} ZIG_OLDEST_FIRST=${ZIG_OLDEST_FIRST-1} ZIG_READ_CAP=${ZIG_READ_CAP-6}
export ZIG_BUF_RUNS=${ZIG_BUF_RUNS-1} ZIG_FIXED_FILES=${ZIG_FIXED_FILES-2} ZIG_PG_POLL_FIRST=${ZIG_PG_POLL_FIRST-1} ZIG_ACK_SKIP_MS=${ZIG_ACK_SKIP_MS-15}
export CONDUIT_FLAGS=${CONDUIT_FLAGS-ackdelay=off}
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
