require_relative "config/application"

# Loaded once in the master process; Iodine forks the workers from it.
# Compact and age the boot-time heap so the workers keep sharing it rather than copying it page by page.
Process.warmup

# YJIT is switched on only now that the app has booted, so it compiles just the code that serves requests,
# and every forked worker inherits it. (Rails does the same with config.yjit.)
RubyVM::YJIT.enable

run Rage.application
