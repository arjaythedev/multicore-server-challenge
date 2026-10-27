#!/usr/bin/env bash
# Foreground prefork server. Configured by DATABASE_URL, JWT_SECRET, HOST, PORT and WORKERS.
set -euo pipefail
cd "$(dirname "$0")"

if [ -d "$HOME/.perl5-conduit/lib/perl5" ]; then
  export PERL5LIB="$HOME/.perl5-conduit/lib/perl5${PERL5LIB:+:$PERL5LIB}"
elif [ -d "$HOME/perl5/lib/perl5" ]; then
  export PERL5LIB="$HOME/perl5/lib/perl5${PERL5LIB:+:$PERL5LIB}"
fi

exec perl server.pl
