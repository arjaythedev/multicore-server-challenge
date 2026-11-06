class ApplicationController < RageController::API
  include Authentication
  include RequestInput

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::RecordNotUnique, with: :unprocessable

  skip_authentication only: :route_not_found

  def route_not_found = not_found

  # Rage's render calls to_json, which Active Support (loaded by Active Record) sends through its own encoder: an
  # encoder object per call, an as_json pass, and HTML-entity escaping. Every response here is hashes, arrays,
  # strings (timestamps are formatted already), integers, booleans and nils, so the json gem's generator gives the
  # same JSON values directly. Only the escaping differs: < > & are written as they are, not as \u escapes.
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
