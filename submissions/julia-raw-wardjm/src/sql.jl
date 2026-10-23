# All SQL. Reads run batched: the per-request query is the inner side of a LATERAL join over the unnested parameters
# of every queued request of that kind, r(i, v = viewer, l = limit, o = offset, k = key), so Postgres executes it
# once per request, in one statement. Subqueries that use no request parameter are tied to the request row
# (r.i >= 0) so they too run once per request: no request is served another's result.
#
# Article columns (after i): id, slug, title, description, [body], created_at, updated_at, tag_list,
# favorites_count, favorited, username, bio, image, following.

const L_NONE = 0     # (i)
const L_VIEWER = 1   # (i, v)
const L_VKEY = 2     # (i, v, k)
const L_LIST = 3     # (i, v, l, o)
const L_LISTKEY = 4  # (i, v, l, o, k)
const L_KEY = 5      # (i, k)

const UNNEST = Dict(
    L_NONE => "unnest(\$1::int4[]) AS r(i)",
    L_VIEWER => "unnest(\$1::int4[], \$2::int8[]) AS r(i, v)",
    L_VKEY => "unnest(\$1::int4[], \$2::int8[], \$3::text[]) AS r(i, v, k)",
    L_LIST => "unnest(\$1::int4[], \$2::int8[], \$3::int4[], \$4::int8[]) AS r(i, v, l, o)",
    L_LISTKEY => "unnest(\$1::int4[], \$2::int8[], \$3::int4[], \$4::int8[], \$5::text[]) AS r(i, v, l, o, k)",
    L_KEY => "unnest(\$1::int4[], \$2::text[]) AS r(i, k)")

const LAYOUT_OIDS = Dict(
    L_NONE => [OID_INT4ARR],
    L_VIEWER => [OID_INT4ARR, OID_INT8ARR],
    L_VKEY => [OID_INT4ARR, OID_INT8ARR, OID_TEXTARR],
    L_LIST => [OID_INT4ARR, OID_INT8ARR, OID_INT4ARR, OID_INT8ARR],
    L_LISTKEY => [OID_INT4ARR, OID_INT8ARR, OID_INT4ARR, OID_INT8ARR, OID_TEXTARR],
    L_KEY => [OID_INT4ARR, OID_TEXTARR])

# per-request placeholders -> request-row columns
function bind_params(sql::String, layout::Int)
    replace(sql, r"\$(\d+)" => function (m)
        n = parse(Int, m[2:end])
        if layout == L_VIEWER
            n == 1 ? "r.v" : error(sql)
        elseif layout == L_VKEY
            n == 1 ? "r.v" : n == 2 ? "r.k" : error(sql)
        elseif layout == L_KEY
            n == 1 ? "r.k" : error(sql)
        else
            ("r.v", "r.l", "r.o", "r.k")[n]
        end
    end)
end

batched(per, layout) = ("SELECT r.i, x.* FROM " * UNNEST[layout] * " CROSS JOIN LATERAL (" * bind_params(per, layout) * ") x",
    LAYOUT_OIDS[layout])

# lists: (i, count, article columns...), with one row of NULL article columns when the page is empty.
# OFFSET 0 keeps the count a subquery evaluated once per request.
batched_list(page, count, layout) = ("SELECT r.i, c.n, x.* FROM " * UNNEST[layout] *
                                     " CROSS JOIN LATERAL (SELECT " * bind_params(count, layout) * " AS n OFFSET 0) c" *
                                     " LEFT JOIN LATERAL (" * bind_params(page, layout) * ") x ON true", LAYOUT_OIDS[layout])

# statement ids
const S_TAGS = 1
const S_ARTICLE = 2
const S_COMMENTS = 3
const S_PROFILE = 4
const S_USER = 5
const S_LIST_ALL = 6
const S_LIST_TAG = 7
const S_LIST_AUTHOR = 8
const S_LIST_FAV = 9
const S_FEED = 10
const S_LOGIN = 11
const S_ARTICLE_INSERT = 12
const S_TAGS_INSERT = 13
const S_ARTICLE_TAGS_INSERT = 14
const S_ARTICLE_BY_CURRVAL = 15
const S_ARTICLE_UPDATE = 16
const S_ARTICLE_AUTHOR = 17
const S_ARTICLE_DELETE = 18
const S_FAV_INSERT = 19
const S_FAV_DELETE = 20
const S_ARTICLE_BY_SLUG = 21
const S_COMMENT_INSERT = 22
const S_COMMENT_DELETE = 23
const S_COMMENT_AUTHOR = 24
const S_USER_INSERT = 25
const S_USER_UPDATE = 26
const S_FOLLOW = 27
const S_UNFOLLOW = 28

