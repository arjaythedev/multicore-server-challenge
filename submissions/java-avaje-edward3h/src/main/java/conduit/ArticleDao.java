package conduit;

import java.time.OffsetDateTime;
import java.util.List;

import org.ethelred.kiwiproc.annotation.DAO;
import org.ethelred.kiwiproc.annotation.SqlQuery;
import org.ethelred.kiwiproc.annotation.SqlUpdate;
import org.ethelred.kiwiproc.api.TransactionalDAO;
import org.jspecify.annotations.Nullable;

/** Articles, the feed, tags on articles, and favorites. */
@DAO
public interface ArticleDao extends TransactionalDAO<ArticleDao> {

    record ArticleRow(long id, String slug, String title, String description, OffsetDateTime createdAt,
            OffsetDateTime updatedAt, List<String> tagList, long favoritesCount, boolean favorited, String username,
            @Nullable String bio, @Nullable String image, boolean following) {
    }

    record ArticleFullRow(long id, String slug, String title, String description, String body, OffsetDateTime createdAt,
            OffsetDateTime updatedAt, List<String> tagList, long favoritesCount, boolean favorited, String username,
            @Nullable String bio, @Nullable String image, boolean following) {
    }

    record OwnerRow(long id, long authorId) {
    }

    // ---- shared fragments (:viewer = viewer) ----

    String LIST_SELECT = """
            SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
                   ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                          WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
                   (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
                   EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = :viewer) AS favorited,
                   u.username, u.bio, u.image,
                   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = :viewer AND fo.followee_id = a.author_id) AS following
              FROM articles a
              JOIN users u ON u.id = a.author_id
            """;

    String FULL_SELECT = """
            SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
                   ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                          WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
                   (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
                   EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = :viewer) AS favorited,
                   u.username, u.bio, u.image,
                   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = :viewer AND fo.followee_id = a.author_id) AS following
              FROM articles a
              JOIN users u ON u.id = a.author_id
            """;

    String ORDER_PAGE = " ORDER BY a.id DESC LIMIT :limit OFFSET :offset";

    // ---- lists ----

    @SqlQuery(LIST_SELECT + ORDER_PAGE)
    List<ArticleRow> listAll(long viewer, long limit, long offset);

    @SqlQuery("SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s")
    long countAll();

    @SqlQuery(LIST_SELECT + """
            WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = :tag)
                            ORDER BY at.article_id DESC LIMIT :limit OFFSET :offset) ORDER BY a.id DESC""")
    List<ArticleRow> listByTag(long viewer, long limit, long offset, String tag);

    @SqlQuery("""
            SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = :tag) LIMIT 1000) s""")
    long countByTag(String tag);

    @SqlQuery(LIST_SELECT + "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = :author)" + ORDER_PAGE)
    List<ArticleRow> listByAuthor(long viewer, long limit, long offset, String author);

    @SqlQuery("""
            SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = :author) LIMIT 1000) s""")
    long countByAuthor(String author);

    @SqlQuery(LIST_SELECT + """
            WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = :favoritedBy)
                            ORDER BY f.article_id DESC LIMIT :limit OFFSET :offset) ORDER BY a.id DESC""")
    List<ArticleRow> listFavorited(long viewer, long limit, long offset, String favoritedBy);

    @SqlQuery("""
            SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = :favoritedBy) LIMIT 1000) s""")
    long countFavorited(String favoritedBy);

    @SqlQuery(LIST_SELECT + """
            WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
                (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (CAST(:limit AS int) + CAST(:offset AS int))) x
              WHERE fo.follower_id = :viewer ORDER BY x.id DESC LIMIT :limit OFFSET :offset) ORDER BY a.id DESC""")
    List<ArticleRow> feed(long viewer, long limit, long offset);

    @SqlQuery("""
            SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = :viewer) LIMIT 1000) s""")
    long countFeed(long viewer);

    // ---- single articles ----

    @SqlQuery(FULL_SELECT + "WHERE a.slug = :slug")
    @Nullable
    ArticleFullRow findBySlug(long viewer, String slug);

    @SqlQuery(FULL_SELECT + "WHERE a.id = :id")
    @Nullable
    ArticleFullRow findById(long viewer, long id);

    @SqlQuery("SELECT id, author_id FROM articles WHERE slug = :slug")
    @Nullable
    OwnerRow owner(String slug);

    @SqlQuery("SELECT id FROM articles WHERE slug = :slug")
    @Nullable
    Long idBySlug(String slug);

    // ---- writes ----

    @SqlQuery("""
            INSERT INTO articles (id, slug, author_id, title, description, body)
            SELECT n.id, trim(both '-' from lower(regexp_replace(CAST(:title AS text), '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
                   :author, :title, :description, :body
              FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
            RETURNING id""")
    long insert(long author, String title, String description, String body);

    @SqlUpdate("INSERT INTO tags (name) SELECT DISTINCT unnest(CAST(:tags AS text[])) ON CONFLICT (name) DO NOTHING")
    void insertTags(List<String> tags);

    @SqlUpdate("INSERT INTO article_tags (article_id, tag_id) SELECT :id, t.id FROM tags t WHERE t.name = ANY(CAST(:tags AS text[]))")
    void tagArticle(long id, List<String> tags);

    @SqlUpdate("""
            UPDATE articles SET title = COALESCE(:title, title), description = COALESCE(:description, description), body = COALESCE(:body, body),
                   slug = CASE WHEN CAST(:title AS text) IS NULL THEN slug
                               ELSE trim(both '-' from lower(regexp_replace(CAST(:title AS text), '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
                   updated_at = now()
             WHERE id = :id""")
    void update(long id, @Nullable String title, @Nullable String description, @Nullable String body);

    @SqlUpdate("DELETE FROM articles WHERE id = :id")
    void delete(long id);

    @SqlUpdate("INSERT INTO favorites (user_id, article_id) VALUES (:viewer, :id) ON CONFLICT DO NOTHING")
    void favorite(long viewer, long id);

    @SqlUpdate("DELETE FROM favorites WHERE user_id = :viewer AND article_id = :id")
    void unfavorite(long viewer, long id);
}
