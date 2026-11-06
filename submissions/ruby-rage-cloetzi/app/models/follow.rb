class Follow < ApplicationRecord
  belongs_to :follower, class_name: "User"
  belongs_to :followee, class_name: "User"

  # `following`: whether `viewer_id` follows the user in `user_column`, as a select-list expression.
  def self.following_sql(user_column, viewer_id)
    bound_sql(<<~SQL.squish, viewer_id)
      EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = #{user_column}) AS following
    SQL
  end

  def self.follow(follower_id, followee_id)
    insert({ follower_id:, followee_id: })
  end

  def self.unfollow(follower_id, followee_id)
    where(follower_id:, followee_id:).delete_all
  end
end
