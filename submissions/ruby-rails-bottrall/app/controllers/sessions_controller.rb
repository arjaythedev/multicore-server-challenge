class SessionsController < ApplicationController
  skip_authentication

  def create
    fields = string_fields(body_object("user"), required: %i[email password])
    return unprocessable unless fields

    user = User.authenticate_by(fields)
    return unauthorized unless user

    render json: { user: ConduitJson.user(user, token: access_tokens.issue(user.id)) }
  end
end
