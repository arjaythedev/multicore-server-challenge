class Article < Sequel::Model
  many_to_one :author, class: :User
  one_to_many :comments
  one_to_many :favorites
  many_to_many :tags, join_table: :article_tags

  LIST_COLUMNS = %i[id slug title description created_at updated_at].map { Sequel[:articles][it] }.freeze
  FULL_COLUMNS = [*LIST_COLUMNS, Sequel[:articles][:body]].freeze

  TAG_LIST = Sequel.lit(<<~SQL.split.join(" "))
    ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
           WHERE at.article_id = articles.id ORDER BY t.name) AS tag_list
  SQL
  FAVORITES_COUNT = Sequel.lit("(SELECT count(*) FROM favorites f WHERE f.article_id = articles.id) AS favorites_count")
  FAVORITED = Sequel.lit(
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = articles.id AND f.user_id = ?) AS favorited", :$viewer
  )

  dataset_module do
    # Every column the API renders for an article as seen by the statement's :$viewer, in one statement: its tags,
    # favorite count, whether the viewer favorited it, and its author's profile. Lists leave out the body.
    def presented(body: false)
      join(:users, id: :author_id).select(
        *(body ? FULL_COLUMNS : LIST_COLUMNS), TAG_LIST, FAVORITES_COUNT, FAVORITED,
        *User::AUTHOR_COLUMNS, Follow.following(Sequel[:articles][:author_id])
      )
    end

    def newest_first = reverse(Sequel[:articles][:id])
  end

  BY_SLUG = presented(body: true).where(Sequel[:articles][:slug] => :$slug).prepare(:first, :article_by_slug)
  BY_ID = presented(body: true).where(Sequel[:articles][:id] => :$id).prepare(:first, :article_by_id)
  ID_BY_SLUG = where(slug: :$slug).select(:id).naked.prepare(:single_value, :article_id_by_slug)

  # The article as the API renders it for `viewer_id`; Sequel::NoMatchingRow if there is none.
  def self.presented_by_slug!(viewer_id, slug) = BY_SLUG.call(viewer: viewer_id, slug:) || raise(Sequel::NoMatchingRow)
  def self.presented_by_id(viewer_id, id) = BY_ID.call(viewer: viewer_id, id:)
  def self.id_for!(slug) = ID_BY_SLUG.call(slug:) || raise(Sequel::NoMatchingRow)

  # Slugs are the slugified title plus the id, which the insert takes from the sequence up front.
  def self.publish(author_id:, title:, description:, body:, tag_names: [])
    db.transaction do
      id = db.get(Sequel.function(:nextval, Sequel.function(:pg_get_serial_sequence, "articles", "id")))
      dataset.insert(id:, slug: slug_for(title, id), author_id:, title:, description:, body:)
      ArticleTag.dataset.multi_insert(Tag.ids_for(tag_names).map { |tag_id| { article_id: id, tag_id: } }) if tag_names.any?
      id
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
    this.update(**changes, updated_at: Sequel::CURRENT_TIMESTAMP)
  end

  def written_by?(user_id) = author_id == user_id
end
