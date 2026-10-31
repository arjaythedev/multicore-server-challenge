class Favorite < ApplicationRecord
  belongs_to :user
  belongs_to :article

  def self.favorite(user_id, article_id)
    insert({ user_id:, article_id: })
  end

  def self.unfavorite(user_id, article_id)
    where(user_id:, article_id:).delete_all
  end
end
