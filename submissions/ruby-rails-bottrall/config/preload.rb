# Loaded by falcon.rb in the parent process before it forks the workers.
require_relative "environment"

# Compact and age the boot-time heap so the forked workers keep sharing it rather than copying it page by page.
Process.warmup
