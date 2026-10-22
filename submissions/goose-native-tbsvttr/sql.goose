// The statements, prepared on every connection as s0, s1, ... $1 is always the viewer (0 = anonymous) where there
// is one. Each request is one statement where the reference SQL runs several; a list picks its page before the
// per-article subqueries run; an anonymous viewer skips the favorited and following probes.

import pg;

let ST_REGISTER = 0;
let ST_LOGIN = 1;
let ST_CURRENT_USER = 2;
let ST_UPDATE_USER = 3;
let ST_PROFILE = 4;
let ST_FOLLOW = 5;
let ST_UNFOLLOW = 6;
let ST_LIST_ALL = 7;
let ST_LIST_TAG = 8;
let ST_LIST_AUTHOR = 9;
let ST_LIST_FAVORITED = 10;
let ST_FEED = 11;
let ST_ARTICLE = 12;
let ST_INSERT_ARTICLE = 13;
let ST_INSERT_TAGS = 14;
let ST_INSERT_ARTICLE_TAGS = 15;
let ST_INSERTED_ARTICLE = 16;
let ST_UPDATE_ARTICLE = 17;
let ST_DELETE_ARTICLE = 18;
let ST_FAVORITE = 19;
let ST_UNFAVORITE = 20;
let ST_COMMENTS = 21;
let ST_CREATE_COMMENT = 22;
let ST_DELETE_COMMENT = 23;
let ST_TAGS = 24;
let ST_BATCH_ALL = 25;           // ST_LIST_ALL .. ST_LIST_FAVORITED for many members at once, in that order
let ST_BATCH_TAG = 26;
let ST_BATCH_AUTHOR = 27;
let ST_BATCH_FAVORITED = 28;
let ST_SHARE_ALL = 29;           // the same with the articles read once
let ST_SHARE_TAG = 30;
let ST_SHARE_AUTHOR = 31;
let ST_SHARE_FAVORITED = 32;
let ST_BATCH_ARTICLE = 33;      // live article reads, shared once per distinct requested slug in this execution
let STATEMENTS = 34;

fn slugify(out: u8[>..]&, x: const u8[:]) {
    format(out, "trim(both '-' from lower(regexp_replace(", x, ", '[^A-Za-z0-9]+', '-', 'g')))");
}

// The tag list as JSON text (bytea), copied into the response as it comes.
let TAG_LIST = "convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8')";
let FAVORITES_COUNT = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)";
let FAVORITED = "($1 <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1))";
let VIEWER_FAVORITE = "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)";

fn following(out: u8[>..]&, followee: const u8[:]) {
    format(out, "($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = ", followee, "))");
}

// Article columns, read in this order by write_article: slug, title, description, [body,] created_at, updated_at,
// tag list, favorites count, favorited, username, bio, image, following.
fn columns(out: u8[>..]&, body: bool, favorited: const u8[:], count: const u8[:], follow: const u8[:]) {
    out.append("a.slug, a.title, a.description, ");
    if body { out.append("a.body, "); }
    format(out, "a.created_at, a.updated_at, ", TAG_LIST, ", ", count, ", ", favorited, ", u.username, u.bio, u.image, ");
    if follow.len > 0 { out.append(follow); } else { following(out, "a.author_id"); }
}

fn plain_columns(out: u8[>..]&, body: bool) { columns(out, body, FAVORITED, FAVORITES_COUNT, ""); }

// One scan of the article's favorites gives both its count and whether the viewer is among them.
let FAV_LATERAL = " LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1), false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true";

// A page and its capped count in one statement: the count row with the page joined to it (an empty page leaves one
// row whose page columns are NULL). The inner LIMIT is the constant 100 and $2 applies outside it, so the generic
// plan is the right plan. Columns: the article columns, a.id, then the count. $2 limit, $3 offset, $4 filter.
fn page_with_count(out: u8[>..]&, i: i64) {
    format(out, "WITH c AS (", list_count(i), ") SELECT p.*, c.n FROM c LEFT JOIN LATERAL (SELECT ");
    let one_scan = i == ST_LIST_ALL || i == ST_LIST_TAG;
    if one_scan {
        columns(out, false, "fv.fav", "fv.fc", "");
    } else if i == ST_LIST_FAVORITED {
        // The viewer's favorites and followees are read once for the page, not probed per article.
        columns(out, false, "a.id = ANY(ARRAY(SELECT vf.article_id FROM favorites vf WHERE vf.user_id = $1))", FAVORITES_COUNT,
                "a.author_id = ANY(ARRAY(SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = $1))");
    } else {
        columns(out, false, FAVORITED, FAVORITES_COUNT, if i == ST_FEED { "true" } else { "" });
    }
    format(out, ", a.id FROM (", list_page(i), ") p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id");
    if one_scan { out.append(FAV_LATERAL); }
    out.append(" ORDER BY a.id DESC) p ON true ORDER BY p.id DESC");
}

