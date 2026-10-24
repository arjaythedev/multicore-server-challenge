package conduit;

import java.time.OffsetDateTime;
import java.util.List;

import org.ethelred.kiwiproc.annotation.DAO;
import org.ethelred.kiwiproc.annotation.SqlQuery;
import org.ethelred.kiwiproc.annotation.SqlUpdate;
import org.jspecify.annotations.Nullable;

@DAO
public interface CommentDao {

    record CommentRow(long id, String body, OffsetDateTime createdAt, OffsetDateTime updatedAt, String username,
            @Nullable String bio, @Nullable String image, boolean following) {
    }

    /** A freshly inserted comment: its author is the viewer, so there is no "following". */
    record NewCommentRow(long id, String body, OffsetDateTime createdAt, OffsetDateTime updatedAt, String username,
            @Nullable String bio, @Nullable String image) {
    }

    @SqlQuery("""
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
                   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = :viewer AND fo.followee_id = c.author_id) AS following
              FROM comments c JOIN users u ON u.id = c.author_id
             WHERE c.article_id = :articleId
             ORDER BY c.created_at DESC, c.id DESC
             LIMIT 100""")
    List<CommentRow> list(long viewer, long articleId);

    @SqlQuery("""
            WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES (:articleId, :author, :body)
                       RETURNING id, body, created_at, updated_at, author_id)
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
              FROM c JOIN users u ON u.id = c.author_id""")
    NewCommentRow insert(long articleId, long author, String body);

    @SqlQuery("""
            SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
             WHERE c.id = :id AND a.slug = :slug""")
    @Nullable
    Long authorOf(long id, String slug);

    @SqlUpdate("DELETE FROM comments WHERE id = :id")
    void delete(long id);
}
