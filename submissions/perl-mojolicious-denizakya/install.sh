#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: system Perl 5.38 plus all dependencies from apt
# (Mojolicious, DBI, DBD::Pg with libpq, Crypt::Eksblowfish for bcrypt) — no compilation from CPAN.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
  perl \
  libmojolicious-perl \
  libdbi-perl \
  libdbd-pg-perl \
  libcrypt-eksblowfish-perl
perl -MMojolicious -MDBI -MDBD::Pg -MCrypt::Eksblowfish::Bcrypt -e 'print "perl $^V, Mojolicious $Mojolicious::VERSION, deps ok\n"'