// min(1000, rows): small sets are counted, and a 1000th row proves the cap without counting to it.
fn capped_from(from: const u8[:], key: const u8[:]) -> u8[>..] {
    str("SELECT CASE WHEN EXISTS (SELECT 1 ", from, " ORDER BY ", key, " OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) ",
        from, ") END AS n")
}

fn capped_select(select: const u8[:]) -> u8[>..] { str("SELECT count(*) AS n FROM (", select, " LIMIT 1000) s") }

// A list's capped count (one row, n).
fn list_count(i: i64) -> u8[>..] {
    return match i {
        ST_LIST_ALL => capped_from("FROM articles a", "a.id"),
        ST_LIST_TAG => capped_from("FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)", "at.article_id"),
        ST_LIST_AUTHOR => capped_select("SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4)"),
        ST_LIST_FAVORITED => capped_select("SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4)"),
        _ => capped_select("SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)"),
    };
}

// A list's page of article ids, newest first.
fn list_page(i: i64) -> u8[>..] {
    let ids = match i {
        ST_LIST_ALL => "SELECT id FROM articles ORDER BY id DESC",
        ST_LIST_TAG => "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC",
        ST_LIST_AUTHOR => "SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC",
        ST_LIST_FAVORITED => "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC",
        // Being in the feed proves the viewer follows the author, in the same snapshot. $4 is limit + offset.
        _ => "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC",
    };
    return str("SELECT id FROM (", ids, " LIMIT 100 OFFSET $3) b ORDER BY id DESC LIMIT $2");
}

// The sql with each $n parameter replaced by r.pn, the column of the request row it runs for. Every '$' is a
// parameter: the list statements have no '$' in a literal.
fn lateral(out: u8[>..]&, sql: const u8[:]) {
    for c in sql { if c == '$' { out.append("r.p"); } else { out.push(c); } }
}

// The requests of a batch: one row per member, its parameters as p1.., and its position as ord.
fn requests(out: u8[>..]&, nparams: i64) {
    out.append("unnest(");
    for k in nparams { format(out, if k > 0 { "," } else { "" }, "$", k + 1, if k < 3 { "::bigint[]" } else { "::text[]" }); }
    out.append(") WITH ORDINALITY AS r(");
    for k in nparams { format(out, "p", k + 1, ","); }
    out.append("ord)");
}

fn list_params(i: i64) -> i64 { if i == ST_LIST_ALL { 3 } else { 4 } }

// Queued lists of one kind as one execution: each member's page runs as before, and its rows come back in member
// order with ord as the last column.
fn batch_list(out: u8[>..]&, i: i64) {
    out.append("SELECT q.*, r.ord FROM ");
    requests(out, list_params(i));
    out.append(" CROSS JOIN LATERAL (");
    var one: u8[>..] = [];
    page_with_count(one, i);
    lateral(out, one);
    out.append(") q ORDER BY r.ord, q.id DESC");
}

// The same, for members that mostly ask for the same page: the pages are cut first, and every distinct article is
// read once (tags, favorite count, author); only favorited and following are worked out per member.
fn shared_list(out: u8[>..]&, i: i64) {
    out.append("WITH r AS MATERIALIZED (SELECT * FROM ");
    requests(out, list_params(i));
    out.append("), counted AS MATERIALIZED (SELECT r.*, c.n FROM r CROSS JOIN LATERAL (");
    lateral(out, list_count(i));
    out.append(") c), pages AS MATERIALIZED (SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r LEFT JOIN LATERAL (");
    lateral(out, list_page(i));
    format(out, ") p ON true), ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL), ",
           "e AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, ",
           TAG_LIST, " AS tags, ", FAVORITES_COUNT, " AS fc, u.username, u.bio, u.image ",
           "FROM ids JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id) ",
           "SELECT e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc, ",
           "(p.viewer <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = p.viewer)), ",
           "e.username, e.bio, e.image, ",
           "(p.viewer <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.viewer AND fo.followee_id = e.author_id)), ",
           "e.id, p.n, p.ord FROM pages p LEFT JOIN e ON e.id = p.id ORDER BY p.ord, e.id DESC");
}

