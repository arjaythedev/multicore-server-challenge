class Article < ApplicationRecord
  belongs_to :author, class_name: "User"
  has_many :article_tags
  has_many :tags, through: :article_tags
  has_many :favorites
  has_many :comments

  LIST_COLUMNS = %i[id slug title description created_at updated_at].freeze
  FULL_COLUMNS = [*LIST_COLUMNS, :body].freeze

  TAGS_AND_FAVORITES = <<~SQL.squish
    ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
           WHERE at.article_id = articles.id ORDER BY t.name) AS tag_list,
    (SELECT count(*) FROM favorites f WHERE f.article_id = articles.id) AS favorites_count
  SQL
  FAVORITED = <<~SQL.squish
    EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = articles.id AND f.user_id = ?) AS favorited
  SQL

  # Every column the API renders for an article as seen by `viewer_id`, in one statement: its tags, favorite
  # count, whether the viewer favorited it, and its author's profile. Lists leave out the body.
  scope :presented_for, ->(viewer_id, body: false) {
    joins(:author).select(
      *(body ? FULL_COLUMNS : LIST_COLUMNS),
      bound_sql(TAGS_AND_FAVORITES), bound_sql(FAVORITED, viewer_id),
      User.author_columns, Follow.following_sql("articles.author_id", viewer_id)
    )
  }

  scope :newest_first, -> { order(id: :desc) }
  scope :page, ->(limit, offset) { newest_first.limit(limit).offset(offset) }
  scope :by_author, ->(username) { where_scalar(author_id: User.where(username:).select(:id)) }

  # Slugs are the slugified title plus the id, which the insert takes from the sequence up front.
  def self.publish(author_id:, title:, description:, body:, tag_names: [])
    transaction do
      id = connection.select_value("SELECT nextval(pg_get_serial_sequence('articles', 'id'))")
      article = create!(id:, slug: slug_for(title, id), author_id:, title:, description:, body:)
      ArticleTag.insert_all(Tag.ids_for(tag_names).map { |tag_id| { article_id: id, tag_id: } }) if tag_names.any?
      article
    end
  end

  # Byte-identical to the spec's SQL: trim(both '-' from lower(regexp_replace(title, '[^A-Za-z0-9]+', '-', 'g'))).
  def self.slug_for(title, id)
    "#{title.gsub(/[^A-Za-z0-9]+/, "-").downcase.delete_prefix("-").delete_suffix("-")}-#{id}"
  end

  # Changes only the fields given; a new title also means a new slug.
  def revise(title: nil, description: nil, body: nil)
    changes = { title:, description:, body: }.compact
    changes[:slug] = self.class.slug_for(title, id) if title
    update_columns(**changes, updated_at: Time.now)
  end

  def written_by?(user_id) = author_id == user_id
end
