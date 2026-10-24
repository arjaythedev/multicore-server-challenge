# Reads articles with the reference SQL from SPEC.md and turns each row into the Article JSON object.
#
# The list endpoints need a favourites count, "favorited" and "following" for every row, and the ordering, paging
# and 1,000-capped counts have to match the reference exactly, so this runs the spec's SQL directly (as prepared
# statements, via binds) rather than building it with ActiveRecord associations.
#
# $1 is always the viewer's user id (0 when anonymous, which matches no rows).
module ArticleQuery
  module_function

  # ARTICLE_LIST_SELECT from the spec. The only change: the tag list comes back as JSON
  # (array_to_json(ARRAY(...)) instead of ARRAY(...)), which is the same list but simpler to read in Ruby.
  def select_sql(with_body)
    <<~SQL
      SELECT a.id, a.slug, a.title, a.description, #{"a.body, " if with_body}a.created_at, a.updated_at,
             array_to_json(ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                                  WHERE at.article_id = a.id ORDER BY t.name)) AS tag_list,
             (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
             EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
             u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
        FROM articles a
        JOIN users u ON u.id = a.author_id
    SQL
  end

  ORDER_PAGE = "ORDER BY a.id DESC LIMIT $2 OFFSET $3"

  # Page and count SQL for GET /api/articles, by filter (SPEC.md table). Page binds: $1 viewer, $2 limit,
  # $3 offset, $4 filter value. Count binds: $1 filter value.
  LIST_FILTERS = {
    nil => {
      page: "",
      count: "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s"
    },
    tag: {
      page: "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) " \
            "ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
      count: "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s"
    },
    author: {
      page: "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) #{ORDER_PAGE}",
      count: "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s"
    },
    favorited: {
      page: "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) " \
            "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
      count: "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s"
    }
  }.freeze

  FEED_PAGE = <<~SQL
    WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
        (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x
      WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC
  SQL
  FEED_COUNT = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN " \
               "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"

  # GET /api/articles. filter is nil or [:tag | :author | :favorited, value]. Returns [articles, count].
  def list(viewer_id, filter, limit, offset)
    kind, value = filter
    sqls = LIST_FILTERS.fetch(kind)
    page_binds = [viewer_id, limit, offset]
    page_binds << value if kind
    articles = rows("#{select_sql(false)} #{sqls[:page].presence || ORDER_PAGE}", page_binds, with_body: false)
    count = connection.select_value(sqls[:count], "Article Count", kind ? [value] : [])
    [articles, Integer(count)]
  end

  # GET /api/articles/feed. Returns [articles, count].
  def feed(viewer_id, limit, offset)
    articles = rows("#{select_sql(false)} #{FEED_PAGE}", [viewer_id, limit, offset], with_body: false)
    count = connection.select_value(FEED_COUNT, "Feed Count", [viewer_id])
    [articles, Integer(count)]
  end

  # ARTICLE_FULL_SELECT WHERE a.slug = $2. Returns the article hash or nil.
  def find_by_slug(viewer_id, slug)
    rows("#{select_sql(true)} WHERE a.slug = $2", [viewer_id, slug], with_body: true).first
  end

  # ARTICLE_FULL_SELECT WHERE a.id = $2. Returns the article hash or nil.
  def find_by_id(viewer_id, id)
    rows("#{select_sql(true)} WHERE a.id = $2", [viewer_id, id], with_body: true).first
  end

  def rows(sql, binds, with_body:)
    connection.select_all(sql, "Article Load", binds).map { |row| to_json_object(row, with_body) }
  end

  # One result row -> the Article object from SPEC.md (list endpoints omit "body").
  def to_json_object(row, with_body)
    article = {
      slug: row["slug"],
      title: row["title"],
      description: row["description"],
      tagList: json_array(row["tag_list"]),
      createdAt: timestamp(row["created_at"]),
      updatedAt: timestamp(row["updated_at"]),
      favorited: boolean(row["favorited"]),
      favoritesCount: Integer(row["favorites_count"]),
      author: {
        username: row["username"],
        bio: row["bio"],
        image: row["image"],
        following: boolean(row["following"])
      }
    }
    article[:body] = row["body"] if with_body
    article
  end

  # RFC 3339 in UTC with exactly 3 fractional digits, truncated not rounded: Ruby's %L truncates.
  # The pg driver normally hands back a Time already; a string is parsed just in case.
  def timestamp(value)
    time = value.is_a?(String) ? Time.parse(value) : value
    time.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
  end

  def json_array(value)
    value.is_a?(String) ? JSON.parse(value) : Array(value)
  end

  def boolean(value)
    ActiveModel::Type::Boolean.new.cast(value) || false
  end

  def connection
    ActiveRecord::Base.connection
  end
end
