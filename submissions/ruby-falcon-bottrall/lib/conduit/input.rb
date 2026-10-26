require "json"
require "uri"

module Conduit
  module Input
    module_function

    MAX_BIGINT = 2**63 - 1
    DIGITS = /\A[0-9]+\z/
    EMPTY = {}.freeze

    def body(env, resource)
      text = env["rack.input"]&.read
      return if text.nil? || text.empty?

      parsed = JSON.parse(text)
      object = parsed[resource] if parsed.is_a?(Hash)
      object if object.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def string_fields(object, required: [], optional: [], blank_ok: [])
      return unless object

      fields = (required + optional).filter_map { |name|
        value = object[name]
        [name, value] unless value.nil? && optional.include?(name)
      }.to_h
      valid = fields.all? { |name, value| value.is_a?(String) && (!value.empty? || blank_ok.include?(name)) }
      fields if valid
    end

    def string_list(object, name)
      list = object&.fetch(name, nil) || []
      list if list.is_a?(Array) && list.all? { it.is_a?(String) && !it.empty? }
    end

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

    def segment(raw)
      decoded = raw.include?("%") ? URI.decode_uri_component(raw) : raw
      decoded.force_encoding(Encoding::UTF_8) # Rack hands over request strings as binary
      decoded if decoded.valid_encoding?
    rescue ArgumentError # a stray % that isn't an escape
      nil
    end

    def form_decode(raw)
      decoded = raw.include?("%") || raw.include?("+") ? URI.decode_www_form_component(raw) : raw
      decoded.force_encoding(Encoding::UTF_8).valid_encoding? ? decoded : ""
    rescue ArgumentError # a stray % that isn't an escape
      ""
    end
  end
end
