package challenge.pg;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

public final class Stmt {
    public static final int INT8 = 20;
    public static final int INT4 = 23;
    public static final int TEXT = 25;
    public static final int BOOL = 16;
    public static final int TEXT_ARRAY = 1009;
    public static final int INT8_ARRAY = 1016;
    public static final int INT4_ARRAY = 1007;
    private static final List<Statement> REGISTRY = new ArrayList<>();
    public static final int TAGS = register("SELECT name FROM tags ORDER BY name");
    public static final int REGISTER = register("INSERT INTO users (username,email,password_hash) VALUES ($1,$2,$3) RETURNING id,username,email,bio,image",
            TEXT, TEXT, TEXT);
    public static final int LOGIN = register("SELECT id,username,email,bio,image,password_hash FROM users WHERE email=$1", TEXT);
    public static final int USER = register("SELECT id,username,email,bio,image FROM users WHERE id=$1", INT8);
    public static final int UPDATE_USER = register("UPDATE users SET email=COALESCE($2,email),username=COALESCE($3,username),password_hash=COALESCE($4,password_hash),bio=COALESCE($5,bio),image=COALESCE($6,image) WHERE id=$1 RETURNING id,username,email,bio,image",
            INT8, TEXT, TEXT, TEXT, TEXT, TEXT);
    public static final int PROFILE = register("SELECT u.username,u.bio,u.image,EXISTS (SELECT 1 FROM follows f WHERE f.follower_id=$1 AND f.followee_id=u.id) FROM users u WHERE u.username=$2",
            INT8, TEXT);
    public static final int FOLLOW = register("WITH u AS (SELECT id,username,bio,image FROM users WHERE username=$2), ins AS (INSERT INTO follows SELECT $1,u.id FROM u ON CONFLICT DO NOTHING) SELECT username,bio,image FROM u",
            INT8, TEXT);
    public static final int UNFOLLOW = register("WITH u AS (SELECT id,username,bio,image FROM users WHERE username=$2), del AS (DELETE FROM follows WHERE follower_id=$1 AND followee_id IN (SELECT id FROM u)) SELECT username,bio,image FROM u",
            INT8, TEXT);
    private static final String ARTICLE_COLUMNS = "a.id,a.slug,a.title,a.description,";
    private static final String ARTICLE_DECORATION = "a.created_at,a.updated_at,ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id=at.tag_id WHERE at.article_id=a.id ORDER BY t.name),(SELECT count(*) FROM favorites f WHERE f.article_id=a.id),EXISTS(SELECT 1 FROM favorites f WHERE f.user_id=$1::int8 AND f.article_id=a.id),u.username,u.bio,u.image,EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$1::int8 AND fo.followee_id=a.author_id)";

    private static int list(String page, String count, boolean filter) {
        // limit is validated to 1..100: the constant outer LIMIT caps the planner's row estimate for a parameter LIMIT
        // (otherwise 10% of the table), so a batched LATERAL page never turns into a hash join over all articles
        String sql = "WITH page AS (SELECT id FROM ("
                + page
                + ") pg LIMIT 100), cnt AS (SELECT count(*) AS n FROM ("
                + count
                + " LIMIT 1000) s) SELECT "
                + ARTICLE_COLUMNS
                + ARTICLE_DECORATION
                + ",cnt.n FROM cnt LEFT JOIN page p ON true LEFT JOIN articles a ON a.id=p.id LEFT JOIN users u ON u.id=a.author_id ORDER BY a.id DESC";
        return filter ? register(sql, INT8, INT4, INT4, TEXT) : register(sql, INT8, INT4, INT4);
    }

