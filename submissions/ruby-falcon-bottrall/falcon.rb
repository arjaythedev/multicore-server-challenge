#!/usr/bin/env -S falcon host
require "etc"
require "falcon/environment/rack"

service "conduit" do
  include Falcon::Environment::Rack

  url "http://#{ENV.fetch("HOST", "127.0.0.1")}:#{ENV.fetch("PORT", "3000")}"

  endpoint do
    Async::HTTP::Endpoint.parse(url, protocol: Async::HTTP::Protocol::HTTP11).with(reuse_address: true)
  end

  # Without Falcon's default stack, which gzips responses: compression is optional here and cost ~10% of the CPU.
  middleware do
    ::Protocol::Rack::Adapter.new(rack_app)
  end

  count ENV.fetch("WEB_CONCURRENCY") { Etc.nprocessors }.to_i

  # The challenge doesn't restart a crashed server.
  container_options do
    super().merge(restart: false)
  end

  preload "preload.rb"
end
