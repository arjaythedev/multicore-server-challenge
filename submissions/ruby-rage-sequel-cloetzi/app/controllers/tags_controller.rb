class TagsController < ApplicationController
  skip_authentication

  def index
    render json: { tags: Tag.names }
  end
end
