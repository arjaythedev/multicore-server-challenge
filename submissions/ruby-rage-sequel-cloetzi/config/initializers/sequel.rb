require "time"

# Rage runs every request in its own fiber, so Sequel's connection pool hands out connections per fiber rather
# than per thread. Its pool (timed_queue on Ruby >= 3.2) waits on a Thread::Queue, which yields to Rage's fiber
# scheduler, and pg's async API yields while Postgres works, so a worker keeps serving other requests meanwhile.
Sequel.extension :fiber_concurrency

# Every timestamp column is timestamptz; read and write them as UTC.
Sequel.default_timezone = :utc

DB = Sequel.connect(
  ENV.fetch("DATABASE_URL"),
  # One pool per Iodine worker. A request holds a connection only while a query (or transaction) runs.
  max_connections: Integer(ENV.fetch("DB_POOL", 5)),
  pool_timeout: 10,
  # Don't open a connection just to check the URL: the master process boots the app and then forks.
  test: false
)
DB.extension :pg_array # tag_list comes back as a text[]

Sequel::Model.db = DB
# Lookups by primary key, inserts and updates done through a model instance use prepared statements.
Sequel::Model.plugin :prepared_statements
# A single INSERT or UPDATE is atomic on its own; wrapping each save in BEGIN/COMMIT only adds round trips.
# Multi-statement writes (Article.publish) open their own transaction.
Sequel::Model.use_transactions = false
# Like Active Record's save: return nil on validation failure rather than raising.
Sequel::Model.raise_on_save_failure = false

# The master loads the models (which reads the schema) before Iodine forks the workers. Workers must not share
# its connections, so it drops them before forking; each worker then connects on first use.
Iodine.on_state(:pre_start) { DB.disconnect }
