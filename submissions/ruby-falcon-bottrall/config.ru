require_relative "lib/conduit"

db = Conduit::Database.new(url: ENV.fetch("DATABASE_URL"), statements: Conduit::SQL::STATEMENTS,
                           reads: Conduit::SQL::READS, merged: Conduit::SQL::MERGED,
                           batch_window: Float(ENV.fetch("BATCH_WINDOW", "0.010")),
                           pool_size: Integer(ENV.fetch("DB_POOL", "2")))
run Conduit::App.new(db:, tokens: Conduit::Tokens.new(secret: ENV.fetch("JWT_SECRET")), passwords: Conduit::Passwords)
