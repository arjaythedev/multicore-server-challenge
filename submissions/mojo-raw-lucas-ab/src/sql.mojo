# Every SQL statement, prepared on each connection at startup as s<index> (the index is the position in
# statements(), so the constants below must follow its order).
#
# Mostly SPEC.md's reference SQL. Deviations, each returning the same responses:
# - Article creation runs its statements in one Sync batch (an implicit transaction) and reads the new id with
#   currval() instead of a parameter.
# - Each list is one statement (see list_statement): the page's ids first, then the per-article subqueries only for
#   those rows, with the capped count in the same statement.

comptime STMT_TAGS = 0
comptime STMT_USER_INSERT = 1
comptime STMT_USER_BY_EMAIL = 2
comptime STMT_USER_BY_ID = 3
comptime STMT_USER_UPDATE = 4
comptime STMT_PROFILE = 5
comptime STMT_USER_BY_USERNAME = 6
comptime STMT_FOLLOW = 7
comptime STMT_UNFOLLOW = 8
# Lists: $1 viewer, $2 limit, $3 offset, $4 the filter value (tag, author, favorited). Columns: the 13 of
# LIST_COLUMNS (all NULL on the single row of an empty page), then 13 = the capped count.
comptime STMT_LIST_ALL = 9
comptime STMT_LIST_TAG = 10
comptime STMT_LIST_AUTHOR = 11
comptime STMT_LIST_FAVORITED = 12
comptime STMT_FEED = 13
comptime STMT_ARTICLE_BY_SLUG = 14
comptime STMT_ARTICLE_BY_ID = 15
comptime STMT_ARTICLE_INSERT = 16
comptime STMT_TAGS_INSERT = 17
comptime STMT_ARTICLE_TAGS_INSERT = 18
comptime STMT_ARTICLE_OWNER = 19
comptime STMT_ARTICLE_UPDATE = 20
comptime STMT_ARTICLE_DELETE = 21
comptime STMT_ARTICLE_ID = 22
comptime STMT_FAVORITE = 23
comptime STMT_UNFAVORITE = 24
comptime STMT_COMMENTS = 25
comptime STMT_COMMENT_INSERT = 26
comptime STMT_COMMENT_OWNER = 27
comptime STMT_COMMENT_DELETE = 28

comptime LIST_COUNT_COLUMN = 13

# ARTICLE_LIST_SELECT's columns ($1 = viewer): 0 id, 1 slug, 2 title, 3 description, 4 created_at, 5 updated_at,
# 6 tag_list, 7 favorites_count, 8 favorited, 9 username, 10 bio, 11 image, 12 following.
comptime LIST_COLUMNS = (
    "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,"
    " ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id"
    " WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,"
    " (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,"
    " EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,"
    " u.username, u.bio, u.image,"
    " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following"
)
# ARTICLE_FULL_SELECT: the same with a.body after a.description. Columns: 0 id, 1 slug, 2 title, 3 description,
# 4 body, 5 created_at, 6 updated_at, 7 tag_list, 8 favorites_count, 9 favorited, 10 username, 11 bio, 12 image,
# 13 following.
comptime FULL_SELECT = (
    "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,"
    " ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id"
    " WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,"
    " (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,"
    " EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,"
    " u.username, u.bio, u.image,"
    " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following"
    " FROM articles a JOIN users u ON u.id = a.author_id "
)
comptime SLUGIFY_2 = "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))"


def list_statement(ids: StringSlice, count: StringSlice) -> String:
    """One list page plus its capped count, as one statement.

    `ids` selects the column `id` newest-first (the reference SQL's page, without LIMIT/OFFSET); `count` is the
    reference count. The page is cut with OFFSET $3 and a constant LIMIT 100 before LIMIT $2: limit is validated
    to 1..100, so the rows are the same, and the generic plan estimates at most 100 rows instead of 10% of the
    table. The subqueries in LIST_COLUMNS then run only for the page's rows, never for the rows OFFSET skips. The
    count joins the page laterally, so an empty page still returns one row carrying the count."""
    return (
        "SELECT x.*, c.cnt FROM (" + String(count) + ") c(cnt) LEFT JOIN LATERAL (" + LIST_COLUMNS
        + " FROM (SELECT q.id FROM (" + String(ids) + " OFFSET $3 LIMIT 100) q ORDER BY q.id DESC LIMIT $2) p"
        " JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id) x ON true ORDER BY x.id DESC"
    )


