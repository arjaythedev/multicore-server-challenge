# frozen_string_literal: true

require "pg"

# Postgres for one process: a few connections in libpq pipeline mode, shared by every request fiber.
#
# A request sends its statement(s) and a Sync on one connection and waits on its own fiber-local queue.
# Nothing is flushed then: one flusher fiber per connection runs after the requests of the current
# event-loop pass have queued theirs and writes them all at once, and one reader fiber per connection
# reads results as they arrive and hands each group (the results up to its Sync) to the fiber that
# sent it. Each group is its own implicit transaction, so an error aborts only that request's statements.
#
# Only Fiber-scheduler primitives are used (IO#wait_readable/wait_writable, Thread::Queue), so it runs
# under Async's scheduler and Itsi's alike.
class DB
  Error = Class.new(StandardError)

  # A failed statement: its SQLSTATE (e.g. "23505" for a unique violation).
  class Failed < Error
    attr_reader :sqlstate

    def initialize(sqlstate, message)
      @sqlstate = sqlstate
      super(message)
    end
  end

  class Conn
    attr_reader :pending

    def initialize(url, statements, setup)
      @pg = PG.connect(url)
      setup.each { |sql| @pg.exec(sql) }
      statements.each { |name, sql| @pg.prepare(name.to_s, sql) }
      @pg.setnonblocking(true)
      @pg.enter_pipeline_mode
      @io = @pg.socket_io
      @groups = [] # [queue, results] per sent group, in order
      @pending = 0
      @dirty = false
      @kick = Thread::Queue.new
      @send_sync = @pg.respond_to?(:send_pipeline_sync) # libpq 17+: queue the Sync without flushing
    end

    def start
      Fiber.schedule { read_loop }
      Fiber.schedule { flush_loop }
    end

    # Sends `statements` ([[name, params], ...]) as one group and waits for its results.
    def run(statements, queue)
      i = 0
      while i < statements.size
        name, params = statements[i]
        @pg.send_query_prepared(name.name, params) # Symbol#name: a frozen String, no allocation
        i += 1
      end
      if @send_sync then @pg.send_pipeline_sync else @pg.pipeline_sync end
      @groups << [queue, []]
      @pending += 1
      unless @dirty
        @dirty = true
        @kick.push(true)
      end
      queue.pop
    end

    # Ends both fibers, then the connection.
    def close
      @closed = true
      @kick.close
      @pg.close
    end

    private

    def flush_loop
      loop do
        @kick.pop or return # nil: closed
        @dirty = false
        @io.wait_writable until @pg.flush
      end
    end

    def read_loop
      loop do
        @io.wait_readable
        @pg.consume_input
        # With nothing in flight libpq is never busy and get_result returns nil forever: stop then.
        until @groups.empty? || @pg.is_busy
          result = @pg.get_result
          next unless result # end of one statement's results
          group = @groups.first
          if result.result_status == PG::PGRES_PIPELINE_SYNC
            result.clear
            @groups.shift
            @pending -= 1
            group[0].push(group[1])
          else
            group[1] << result
          end
        end
      end
    rescue StandardError => error
      fail_all(error) unless @closed
    end

    def fail_all(error)
      warn "postgres connection failed: #{error.class}: #{error.message}"
      @groups.each { |queue, _| queue.push(error) }
      @groups.clear
    end
  end

  def initialize(url, size, statements, setup: [])
    @conns = Array.new(size) { Conn.new(url, statements, setup) }
    @next = 0
  end

  def start
    @conns.each(&:start)
  end

  def close
    @conns.each(&:close)
  end

  # Runs one prepared statement and returns its PG::Result, or raises DB::Failed.
  def query(name, params)
    results = group([[name, params]])
    results[0]
  end

  # Runs several prepared statements as one group (one round trip, one implicit transaction) and returns
  # their results. Raises DB::Failed for the first failed statement.
  def group(statements)
    queue = (Thread.current[:db_queue] ||= Thread::Queue.new) # Thread#[] is fiber-local
    results = pick.run(statements, queue)
    raise results if results.is_a?(Exception)

    results.each do |result|
      status = result.result_status
      next if status == PG::PGRES_TUPLES_OK || status == PG::PGRES_COMMAND_OK

      sqlstate = result.error_field(PG::Result::PG_DIAG_SQLSTATE)
      message = result.error_message
      results.each(&:clear)
      raise Failed.new(sqlstate, message)
    end
    results
  end

  # The first column of the first row of one statement, or nil when it returned no row.
  def value(name, params)
    result = query(name, params)
    value = result.ntuples.zero? ? nil : result.getvalue(0, 0)
    result.clear
    value
  end

  private

  # The connection with the fewest groups in flight.
  def pick
    best = @conns[0]
    i = 1
    while i < @conns.size
      best = @conns[i] if @conns[i].pending < best.pending
      i += 1
    end
    best
  end
end
