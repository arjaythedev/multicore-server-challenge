# Loaded by falcon.rb in the parent process before it forks the workers.
require_relative "lib/conduit"

# Turn YJIT on now that the code has loaded, so it compiles only what runs while serving requests. The forked
# workers inherit it.
RubyVM::YJIT.enable

# Compact and age the boot-time heap so the workers keep sharing it rather than copying it page by page.
Process.warmup
