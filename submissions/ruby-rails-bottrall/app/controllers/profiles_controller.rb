class ProfilesController < ApplicationController
  allow_anonymous

  def show
    user = User.profile_for(viewer_id).find_by!(username: params[:username])

    render json: { profile: ConduitJson.profile(user, following: user[:following]) }
  end
end