function statements(app_sorts_tags::Bool)
    tag_order = app_sorts_tags ? "" : " ORDER BY 1"
    following = "(SELECT true FROM follows fo WHERE fo.follower_id = \$1 AND fo.followee_id = a.author_id) IS NOT NULL"
    # tag names by primary key per tag (the planner otherwise hashes a scan of all tags for every article);
    # favorited/following are bounded probes of a primary key
    tail(fol) = "a.created_at, a.updated_at, " *
                "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id" *
                tag_order * ") AS tag_list, " *
                "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " *
                "(SELECT true FROM favorites f WHERE f.user_id = \$1 AND f.article_id = a.id) IS NOT NULL AS favorited, " *
                "u.username, u.bio, u.image, " * fol * " AS following"
    article_tail = tail(following)
    feed_tail = tail("true") # every feed author is followed (same snapshot)
    list_cols = "a.id, a.slug, a.title, a.description, "
    full_select = "SELECT a.id, a.slug, a.title, a.description, a.body, " * article_tail *
                  " FROM articles a JOIN users u ON u.id = a.author_id"
    # the page is cut before anything is joined or computed: OFFSET rows cost an index step only
    page_cols = "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a"
    list_of(ids, t) = "SELECT " * list_cols * t * " FROM (" * ids * ") p JOIN articles a ON a.id = p.id " *
                      "JOIN users u ON u.id = a.author_id ORDER BY p.id DESC"

    # capped counts. "At least 1000?" is whether a 1000th row exists, cheaper than counting 1000 rows.
    count_all = "CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 " *
                "ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END"
    # tags and feeds mostly reach the cap (every seeded tag, ~80% of feeds), so test for it first
    capped(from) = "CASE WHEN EXISTS (SELECT 1 FROM " * from * " OFFSET 999) THEN 1000 " *
                   "ELSE (SELECT count(*) FROM (SELECT 1 FROM " * from * " LIMIT 1000) s) END"
    count_tag = capped("article_tags c WHERE c.tag_id = (SELECT t.id FROM tags t WHERE t.name = \$4)")
    count_author = "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = (SELECT u.id FROM users u WHERE u.username = \$4) LIMIT 1000) s)"
    count_fav = "(SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = (SELECT u.id FROM users u WHERE u.username = \$4) LIMIT 1000) s)"
    # followees as an array: one scan of articles_author_idx for all of them
    count_feed = capped("articles c WHERE c.author_id = ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = \$1))")

    # one row with NULL comment columns when the article has no comments; no row = no article. The viewer's
    # followees are read once per request and each comment's author checked against them.
    comments = """
        SELECT a.id, c.id AS comment_id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
               c.author_id = ANY (f.ids) AS following
          FROM articles a
          CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = \$1) AS ids) f
          LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
                              WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
          LEFT JOIN users u ON u.id = c.author_id
         WHERE a.slug = \$2
         ORDER BY c.created_at DESC, c.id DESC"""
    profile = """
        SELECT u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = \$1 AND fo.followee_id = u.id) AS following
          FROM users u WHERE u.username = \$2"""

    I8, T = OID_INT8, OID_TEXT
    s = Vector{Tuple{String,Vector{UInt32}}}(undef, 28)
    s[S_TAGS] = ("SELECT r.i, ARRAY(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) FROM " * UNNEST[L_NONE],
        LAYOUT_OIDS[L_NONE])
    s[S_ARTICLE] = batched(full_select * " WHERE a.slug = \$2", L_VKEY)
    s[S_COMMENTS] = batched(comments, L_VKEY)
    s[S_PROFILE] = batched(profile, L_VKEY)
    s[S_USER] = batched("SELECT id, username, email, bio, image FROM users WHERE id = \$1", L_VIEWER)
    s[S_LOGIN] = batched("SELECT id, username, email, bio, image, password_hash FROM users WHERE email = \$1", L_KEY)
    s[S_LIST_ALL] = batched_list("SELECT " * list_cols * article_tail * " FROM (" * page_cols *
                                 " ORDER BY a.id DESC LIMIT \$2 OFFSET \$3) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC",
        count_all, L_LIST)
    s[S_LIST_AUTHOR] = batched_list("SELECT " * list_cols * article_tail * " FROM (" * page_cols *
                                    " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = \$4) ORDER BY a.id DESC LIMIT \$2 OFFSET \$3) a" *
                                    " JOIN users u ON u.id = a.author_id ORDER BY a.id DESC", count_author, L_LISTKEY)
    s[S_LIST_TAG] = batched_list(list_of(
            "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = \$4) " *
            "ORDER BY at.article_id DESC LIMIT \$2 OFFSET \$3", article_tail), count_tag, L_LISTKEY)
    s[S_LIST_FAV] = batched_list(list_of(
            "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = \$4) " *
            "ORDER BY f.article_id DESC LIMIT \$2 OFFSET \$3", article_tail), count_fav, L_LISTKEY)
    s[S_FEED] = batched_list(list_of(
            "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " *
            "ORDER BY a2.id DESC LIMIT (\$2::bigint + \$3::bigint)) x WHERE fo.follower_id = \$1 ORDER BY x.id DESC LIMIT \$2 OFFSET \$3",
            feed_tail), count_feed, L_LIST)

    # $1 viewer, $2 slug prefix ("<slugified title>-"), $3 title, $4 description, $5 body
    s[S_ARTICLE_INSERT] = ("""
        INSERT INTO articles (id, slug, author_id, title, description, body)
        SELECT n.id, \$2 || n.id, \$1, \$3, \$4, \$5
          FROM (SELECT nextval('articles_id_seq'::regclass) AS id) n""", [I8, T, T, T, T])
    # only tags that don't exist yet (no sequence burn), in name order (no deadlock between concurrent creates)
    s[S_TAGS_INSERT] = ("""
        INSERT INTO tags (name)
        SELECT n FROM (SELECT DISTINCT unnest(\$1::text[]) AS n) x
         WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = x.n)
         ORDER BY n
        ON CONFLICT (name) DO NOTHING""", [OID_TEXTARR])
    s[S_ARTICLE_TAGS_INSERT] = ("""
        INSERT INTO article_tags (article_id, tag_id)
        SELECT (SELECT currval('articles_id_seq'::regclass)), t.id FROM tags t WHERE t.name = ANY(\$1::text[])""", [OID_TEXTARR])
    s[S_ARTICLE_BY_CURRVAL] = (full_select * " WHERE a.id = (SELECT currval('articles_id_seq'::regclass))", [I8])
    # $1 viewer, $2 slug, $3 title, $4 description, $5 body, $6 new slug prefix (NULL when the title is unchanged)
    s[S_ARTICLE_UPDATE] = ("""
        WITH a AS (
          UPDATE articles SET title = COALESCE(\$3, title), description = COALESCE(\$4, description), body = COALESCE(\$5, body),
                 slug = CASE WHEN \$6::text IS NULL THEN slug ELSE \$6 || id END,
                 updated_at = now()
           WHERE slug = \$2 AND author_id = \$1
          RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
        SELECT a.id, a.slug, a.title, a.description, a.body, """ * article_tail * " FROM a JOIN users u ON u.id = a.author_id",
        [I8, T, T, T, T, T])
    s[S_ARTICLE_AUTHOR] = ("SELECT author_id FROM articles WHERE slug = \$1", [T])
    s[S_ARTICLE_DELETE] = ("DELETE FROM articles WHERE slug = \$1 AND author_id = \$2", [T, I8])
    # the write, then the read-back as its own statement in the same Sync group: its snapshot then includes a
    # conflicting write the insert waited for
    s[S_FAV_INSERT] = ("INSERT INTO favorites (user_id, article_id) SELECT \$1, a.id FROM articles a WHERE a.slug = \$2 ON CONFLICT DO NOTHING", [I8, T])
    s[S_FAV_DELETE] = ("DELETE FROM favorites WHERE user_id = \$1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = \$2)", [I8, T])
    s[S_ARTICLE_BY_SLUG] = (full_select * " WHERE a.slug = \$2", [I8, T])
    # $1 viewer, $2 slug, $3 body
    s[S_COMMENT_INSERT] = ("""
        WITH c AS (INSERT INTO comments (article_id, author_id, body)
                   SELECT a.id, \$1, \$3 FROM articles a WHERE a.slug = \$2
                   RETURNING id, body, created_at, updated_at, author_id)
        SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
          FROM c JOIN users u ON u.id = c.author_id""", [I8, T, T])
    # $1 comment id, $2 slug, $3 viewer
    s[S_COMMENT_DELETE] = ("DELETE FROM comments c USING articles a WHERE c.id = \$1 AND a.id = c.article_id AND a.slug = \$2 AND c.author_id = \$3", [I8, T, I8])
    s[S_COMMENT_AUTHOR] = ("SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = \$1 AND a.slug = \$2", [I8, T])
    s[S_USER_INSERT] = ("INSERT INTO users (username, email, password_hash) VALUES (\$1, \$2, \$3) RETURNING id, username, email, bio, image", [T, T, T])
    s[S_USER_UPDATE] = ("""
        UPDATE users SET email = COALESCE(\$2, email), username = COALESCE(\$3, username),
                         password_hash = COALESCE(\$4, password_hash), bio = COALESCE(\$5, bio), image = COALESCE(\$6, image)
         WHERE id = \$1
        RETURNING id, username, email, bio, image""", [I8, T, T, T, T, T])
    s[S_FOLLOW] = ("""
        WITH u AS (SELECT id, username, bio, image FROM users WHERE username = \$2),
             i AS (INSERT INTO follows (follower_id, followee_id) SELECT \$1, u.id FROM u ON CONFLICT DO NOTHING)
        SELECT username, bio, image FROM u""", [I8, T])
    s[S_UNFOLLOW] = ("""
        WITH u AS (SELECT id, username, bio, image FROM users WHERE username = \$2),
             d AS (DELETE FROM follows WHERE follower_id = \$1 AND followee_id IN (SELECT id FROM u))
        SELECT username, bio, image FROM u""", [I8, T])
    s
end
