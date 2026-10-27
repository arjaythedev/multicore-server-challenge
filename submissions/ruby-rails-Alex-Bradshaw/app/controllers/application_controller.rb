class ApplicationController < ActionController::API
  # Rails would otherwise wrap a bare JSON body under a key named after the controller ("user" in
  # UsersController), which would make the "no wrapper" conformance checks succeed when they must fail.
  wrap_parameters false

  # Malformed JSON is a 422 in this spec (Rails' default is 400). Rails raises this when params is first read.
  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render_error(:unprocessable_content, "request body is not valid JSON")
  end

  # The catch-all route at the bottom of config/routes.rb.
  def route_not_found
    render_error(:not_found, "not found")
  end

  private

  # Authentication (SPEC.md): the header is `Authorization: Token <jwt>`, verified on every request.
  #
  #   before_action :require_auth!   - endpoints marked "auth required": missing or invalid token -> 401
  #   before_action :optional_auth   - endpoints marked "auth optional": no header -> anonymous (viewer_id 0),
  #                                    but a header that is present and invalid is still a 401
  #
  # Afterwards, viewer_id is the logged-in user's id (or 0) and current_token is the raw token they sent.
  attr_reader :viewer_id, :current_token

  def require_auth!
    token = token_from_header
    user_id = token && AuthToken.user_id_from(token)
    # Rendering inside a before_action halts the request, so the action never runs.
    return render_error(:unauthorized, "missing or invalid token") unless user_id

    @viewer_id = user_id
    @current_token = token
  end

  def optional_auth
    if request.authorization.nil?
      @viewer_id = 0 # anonymous; no user has id 0
    else
      require_auth!
    end
  end

  # "Token <jwt>" -> "<jwt>"; anything else (Bearer, no scheme, empty) -> nil.
  def token_from_header
    scheme, token = request.authorization.to_s.split(" ", 2)
    token if scheme == "Token" && token.present?
  end

  MAX_LIMIT = 100
  # The feed's reference SQL adds limit + offset as 32-bit ints, so offsets are capped below that to avoid an
  # overflow error. (No real client pages 2 billion articles deep.)
  MAX_OFFSET = 2_147_483_647 - MAX_LIMIT

  # Reads ?limit= (default 20, 1..100) and ?offset= (default 0). Both must be plain digit strings ("05" is fine,
  # "+5", " 5", "1.5" and "" are not). Returns [limit, offset], or renders a 422 and returns nil.
  def pagination
    limit = page_param(:limit, 20, 1..MAX_LIMIT)
    offset = page_param(:offset, 0, 0..MAX_OFFSET)
    return [limit, offset] if limit && offset

    render_error(:unprocessable_content, "limit must be an integer 1-100 and offset an integer >= 0")
    nil
  end

  def page_param(name, default, range)
    raw = params[name]
    return default if raw.nil?
    return unless raw.is_a?(String) && raw.match?(/\A\d+\z/)

    value = raw.to_i # to_i, not Integer(): Integer("05") would read it as octal
    value if range.cover?(value)
  end

  # Every error in the spec has the shape {"errors": {"body": ["<message>"]}}.
  def render_error(status, message)
    render json: { errors: { body: [message] } }, status: status
  end
end
