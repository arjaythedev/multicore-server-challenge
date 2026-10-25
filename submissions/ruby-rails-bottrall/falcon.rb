#!/usr/bin/env -S falcon host
require "etc"
require "falcon/environment/rack"

service "conduit" do
  include Falcon::Environment::Rack

  url "http://#{ENV.fetch("HOST", "127.0.0.1")}:#{ENV.fetch("PORT", "3000")}"

  # Plain HTTP/1.1 with keep-alive, and no idle timeout: Nginx (or a browser) decides when to close.
  endpoint do
    Async::HTTP::Endpoint.parse(url, protocol: Async::HTTP::Protocol::HTTP11).with(reuse_address: true)
  end

  # Falcon's default stack gzips any response the client accepts gzip for. Compression is optional in this API
  # and costs ~10% of a worker's CPU, so serve the Rack app without it.
  middleware do
    ::Protocol::Rack::Adapter.new(rack_app)
  end

  # One forked worker per core, each an event loop serving every connection on its own fiber.
  count ENV.fetch("WEB_CONCURRENCY") { Etc.nprocessors }.to_i

  # The challenge doesn't restart a crashed server, so neither does the container.
  container_options do
    super().merge(restart: false)
  end

  # Boot Rails once in the parent; workers fork from it and share its memory copy-on-write.
  preload "config/preload.rb"
end