// Only currently queued article requests participate. The shared metadata is materialized inside this statement,
// never retained for another request. Unknown slugs emit no row; ordinality lets the caller route each 404.
fn batch_article(out: u8[>..]&) {
    out.append("WITH r AS MATERIALIZED (SELECT * FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS q(viewer, slug, ord)), ");
    out.append("slugs AS (SELECT DISTINCT slug FROM r), e AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.body, ");
    format(out, "a.created_at, a.updated_at, a.author_id, ", TAG_LIST, " AS tags, ", FAVORITES_COUNT, " AS fc, u.username, u.bio, u.image ",
           "FROM slugs JOIN articles a ON a.slug = slugs.slug JOIN users u ON u.id = a.author_id) ",
           "SELECT e.slug, e.title, e.description, e.body, e.created_at, e.updated_at, e.tags, e.fc, ",
           "(r.viewer <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = r.viewer)), ",
           "e.username, e.bio, e.image, ",
           "(r.viewer <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = e.author_id)), ",
           "r.ord FROM r JOIN e ON e.slug = r.slug ORDER BY r.ord");
}

fn statement(out: u8[>..]&, i: i64) {
    match i {
        ST_REGISTER => out.append("INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image"),
        ST_LOGIN => out.append("SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"),
        ST_CURRENT_USER => out.append("SELECT username, email, bio, image FROM users WHERE id = $1"),
        ST_UPDATE_USER => out.append("UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING username, email, bio, image"),
        ST_PROFILE => {
            out.append("SELECT u.username, u.bio, u.image, ");
            following(out, "u.id");
            out.append(" FROM users u WHERE u.username = $2");
        },
        ST_FOLLOW => out.append("WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) SELECT username, bio, image FROM t"),
        ST_UNFOLLOW => out.append("WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) SELECT username, bio, image FROM t"),
        ST_LIST_ALL, ST_LIST_TAG, ST_LIST_AUTHOR, ST_LIST_FAVORITED, ST_FEED => page_with_count(out, i),
        ST_BATCH_ALL, ST_BATCH_TAG, ST_BATCH_AUTHOR, ST_BATCH_FAVORITED => batch_list(out, ST_LIST_ALL + i - ST_BATCH_ALL),
        ST_SHARE_ALL, ST_SHARE_TAG, ST_SHARE_AUTHOR, ST_SHARE_FAVORITED => shared_list(out, ST_LIST_ALL + i - ST_SHARE_ALL),
        ST_BATCH_ARTICLE => batch_article(out),
        ST_ARTICLE => {
            out.append("SELECT ");
            plain_columns(out, true);
            out.append(" FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2");
        },
        // Create runs as one implicit transaction: the article, its tags, their links, then the article as read back.
        ST_INSERT_ARTICLE => {
            out.append("INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id, ");
            slugify(out, "$2");
            out.append(" || '-' || n.id, $1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n");
        },
        // New names go in sorted order, so two creates adding the same new tags wait on each other instead of
        // deadlocking.
        // Names already there are read, not inserted: only the missing ones take the insert and conflict check.
        ST_INSERT_TAGS => out.append("INSERT INTO tags (name) SELECT x.name FROM (SELECT DISTINCT unnest($1::text[]) AS name) x WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = x.name) ORDER BY 1 ON CONFLICT (name) DO NOTHING"),
        ST_INSERT_ARTICLE_TAGS => out.append("INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])"),
        ST_INSERTED_ARTICLE => {
            out.append("SELECT ");
            plain_columns(out, true);
            out.append(" FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))");
        },
        // $2 slug, $3 title, $4 description, $5 body: author_id, then the article if the viewer wrote it.
        ST_UPDATE_ARTICLE => {
            out.append("WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2), a AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body), slug = CASE WHEN $3::text IS NULL THEN slug ELSE ");
            slugify(out, "$3");
            out.append(" || '-' || id END, updated_at = now() WHERE id = (SELECT id FROM t WHERE author_id = $1) RETURNING id, slug, title, description, body, created_at, updated_at, author_id) SELECT t.author_id, x.* FROM t LEFT JOIN LATERAL (SELECT ");
            plain_columns(out, true);
            out.append(" FROM a JOIN users u ON u.id = a.author_id) x ON true");
        },
        ST_DELETE_ARTICLE => out.append("WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2), d AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $1)) SELECT author_id FROM t"),
        // Only establish existence while mutating. A separate ST_ARTICLE after
        // ReadyForQuery reads the committed count, including concurrent writers
        // that the mutation's earlier statement snapshot could not see.
        ST_FAVORITE => out.append("WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) SELECT id FROM t"),
        ST_UNFAVORITE => out.append("WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t)) SELECT id FROM t"),
        // No row: unknown article. One row with a NULL id: no comments. The viewer's followees are read once.
        ST_COMMENTS => {
            out.append("SELECT x.id, x.created_at, x.updated_at, x.body, x.username, x.bio, x.image, x.following FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image, ");
            out.append("($1 <> 0 AND c.author_id IN (SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = $1))");
            out.append(" AS following FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x ON true WHERE a.slug = $2 ORDER BY x.created_at DESC, x.id DESC");
        },
        // $2 body, $3 slug. No row: unknown article.
        ST_CREATE_COMMENT => out.append("WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $2 FROM articles a WHERE a.slug = $3 RETURNING id, created_at, updated_at, body) SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image FROM c, users u WHERE u.id = $1"),
        // $2 comment id, $3 slug: author_id; the comment is deleted only if the viewer wrote it.
        ST_DELETE_COMMENT => out.append("WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $2 AND a.slug = $3), d AS (DELETE FROM comments WHERE id = (SELECT id FROM c WHERE author_id = $1)) SELECT author_id FROM c"),
        // One JSON array (NULL without tags); array_to_json, since json_agg puts a space after every comma.
        ST_TAGS => out.append("SELECT convert_to(array_to_json(array_agg(name ORDER BY name))::text, 'UTF8') FROM tags"),
        _ => abort("no such statement"),
    }
}

