# follows has a composite primary key (follower_id, followee_id), which Rails picks up from the schema.
class Follow < ApplicationRecord
  # Does follower_id follow followee_id? Always false for an anonymous viewer (id 0, which no user has).
  def self.following?(follower_id, followee_id)
    follower_id != 0 && exists?(follower_id: follower_id, followee_id: followee_id)
  end
end