    public static final int ARTICLES = list("SELECT id FROM articles ORDER BY id DESC LIMIT $2::int4 OFFSET $3::int4", "SELECT 1 FROM articles", false);
    public static final int ARTICLES_TAG = list("SELECT article_id AS id FROM article_tags WHERE tag_id=(SELECT id FROM tags WHERE name=$4::text) ORDER BY article_id DESC LIMIT $2::int4 OFFSET $3::int4",
            "SELECT 1 FROM article_tags WHERE tag_id=(SELECT id FROM tags WHERE name=$4::text)", true);
    public static final int ARTICLES_AUTHOR = list("SELECT id FROM articles WHERE author_id=(SELECT id FROM users WHERE username=$4::text) ORDER BY id DESC LIMIT $2::int4 OFFSET $3::int4",
            "SELECT 1 FROM articles WHERE author_id=(SELECT id FROM users WHERE username=$4::text)", true);
    public static final int ARTICLES_FAVORITED = list("SELECT article_id AS id FROM favorites WHERE user_id=(SELECT id FROM users WHERE username=$4::text) ORDER BY article_id DESC LIMIT $2::int4 OFFSET $3::int4",
            "SELECT 1 FROM favorites WHERE user_id=(SELECT id FROM users WHERE username=$4::text)", true);
    public static final int FEED = list("SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id=fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int8+$3::int8)) x WHERE fo.follower_id=$1::int8 ORDER BY x.id DESC LIMIT $2::int4 OFFSET $3::int4",
            "SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id=$1::int8)", false);
    public static final int ARTICLE = register("SELECT " + ARTICLE_COLUMNS + "a.body," + ARTICLE_DECORATION + " FROM articles a JOIN users u ON u.id=a.author_id WHERE a.slug=$2::text",
            INT8, TEXT);
    public static final int COMMENTS = register("SELECT c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image,EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$1::int8 AND fo.followee_id=c.author_id) FROM articles a LEFT JOIN LATERAL (SELECT id,body,created_at,updated_at,author_id FROM comments WHERE article_id=a.id ORDER BY created_at DESC,id DESC LIMIT 100) c ON true LEFT JOIN users u ON u.id=c.author_id WHERE a.slug=$2::text ORDER BY c.created_at DESC,c.id DESC",
            INT8, TEXT);
    // tag names in one join for the whole statement: as a per-article subplan, the generic plan hashed all of tags
    // (seq scan, 200 rows) once per article, a third of a list batch's time
    private static final String BATCH_DECO = "SELECT a.id,a.slug,a.title,a.description,a.body,a.created_at,a.updated_at,a.author_id,tg.tags,(SELECT count(*) FROM favorites f WHERE f.article_id=a.id) AS fav_count,u.username,u.bio,u.image FROM ids JOIN articles a ON a.id=ids.id JOIN users u ON u.id=a.author_id LEFT JOIN (SELECT at.article_id,array_agg(t.name ORDER BY t.name) AS tags FROM ids ti JOIN article_tags at ON at.article_id=ti.id JOIN tags t ON t.id=at.tag_id GROUP BY at.article_id) tg ON tg.article_id=a.id";
    private static final String BATCH_COLUMNS = "d.id,d.slug,d.title,d.description,";
    private static final String BATCH_DECORATION = "d.created_at,d.updated_at,COALESCE(d.tags,ARRAY[]::text[]) AS array,COALESCE(d.fav_count,0::bigint) AS count,EXISTS(SELECT 1 FROM favorites f WHERE f.user_id=r.viewer AND f.article_id=d.id),d.username,d.bio,d.image,EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=r.viewer AND fo.followee_id=d.author_id)";
    // each slug is looked up once (m), and the article row read there is the one returned: deco adds only what is
    // shared by every request for the article (tags, favorites count, author)
    public static final int ARTICLE_BATCH = register("WITH r AS MATERIALIZED (SELECT * FROM unnest($1::text[],$2::int8[]) WITH ORDINALITY AS r(slug,viewer,i)), m AS MATERIALIZED (SELECT r.i,r.viewer,a.id,a.slug,a.title,a.description,a.body,a.created_at,a.updated_at,a.author_id FROM r JOIN articles a ON a.slug=r.slug), ids AS (SELECT DISTINCT id,author_id FROM m), deco AS MATERIALIZED (SELECT ids.id,tg.tags,(SELECT count(*) FROM favorites f WHERE f.article_id=ids.id) AS fav_count,u.username,u.bio,u.image FROM ids JOIN users u ON u.id=ids.author_id LEFT JOIN (SELECT at.article_id,array_agg(t.name ORDER BY t.name) AS tags FROM ids ti JOIN article_tags at ON at.article_id=ti.id JOIN tags t ON t.id=at.tag_id GROUP BY at.article_id) tg ON tg.article_id=ids.id) SELECT r.i::int4,r.id,r.slug,r.title,r.description,r.body,r.created_at,r.updated_at,COALESCE(d.tags,ARRAY[]::text[]) AS array,COALESCE(d.fav_count,0::bigint) AS count,EXISTS(SELECT 1 FROM favorites f WHERE f.user_id=r.viewer AND f.article_id=r.id),d.username,d.bio,d.image,EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=r.viewer AND fo.followee_id=r.author_id) FROM m r JOIN deco d ON d.id=r.id ORDER BY r.i",
            TEXT_ARRAY, INT8_ARRAY);
    public static final int COMMENTS_BATCH = register("WITH r AS MATERIALIZED (SELECT * FROM unnest($1::text[],$2::int8[]) WITH ORDINALITY AS r(slug,viewer,i)), m AS MATERIALIZED (SELECT r.i,r.viewer,a.id FROM r JOIN articles a ON a.slug=r.slug), ids AS (SELECT DISTINCT id FROM m), comments_deco AS MATERIALIZED (SELECT ids.id AS article_id,c.id,c.body,c.created_at,c.updated_at,c.author_id,u.username,u.bio,u.image FROM ids LEFT JOIN LATERAL (SELECT id,body,created_at,updated_at,author_id FROM comments WHERE article_id=ids.id ORDER BY created_at DESC,id DESC LIMIT 100) c ON true LEFT JOIN users u ON u.id=c.author_id) SELECT r.i::int4,c.id,c.body,c.created_at,c.updated_at,c.username,c.bio,c.image,EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=r.viewer AND fo.followee_id=c.author_id) FROM m r JOIN comments_deco c ON c.article_id=r.id ORDER BY r.i,c.created_at DESC,c.id DESC",
            TEXT_ARRAY, INT8_ARRAY);

