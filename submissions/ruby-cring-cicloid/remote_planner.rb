# frozen_string_literal: true

require "json"
require "socket"
require_relative "planner"

# Batched reads for the whole server instead of per worker. PLANNERS processes run Planner (planner.rb)
# against Postgres, and the HTTP workers send them their reads over stream socketpairs made before the
# fork. Planners take turns by time: every worker sends what it receives during window w to planner
# w mod PLANNERS (CLOCK_MONOTONIC is the same clock in every process), so each window is still one batch for
# the whole server, while planning and assembly are spread over several processes. With a planner per
# worker, every planner looked up the same hot articles, favorite counts and comments in its own batches.
#
# Frames are a 4-byte length, then:
#   request: id (u32), kind (u8), viewer (i64), then a, b, c, each a u16 length (0xFFFF = nil) and bytes
#   reply:   id (u32), status (u8: 0 document, 1 not found, 2 failed, 3 user as JSON), payload
module RemotePlanner
  KINDS = %i[tags user profile article comments feed global tag author favorited article_id].freeze
  KIND_INDEX = KINDS.each_with_index.to_h.freeze
  NIL_FIELD = "\xFF\xFF".b.freeze
  DOCUMENT = 0
  MISSING = 1
  FAILED = 2
  USER = 3
  READ_SIZE = 1 << 16

  # Reads length-prefixed frames from `socket` and yields each payload, until the peer closes.
  def self.frames(socket)
    buffer = String.new(capacity: READ_SIZE, encoding: Encoding::BINARY)
    loop do
      chunk = socket.read_nonblock(READ_SIZE, exception: false)
      if chunk == :wait_readable
        socket.wait_readable
        next
      end
      break if chunk.nil?

      buffer << chunk
      at = 0
      while buffer.bytesize - at >= 4
        length = buffer.unpack1("N", offset: at)
        break if buffer.bytesize - at - 4 < length

        yield buffer.byteslice(at + 4, length)
        at += 4 + length
      end
      buffer = buffer.byteslice(at, buffer.bytesize - at) if at.positive?
    end
  end

  def self.field(value) = value.nil? ? NIL_FIELD : [value.bytesize].pack("n") << value.b

  # Worker side: the Planner interface, answered by the planner processes.
  class Client
    Pending = Struct.new(:fiber, :status, :payload)

    def initialize(sockets, window)
      @sockets = sockets
      @window_ms = (window * 1000).round.clamp(1, nil)
      @next = 0
      @waiting = {}
      @out = sockets.map { String.new(capacity: 1 << 16, encoding: Encoding::BINARY) }
      @kick = Thread::Queue.new
      @dirty = false
      sockets.each { |socket| Fiber.schedule { read(socket) } }
      Fiber.schedule { flush_loop }
    end

    def tags = ask(:tags, 0, nil, nil, nil)

    def user(id)
      payload = ask(:user, id, nil, nil, nil)
      payload && JSON.parse(payload)
    end

    def profile(viewer, username) = ask(:profile, viewer, username, nil, nil)
    def article(viewer, slug) = ask(:article, viewer, slug, nil, nil)
    def article_by_id(viewer, id) = ask(:article_id, viewer, id, nil, nil)
    def comments(viewer, slug) = ask(:comments, viewer, slug, nil, nil)
    def feed(viewer, limit, offset) = ask(:feed, viewer, limit, offset, nil)
    def list(kind, viewer, value, limit, offset) = ask(kind, viewer, value, limit, offset)

    private

    def ask(kind, viewer, a, b, c)
      id = (@next = (@next + 1) & 0xFFFFFFFF)
      pending = Pending.new(Fiber.current, nil, nil)
      @waiting[id] = pending
      body = [id, KIND_INDEX.fetch(kind), viewer].pack("NCq>") << RemotePlanner.field(a) << RemotePlanner.field(b) <<
             RemotePlanner.field(c)
      planner = (Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) / @window_ms) % @sockets.size
      @out[planner] << [body.bytesize].pack("N") << body
      unless @dirty # one write per planner per event-loop pass, for every request queued in it
        @dirty = true
        @kick.push(true)
      end
      Fiber.scheduler.block(pending, nil) until pending.status
      case pending.status
      when DOCUMENT, USER then pending.payload.force_encoding(Encoding::UTF_8)
      when MISSING then nil
      else raise "planner failed: #{pending.payload}"
      end
    end

    def flush_loop
      loop do
        @kick.pop
        @dirty = false
        @out.each_with_index do |out, i|
          next if out.empty?

          data = out.dup
          out.clear
          @sockets[i].write(data)
        end
      end
    end

    def read(socket)
      RemotePlanner.frames(socket) do |frame|
        id, status = frame.unpack("NC")
        pending = @waiting.delete(id) or next
        pending.payload = frame.byteslice(5, frame.bytesize - 5)
        pending.status = status
        Fiber.scheduler.unblock(pending, pending.fiber)
      end
      failed = @waiting.values
      @waiting.clear
      failed.each do |pending| # the planner is gone
        pending.status = FAILED
        pending.payload = "planner process exited"
        Fiber.scheduler.unblock(pending, pending.fiber)
      end
    end
  end

  # Planner side: reads the workers' requests into the planner, writes each worker's answers from a batch
  # in one write.
  class Server
    Reply = Struct.new(:server, :socket, :id) do
      def call(request) = server.answer(socket, id, request)
    end

    def initialize(planner, sockets)
      @planner = planner
      @sockets = sockets
      @out = {} # socket => [header, payload, header, payload, ...] waiting to be written
      planner.after_batch = -> { flush }
    end

    def run(task)
      @sockets.each { |socket| task.async { read(socket) } }
    end

    def answer(socket, id, request)
      out = (@out[socket] ||= [])
      if request.error
        status = FAILED
        payload = request.error.message.b
      elsif request.document == :missing
        status = MISSING
        payload = ""
      elsif request.kind == :user
        status = USER
        payload = JSON.generate(request.document)
      else
        status = DOCUMENT
        payload = request.document
      end
      out << [5 + payload.bytesize, id, status].pack("NNC") << payload # written as is (writev): no copy
    end

    private

    def read(socket)
      RemotePlanner.frames(socket) do |frame|
        id, kind, viewer = frame.unpack("NCq>")
        at = 13
        args = Array.new(3) do
          length = frame.unpack1("n", offset: at)
          at += 2
          if length == 0xFFFF
            nil
          else
            value = frame.byteslice(at, length).force_encoding(Encoding::UTF_8)
            at += length
            value
          end
        end
        @planner.submit(Planner::Request.new(KINDS.fetch(kind), viewer, args[0], args[1], args[2], nil, nil, nil,
                                             Reply.new(self, socket, id)))
      end
    end

    def flush
      @out.each do |socket, out|
        next if out.empty?

        parts = out.dup
        out.clear
        parts.each_slice(512) { |slice| socket.write(*slice) } # IOV_MAX is 1,024
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
