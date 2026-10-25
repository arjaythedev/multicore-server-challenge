class User < ApplicationRecord
  # The schema names the bcrypt column password_hash; has_secure_password expects password_digest.
  alias_attribute :password_digest, :password_hash
  has_secure_password

  has_many :articles, foreign_key: :author_id, inverse_of: :author
  has_many :comments, foreign_key: :author_id, inverse_of: :author
  has_many :favorites
  has_many :follows, foreign_key: :follower_id, inverse_of: :follower

  validates :username, :email, presence: true

  # Selects the user's profile columns plus whether `viewer_id` follows them.
  scope :profile_for, ->(viewer_id) {
    select(:id, :username, :bio, :image, Follow.following_sql("users.id", viewer_id))
  }

  # The author's profile columns, for selecting alongside the articles or comments they wrote.
  def self.author_columns
    bound_sql("users.username AS author_username, users.bio AS author_bio, users.image AS author_image")
  end

  def followed_by?(viewer_id)
    Follow.exists?(follower_id: viewer_id, followee_id: id)
  end
end
