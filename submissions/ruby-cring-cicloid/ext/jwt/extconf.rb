# frozen_string_literal: true

# Builds FastJWT (jwt.c), linked against libsodium from install.sh.
require "mkmf"

abort "libsodium not found (install.sh builds it)" unless have_library("sodium", "crypto_auth_hmacsha256", "sodium.h")
$CFLAGS << " -O3 #{ENV.fetch("NATIVE", "")} -std=gnu11 -Wall"
create_makefile("fast_jwt")
