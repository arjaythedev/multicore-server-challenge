class ArticleTag < ApplicationRecord
  belongs_to :article
  belongs_to :tag

  scope :named, ->(name) { where(tag_id: Tag.where(name:).select(:id)) }
end
