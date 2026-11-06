class ApplicationController < RageController::API
  include Authentication
  include RequestInput

  rescue_from Sequel::NoMatchingRow, with: :not_found
  rescue_from Sequel::UniqueConstraintViolation, with: :unprocessable

  skip_authentication only: :route_not_found

  def route_not_found = not_found

  # Rage's render calls to_json. Every response here is hashes, arrays, strings (timestamps are formatted already),
  # integers, booleans and nils, so hand it the json gem's output directly.
  def render(json: nil, **)
    super(json: json.nil? || json.is_a?(String) ? json : JSON.generate(json), **)
  end

  private

  def render_error(status, message)
    render json: { errors: { body: [message] } }, status:
  end

  def unauthorized = render_error(:unauthorized, "unauthorized")
  def forbidden = render_error(:forbidden, "forbidden")
  def not_found = render_error(:not_found, "not found")
  def unprocessable = render_error(:unprocessable_content, "invalid request")
end
