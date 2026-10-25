require "async"
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

    # `reads` names the statements that only read, which can share the pipeline; `merged` holds the merged
    # forms of those that concurrent requests can share an execution of (see SQL.merged), and `window` is how
    # long the pipeline collects requests before sending them.
    def initialize(url:, statements:, reads:, merged:, window:, pool_size:)
      @reads = reads
      @pipeline = Pipeline.new(-> { Database.connect(url) }, statements.slice(*reads), merged:, window:)
      @pool = Pool.new(-> { Database.connect(url) }, statements, size: pool_size)
    end

    # The rows of the named statement.
    def query(name, *params)
      @reads.include?(name) ? @pipeline.query(name, params) : @pool.query(name, params)
    end

    # The first column of the first row, or nil if there are no rows.
    def value(name, *params)
      return @pipeline.value(name, params) if @reads.include?(name)

      result = @pool.query(name, params)
      result.ntuples.zero? ? nil : result.getvalue(0, 0)
    end

    # Runs the block in a transaction on one connection; it gets a callable that runs statements.
    def transaction(&) = @pool.transaction(&)

    # One connection in pipeline mode, shared by every fiber in the worker. The first read asked for waits a
    # moment (`window`) while other requests ask for theirs, then sends them all as one group: one write, and
    # one implicit transaction under a single Sync instead of one each. Requests in the group for the same
    # mergeable statement share one execution of its merged form, each getting its own row of the result.
    # A reader fiber collects the results, which come back in the order they were sent, and hands each request
    # its row.
    #
    # Everything in a group is a read, and in READ COMMITTED each statement still sees the data as of when it
    # starts. Nothing is kept once the group's requests have their answers.
    class Pipeline
      # A pipelined connection: the requests waiting to go out, and for each execution in flight, in the order
      # they were sent, the replies waiting on it and whether the group's Sync follows it.
      Line = Data.define(:pg, :pending, :replies)

      # A request for a read: its statement and parameters, and the queue its answer comes back on.
      Request = Data.define(:name, :params, :reply)

      # Errors that mean the connection is gone, rather than anything wrong with the query.
      DISCONNECTED = [PG::ConnectionBad, PG::UnableToSend, PG::AdminShutdown, ClosedQueueError].freeze

      def initialize(connect, statements, merged:, window:)
        @connect = connect
        @statements = statements
        @merged = merged
        @window = window
        @line = nil
      end

      # The rows of a read.
      def query(name, params)
        result, = submit(name, params)
        result
      end

      # The first column of a read's first row, or nil if there are no rows.
      def value(name, params)
        result, row = submit(name, params)
        result.getvalue(row, 0) if row < result.ntuples
      end

      private

      # [result, row]: the result holding the request's answer, and the row it's in. Reads are safe to repeat,
      # so a request that finds its connection gone runs once more on a new one, and one skipped because
      # another statement in its group failed runs again.
      def submit(name, params, retried: false)
        line = @line || open
        reply = Thread::Queue.new
        line.pending << Request.new(name:, params:, reply:)
        if line.pending.size == 1
          sleep(@window)
          send_pending(line)
        end
        result, row = reply.pop
        raise result if result.is_a?(Exception)
        return submit(name, params, retried:) if result.result_status == PG::PGRES_PIPELINE_ABORTED

        result.check
        [result, row]
      rescue *DISCONNECTED
        raise if retried

        @line = nil if @line.equal?(line)
        submit(name, params, retried: true)
      end

      def open
        pg = @connect.call
        @statements.each { |name, sql| pg.prepare(name.name, sql) }
        @merged.each { |name, sql| pg.prepare(merged_name(name), sql) }
        pg.setnonblocking(true) # sends only buffer, and send_pending flushes
        pg.enter_pipeline_mode
        line = Line.new(pg:, pending: [], replies: Thread::Queue.new)
        @line = line
        # The reader is a task of its own under the event loop, not a child of the request that happened to
        # open the connection: Async stops a task's children with it, as when that request's client hangs up.
        Async::Task.new(Fiber.scheduler) { read(line) }.run
        line
      end

      def merged_name(name) = "#{name}*"

      # Sends the waiting requests as one group. Queues every reply and sends every message before anything
      # can yield, so the replies stay in the order the results will come back in.
      def send_pending(line)
        group = line.pending.dup
        return if group.empty? # the connection was retired while the group waited, failing it already

        line.pending.clear
        executions = group.group_by(&:name).flat_map { |name, requests| executions(name, requests) }
        executions.each_with_index do |(statement, params, replies), index|
          line.replies << [replies, index == executions.size - 1]
          line.pg.send_query_prepared(statement, params)
        end
        line.pg.pipeline_sync
        line.pg.socket_io.wait_writable until line.pg.flush
      rescue *DISCONNECTED => error
        # Every request in the group gets the error, and each runs again on a new connection.
        group.each { it.reply << error }
        retire(line, nil, error)
      end

      # [statement, params, [[reply, row], ...]] for each execution that answers `requests`: one merged
      # execution if the statement can be merged and more than one request wants it, otherwise one each.
      def executions(name, requests)
        return requests.map { [name.name, it.params, [[it.reply, 0]]] } unless requests.size > 1 && @merged.key?(name)

        arrays = requests.map(&:params).transpose.map { ARRAY.encode(it) }
        shared = arrays.empty? # the same statement for every request: they all read its one row
        replies = requests.each_with_index.map { |request, row| [request.reply, shared ? 0 : row] }
        [[merged_name(name), arrays, replies]]
      end

      # Each execution's results are its result, then nil; the last in a group is followed by the result
      # marking the group's Sync.
      def read(line)
        replies = nil
        loop do
          replies, synced = line.replies.pop
          result = line.pg.get_result
          line.pg.get_result
          line.pg.get_result if synced
          replies.each { |reply, row| reply << [result, row] }
          replies = nil
        end
      rescue PG::Error, IOError => error
        nil
      ensure
        retire(line, replies, error || PG::ConnectionBad.new("pipeline closed"))
      end

      # Takes a connection out of service, failing the requests waiting on it; the next request opens a new one.
      def retire(line, replies, error)
        @line = nil if @line.equal?(line)
        line.replies.close
        replies&.each { |reply, _| reply << error }
        while (waiting, = line.replies.pop)
          waiting.each { |reply, _| reply << error }
        end
        line.pending.each { it.reply << error }
        line.pending.clear
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
        rescue PG::Error
          # A connection the server has dropped (it may say so with an error of its own, such as
          # admin_shutdown) won't work again: replace it rather than return it to the pool.
          unless conn.pg.status == PG::CONNECTION_OK
            conn.pg.close unless conn.pg.finished?
            @open -= 1
            conn = nil
          end
          raise
        ensure
          @idle.push(conn) if conn
        end
      end

      # An idle connection, checked first: one the server dropped while it sat in the pool is replaced before
      # a write is sent down it, so writes never need retrying.
      def checkout
        if @idle.empty? && @open < @size
          @open += 1
          return connect
        end

        conn = @idle.pop
        return conn if alive?(conn.pg)

        conn.pg.close unless conn.pg.finished?
        connect
      rescue PG::Error
        @open -= 1
        raise
      end

      def connect = Connection.new(pg: @connect.call, prepared: Set.new)

      # Reads anything the server sent while the connection was idle, such as the error it sends as it hangs up.
      def alive?(pg)
        pg.consume_input
        pg.status == PG::CONNECTION_OK
      rescue PG::Error
        false
      end
    end
  end
end
