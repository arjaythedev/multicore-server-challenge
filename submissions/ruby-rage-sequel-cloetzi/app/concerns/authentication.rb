# RealWorld's token auth: "Authorization: Token <jwt>". Every action requires a valid token unless its
# controller declares otherwise:
#
#   allow_anonymous only: :index    # no header means viewer 0; a header that is present must still be valid
#   skip_authentication             # no token involved at all
module Authentication
  ANONYMOUS = 0

  def self.included(controller)
    controller.extend(ClassMethods)
    controller.before_action :require_viewer
  end

  module ClassMethods
    def allow_anonymous(**)
      skip_before_action(:require_viewer, **)
      before_action(:resolve_viewer, **)
    end

    def skip_authentication(**)
      skip_before_action(:require_viewer, **)
    end
  end

  private

  # The id of the user the request's token belongs to, or ANONYMOUS.
  attr_reader :viewer_id

  # The token exactly as the request presented it (GET/PUT /api/user echo it back).
  attr_reader :presented_token

  def require_viewer
    authenticate
  end

  def resolve_viewer
    authorization.to_s.strip.empty? ? @viewer_id = ANONYMOUS : authenticate
  end

  def authenticate
    header = authorization.to_s
    @presented_token = header.delete_prefix("Token ") if header.start_with?("Token ")
    @viewer_id = @presented_token && access_tokens.user_id(@presented_token)
    unauthorized unless @viewer_id
  end

  def authorization = request.headers["Authorization"]

  def access_tokens = ACCESS_TOKENS
end
