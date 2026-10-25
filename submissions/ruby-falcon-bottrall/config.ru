# The composition root: wires the app to Postgres, the JWT secret and bcrypt from the environment.
require_relative "lib/conduit"

db = Conduit::Database.new(url: ENV.fetch("DATABASE_URL"), statements: Conduit::SQL::STATEMENTS,
                           reads: Conduit::SQL::READS, pool_size: Integer(ENV.fetch("DB_POOL", "2")))
run Conduit::App.new(db:, tokens: Conduit::Tokens.new(secret: ENV.fetch("JWT_SECRET")), passwords: Conduit::Passwords)
