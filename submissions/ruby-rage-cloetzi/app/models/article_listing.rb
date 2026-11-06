# The lists behind GET /api/articles and GET /api/articles/feed. Each listing is a page of articles plus the
# relation its capped `articlesCount` counts. Lists filtered through another table (tags, favorites, follows)
# page inside the id subquery, so Postgres walks one index newest-first and stops after a page.
module ArticleListing
  extend self

  Listing = Data.define(:page, :counted) do
    def articles_for(viewer_id) = page.presented_for(viewer_id)
    def total = ApplicationRecord.capped_count(counted)
  end

  FEED_IDS = <<~SQL.squish
    articles.id IN (
      SELECT x.id FROM follows fo CROSS JOIN LATERAL (
        SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT :window
      ) x
      WHERE fo.follower_id = :viewer_id ORDER BY x.id DESC LIMIT :limit OFFSET :offset)
  SQL

  # Only the first of tag, author and favorited applies.
  def filtered(tag: nil, author: nil, favorited: nil, limit:, offset:)
    if tag then tagged(tag, limit:, offset:)
    elsif author then by_author(author, limit:, offset:)
    elsif favorited then favorited_by(favorited, limit:, offset:)
    else everything(limit:, offset:)
    end
  end

  def everything(limit:, offset:)
    Listing.new(page: Article.page(limit, offset), counted: Article.all)
  end

  def by_author(username, limit:, offset:)
    articles = Article.by_author(username)
    Listing.new(page: articles.page(limit, offset), counted: articles)
  end

  def tagged(tag, limit:, offset:)
    joined = ArticleTag.named(tag)
    page_through(joined, :article_id, limit:, offset:)
  end

  def favorited_by(username, limit:, offset:)
    joined = Favorite.where_scalar(user_id: User.where(username:).select(:id))
    page_through(joined, :article_id, limit:, offset:)
  end

  def feed(viewer_id, limit:, offset:)
    page = Article.where(Arel.sql(FEED_IDS, viewer_id:, window: limit + offset, limit:, offset:)).newest_first
    Listing.new(page:, counted: Article.where(author_id: Follow.where(follower_id: viewer_id).select(:followee_id)))
  end

  private

  def page_through(joined, article_column, limit:, offset:)
    ids = joined.order(article_column => :desc).limit(limit).offset(offset).select(article_column)
    Listing.new(page: Article.where(id: ids).newest_first, counted: joined)
  end
end
