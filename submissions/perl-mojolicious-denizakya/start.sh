#!/usr/bin/env bash
# Runs Hypnotoad (Mojolicious's preforking supervisor) in the foreground: one worker per core,
# each worker a single-threaded event loop with one Postgres connection. Configured only by
# DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
cd "$(dirname "$0")"

if [ -d "$HOME/.perl5-conduit/lib/perl5" ]; then
  export PERL5LIB="$HOME/.perl5-conduit/lib/perl5${PERL5LIB:+:$PERL5LIB}"
fi

# Only needed on macOS: Objective-C runtime refuses fork()ed children by default. No-op on Linux.
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

exec perl hypnotoad.pl conduit.pl -f
