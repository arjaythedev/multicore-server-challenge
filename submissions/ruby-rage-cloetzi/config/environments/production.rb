Rage.configure do
  # One Iodine worker process per core (-1), each a single thread running an event loop with a fiber per request.
  config.server.workers_count = ENV.fetch("WEB_CONCURRENCY", -1).to_i
  config.server.port = ENV.fetch("PORT", 3000).to_i

  # Keep idle keep-alive connections for 2 minutes (Iodine's default is 40 s; Nginx expects at least 65 s).
  config.server.timeout = 120

  config.logger = Rage::Logger.new($stdout)
  config.log_level = Logger.const_get(ENV.fetch("RAGE_LOG_LEVEL", "warn").upcase)
end

# Iodine's master respawns a worker that crashes. The challenge doesn't restart a crashed server, so a crashed
# worker stops the whole server instead.
Iodine.on_state(:on_child_crush) { Iodine.stop }
