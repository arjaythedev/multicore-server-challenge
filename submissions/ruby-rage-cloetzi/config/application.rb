require "bundler/setup"
require "rage"
Bundler.require(*Rage.groups)

require "active_record"
require "rage/all"

require_relative "../lib/access_tokens"
require_relative "../lib/malformed_body"

Rage.configure do
  # Rage parses request bodies before any controller runs, and answers one it can't parse with a bare 400.
  # The API's contract for a malformed body is a 422 with the usual error JSON.
  config.middleware.use MalformedBody
end

require "rage/setup"
