class Follow < Sequel::Model
  many_to_one :follower, class: :User
  many_to_one :followee, class: :User

  # `following`: whether the viewer (the statement's :$viewer) follows the user in `user_column`.
  def self.following(user_column)
    Sequel.lit("EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = ?) AS following",
               :$viewer, user_column)
  end

  def self.follow(follower_id, followee_id)
    dataset.insert_conflict.insert(follower_id:, followee_id:)
  end

  def self.unfollow(follower_id, followee_id)
    where(follower_id:, followee_id:).delete
  end
end
