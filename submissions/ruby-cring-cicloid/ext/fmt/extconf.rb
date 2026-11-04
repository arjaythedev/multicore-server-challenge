# frozen_string_literal: true

# Builds Fmt (fmt.c), the document pieces planner.rb joins.
require "mkmf"

$CFLAGS << " -O3 #{ENV.fetch("NATIVE", "")} -std=gnu11 -Wall"
create_makefile("fmt")