    private static int batchList(int single, String inputs, boolean global,
            int... types) {
        String sql = REGISTRY.get(single)
                             .sql()
                             .replace("$3::int8", "r.off::int8")
                             .replace("$2::int8", "r.lim::int8")
                             .replace("$3::int4", "r.off")
                             .replace("$2::int4", "r.lim")
                             .replace("$1::int8", "r.viewer");
        String prefix = "";
        if (global) {
            prefix = "WITH shared_cnt AS MATERIALIZED (SELECT count(*) AS n FROM (SELECT 1 FROM articles LIMIT 1000) s) ";
            sql = sql.replace("cnt AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles LIMIT 1000) s)", "cnt AS (SELECT n FROM shared_cnt)");
        } else if (single == FEED) {
            prefix = "WITH candidates AS MATERIALIZED (SELECT fo.followee_id FROM unnest($1::int8[],$2::int4[],$3::int4[]) AS b(viewer,lim,off) JOIN follows fo ON fo.follower_id=b.viewer GROUP BY fo.followee_id ORDER BY count(*) DESC,fo.followee_id LIMIT 4), prolific AS MATERIALIZED (SELECT c.followee_id,EXISTS (SELECT 1 FROM articles a WHERE a.author_id=c.followee_id ORDER BY a.id DESC OFFSET 999 LIMIT 1) AS proven FROM candidates c) ";
            sql = sql.replace(
                    "cnt AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id=r.viewer) LIMIT 1000) s)",
                    "cnt AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM prolific c JOIN follows fo ON fo.follower_id=r.viewer AND fo.followee_id=c.followee_id WHERE c.proven) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id=r.viewer) LIMIT 1000) s) END AS n)");
        }
        int select = sql.indexOf(" SELECT " + ARTICLE_COLUMNS);
        sql = sql.substring(0, select) + " SELECT p.id,cnt.n FROM cnt LEFT JOIN page p ON true";
        String ctes = prefix.isEmpty() ? "WITH " : prefix + ", ";
        String columns = (single == FEED ? "viewer,lim,off" : "lim,off,viewer") + ",i";
        return decorated(
                ctes
                        + "r AS MATERIALIZED (SELECT * FROM unnest("
                        + inputs
                        + ") WITH ORDINALITY AS r("
                        + columns
                        + ")), pages AS MATERIALIZED (SELECT r.i,r.viewer,p.id,p.n FROM r CROSS JOIN LATERAL ("
                        + sql
                        + ") p)",
                types);
    }

