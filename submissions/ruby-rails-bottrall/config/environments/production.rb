Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  config.logger = ActiveSupport::Logger.new($stdout)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "warn")
  config.active_support.report_deprecations = false

  # Nothing here is served from disk, cached by clients or traced per request, so drop the middleware
  # that would only spend CPU on it: ETag hashes every body, Runtime/RequestId add headers no one reads.
  config.public_file_server.enabled = false
  config.middleware.delete Rack::ETag
  config.middleware.delete Rack::ConditionalGet
  config.middleware.delete Rack::Runtime
  config.middleware.delete Rack::Sendfile
  config.middleware.delete ActionDispatch::RequestId
  config.middleware.delete ActionDispatch::RemoteIp
  config.middleware.delete Rails::Rack::Logger
end
