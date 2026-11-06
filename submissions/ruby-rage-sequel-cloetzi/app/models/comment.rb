class Comment < Sequel::Model
  many_to_one :article
  many_to_one :author, class: :User

  # The newest 100 comments of an article, each with its author's profile as seen by the statement's :$viewer.
  THREAD = join(:users, id: :author_id)
    .select(Sequel[:comments][:id], Sequel[:comments][:body], Sequel[:comments][:created_at],
            Sequel[:comments][:updated_at], *User::AUTHOR_COLUMNS, Follow.following(Sequel[:comments][:author_id]))
    .where(Sequel[:comments][:article_id] => :$article_id)
    .reverse(Sequel[:comments][:created_at], Sequel[:comments][:id])
    .limit(100)
    .prepare(:select, :comment_thread)

  def self.thread(viewer_id, article_id) = THREAD.call(viewer: viewer_id, article_id:)
end
