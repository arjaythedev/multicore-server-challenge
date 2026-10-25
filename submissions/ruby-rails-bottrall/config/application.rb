require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module Conduit
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true

    # Rails' default, spelled out because it's the biggest single win here: YJIT is enabled after boot, so it
    # compiles only code that runs while serving requests (in config/preload.rb's parent, inherited by workers).
    config.yjit = true

    # Falcon serves each request on its own fiber, so per-request state (the leased database connection,
    # CurrentAttributes, the query cache) must be fiber-local rather than thread-local.
    config.active_support.isolation_level = :fiber

    # The API's error contract is 422 for any malformed body, so params arrive exactly as sent: no wrapping
    # of unwrapped bodies into {"user": ...}, and no deep munging of [null] into [].
    config.action_controller.wrap_parameters_by_default = false
    config.action_dispatch.perform_deep_munge = false

    # Timestamps are stored as timestamptz and always rendered in UTC; plain Time objects are enough.
    config.active_record.time_zone_aware_attributes = false

    # Foreign keys already guarantee these; validating them would cost a SELECT per association on every insert.
    config.active_record.belongs_to_required_by_default = false

    # Rails' defaults guard HTML pages against framing and XSS; a JSON API only needs nosniff.
    config.action_dispatch.default_headers = { "X-Content-Type-Options" => "nosniff" }

    config.x.jwt_secret = ENV.fetch("JWT_SECRET")
  end
end
