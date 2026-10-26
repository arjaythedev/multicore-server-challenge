require "async"
require "pg"

module Conduit
  class Database
    # JIT only slows these index lookups down, and with `LIMIT $n` the generic plan estimates enough rows to
    # spend 170 ms compiling. With JIT off the generic plans match the custom ones, so forcing them skips planning.
    OPTIONS = "-c jit=off -c plan_cache_mode=force_generic_plan"
    ARRAY = PG::TextEncoder::Array.new.freeze

    def self.array(values) = ARRAY.encode(values)

    def self.connect(url) = PG.connect(url, options: OPTIONS)

    def initialize(url:, statements:, reads:, merged:, batch_window:, pool_size:)
      @reads = reads
      @pipeline = Pipeline.new(-> { Database.connect(url) }, statements.slice(*reads), merged:, batch_window:)
      # Writes get their own connections so a commit waiting on the WAL doesn't hold up the pipelined reads.
      @pool = Pool.new(-> { Database.connect(url) }, statements, size: pool_size)
    end

    def query(name, *params)
      @reads.include?(name) ? @pipeline.query(name, params) : @pool.query(name, params)
    end

    def value(name, *params)
      return @pipeline.value(name, params) if @reads.include?(name)

      result = @pool.query(name, params)
      result.ntuples.zero? ? nil : result.getvalue(0, 0)
    end

    def transaction(&) = @pool.transaction(&)

    class Pipeline
      Line = Data.define(:pg, :pending, :in_flight)
      Request = Data.define(:name, :params, :reply)
      Answer = Data.define(:reply, :row)
      Execution = Data.define(:statement, :params, :answers)
      InFlight = Data.define(:answers, :ends_group)

      DISCONNECTED = [PG::ConnectionBad, PG::UnableToSend, PG::AdminShutdown, ClosedQueueError].freeze

      def initialize(connect, statements, merged:, batch_window:)
        @connect = connect
        @statements = statements
        @merged = merged
        @batch_window = batch_window
        @line = nil
      end

      def query(name, params)
        result, = submit(name, params)
        result
      end

      def value(name, params)
        result, row = submit(name, params)
        result.getvalue(row, 0) if row < result.ntuples
      end

      private

      def submit(name, params, retried: false)
        line = @line || open
        reply = Thread::Queue.new
        line.pending << Request.new(name:, params:, reply:)
        if line.pending.size == 1
          # Gives other requests time to queue their reads, so they go out together and can be merged.
          sleep(@batch_window)
          send_pending(line)
        end
        result, row = reply.pop
        raise result if result.is_a?(Exception)
        # Another statement in the group failed, so Postgres skipped this one.
        return submit(name, params, retried:) if result.result_status == PG::PGRES_PIPELINE_ABORTED

        result.check
        [result, row]
      rescue *DISCONNECTED
        # Reads are safe to repeat, so they get one more try on a new connection.
        raise if retried

        @line = nil if @line.equal?(line)
        submit(name, params, retried: true)
      end

      def open
        pg = @connect.call
        @statements.each { |name, sql| pg.prepare(name.name, sql) }
        @merged.each { |name, sql| pg.prepare(merged_name(name), sql) }
        pg.setnonblocking(true) # so sends only buffer and never yield partway through a group
        pg.enter_pipeline_mode
        line = Line.new(pg:, pending: [], in_flight: Thread::Queue.new)
        @line = line
        # Not a child of the current request's task: Async stops a task's children with it, as when that
        # request's client hangs up.
        Async::Task.new(Fiber.scheduler) { read(line) }.run
        line
      end

      def merged_name(name) = "#{name}*"

      def send_pending(line)
        group = line.pending.dup
        return if group.empty? # retire already failed it

        line.pending.clear
        executions = group.group_by(&:name).flat_map { |name, requests| executions(name, requests) }
        # Nothing in this loop can yield, so in_flight stays in the order Postgres will answer in.
        executions.each_with_index do |execution, index|
          line.in_flight << InFlight.new(answers: execution.answers, ends_group: index == executions.size - 1)
          line.pg.send_query_prepared(execution.statement, execution.params)
        end
        # One Sync makes the group one implicit transaction. That's safe because they're all reads, and in READ
        # COMMITTED each statement still takes its own snapshot.
        line.pg.pipeline_sync
        line.pg.socket_io.wait_writable until line.pg.flush
      rescue *DISCONNECTED => error
        group.each { it.reply << error }
        retire(line, error)
      end

      def executions(name, requests)
        unless requests.size > 1 && @merged.key?(name)
          return requests.map { |request|
            Execution.new(statement: name.name, params: request.params, answers: [Answer.new(reply: request.reply, row: 0)])
          }
        end

        arrays = requests.map(&:params).transpose.map { ARRAY.encode(it) }
        same_for_everyone = arrays.empty?
        answers = requests.each_with_index.map { |request, row|
          Answer.new(reply: request.reply, row: same_for_everyone ? 0 : row)
        }
        [Execution.new(statement: merged_name(name), params: arrays, answers:)]
      end

      def read(line)
        current = nil
        loop do
          current = line.in_flight.pop
          result = line.pg.get_result
          # libpq follows each statement's result with nil, and the last in a group with the Sync's result.
          line.pg.get_result
          line.pg.get_result if current.ends_group
          current.answers.each { it.reply << [result, it.row] }
          current = nil
        end
      rescue PG::Error, IOError => error
        nil
      ensure
        retire(line, error || PG::ConnectionBad.new("pipeline closed"), current)
      end

      def retire(line, error, current = nil)
        @line = nil if @line.equal?(line)
        line.in_flight.close
        current&.answers&.each { it.reply << error }
        while (waiting = line.in_flight.pop)
          waiting.answers.each { it.reply << error }
        end
        line.pending.each { it.reply << error }
        line.pending.clear
        line.pg.close unless line.pg.finished?
      end
    end

    class Pool
      Connection = Data.define(:pg, :prepared)

      def initialize(connect, statements, size:)
        @connect = connect
        @statements = statements
        @size = size
        @idle = Thread::Queue.new # under the fiber scheduler, waiting on it blocks just the waiting fiber
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
          # A dropped connection can surface as a server error (admin_shutdown) rather than ConnectionBad.
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

      def checkout
        if @idle.empty? && @open < @size
          @open += 1
          return connect
        end

        conn = @idle.pop
        # Checked before use rather than retried after, since writes aren't safe to repeat.
        return conn if alive?(conn.pg)

        conn.pg.close unless conn.pg.finished?
        connect
      rescue PG::Error
        @open -= 1
        raise
      end

      def connect = Connection.new(pg: @connect.call, prepared: Set.new)

      def alive?(pg)
        pg.consume_input # reads the error the server sends when it drops an idle connection
        pg.status == PG::CONNECTION_OK
      rescue PG::Error
        false
      end
    end
  end
end