// The parameter types: i int8, t text, I int8[], a text[].
fn statement_types(i: i64) -> const u8[:] {
    match i {
        ST_REGISTER => "ttt",
        ST_LOGIN => "t",
        ST_CURRENT_USER => "i",
        ST_UPDATE_USER => "ittttt",
        ST_LIST_ALL => "iii",
        ST_LIST_TAG, ST_LIST_AUTHOR, ST_LIST_FAVORITED => "iiit",
        ST_FEED => "iiii",
        ST_BATCH_ALL, ST_SHARE_ALL => "III",
        ST_BATCH_TAG, ST_BATCH_AUTHOR, ST_BATCH_FAVORITED, ST_SHARE_TAG, ST_SHARE_AUTHOR, ST_SHARE_FAVORITED => "IIIa",
        ST_BATCH_ARTICLE => "Ia",
        ST_INSERT_ARTICLE => "ittt",
        ST_INSERT_TAGS, ST_INSERT_ARTICLE_TAGS => "a",
        ST_INSERTED_ARTICLE => "i",
        ST_UPDATE_ARTICLE => "itttt",
        ST_CREATE_COMMENT => "itt",
        ST_DELETE_COMMENT => "iit",
        ST_TAGS => "",
        _ => "it",
    }
}

// Parse messages for every statement, then a Sync.
fn prepare_all(out: u8[>..]&) {
    for i in STATEMENTS {
        var sql: u8[>..] = [];
        statement(sql, i);
        var types: i64[..8] = [];
        for c in statement_types(i) {
            types.push(if c == 'i' { OID_INT8 } else if c == 't' { OID_TEXT } else if c == 'I' { OID_INT8_ARRAY } else { OID_TEXT_ARRAY });
        }
        parse_stmt(out, i, sql, types);
    }
    sync(out);
}
