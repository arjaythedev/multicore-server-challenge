class TagsController < ApplicationController
  skip_authentication

  def index
    render json: { tags: Tag.order(:name).pluck(:name) }
  end
end