def statements() -> List[String]:
    var s = List[String]()
    s.append("SELECT name FROM tags ORDER BY name")  # STMT_TAGS
    s.append(  # STMT_USER_INSERT
        "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)"
        " RETURNING id, username, email, bio, image"
    )
    s.append("SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1")
    s.append("SELECT id, username, email, bio, image FROM users WHERE id = $1::bigint")  # STMT_USER_BY_ID
    s.append(  # STMT_USER_UPDATE
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),"
        " password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)"
        " WHERE id = $1::bigint RETURNING id, username, email, bio, image"
    )
    s.append(  # STMT_PROFILE ($1 viewer, $2 username): id, username, bio, image, following
        "SELECT u.id, u.username, u.bio, u.image,"
        " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following"
        " FROM users u WHERE u.username = $2"
    )
    s.append("SELECT id, username, bio, image FROM users WHERE username = $1")  # STMT_USER_BY_USERNAME
    s.append("INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING")
    s.append("DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2")  # STMT_UNFOLLOW
    s.append(  # STMT_LIST_ALL
        list_statement(
            "SELECT a2.id FROM articles a2 ORDER BY a2.id DESC",
            "SELECT count(*) FROM (SELECT 1 FROM articles a3 LIMIT 1000) s",
        )
    )
    s.append(  # STMT_LIST_TAG
        list_statement(
            "SELECT at2.article_id AS id FROM article_tags at2"
            " WHERE at2.tag_id = (SELECT t2.id FROM tags t2 WHERE t2.name = $4) ORDER BY at2.article_id DESC",
            "SELECT count(*) FROM (SELECT 1 FROM article_tags at3"
            " WHERE at3.tag_id = (SELECT t3.id FROM tags t3 WHERE t3.name = $4) LIMIT 1000) s",
        )
    )
    s.append(  # STMT_LIST_AUTHOR
        list_statement(
            "SELECT a2.id FROM articles a2"
            " WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC",
            "SELECT count(*) FROM (SELECT 1 FROM articles a3"
            " WHERE a3.author_id = (SELECT u3.id FROM users u3 WHERE u3.username = $4) LIMIT 1000) s",
        )
    )
    s.append(  # STMT_LIST_FAVORITED
        list_statement(
            "SELECT f2.article_id AS id FROM favorites f2"
            " WHERE f2.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f2.article_id DESC",
            "SELECT count(*) FROM (SELECT 1 FROM favorites f3"
            " WHERE f3.user_id = (SELECT fu3.id FROM users fu3 WHERE fu3.username = $4) LIMIT 1000) s",
        )
    )
    s.append(  # STMT_FEED
        list_statement(
            "SELECT x2.id FROM follows fo2 CROSS JOIN LATERAL"
            " (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo2.followee_id ORDER BY a2.id DESC"
            " LIMIT ($2::int + $3::int)) x2 WHERE fo2.follower_id = $1 ORDER BY x2.id DESC",
            "SELECT count(*) FROM (SELECT 1 FROM articles a3 WHERE a3.author_id IN"
            " (SELECT fo3.followee_id FROM follows fo3 WHERE fo3.follower_id = $1) LIMIT 1000) s",
        )
    )
    s.append(String(FULL_SELECT) + "WHERE a.slug = $2")  # STMT_ARTICLE_BY_SLUG
    s.append(String(FULL_SELECT) + "WHERE a.id = $2")  # STMT_ARTICLE_BY_ID
    s.append(  # STMT_ARTICLE_INSERT ($1 author, $2 title, $3 description, $4 body)
        "INSERT INTO articles (id, slug, author_id, title, description, body)"
        " SELECT n.id, " + SLUGIFY_2 + " || '-' || n.id, $1, $2, $3, $4"
        " FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id"
    )
    s.append("INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING")
    s.append(  # STMT_ARTICLE_TAGS_INSERT: same batch as the article insert, so currval is its id
        "INSERT INTO article_tags (article_id, tag_id)"
        " SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])"
    )
    s.append("SELECT id, author_id FROM articles WHERE slug = $1")  # STMT_ARTICLE_OWNER
    s.append(  # STMT_ARTICLE_UPDATE ($1 id, $2 title, $3 description, $4 body)
        "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description),"
        " body = COALESCE($4, body),"
        " slug = CASE WHEN $2::text IS NULL THEN slug ELSE " + SLUGIFY_2 + " || '-' || id END,"
        " updated_at = now() WHERE id = $1"
    )
    s.append("DELETE FROM articles WHERE id = $1")  # STMT_ARTICLE_DELETE
    s.append("SELECT id FROM articles WHERE slug = $1")  # STMT_ARTICLE_ID
    s.append("INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING")
    s.append("DELETE FROM favorites WHERE user_id = $1 AND article_id = $2")  # STMT_UNFAVORITE
    s.append(  # STMT_COMMENTS ($1 viewer, $2 article): id, body, created_at, updated_at, username, bio, image, following
        "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,"
        " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following"
        " FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = $2"
        " ORDER BY c.created_at DESC, c.id DESC LIMIT 100"
    )
    s.append(  # STMT_COMMENT_INSERT ($1 article, $2 author, $3 body): id, body, created_at, updated_at, username, bio, image
        "WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3)"
        " RETURNING id, body, created_at, updated_at, author_id)"
        " SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image"
        " FROM c JOIN users u ON u.id = c.author_id"
    )
    s.append(  # STMT_COMMENT_OWNER ($1 comment id, $2 slug)
        "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2"
    )
    s.append("DELETE FROM comments WHERE id = $1")  # STMT_COMMENT_DELETE
    return s^
