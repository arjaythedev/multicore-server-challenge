class ApplicationController < ActionController::API
  include Authentication
  include RequestInput

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::RecordNotUnique, with: :unprocessable

  skip_authentication only: :route_not_found

  def route_not_found = not_found

  private

  def render_error(status, message)
    render json: { errors: { body: [message] } }, status:
  end

  def unauthorized = render_error(:unauthorized, "unauthorized")
  def forbidden = render_error(:forbidden, "forbidden")
  def not_found = render_error(:not_found, "not found")
  def unprocessable = render_error(:unprocessable_content, "invalid request")
end
