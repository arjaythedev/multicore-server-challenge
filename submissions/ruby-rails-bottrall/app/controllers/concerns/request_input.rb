# Reads request bodies, which come wrapped as {"<resource>": {...}}, and the limit/offset query parameters.
# Input that isn't shaped exactly as the endpoint expects is a 422, so these return nil rather than coercing:
# a number is not a string, and [null] is not a tag list.
module RequestInput
  extend ActiveSupport::Concern

  MAX_BIGINT = 2**63 - 1

  included do
    rescue_from ActionDispatch::Http::Parameters::ParseError, with: :unprocessable
  end

  private

  # The object under `resource`, or nil when the body isn't {resource: {...}}.
  def body_object(resource)
    object = request.request_parameters[resource]
    object if object.is_a?(Hash)
  end

  # The named string fields of `object`, keyed by symbol, or nil if any is invalid. Required fields must be
  # present; optional ones may be absent or null and are then left out. Every field given must be a string,
  # and a non-empty one unless it is listed in `blank_ok`.
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

  # {limit:, offset:} from the query string: limit 1..100 (default 20), offset >= 0 (default 0), both plain
  # decimal digits when given. Nil if either is invalid.
  def page_params
    limit = query_integer("limit", default: 20)
    offset = query_integer("offset", default: 0)
    { limit:, offset: } if limit&.between?(1, 100) && offset
  end

  def query_integer(name, default:)
    query = request.query_parameters
    return default unless query.key?(name)

    value = query[name]
    integer = value.to_i if value.is_a?(String) && value.match?(/\A[0-9]+\z/)
    integer if integer && integer <= MAX_BIGINT
  end
end
