# frozen_string_literal: true

require "json"
require "pg"

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
  WINDOW = Float(ENV.fetch("READ_WINDOW_MS", "20")) / 1000
  MAX = Integer(ENV.fetch("READ_MAX", "512")) # requests per batch; a backlog runs as several batches

  # One read request. `kind` and `args` say what it wants; `document` (or `missing`) is the answer.
  Request = Struct.new(:kind, :viewer, :a, :b, :c, :queue, :document)

  FALSE = "false"
  TRUE = "true"
  NULL = "null"

  def initialize(db)
    @db = db
    @pending = []
    @signal = Thread::Queue.new
    @array = PG::TextEncoder::Array.new
    Fiber.schedule { run }
  end

  # The documents. `nil` means: not found.
  def tags = ask(:tags, 0, nil, nil, nil)
  def user(id) = ask(:user, id, nil, nil, nil) # [id, username, email, bio, image] or nil
  def profile(viewer, username) = ask(:profile, viewer, username, nil, nil)
  def article(viewer, slug) = ask(:article, viewer, slug, nil, nil)
  def comments(viewer, slug) = ask(:comments, viewer, slug, nil, nil)
  def feed(viewer, limit, offset) = ask(:feed, viewer, limit, offset, nil)
  # kind: :global (value nil), :tag, :author or :favorited
  def list(kind, viewer, value, limit, offset) = ask(kind, viewer, value, limit, offset)

  private

  def ask(kind, viewer, a, b, c)
    queue = (Thread.current[:planner_queue] ||= Thread::Queue.new) # Thread#[] is fiber-local
    @pending << Request.new(kind, viewer, a, b, c, queue, nil)
    @signal.push(Process.clock_gettime(Process::CLOCK_MONOTONIC)) if @pending.size == 1
    answer = queue.pop
    raise answer if answer.is_a?(Exception)

    answer == :missing ? nil : answer
  end

  def run
    loop do
      opened = @signal.pop
      wait = opened + WINDOW - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep(wait) if wait.positive?
      until @pending.empty?
        batch = @pending.shift(MAX)
        begin
          answer(batch)
        rescue StandardError => error
          batch.each { |request| request.queue.push(error) } # nothing was delivered: answer() delivers last
        end
      end
    end
  end

  # --- one batch ------------------------------------------------------------------------------------

  def answer(batch)
    @batch = batch
    @articles = {} # id => row fields (phase A), enriched in phase B
    @flags_fav = [] # [viewer, article] pairs to look up
    @flags_follow = [] # [viewer, user] pairs
    @fav = {} # (viewer << 32 | article) => true, filled in phase B
    @follow = {} # (viewer << 32 | user) => true
    statements = []
    @slots = [] # [statement index, handler] for phase A results

    by_kind = batch.group_by(&:kind)
    plan_tags(by_kind[:tags], statements)
    plan_users(by_kind[:user], statements)
    plan_profiles(by_kind[:profile], statements)
    plan_articles(by_kind[:article], statements)
    plan_comments(by_kind[:comments], statements)
    plan_global(by_kind[:global], statements)
    plan_filtered(:b_tag, by_kind[:tag], statements)
    plan_filtered(:b_author, by_kind[:author], statements)
    plan_filtered(:b_favorited, by_kind[:favorited], statements)
    plan_feed(by_kind[:feed], statements)

    results = @db.group(statements)
    @slots.each { |index, handler| handler.call(results[index]) }
    results.each(&:clear)

    enrich unless @articles.empty? && @flags_follow.empty?
    @finish.each(&:call) if @finish
    @finish = nil
    batch.each { |request| request.queue.push(request.document || :missing) }
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
        @flags_follow << [request.viewer, user_id] if request.viewer.positive?
        later do
          following = following?(request.viewer, user_id)
          request.document = "{\"profile\":{\"username\":#{str(row[2])},\"bio\":#{str(row[3])}," \
                             "\"image\":#{str(row[4])},\"following\":#{following}}}"
        end
      end
    end
  end

  def plan_articles(requests, statements)
    return unless requests

    keys, ordinals = distinct(requests, &:a)
    slot(statements, :b_articles, [@array.encode(keys)]) do |result|
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
          ["{\"id\":#{row[2]},\"createdAt\":\"#{time(row[4])}\",\"updatedAt\":\"#{time(row[5])}\",\"body\":#{str(row[3])}," \
           "\"author\":{\"username\":#{str(row[7])},\"bio\":#{str(row[8])},\"image\":#{str(row[9])},\"following\":",
           row[6].to_i]
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
        pieces.each { |(_, author)| @flags_follow << [viewer, author] }
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

  def plan_feed(requests, statements)
    return unless requests

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
      items = ids.map { |id| article_json(id, viewer, body: false) }
      request.document = "{\"articles\":[#{items.join(",")}],\"articlesCount\":#{count}}"
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

    @flags_fav << [viewer, id]
    @flags_follow << [viewer, @articles[id][:author]]
  end

  def enrich
    ids = @articles.keys
    statements = []
    unless ids.empty?
      encoded = @array.encode(ids)
      statements << [:b_enrich, [encoded, @array.encode(ids.map { |id| @articles[id][:author] })]]
      statements << [:b_tag_names, [encoded]]
    end
    flags = !@flags_fav.empty? || !@flags_follow.empty?
    if flags
      statements << [:b_flags, [@array.encode(@flags_fav.map(&:first)), @array.encode(@flags_fav.map(&:last)),
                                @array.encode(@flags_follow.map(&:first)), @array.encode(@flags_follow.map(&:last))]]
    end
    results = @db.group(statements)
    unless ids.empty?
      rank = {}
      names = {}
      results[1].each_row do |row|
        tag = row[0].to_i
        rank[tag] = rank.size
        names[tag] = str(row[1])
      end
      results[0].each_row do |row|
        article = @articles[row[0].to_i]
        tags = parse_ids(row[1]).sort_by! { |tag| rank[tag] || 0 }
        article[:fragments] = fragments(article, tags.map { |tag| names[tag] }, row[2], row[3], row[4], row[5])
      end
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
    head = "{\"slug\":#{str(row[3])},\"title\":#{str(row[4])},\"description\":#{str(row[5])}"
    tail = ",\"tagList\":[#{tag_names.join(",")}],\"createdAt\":\"#{time(row[6])}\",\"updatedAt\":\"#{time(row[7])}\",\"favorited\":"
    middle = ",\"favoritesCount\":#{favorites},\"author\":{\"username\":#{str(username)},\"bio\":#{str(bio)}," \
             "\"image\":#{str(image)},\"following\":"
    body = article[:body] && ",\"body\":#{str(article[:body])}"
    [head, body, tail, middle]
  end

  def article_json(id, viewer, body:)
    article = @articles[id]
    head, body_part, tail, middle = article[:fragments]
    out = String.new(head, capacity: 512)
    out << body_part if body && body_part
    out << tail << favorited?(viewer, id) << middle << following?(viewer, article[:author]) << "}}"
  end

  # --- formatting ---------------------------------------------------------------------------------------

  # A JSON string, or null.
  def str(value) = value.nil? ? NULL : JSON.generate(value)

  # "2024-09-15 14:22:31.123456+00" (Postgres text, TimeZone UTC) -> "2024-09-15T14:22:31.123" (truncated to
  # milliseconds; the fraction is absent when it is zero) + "Z".
  def time(text)
    frac = text.getbyte(19) == 46 ? text.byteslice(20, 3).ljust(3, "0").tr("+", "0") : "000"
    frac = frac.gsub(/[^0-9]/, "0") unless frac.match?(/\A[0-9]{3}\z/)
    "#{text.byteslice(0, 10)}T#{text.byteslice(11, 8)}.#{frac}Z"
  end

  def parse_ids(text)
    return [] if text.bytesize <= 2

    text.byteslice(1, text.bytesize - 2).split(",").map!(&:to_i)
  end
end
