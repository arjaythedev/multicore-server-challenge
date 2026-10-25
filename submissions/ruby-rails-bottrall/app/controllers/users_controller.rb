class UsersController < ApplicationController
  skip_authentication

  def create
    fields = string_fields(body_object("user"), required: %i[username email password])
    return unprocessable unless fields

    user = User.new(fields)
    return unprocessable unless user.save

    render json: { user: ConduitJson.user(user, token: access_tokens.issue(user.id)) }, status: :created
  end
end
