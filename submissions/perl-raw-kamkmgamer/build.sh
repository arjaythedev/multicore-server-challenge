#!/usr/bin/env bash
# Build check only: the server is plain Perl, there is nothing to compile.
set -euo pipefail
cd "$(dirname "$0")"

# Local development helper: use a cpanm local-lib when the box modules are absent.
if [ -d "$HOME/.perl5-conduit/lib/perl5" ]; then
  export PERL5LIB="$HOME/.perl5-conduit/lib/perl5${PERL5LIB:+:$PERL5LIB}"
elif [ -d "$HOME/perl5/lib/perl5" ]; then
  export PERL5LIB="$HOME/perl5/lib/perl5${PERL5LIB:+:$PERL5LIB}"
fi

perl -MDBD::Pg -MJSON::XS -MCrypt::Eksblowfish::Bcrypt -MEV -MDigest::SHA -MMIME::Base64 \
  -e 'printf "deps ok: DBD::Pg %s, JSON::XS %s\n", $DBD::Pg::VERSION, $JSON::XS::VERSION'
perl -c server.pl
echo "build ok"
