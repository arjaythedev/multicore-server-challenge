Rage.configure do
  config.server.workers_count = 1
  config.server.port = ENV.fetch("PORT", 3000).to_i
  config.logger = Rage::Logger.new($stdout)
  config.log_level = Logger::DEBUG
  config.middleware.use Rage::Reloader
end
