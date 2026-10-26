require_relative "lib/conduit"

# Enabled after loading so it only compiles what runs while serving requests.
RubyVM::YJIT.enable

# So the forked workers keep sharing the boot heap instead of copying it page by page.
Process.warmup
