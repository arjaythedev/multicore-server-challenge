require "json"
require "uri"

module Conduit
  # Reads what a request sends: bodies, which come wrapped as {"<resource>": {...}}, the query string, and path
  # segments. Input that isn't shaped exactly as the endpoint expects is a 422, so these return nil rather than
  # coercing: a number is not a string, and [null] is not a tag list.
  module Input
    module_function

    MAX_BIGINT = 2**63 - 1
    DIGITS = /\A[0-9]+\z/
    EMPTY = {}.freeze

    # The object under `resource` in the JSON body, or nil when the body isn't {resource: {...}}.
    def body(env, resource)
      text = env["rack.input"]&.read
      return if text.nil? || text.empty?

      parsed = JSON.parse(text)
      object = parsed[resource] if parsed.is_a?(Hash)
      object if object.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    # The named string fields of `object`, or nil if any is invalid. Required fields must be present; optional
    # ones may be absent or null and are then left out. Every field given must be a string, and a non-empty one
    # unless it is listed in `blank_ok`.
    def string_fields(object, required: [], optional: [], blank_ok: [])
      return unless object

      fields = (required + optional).filter_map { |name|
        value = object[name]
        [name, value] unless value.nil? && optional.include?(name)
      }.to_h
      valid = fields.all? { |name, value| value.is_a?(String) && (!value.empty? || blank_ok.include?(name)) }
      fields if valid
    end

    # An optional array of non-empty strings (absent or null means none), or nil if it's anything else.
    def string_list(object, name)
      list = object&.fetch(name, nil) || []
      list if list.is_a?(Array) && list.all? { it.is_a?(String) && !it.empty? }
    end

    # The query string's parameters; the first wins when one is repeated.
    def query(env)
      string = env["QUERY_STRING"]
      return EMPTY if string.nil? || string.empty?

      string.split("&").each_with_object({}) { |pair, params|
        next if pair.empty?

        name, value = pair.split("=", 2)
        name = form_decode(name)
        params[name] = form_decode(value || "") unless params.key?(name)
      }
    end

    # [limit, offset] from the query: limit 1..100 (default 20), offset >= 0 (default 0), both plain decimal
    # digits when given. Nil if either is invalid.
    def page(query)
      limit = integer(query, "limit", default: 20)
      offset = integer(query, "offset", default: 0)
      [limit, offset] if limit&.between?(1, 100) && offset
    end

    def integer(query, name, default:)
      return default unless query.key?(name)

      value = query[name]
      number = value.to_i if value.match?(DIGITS)
      number if number && number <= MAX_BIGINT
    end

    # A percent-decoded path segment (a slug or a username), or nil if it doesn't decode to valid UTF-8.
    # Rack hands over request strings as binary; `raw` is a fresh one from splitting the path.
    def segment(raw)
      decoded = raw.include?("%") ? URI.decode_uri_component(raw) : raw
      decoded.force_encoding(Encoding::UTF_8)
      decoded if decoded.valid_encoding?
    rescue ArgumentError # a stray % that isn't an escape
      nil
    end

    # A decoded query string name or value; one that isn't valid UTF-8 counts as empty.
    def form_decode(raw)
      decoded = raw.include?("%") || raw.include?("+") ? URI.decode_www_form_component(raw) : raw
      decoded.force_encoding(Encoding::UTF_8).valid_encoding? ? decoded : ""
    rescue ArgumentError # a stray % that isn't an escape
      ""
    end
  end
end
