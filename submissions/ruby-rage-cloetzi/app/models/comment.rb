class Comment < ApplicationRecord
  belongs_to :article
  belongs_to :author, class_name: "User"

  # The newest 100 comments of an article, each with its author's profile as seen by `viewer_id`.
  scope :thread_for, ->(viewer_id) {
    joins(:author)
      .select(:id, :body, :created_at, :updated_at, User.author_columns,
              Follow.following_sql("comments.author_id", viewer_id))
      .order(created_at: :desc, id: :desc)
      .limit(100)
  }
end
