class ProfilesController < ApplicationController
  allow_anonymous

  def show
    user = User.profile(viewer_id, params[:username]) or raise Sequel::NoMatchingRow

    render json: { profile: ConduitJson.profile(user, following: user[:following]) }
  end
end
