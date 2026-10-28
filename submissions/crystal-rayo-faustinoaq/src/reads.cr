require "set"
require "./reads_sql"

module Conduit::Reads
  # Only waiting requests share data. Each round discards all results on completion.
  record Request, handle : Rayo::Context::Deferred, kind : Int32, viewer : Int64,
    limit : Int64, offset : Int64, key : Bytes

  class Round
    getter transport : Rayo::PG::RingTransport
    getter? busy = false
    @group : Rayo::PG::Coalescer::Group(Request)?
    @requests = Array(Request).new(128)
    @mapping = [] of Tuple(Int32, Int64, Int64)
    @ids = Set(Int64).new
    @favorites = Set(Tuple(Int64, Int64)).new
    @follows = Set(Tuple(Int64, Int64)).new
    @rows = {} of Int64 => Rayo::PG::Row
    @comments = [] of Rayo::PG::Row
    @args = StaticArray(Rayo::PG::Batch, 5).new { Rayo::PG::Batch.new }
    @full = Rayo::PG::Batch.new
    @pairs = Rayo::PG::Batch.new
    @viewers = Rayo::PG::Batch.new

    def initialize(@transport : Rayo::PG::RingTransport)
    end

    def start(group : Rayo::PG::Coalescer::Group(Request))
      @group = group
      @busy = true
      @mapping.clear
      @ids.clear
      @favorites.clear
      @follows.clear
      @args.each &.clear
      group.each { |r| @requests << r }
      @requests.each do |r|
        @args[0].add(r.viewer)
        @args[1].add(r.limit)
        @args[2].add(r.offset)
        @args[3].add(r.key)
        @args[4].add(r.kind.to_i64)
      end
      if @requests.empty?
        @busy = false
        group.done
        return
      end
      case @requests.first.kind
      when 8, 9
        stmt = @requests.first.kind == 8 ? ReadSql::USERS : ReadSql::PROFILES
        if @requests.first.kind == 8
          @transport.conn.query(stmt, @args[0].param, state: self.as(Void*)) { |res, state| state.as(Round).people(res) }
        else
          @transport.conn.query(stmt, @args[0].param, @args[3].param, state: self.as(Void*)) { |res, state| state.as(Round).people(res) }
        end
      when 7
        @transport.conn.query(Sql::TAGS, state: self.as(Void*)) do |res, state|
          state.as(Round).tags(res)
        end
      when 6
        @transport.conn.query(ReadSql::COMMENTS, @args[0].param, @args[3].param, state: self.as(Void*)) do |res, state|
          state.as(Round).comments(res)
        end
      else
        @transport.conn.query(ReadSql::MIXED, @args[0].param, @args[1].param,
          @args[2].param, @args[3].param, @args[4].param, state: self.as(Void*)) do |res, state|
          state.as(Round).pages(res)
        end
      end
    end

    def people(res)
      return fail if res.error?
      res.each_partition(@requests.size) do |part, i|
        r = @requests[i]
        r.handle.finish do |ctx|
          if row = part.first?
            if r.kind == 8
              ctx.json user: {email: row.str(3), token: Conduit.token(ctx), username: row.str(2), bio: Conduit.nullable(row, 4), image: Conduit.nullable(row, 5)}
            else
              ctx.json profile: Conduit.profile(row, 2, row.bool(5))
            end
          else
            Conduit.error(ctx, r.kind == 8 ? 401 : 404)
          end
        end
      end
      release
    end

    def tags(res)
      return fail if res.error?
      @requests.each do |r|
        r.handle.finish do |ctx|
          ctx.json do |j|
            j.object { j.field("tags") { j.array { res.each { |row| j.value(row.str(0)) } } } }
          end
        end
      end
      release
    end

    def comments(res)
      return fail if res.error?
      res.each { |row| @comments << row }
      pos = 0
      @requests.each_with_index do |r, ord|
        first = pos
        while pos < @comments.size && @comments[pos].i32(0) == ord + 1
          pos += 1
        end
        r.handle.finish do |ctx|
          if @comments[first].null?(1)
            Conduit.error(ctx, 404)
          else
            ctx.json do |j|
              j.object do
                j.field("comments") do
                  j.array do
                    (first...pos).each do |i|
                      row = @comments[i]
                      j.value(Conduit.comment(ctx, row, row.bool(9), 2)) unless row.null?(2)
                    end
                  end
                end
              end
            end
          end
        end
      end
      @comments.clear
      release
    end

    def pages(res)
      return fail if res.error?
      @args[0].clear
      @full.clear
      @pairs.clear
      @viewers.clear
      res.each do |row|
        ord = row.i32(0) - 1
        id = row.null?(1) ? 0_i64 : row.i64(1)
        @mapping << {ord, id, row.i64(2)}
        next if id == 0
        @args[0].add(id) if @ids.add?(id)
        r = @requests[ord]
        @full.add(id) if r.kind == 5
        if r.viewer > 0
          @pairs.add(id)
          @viewers.add(r.viewer)
        end
      end
      # Consume flags first so the final callback can serialize borrowed article
      # rows directly, without copying their text or retaining PG result views.
      @transport.conn.query(ReadSql::FAVORITES, @pairs.param, @viewers.param, state: self.as(Void*)) do |res, state|
        state.as(Round).flags(res, false)
      end
      @transport.conn.query(ReadSql::FOLLOWS, @pairs.param, @viewers.param, state: self.as(Void*)) do |res, state|
        state.as(Round).flags(res, true)
      end
      @transport.conn.query(ReadSql::ENRICH, @args[0].param, @full.param, state: self.as(Void*)) do |res, state|
        state.as(Round).articles(res)
      end
    end

    def flags(res, follows)
      if res.error?
        @failed = true
      else
        set = follows ? @follows : @favorites
        res.each { |row| set.add({row.i64(0), row.i64(1)}) }
      end
    end

    @failed = false

    def articles(res)
      return fail if res.error? || @failed
      res.each { |row| @rows[row.i64(0)] = row }
      pos = 0
      @requests.each_with_index do |r, ord|
        first = pos
        while pos < @mapping.size && @mapping[pos][0] == ord
          pos += 1
        end
        if ctx = r.handle.context
          begin
            if r.kind == 5
              id = @mapping[first][1]
              if row = @rows[id]?
                ctx.json article: fields(ctx, row, r)
              else
                Conduit.error(ctx, 404)
              end
            else
              ctx.json do |j|
                j.object do
                  j.field("articles") do
                    j.array do
                      (first...pos).each do |i|
                        if row = @rows[@mapping[i][1]]?
                          j.value(fields(ctx, row, r))
                        end
                      end
                    end
                  end
                  j.field("articlesCount", @mapping[first][2])
                end
              end
            end
          rescue
            Conduit.error(ctx, 500)
          end
          r.handle.finish
        end
      end
      release
    end

    private def fields(ctx, row, request)
      Conduit.article_fields(ctx, row, true,
        @favorites.includes?({request.viewer, row.i64(0)}),
        @follows.includes?({request.viewer, row.i64(14)}), request.kind == 5)
    end

    def fail
      @requests.each do |r|
        r.handle.finish { |ctx| Conduit.error(ctx, 500) }
      end
      release
    end

    private def release
      @requests.clear
      @mapping.clear
      @rows.clear
      @ids.clear
      @favorites.clear
      @follows.clear
      @args.each &.clear
      {@full, @pairs, @viewers}.each &.clear
      @failed = false
      @busy = false
      @group.not_nil!.done
      @group = nil
    end
  end

  class Driver
    include Rayo::Uring::Flusher
    getter coordinator : Rayo::PG::Coalescer(Request)
    @transports = StaticArray(Rayo::PG::RingTransport, 2).new { Rayo::PG::RingTransport.new(ENV["DATABASE_URL"], 1024) }
    @rounds : Array(Round)

    def initialize
      @transports.each do |transport|
        transport.conn.query(ReadSql::SETTINGS) { |res| raise "read session setup failed" if res.error? }
      end
      @rounds = Array(Round).new(8) { |i| Round.new(@transports[i % 2]) }
      @coordinator = Rayo::PG::Coalescer(Request).new(batch_size: 1024, groups: 32, depth: 8,
        parameters: 0, window_us: 17500, max_window_us: 35000) do |group|
        Conduit::Reads.driver.not_nil!.dispatch(group)
      end
      @coordinator.attach
    end

    def dispatch(group)
      round = @rounds.find { |r| !r.busy? }.not_nil!
      begin
        round.start(group)
      rescue
        round.fail
      end
    end

    def flush : Nil
      @transports.each &.flush
    end
  end

  class_property driver : Driver? = nil

  def self.start
    self.driver = Driver.new
    Rayo::Uring.add_flusher(driver.not_nil!)
  end

  def self.enqueue(ctx, kind, viewer, limit = 1_i64, offset = 0_i64, key = Bytes.empty)
    coordinator = driver.not_nil!.coordinator
    queue = kind < 6 ? 0 : kind - 5
    unless coordinator.available?(queue)
      Conduit.error(ctx, 503)
      return
    end
    coordinator.enqueue(Request.new(ctx.defer, kind, viewer, limit, offset, key), key: queue)
  end
end
