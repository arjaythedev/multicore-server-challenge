# frozen_string_literal: true

# Builds BcryptLanes (lanes.c with the vendored bcrypt core).
require "mkmf"

$CFLAGS << " -O3 #{ENV.fetch("NATIVE", "")} -std=gnu11 -Wall -Wno-unused-parameter -Wno-unused-function -Wno-sign-compare"
$srcs = ["lanes.c"] # crypt-bcrypt.c is #included by lanes.c, not compiled on its own
create_makefile("bcrypt_lanes")
