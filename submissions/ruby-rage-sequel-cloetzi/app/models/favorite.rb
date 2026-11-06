class Favorite < Sequel::Model
  many_to_one :user
  many_to_one :article

  def self.favorite(user_id, article_id)
    dataset.insert_conflict.insert(user_id:, article_id:)
  end

  def self.unfavorite(user_id, article_id)
    where(user_id:, article_id:).delete
  end
end
