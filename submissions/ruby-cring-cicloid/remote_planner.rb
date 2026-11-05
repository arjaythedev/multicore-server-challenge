# frozen_string_literal: true

require "json"
require_relative "planner"
require_relative "ext/shmq/shmq"

# Batched reads for the whole server instead of per worker. PLANNERS processes run Planner (planner.rb)
# against Postgres, and the HTTP workers send them their reads through shared memory: for each (worker,
# planner) pair, one ring of requests and one of replies (ext/shmq), mapped before the fork, each with an
# eventfd that is written once per batch, not per message. Planners take turns by time: every worker sends
# what it receives during window w to planner w mod PLANNERS (CLOCK_MONOTONIC is the same clock in every
# process), so each window is one batch for the whole server while planning and assembly are spread over
# several processes. With a planner per worker, every planner looked up the same hot articles, favorite
# counts and comments in its own, smaller batches. (A first version over socketpairs spent in framing,
# syscalls and copies about what it saved in Postgres.)
#
# Messages:
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
  REQUEST_RING = Integer(ENV.fetch("PLANNER_REQUEST_RING", (1 << 20).to_s))
  REPLY_RING = Integer(ENV.fetch("PLANNER_REPLY_RING", (16 << 20).to_s))

  # The two rings between one worker and one planner, made before the fork.
  Link = Struct.new(:requests, :replies) do
    def self.make = new(Shmq::Ring.new(REQUEST_RING), Shmq::Ring.new(REPLY_RING))
  end

  def self.field(value) = value.nil? ? NIL_FIELD : [value.bytesize].pack("n") << value.b

  # Pushes `message`, waiting (and waking the consumer) while the ring is full.
  def self.push(ring, message)
    until ring.push(message)
      ring.notify
      sleep 0.0005
    end
  end

  # Yields every message that arrives on `ring`.
  def self.each_message(ring)
    io = IO.for_fd(ring.eventfd, autoclose: false)
    loop do
      io.wait_readable
      ring.drain.each { |message| yield message }
    end
  end

  # Worker side: the Planner interface, answered by the planner processes.
  class Client
    Pending = Struct.new(:fiber, :status, :payload)

    def initialize(links, window)
      @links = links
      @window_ms = (window * 1000).round.clamp(1, nil)
      @next = 0
      @waiting = {}
      @dirty = Array.new(links.size, false)
      @kick = Thread::Queue.new
      @kicked = false
      links.each { |link| Fiber.schedule { read(link.replies) } }
      Fiber.schedule { notify_loop }
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
      message = [id, KIND_INDEX.fetch(kind), viewer].pack("NCq>") << RemotePlanner.field(a) << RemotePlanner.field(b) <<
                RemotePlanner.field(c)
      planner = (Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) / @window_ms) % @links.size
      RemotePlanner.push(@links[planner].requests, message)
      @dirty[planner] = true
      unless @kicked # one wake-up per planner per event-loop pass
        @kicked = true
        @kick.push(true)
      end
      Fiber.scheduler.block(pending, nil) until pending.status
      case pending.status
      when DOCUMENT, USER then pending.payload.force_encoding(Encoding::UTF_8)
      when MISSING then nil
      else raise "planner failed: #{pending.payload}"
      end
    end

    def notify_loop
      loop do
        @kick.pop
        @kicked = false
        @dirty.each_with_index do |dirty, i|
          next unless dirty

          @dirty[i] = false
          @links[i].requests.notify
        end
      end
    end

    def read(ring)
      RemotePlanner.each_message(ring) do |message|
        id, status = message.unpack("NC")
        pending = @waiting.delete(id) or next
        pending.payload = message.byteslice(5, message.bytesize - 5)
        pending.status = status
        Fiber.scheduler.unblock(pending, pending.fiber)
      end
    end
  end

  # Worker side, split: the cheap point lookups with nothing to share between requests (tags, the current
  # user, profiles; about a third of all reads) stay in the worker's own Planner, and the reads that share
  # work across requests (articles, comments, lists, feeds) go to the planner processes. A single planner
  # process otherwise ran out of its one core before Postgres did. PLANNER_LOCAL=0 sends everything.
  class Split
    def initialize(local, remote)
      @local = local
      @remote = remote
    end

    def tags = @local.tags
    def user(id) = @local.user(id)
    def profile(viewer, username) = @local.profile(viewer, username)
    def article(viewer, slug) = @remote.article(viewer, slug)
    def article_by_id(viewer, id) = @remote.article_by_id(viewer, id)
    def comments(viewer, slug) = @remote.comments(viewer, slug)
    def feed(viewer, limit, offset) = @remote.feed(viewer, limit, offset)
    def list(kind, viewer, value, limit, offset) = @remote.list(kind, viewer, value, limit, offset)
  end

  # Planner side: reads every worker's requests into the planner and answers each worker's share of a batch
  # with one wake-up.
  class Server
    Reply = Struct.new(:server, :index, :id) do
      def call(request) = server.answer(index, id, request)
    end

    def initialize(planner, links)
      @planner = planner
      @links = links
      @dirty = Array.new(links.size, false)
      planner.after_batch = -> { flush }
    end

    def run(task)
      @links.each_with_index { |link, index| task.async { read(link.requests, index) } }
    end

    def answer(index, id, request)
      if request.error
        status = FAILED
        payload = request.error.message
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
      message = [id, status].pack("NC") << payload.b
      RemotePlanner.push(@links[index].replies, message)
      @dirty[index] = true
    end

    private

    def read(ring, index)
      RemotePlanner.each_message(ring) do |message|
        id, kind, viewer = message.unpack("NCq>")
        at = 13
        args = Array.new(3) do
          length = message.unpack1("n", offset: at)
          at += 2
          if length == 0xFFFF
            nil
          else
            value = message.byteslice(at, length).force_encoding(Encoding::UTF_8)
            at += length
            value
          end
        end
        @planner.submit(Planner::Request.new(KINDS.fetch(kind), viewer, args[0], args[1], args[2], nil, nil, nil,
                                             Reply.new(self, index, id)))
      end
    end

    def flush
      @dirty.each_with_index do |dirty, i|
        next unless dirty

        @dirty[i] = false
        @links[i].replies.notify
      end
    end
  end
end
