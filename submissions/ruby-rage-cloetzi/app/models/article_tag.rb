class ArticleTag < ApplicationRecord
  belongs_to :article
  belongs_to :tag

  scope :named, ->(name) { where_scalar(tag_id: Tag.where(name:).select(:id)) }
end
