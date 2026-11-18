# frozen_string_literal: true

# Builds Shmq (shmq.c), the shared-memory rings between workers and planner processes.
require "mkmf"

$CFLAGS << " -O3 #{ENV.fetch("NATIVE", "")} -std=gnu11 -Wall"
create_makefile("shmq")
