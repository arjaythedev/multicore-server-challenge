class FollowsController < ApplicationController
  before_action :set_user

  def create
    Follow.follow(viewer_id, @user.id)
    render json: { profile: ConduitJson.profile(@user, following: true) }
  end

  def destroy
    Follow.unfollow(viewer_id, @user.id)
    render json: { profile: ConduitJson.profile(@user, following: false) }
  end

  private

  def set_user
    @user = User.select(:id, :username, :bio, :image).first(username: params[:profile_username]) or raise Sequel::NoMatchingRow
  end
end
