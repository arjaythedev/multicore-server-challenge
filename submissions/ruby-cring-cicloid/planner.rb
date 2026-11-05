# frozen_string_literal: true

require "json"
require "pg"
require_relative "ext/fmt/fmt"

# Batched reads for one worker process. A read request joins the current batch and its fiber waits; the
# first request of a batch opens a window (READ_WINDOW_MS), and when it closes the whole batch goes to
# Postgres in two pipelined round trips (SQL::BATCH): phase A resolves what each request is about, over
# the batch's distinct keys, and phase B enriches every article phase A returned once, plus the viewers'
# favorited/following flags. Each request's document is then assembled here and handed to its fiber.
#
# Nothing outlives a batch: every value in a response was read from Postgres while that request waited.
# While one batch runs the next one collects, so the busier the worker, the bigger (and cheaper per
# request) the batches.
class Planner
  WINDOW = Float(ENV.fetch("READ_WINDOW_MS", "40")) / 1000 # 20 ms: more Postgres CPU per request locally
  MAX = Integer(ENV.fetch("READ_MAX", "256")) # requests per batch; a backlog runs as several batches
  # Batches in flight at once per process, each on its own planner object (a lane) sharing one intake. With
  # one, a slow batch held up every read behind it while Postgres had connections to spare (on the full seed:
  # p50 75 ms, max 2.6 s at 30,000 users on 4 cores with the box 40% idle).
  LANES = Integer(ENV.fetch("READ_LANES", "2"))

  # One read request. `kind` and `args` say what it wants; `document` (or `missing`) is the answer.
  # Either `fiber` (a request in this process) waits for it, or `reply` (a request from another process,
  # see remote_planner.rb) is called with it.
  Request = Struct.new(:kind, :viewer, :a, :b, :c, :fiber, :document, :error, :reply)

  FALSE = "false"
  TRUE = "true"
  NULL = "null"

  attr_reader :after_batch # called after each batch's answers were handed out (remote_planner.rb)

  # `shared`: the intake ([pending, signal]) of the first lane, for the others.
  # Distinct (viewer, id) pairs, written straight into the two int8[] literals b_flags takes: a few thousand
  # pairs per batch, which as arrays of pairs then mapped and joined took ~9% of a planner's CPU.
  class Pairs
    def initialize
      @seen = {}
      @firsts = String.new("{", capacity: 4096)
      @seconds = String.new("{", capacity: 4096)
    end

    def add(first, second)
      key = (first << 32) | second
      return if @seen.key?(key)

      unless @seen.empty?
        @firsts << ","
        @seconds << ","
      end
      @seen[key] = true
      @firsts << first.to_s
      @seconds << second.to_s
    end

    def empty? = @seen.empty?
    def firsts = "#{@firsts}}"
    def seconds = "#{@seconds}}"
  end

  def initialize(db, lanes: LANES, shared: nil)
    @db = db
    if shared
      @pending, @signal = shared
    else
      @pending = []
      @signal = Thread::Queue.new
      @lanes = Array.new(lanes - 1) { Planner.new(db, shared: [@pending, @signal]) }
    end
    @array = PG::TextEncoder::Array.new
    Fiber.schedule { run }
  end

  def after_batch=(callback)
    @after_batch = callback
    @lanes&.each { |lane| lane.after_batch = callback }
  end

  # The documents. `nil` means: not found.
  def tags = ask(:tags, 0, nil, nil, nil)
  def user(id) = ask(:user, id, nil, nil, nil) # [id, username, email, bio, image] or nil
  def profile(viewer, username) = ask(:profile, viewer, username, nil, nil)
  def article(viewer, slug) = ask(:article, viewer, slug, nil, nil)
  def article_by_id(viewer, id) = ask(:article_id, viewer, id, nil, nil) # id as a decimal string
  def comments(viewer, slug) = ask(:comments, viewer, slug, nil, nil)
  def feed(viewer, limit, offset) = ask(:feed, viewer, limit, offset, nil)
  # kind: :global (value nil), :tag, :author or :favorited
  def list(kind, viewer, value, limit, offset) = ask(kind, viewer, value, limit, offset)

  # A request from another process; its `reply` is called when the batch is done.
  def submit(request)
    @pending << request
    @signal.push(Process.clock_gettime(Process::CLOCK_MONOTONIC)) if @pending.size == 1
  end

  private

  # The requesting fiber parks itself with the scheduler's block hook and the batch resumes it with unblock:
  # a Thread::Queue per wait cost several times the wake-up itself. Safe on one thread: a request always
  # blocks before its batch runs, since the batch starts on a later pass of the event loop.
  def ask(kind, viewer, a, b, c)
    request = Request.new(kind, viewer, a, b, c, Fiber.current, nil, nil, nil)
    @pending << request
    @signal.push(Process.clock_gettime(Process::CLOCK_MONOTONIC)) if @pending.size == 1
    Fiber.scheduler.block(request, nil) until request.document || request.error
    raise request.error if request.error

    request.document == :missing ? nil : request.document
  end

  def wake(request)
    if request.fiber
      Fiber.scheduler.unblock(request, request.fiber)
    else
      request.reply.call(request)
    end
  end

  # Each lane waits for a window to open, collects for WINDOW and takes up to MAX requests. Whatever is left
  # goes straight to the next free lane (the signal is re-pushed with its time already past).
  def run
    loop do
      opened = @signal.pop
      wait = opened + WINDOW - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep(wait) if wait.positive?
      batch = @pending.shift(MAX)
      @signal.push(opened) unless @pending.empty?
      next if batch.empty?

      begin
        answer(batch)
      rescue StandardError => error
        batch.each do |request| # nothing was delivered: answer() delivers last
          request.error = error
          wake(request)
        end
      end
      @after_batch&.call
    end
  end

  # --- one batch ------------------------------------------------------------------------------------

  def answer(batch)
    @batch = batch
    @articles = {} # id => row fields (phase A), enriched in phase B
    @flags_fav = Pairs.new # (viewer, article) pairs to look up
    @flags_follow = Pairs.new # (viewer, user) pairs
    @rows_wanted = {} # article ids phase A knew only by id (shared feeds), read whole in phase B
    @fav = {} # (viewer << 32 | article) => true, filled in phase B
    @follow = {} # (viewer << 32 | user) => true
    statements = []
    @slots = [] # [statement index, handler] for phase A results

    by_kind = batch.group_by(&:kind)
    plan_tags(by_kind[:tags], statements)
    plan_users(by_kind[:user], statements)
    plan_profiles(by_kind[:profile], statements)
    plan_articles(:b_articles, by_kind[:article], statements)
    plan_articles(:b_articles_id, by_kind[:article_id], statements)
    plan_comments(by_kind[:comments], statements)
    plan_global(by_kind[:global], statements)
    plan_filtered(:b_tag, by_kind[:tag], statements)
    plan_filtered(:b_author, by_kind[:author], statements)
    plan_filtered(:b_favorited, by_kind[:favorited], statements)
    plan_feed(by_kind[:feed], statements)

    results = @db.group(statements)
    @slots.each { |index, handler| handler.call(results[index]) }
    results.each(&:clear)

    enrich unless @articles.empty? && @flags_follow.empty? && @rows_wanted.empty? && @flags_fav.empty?
    @finish.each(&:call) if @finish
    @finish = nil
    batch.each do |request|
      request.document ||= :missing
      wake(request)
    end
  end

  def later(&block) = (@finish ||= []) << block

  def slot(statements, name, params, &handler)
    @slots << [statements.size, handler]
    statements << [name, params]
  end

  # Distinct keys of `requests` (by the block's key), and each request's 1-based ordinal.
  def distinct(requests)
    keys = {}
    ordinals = requests.map { |request| keys[yield(request)] ||= keys.size + 1 }
    [keys.keys, ordinals]
  end

  # --- phase A -----------------------------------------------------------------------------------------

  def plan_tags(requests, statements)
    return unless requests

    slot(statements, :b_tags, []) do |result|
      document = "{\"tags\":#{result.getvalue(0, 0)}}"
      requests.each { |request| request.document = document }
    end
  end

  def plan_users(requests, statements)
    return unless requests

    keys, ordinals = distinct(requests, &:viewer)
    slot(statements, :b_users, [@array.encode(keys)]) do |result|
      rows = {}
      result.each_row { |row| rows[row[0].to_i] = row }
      requests.each_with_index do |request, i|
        row = rows[ordinals[i]] or next
        request.document = [row[1].to_i, row[2], row[3], row[4], row[5]]
      end
    end
  end

  def plan_profiles(requests, statements)
    return unless requests

    keys, ordinals = distinct(requests, &:a)
    slot(statements, :b_profiles, [@array.encode(keys)]) do |result|
      rows = {}
      result.each_row { |row| rows[row[0].to_i] = row }
      requests.each_with_index do |request, i|
        row = rows[ordinals[i]] or next
        user_id = row[1].to_i
        @flags_follow.add(request.viewer, user_id) if request.viewer.positive?
        later do
          following = following?(request.viewer, user_id)
          request.document = "{\"profile\":{\"username\":#{str(row[2])},\"bio\":#{str(row[3])}," \
                             "\"image\":#{str(row[4])},\"following\":#{following}}}"
        end
      end
    end
  end

  def plan_articles(name, requests, statements)
    return unless requests

    keys, ordinals = distinct(requests, &:a)
    slot(statements, name, [@array.encode(keys)]) do |result|
      rows = {}
      result.each_row do |row|
        rows[row[0].to_i] = row
        add_article(row, body: row[8])
      end
      requests.each_with_index do |request, i|
        row = rows[ordinals[i]] or next
        id = row[1].to_i
        want_flags(request.viewer, id)
        later { request.document = "{\"article\":#{article_json(id, request.viewer, body: true)}}" }
      end
    end
  end

  # Each distinct article's comments are rendered once per batch, in pieces around the one per-viewer value
  # (author.following); a request joins them with its viewer's flags. Anonymous viewers share one document.
  def plan_comments(requests, statements)
    return unless requests

    keys, ordinals = distinct(requests, &:a)
    slot(statements, :b_comments, [@array.encode(keys)]) do |result|
      found = {} # k => [comment rows]
      result.each_row do |row|
        list = (found[row[0].to_i] ||= [])
        list << row if row[2]
      end
      rendered = {} # k => [[prefix, author id], ...]
      found.each do |k, list|
        list.sort_by! { |row| row[10].to_i } # newest first (n from the statement)
        rendered[k] = list.map do |row|
          [Fmt.comment(row[2], row[4], row[5], row[3], row[7], row[8], row[9]), row[6].to_i]
        end
      end
      anonymous = {} # k => document
      requests.each_with_index do |request, i|
        k = ordinals[i]
        pieces = rendered[k] or next
        viewer = request.viewer
        unless viewer.positive?
          request.document = (anonymous[k] ||= comments_document(pieces, 0))
          next
        end
        pieces.each { |(_, author)| @flags_follow.add(viewer, author) }
        later { request.document = comments_document(pieces, viewer) }
      end
    end
  end

  def comments_document(pieces, viewer)
    out = String.new("{\"comments\":[", capacity: 64 + (pieces.size * 256))
    pieces.each_with_index do |(prefix, author), i|
      out << "," unless i.zero?
      out << prefix << (viewer.positive? ? following?(viewer, author) : FALSE) << "}}"
    end
    out << "]}"
  end

  def plan_global(requests, statements)
    return unless requests

    keys, ordinals = distinct(requests) { |request| [request.b, request.c] }
    params = [@array.encode(keys.map(&:first)), @array.encode(keys.map(&:last))]
    slot(statements, :b_global, params) do |result|
      pages, counts = pages_and_counts(result)
      count = counts[0] || 0
      requests.each_with_index do |request, i|
        list_document(request, pages[ordinals[i]] || [], count)
      end
    end
  end

  # tag, author and favorited lists: counts per distinct value, pages per distinct (value, limit, offset).
  def plan_filtered(name, requests, statements)
    return unless requests

    values, value_ordinals = distinct(requests, &:a)
    keys, ordinals = distinct(requests) { |request| [request.a, request.b, request.c] }
    params = [@array.encode(values), @array.encode(keys.map { _1[0] }), @array.encode(keys.map { _1[1] }),
              @array.encode(keys.map { _1[2] })]
    slot(statements, name, params) do |result|
      pages, counts = pages_and_counts(result)
      requests.each_with_index do |request, i|
        list_document(request, pages[ordinals[i]] || [], counts[value_ordinals[i]] || 0)
      end
    end
  end

  # Feeds of up to FEED_SHARED_DEPTH rows (limit + offset) can share their followees' scans (b_feed_scan);
  # the rest go per viewer (b_feed). Off by default: on the full seed the shared scan cost Postgres twice as
  # much (12.8 s against 6.4 s at the same load), because it counts each followee up to 1,000 where the
  # per-viewer count stops at 1,000 in total, and per-worker batches rarely share followees. Worth another
  # look with batches shared by all workers and a count that stops at 1,000 per viewer.
  FEED_SHARED_DEPTH = Integer(ENV.fetch("FEED_SHARED_DEPTH", "0"))

  def plan_feed(requests, statements)
    return unless requests

    shared, deep = requests.partition { |request| request.a.to_i + request.b.to_i <= FEED_SHARED_DEPTH }
    plan_shared_feed(shared, statements) unless shared.empty?
    plan_deep_feed(deep, statements) unless deep.empty?
  end

  def plan_shared_feed(requests, statements)
    viewers = requests.map(&:viewer).uniq
    depth = requests.map { |request| request.a.to_i + request.b.to_i }.max
    follows = Hash.new { |h, k| h[k] = [] } # viewer => followees
    slot(statements, :b_feed_follows, [ints(viewers)]) do |result|
      result.each_row do |row|
        viewer = row[0].to_i
        followee = row[1].to_i
        follows[viewer] << followee
        @follow[(viewer << 32) | followee] = true # a feed's authors are followed by its viewer
      end
    end
    slot(statements, :b_feed_scan, [ints(viewers), depth.to_s]) do |result|
      scans = {} # followee => [count, ids newest first]
      result.each_row { |row| scans[row[0].to_i] = [row[1].to_i, parse_ids(row[2])] }
      requests.each do |request|
        viewer = request.viewer
        limit = request.a.to_i
        offset = request.b.to_i
        count = 0
        ids = []
        follows[viewer].each do |followee|
          scan = scans[followee] or next
          count += scan[0]
          ids.concat(scan[1])
        end
        ids.sort!.reverse!
        page = ids[offset, limit] || []
        page.each do |id|
          @rows_wanted[id] = true unless @articles.key?(id)
          @flags_fav.add(viewer, id)
        end
        later do
          shown = page.select { |id| @articles[id]&.key?(:fragments) } # one deleted since phase A is left out
          out = String.new("{\"articles\":[", capacity: 64 + (shown.size * 640))
          shown.each_with_index do |id, i|
            out << "," unless i.zero?
            append_article(out, id, viewer, body: false)
          end
          request.document = out << "],\"articlesCount\":" << [count, 1000].min.to_s << "}"
        end
      end
    end
  end

  def plan_deep_feed(requests, statements)
    viewers, viewer_ordinals = distinct(requests, &:viewer)
    keys, ordinals = distinct(requests) { |request| [request.viewer, request.a, request.b] }
    params = [@array.encode(viewers), @array.encode(keys.map { _1[0] }), @array.encode(keys.map { _1[1] }),
              @array.encode(keys.map { _1[2] })]
    slot(statements, :b_feed, params) do |result|
      pages, counts = pages_and_counts(result)
      requests.each_with_index do |request, i|
        list_document(request, pages[ordinals[i]] || [], counts[viewer_ordinals[i]] || 0)
      end
    end
  end

  # Page rows (k > 0: article ids, newest first) and count rows (k <= 0: count key -k => count).
  def pages_and_counts(result)
    pages = {}
    counts = {}
    result.each_row do |row|
      k = row[0].to_i
      if k <= 0
        counts[-k] = row[1].to_i
      else
        add_article(row, body: nil)
        (pages[k] ||= []) << row[1].to_i
      end
    end
    pages.each_value { |ids| ids.sort!.reverse! }
    [pages, counts]
  end

  def list_document(request, ids, count)
    viewer = request.viewer
    ids.each { |id| want_flags(viewer, id) }
    later do
      out = String.new("{\"articles\":[", capacity: 64 + (ids.size * 640))
      ids.each_with_index do |id, i|
        out << "," unless i.zero?
        append_article(out, id, viewer, body: false)
      end
      request.document = out << "],\"articlesCount\":" << count.to_s << "}"
    end
  end

  # --- phase B ----------------------------------------------------------------------------------------

  # Row layout from phase A: [k, id, author_id, slug, title, description, created_at, updated_at, body?]
  def add_article(row, body:)
    id = row[1].to_i
    article = (@articles[id] ||= { author: row[2].to_i, row: row })
    article[:body] = body if body
  end

  def want_flags(viewer, id)
    return unless viewer.positive?

    @flags_fav.add(viewer, id)
    @flags_follow.add(viewer, @articles[id][:author])
  end

  def enrich
    @rows_wanted.delete_if { |id, _| @articles.key?(id) } # phase A returned some of them after all
    ids = @articles.keys
    extra = @rows_wanted.keys
    statements = []
    unless ids.empty?
      statements << [:b_enrich, [ints(ids), ints(ids.map { |id| @articles[id][:author] })]]
    end
    statements << [:b_enrich_rows, [ints(extra)]] unless extra.empty?
    statements << [:b_tag_names, [ints(ids + extra)]] unless ids.empty? && extra.empty?
    flags = !@flags_fav.empty? || !@flags_follow.empty?
    if flags
      statements << [:b_flags, [@flags_fav.firsts, @flags_fav.seconds, @flags_follow.firsts, @flags_follow.seconds]]
    end
    results = @db.group(statements)
    at = 0
    enriched = ids.empty? ? nil : results[(at += 1) - 1]
    rows = extra.empty? ? nil : results[(at += 1) - 1]
    names_result = ids.empty? && extra.empty? ? nil : results[(at += 1) - 1]
    rank = {}
    names = {}
    names_result&.each_row do |row|
      tag = row[0].to_i
      rank[tag] = rank.size
      names[tag] = str(row[1])
    end
    enriched&.each_row do |row|
      article = @articles[row[0].to_i]
      tags = parse_ids(row[1]).sort_by! { |tag| rank[tag] || 0 }
      article[:fragments] = fragments(article, tags.map { |tag| names[tag] }, row[2], row[3], row[4], row[5])
    end
    rows&.each_row do |row| # [0, COLS..., tag ids, favorites, username, bio, image]
      add_article(row, body: nil)
      article = @articles[row[1].to_i]
      tags = parse_ids(row[8]).sort_by! { |tag| rank[tag] || 0 }
      article[:fragments] = fragments(article, tags.map { |tag| names[tag] }, row[9], row[10], row[11], row[12])
    end
    if flags
      results.last.each_row do |row|
        key = (row[1].to_i << 32) | row[2].to_i
        (row[0] == "0" ? @fav : @follow)[key] = true
      end
    end
    results.each(&:clear)
  end

  def following?(viewer, user) = @follow[(viewer << 32) | user] ? TRUE : FALSE

  def favorited?(viewer, article) = @fav[(viewer << 32) | article] ? TRUE : FALSE

  # An article's JSON in pieces around the two per-viewer flags (favorited, author.following); built once
  # per batch, joined per request.
  def fragments(article, tag_names, favorites, username, bio, image)
    row = article[:row]
    Fmt.article(row[3], row[4], row[5], article[:body], "[#{tag_names.join(",")}]", row[6], row[7], favorites,
                username, bio, image)
  end

  def article_json(id, viewer, body:) = append_article(String.new(capacity: 1024), id, viewer, body: body)

  # Appends the article's JSON for `viewer` to `out`: the batch's fragments around the two flags.
  def append_article(out, id, viewer, body:)
    article = @articles[id]
    head, body_part, tail, middle = article[:fragments]
    out << head
    out << body_part if body && body_part
    out << tail << favorited?(viewer, id) << middle << following?(viewer, article[:author]) << "}}"
  end

  # --- formatting ---------------------------------------------------------------------------------------

  # A JSON string, or null.
  def str(value) = Fmt.str(value)

  # Postgres text (TimeZone UTC) -> "2024-09-15T14:22:31.123Z", milliseconds truncated.
  def time(text) = Fmt.time(text)

  # An int8[] literal; for integers that's all PG::TextEncoder::Array would write, at a fraction of the cost.
  def ints(values) = "{#{values.join(",")}}"

  def parse_ids(text)
    return [] if text.bytesize <= 2

    text.byteslice(1, text.bytesize - 2).split(",").map!(&:to_i)
  end
end
