class Api::ProfilesController < ApplicationController
  before_action :optional_auth, only: :show
  before_action :require_auth!, only: %i[follow unfollow]
  before_action :load_profile_user # runs after auth, so a missing token is a 401 before an unknown user is a 404

  # GET /api/profiles/:username
  def show
    render_profile(Follow.following?(viewer_id, @user.id))
  end

  # POST /api/profiles/:username/follow
  def follow
    # Follow.insert is INSERT ... ON CONFLICT DO NOTHING, so following someone twice is fine.
    Follow.insert({ follower_id: viewer_id, followee_id: @user.id })
    render_profile(true)
  end

  # DELETE /api/profiles/:username/follow
  def unfollow
    Follow.where(follower_id: viewer_id, followee_id: @user.id).delete_all
    render_profile(false)
  end

  private

  def load_profile_user
    @user = User.find_by(username: params[:username])
    render_error(:not_found, "profile not found") unless @user
  end

  def render_profile(following)
    render json: { profile: @user.as_profile_json(following) }
  end
end
