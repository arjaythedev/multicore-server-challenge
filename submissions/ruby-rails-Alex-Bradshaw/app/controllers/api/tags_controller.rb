class Api::TagsController < ApplicationController
  def index
    tags = Tag.order(:name).pluck(:name)
    render json: { tags: tags }
  end
end
