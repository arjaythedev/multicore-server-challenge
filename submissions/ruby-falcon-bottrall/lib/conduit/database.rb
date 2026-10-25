require "pg"

module Conduit
  # A worker's Postgres connections. Reads go down one pipelined connection that all the worker's requests
  # share; writes and transactions use a small pool of ordinary connections, so a commit waiting on the WAL
  # never holds up the reads queued behind it.
  #
  # Few connections serve this workload better than many: going from 11 connections per worker to 2 cut
  # Postgres's CPU per request by a fifth, and 1 by more, but with one plain connection each worker's queries
  # queue for it, one round trip at a time. Pipelining keeps one backend per worker busy without the queue.
  #
  # Every connection runs with JIT off and generic plans: each statement here is a handful of index lookups,
  # which JIT only slows down (the generic plan for a list estimates enough rows to trigger 170 ms of JIT
  # compilation), and reusing plans skips planning, which costs as much as executing for most of them.
  class Database
    OPTIONS = "-c jit=off -c plan_cache_mode=force_generic_plan"
    ARRAY = PG::TextEncoder::Array.new.freeze

    # A text[] parameter.
    def self.array(values) = ARRAY.encode(values)

    def self.connect(url) = PG.connect(url, options: OPTIONS)

    # `reads` names the statements that only read, which can share the pipeline.
    def initialize(url:, statements:, reads:, pool_size:)
      @reads = reads
      @pipeline = Pipeline.new(-> { Database.connect(url) }, statements.slice(*reads))
      @pool = Pool.new(-> { Database.connect(url) }, statements, size: pool_size)
    end

    # The rows of the named statement.
    def query(name, *params)
      @reads.include?(name) ? @pipeline.query(name, params) : @pool.query(name, params)
    end

    # The first column of the first row, or nil if there are no rows.
    def value(name, *params)
      result = query(name, *params)
      result.ntuples.zero? ? nil : result.getvalue(0, 0)
    end

    # Runs the block in a transaction on one connection; it gets a callable that runs statements.
    def transaction(&) = @pool.transaction(&)

    # One connection in pipeline mode, shared by every fiber in the worker. Each query goes out as soon as
    # it's asked for, followed by its own Sync, so it's still its own implicit transaction; a reader fiber
    # collects the results, which come back in the order the queries were sent, and hands each to its fiber.
    class Pipeline
      # A pipelined connection and the reply queues of its queries in flight, in the order they were sent.
      Line = Data.define(:pg, :replies)

      def initialize(connect, statements)
        @connect = connect
        @statements = statements
        @line = nil
      end

      def query(name, params)
        line = @line || open
        reply = Thread::Queue.new
        # Queue the reply and both messages before anything can yield, so they stay in order across fibers.
        line.replies << reply
        line.pg.send_query_prepared(name.name, params)
        line.pg.pipeline_sync
        line.pg.socket_io.wait_writable until line.pg.flush
        result = reply.pop
        raise result if result.is_a?(Exception)

        result.check
        result
      end

      private

      def open
        pg = @connect.call
        @statements.each { |name, sql| pg.prepare(name.name, sql) }
        pg.setnonblocking(true) # sends only buffer, and query flushes
        pg.enter_pipeline_mode
        @line = Line.new(pg:, replies: Thread::Queue.new)
        line = @line
        Fiber.schedule { read(line) }
        line
      end

      # Each query's results are its result, then nil, then the result marking its Sync.
      def read(line)
        reply = nil
        loop do
          reply = line.replies.pop
          result = line.pg.get_result
          line.pg.get_result
          line.pg.get_result
          reply << result
          reply = nil
        end
      rescue PG::Error, IOError => error
        # The connection is gone: fail the queries waiting on it; the next query opens a new one.
        @line = nil if @line.equal?(line)
        line.replies.close
        reply&.push(error)
        while (waiting = line.replies.pop)
          waiting << error
        end
        line.pg.close unless line.pg.finished?
      end
    end

    # Ordinary connections for writes and transactions, opened as needed up to `size`. Thread::Queue blocks
    # only the waiting fiber.
    class Pool
      Connection = Data.define(:pg, :prepared)

      def initialize(connect, statements, size:)
        @connect = connect
        @statements = statements
        @size = size
        @idle = Thread::Queue.new
        @open = 0
      end

      def query(name, params) = with_connection { run(it, name, params) }

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
        Connection.new(pg: @connect.call, prepared: Set.new)
      rescue PG::Error
        @open -= 1
        raise
      end
    end
  end
end