    /**
     * {@code pages(i, viewer, id, n)}, one row per listed article (id null for
     * an empty page), decorated once per distinct article.
     */
    private static int decorated(String pages, int... types) {
        return register(
                pages
                        + ", ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL), deco AS MATERIALIZED ("
                        + BATCH_DECO.replace("a.description,a.body,", "a.description,")
                        + ") SELECT r.i::int4,"
                        + BATCH_COLUMNS
                        + BATCH_DECORATION
                        + ",r.n FROM pages r LEFT JOIN deco d ON d.id=r.id ORDER BY r.i,d.id DESC",
                types);
    }

    /**
     * A list filtered by a name (tag, author, favoriting user): each distinct
     * name in the batch is resolved and counted once, however many requests
     * ask for it. {@code key} turns names {@code k(name)} into {@code
     * kid}; an unknown name leaves kid null, so its page is empty and its count
     * 0.
     */
    private static int keyedList(String key, String count, String page) {
        return decorated("WITH r AS MATERIALIZED (SELECT * FROM unnest($1::text[],$2::int4[],$3::int4[],$4::int8[]) WITH ORDINALITY AS r(name,lim,off,viewer,i)), k AS MATERIALIZED ("
                        + key.replace("{names}", "(SELECT DISTINCT name FROM r) k")
                        + "), kc AS MATERIALIZED (SELECT k.name,k.kid,(SELECT count(*) FROM ("
                        + count
                        + " LIMIT 1000) s) AS n FROM k), pages AS MATERIALIZED (SELECT r.i,r.viewer,p.id,kc.n FROM r JOIN kc ON kc.name=r.name LEFT JOIN LATERAL (SELECT id FROM ("
                        + page
                        + " LIMIT r.lim OFFSET r.off) pg LIMIT 100) p ON true)",
                TEXT_ARRAY, INT4_ARRAY, INT4_ARRAY, INT8_ARRAY);
    }

