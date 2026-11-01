# The lists behind GET /api/articles and GET /api/articles/feed: a page of articles plus the list's
# `articlesCount`, capped at 1,000. Each list is two prepared statements that take the same arguments. Lists
# filtered through another table (tags, favorites, follows) page inside the id subquery, so Postgres walks one
# index newest-first and stops after a page.
module ArticleListing
  extend self

  Listing = Data.define(:page, :count) do
    # [articles, total]
    def call(viewer_id, **args) = [page.call(viewer: viewer_id, **args), count.call(viewer: viewer_id, **args)]
  end

  PAGE = %i[$limit $offset].freeze

  # count(*) over the relation, but stop counting at `cap`.
  def self.capped_count(dataset, name, cap: 1000)
    capped = dataset.unordered.select(Sequel.lit("1")).limit(cap)
    DB.from(capped.as(:capped)).select(Sequel.function(:count).*).prepare(:single_value, name)
  end

  # column = (subquery), for a subquery that yields at most one value (an id looked up by a unique key). Plain
  # `where(column => subquery)` writes `IN (subquery)`, which Postgres plans as a join, so it can't walk an index
  # in order and stop after a page: it fetches every match and sorts them first.
  def self.scalar_eq(column, subquery) = Sequel::SQL::BooleanExpression.new(:"=", column, subquery)

  # A list filtered through `joined` (rows naming an article in `article_column`), paged by that column.
  def self.through(joined, article_column, name)
    ids = joined.reverse(article_column).limit(*PAGE).select(article_column)
    Listing.new(page: Article.presented.where(Sequel[:articles][:id] => ids).newest_first.prepare(:select, :"#{name}_page"),
                count: capped_count(joined, :"#{name}_count"))
  end

  EVERYTHING = Listing.new(page: Article.presented.newest_first.limit(*PAGE).prepare(:select, :all_page),
                           count: capped_count(Article.dataset, :all_count))

  authored = scalar_eq(Sequel[:articles][:author_id], User.where(username: :$author).select(:id))
  BY_AUTHOR = Listing.new(page: Article.presented.where(authored).newest_first.limit(*PAGE).prepare(:select, :author_page),
                          count: capped_count(Article.where(authored), :author_count))

  TAGGED = through(ArticleTag.where(scalar_eq(:tag_id, Tag.where(name: :$tag).select(:id))), :article_id, :tag)

  FAVORITED_BY = through(Favorite.where(scalar_eq(:user_id, User.where(username: :$favorited).select(:id))),
                         :article_id, :favorited)

  FEED_IDS = Sequel.lit(<<~SQL.split.join(" "), viewer: :$viewer, window: :$window, limit: :$limit, offset: :$offset)
    articles.id IN (
      SELECT x.id FROM follows fo CROSS JOIN LATERAL (
        SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT :window
      ) x
      WHERE fo.follower_id = :viewer ORDER BY x.id DESC LIMIT :limit OFFSET :offset)
  SQL
  FEED = Listing.new(page: Article.presented.where(FEED_IDS).newest_first.prepare(:select, :feed_page),
                     count: capped_count(Article.where(author_id: Follow.where(follower_id: :$viewer).select(:followee_id)),
                                         :feed_count))

  # Only the first of tag, author and favorited applies.
  def filtered(viewer_id, tag: nil, author: nil, favorited: nil, limit:, offset:)
    if tag then TAGGED.call(viewer_id, tag:, limit:, offset:)
    elsif author then BY_AUTHOR.call(viewer_id, author:, limit:, offset:)
    elsif favorited then FAVORITED_BY.call(viewer_id, favorited:, limit:, offset:)
    else EVERYTHING.call(viewer_id, limit:, offset:)
    end
  end

  def feed(viewer_id, limit:, offset:) = FEED.call(viewer_id, limit:, offset:, window: limit + offset)
end
