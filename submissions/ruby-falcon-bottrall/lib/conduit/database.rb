require "pg"

module Conduit
  # A pool of Postgres connections for one worker process. The worker is a single-threaded event loop with a
  # fiber per request: pg hands control back to the loop while a query runs, and Thread::Queue blocks only the
  # waiting fiber, so one worker keeps all its connections busy without threads.
  #
  # Connections open lazily, up to `size`, and prepare each statement the first time they run it. They run with
  # JIT off and generic plans: every statement here is a handful of index lookups, which JIT only slows down
  # (the generic plan for a list estimates enough rows to trigger 170 ms of JIT compilation), and with plans
  # reused Postgres skips planning, which costs as much as executing for most of them.
  class Database
    OPTIONS = "-c jit=off -c plan_cache_mode=force_generic_plan"
    ARRAY = PG::TextEncoder::Array.new.freeze

    Connection = Data.define(:pg, :prepared)

    def initialize(url:, size:, statements:)
      @url = url
      @size = size
      @statements = statements
      @idle = Thread::Queue.new
      @open = 0
    end

    # The rows of the named statement.
    def query(name, *params) = with_connection { run(it, name, params) }

    # The first column of the first row, or nil if there are no rows.
    def value(name, *params)
      result = query(name, *params)
      result.ntuples.zero? ? nil : result.getvalue(0, 0)
    end

    # Runs the block in a transaction on one connection; it gets a callable that runs statements.
    def transaction
      with_connection do |conn|
        conn.pg.exec("BEGIN")
        result = yield ->(name, *params) { run(conn, name, params) }
        conn.pg.exec("COMMIT")
        result
      ensure
        conn.pg.exec("ROLLBACK") unless conn.pg.transaction_status == PG::PQTRANS_IDLE
      end
    end

    # A text[] parameter.
    def self.array(values) = ARRAY.encode(values)

    private

    def run(conn, name, params)
      prepare(conn, name) unless conn.prepared.include?(name)
      conn.pg.exec_prepared(name.name, params)
    end

    def prepare(conn, name)
      conn.pg.prepare(name.name, @statements.fetch(name))
      conn.prepared << name
    end

    def with_connection
      conn = checkout
      begin
        yield conn
      rescue PG::ConnectionBad, PG::UnableToSend
        conn.pg.close
        @open -= 1
        conn = nil
        raise
      ensure
        @idle.push(conn) if conn
      end
    end

    def checkout
      return @idle.pop unless @idle.empty? && @open < @size

      @open += 1
      Connection.new(pg: PG.connect(@url, options: OPTIONS), prepared: Set.new)
    rescue PG::Error
      @open -= 1
      raise
    end
  end
end
