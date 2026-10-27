#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04. Everything comes from the distro archive;
# no CPAN compilation, no downloaded binaries.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
  perl \
  libdbd-pg-perl \
  libjson-xs-perl \
  libcrypt-eksblowfish-perl \
  libev-perl
perl -MDBD::Pg -MJSON::XS -MCrypt::Eksblowfish::Bcrypt -MEV -MDigest::SHA -MMIME::Base64 \
  -e 'printf "perl %s, DBD::Pg %s, JSON::XS %s\n", $^V, $DBD::Pg::VERSION, $JSON::XS::VERSION'
