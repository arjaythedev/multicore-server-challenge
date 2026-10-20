#!/usr/bin/env bash
# Builds the app as a normal user: dependency check and a syntax check of all sources.
set -euo pipefail
cd "$(dirname "$0")"

# Local development: use the cpanm local-lib if present (the box gets everything from apt).
if [ -d "$HOME/.perl5-conduit/lib/perl5" ]; then
  export PERL5LIB="$HOME/.perl5-conduit/lib/perl5${PERL5LIB:+:$PERL5LIB}"
fi

perl -e 'use Mojolicious; use DBI; use DBD::Pg; use Crypt::Eksblowfish::Bcrypt; print "deps ok: Mojolicious $Mojolicious::VERSION, DBI $DBI::VERSION, DBD::Pg $DBD::Pg::VERSION\n"'
perl -Ilib -c conduit.pl
find lib -name '*.pm' -exec perl -Ilib -c {} \; > /dev/null
echo "build ok"
