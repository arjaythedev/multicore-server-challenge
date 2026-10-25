class CurrentUsersController < ApplicationController
  def show
    user = User.find_by(id: viewer_id)
    return unauthorized unless user

    render json: { user: ConduitJson.user(user, token: presented_token) }
  end

  def update
    fields = string_fields(body_object("user"), optional: %i[email username password bio image], blank_ok: %i[bio image])
    return unprocessable unless fields

    user = User.find_by(id: viewer_id)
    return unauthorized unless user
    return unprocessable unless user.update(fields)

    render json: { user: ConduitJson.user(user, token: presented_token) }
  end
end