    public static final int ARTICLES_BATCH = batchList(ARTICLES, "$1::int4[],$2::int4[],$3::int8[]",
            true, INT4_ARRAY, INT4_ARRAY, INT8_ARRAY);
    public static final int FEED_BATCH = batchList(FEED, "$1::int8[],$2::int4[],$3::int4[]",
            false, INT8_ARRAY, INT4_ARRAY, INT4_ARRAY);
    public static final int ARTICLES_TAG_BATCH = keyedList("SELECT k.name,t.id AS kid FROM {names} LEFT JOIN tags t ON t.name=k.name",
            "SELECT 1 FROM article_tags WHERE tag_id=k.kid", "SELECT article_id AS id FROM article_tags WHERE tag_id=kc.kid ORDER BY article_id DESC");
    public static final int ARTICLES_AUTHOR_BATCH = keyedList("SELECT k.name,u.id AS kid FROM {names} LEFT JOIN users u ON u.username=k.name",
            "SELECT 1 FROM articles WHERE author_id=k.kid", "SELECT id FROM articles WHERE author_id=kc.kid ORDER BY id DESC");
    public static final int ARTICLES_FAVORITED_BATCH = keyedList("SELECT k.name,u.id AS kid FROM {names} LEFT JOIN users u ON u.username=k.name",
            "SELECT 1 FROM favorites WHERE user_id=k.kid", "SELECT article_id AS id FROM favorites WHERE user_id=kc.kid ORDER BY article_id DESC");
    public static final int PROFILE_BATCH = register("SELECT r.i::int4,q.* FROM unnest($1::text[],$2::int8[]) WITH ORDINALITY AS r(name,viewer,i) CROSS JOIN LATERAL (SELECT u.username,u.bio,u.image,EXISTS (SELECT 1 FROM follows f WHERE f.follower_id=r.viewer AND f.followee_id=u.id) FROM users u WHERE u.username=r.name) q",
            TEXT_ARRAY, INT8_ARRAY);
    public static final int USER_BATCH = register(
            "SELECT r.i::int4,q.* FROM unnest($1::int8[]) WITH ORDINALITY AS r(id,i) CROSS JOIN LATERAL (SELECT id,username,email,bio,image FROM users WHERE id=r.id) q",
            INT8_ARRAY);
    public static final int INSERT_TAGS = register("INSERT INTO tags (name) SELECT DISTINCT name FROM unnest($1::text[]) name ON CONFLICT (name) DO NOTHING", TEXT_ARRAY);
    public static final int CREATE_ARTICLE = register("WITH n AS (SELECT nextval(pg_get_serial_sequence('articles','id')) AS id), a AS (INSERT INTO articles (id,slug,author_id,title,description,body) SELECT id,$6::text||'-'||id,$1,$2,$3,$4 FROM n RETURNING *), links AS (INSERT INTO article_tags (article_id,tag_id) SELECT a.id,t.id FROM a,tags t WHERE t.name=ANY($5::text[])) SELECT " + ARTICLE_COLUMNS + "a.body,a.created_at,a.updated_at,ARRAY(SELECT DISTINCT name FROM unnest($5::text[]) name ORDER BY name),0::bigint,false,u.username,u.bio,u.image,false FROM a JOIN users u ON u.id=a.author_id",
            INT8, TEXT, TEXT, TEXT, TEXT_ARRAY, TEXT);
    public static final int UPDATE_ARTICLE = register("WITH target AS (SELECT id,author_id FROM articles WHERE slug=$2), a AS (UPDATE articles SET title=COALESCE($3,title),description=COALESCE($4,description),body=COALESCE($5,body),slug=CASE WHEN $3::text IS NULL THEN slug ELSE $6::text||'-'||id END,updated_at=now() WHERE id IN (SELECT id FROM target WHERE author_id=$1) RETURNING *) SELECT " + ARTICLE_COLUMNS + "a.body," + ARTICLE_DECORATION + " FROM target LEFT JOIN a ON true LEFT JOIN users u ON u.id=a.author_id",
            INT8, TEXT, TEXT, TEXT, TEXT, TEXT);
    public static final int DELETE_ARTICLE = register("WITH target AS (SELECT id,author_id FROM articles WHERE slug=$2), del AS (DELETE FROM articles WHERE id IN (SELECT id FROM target WHERE author_id=$1)) SELECT author_id=$1 FROM target",
            INT8, TEXT);
    public static final int FAVORITE = register("INSERT INTO favorites (user_id,article_id) SELECT $1,id FROM articles WHERE slug=$2 ON CONFLICT DO NOTHING",
            INT8, TEXT);
    public static final int UNFAVORITE = register("DELETE FROM favorites WHERE user_id=$1 AND article_id IN (SELECT id FROM articles WHERE slug=$2)",
            INT8, TEXT);
    public static final int CREATE_COMMENT = register("WITH c AS (INSERT INTO comments (article_id,author_id,body) SELECT id,$1,$3 FROM articles WHERE slug=$2 RETURNING *) SELECT c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image FROM c JOIN users u ON u.id=c.author_id",
            INT8, TEXT, TEXT);
    public static final int DELETE_COMMENT = register("WITH target AS (SELECT c.id,c.author_id FROM comments c JOIN articles a ON a.id=c.article_id WHERE c.id=$3 AND a.slug=$2), del AS (DELETE FROM comments WHERE id IN (SELECT id FROM target WHERE author_id=$1)) SELECT author_id=$1 FROM target",
            INT8, TEXT, INT8);
    private static final boolean[] PAGE = new boolean[REGISTRY.size()];

    static {
        for (int id : new int[] {ARTICLES, ARTICLES_TAG, ARTICLES_AUTHOR, ARTICLES_FAVORITED, FEED, COMMENTS}) {
            PAGE[id] = true;
        }
    }

    /**
     * Statements whose rows carry full article or comment lists, sized up front
     * in Query.
     */
    public static boolean page(int id) {
        return PAGE[id];
    }

    public static int count() {
        return PAGE.length;
    }

    private static boolean frozen;

    public record Statement(String sql, int[] parameterOids) {
        public Statement {
            Objects.requireNonNull(sql);
            parameterOids = parameterOids.clone();
        }

        @Override
        public int[] parameterOids() {
            return parameterOids.clone();
        }

        public int parameterCount() {
            return parameterOids.length;
        }
    }

    public static synchronized int register(String sql, int... parameterOids) {
        if (frozen) {
            throw new IllegalStateException("statement registry already in use");
        }
        REGISTRY.add(new Statement(sql, parameterOids));
        return REGISTRY.size() - 1;
    }

    public static synchronized List<Statement> freeze() {
        frozen = true;
        return List.copyOf(REGISTRY);
    }

    private Stmt() {}
}
