class Tag < ApplicationRecord
  has_many :article_tags
  has_many :articles, through: :article_tags

  # Creates any of `names` that don't exist yet and returns the ids of all of them.
  def self.ids_for(names)
    insert_all(names.uniq.map { |name| { name: } }, unique_by: :name)
    where(name: names).pluck(:id)
  end
end
