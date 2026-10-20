package conduit.infrastructure.postgres

import conduit.domain.comment.Comment
import conduit.domain.comment.CommentAuthorship
import conduit.domain.comment.CommentRepository
import conduit.domain.comment.NewComment
import io.vertx.sqlclient.SqlClient
import io.vertx.sqlclient.Tuple

class PostgresCommentRepository(private val client: SqlClient) : CommentRepository {

    override suspend fun findByArticleSlug(viewerId: Long, articleSlug: String): List<Comment>? {
        val rows = client.execute(COMMENTS_BY_ARTICLE_SLUG, Tuple.of(articleSlug, viewerId))
        // no row: no such article; a row with a NULL comment id: an article without comments
        if (rows.size() == 0) {
            return null
        }
        val comments = ArrayList<Comment>(rows.size())
        for (row in rows) {
            if (row.getLong("id") != null) {
                comments.add(row.toComment())
            }
        }
        return comments
    }

    override suspend fun add(articleSlug: String, authorId: Long, comment: NewComment): Comment? {
        return client.execute(COMMENT_INSERT_BY_SLUG, Tuple.of(articleSlug, authorId, comment.body)).firstOrNull()?.toComment()
    }

    override suspend fun findAuthorship(commentId: Long, articleSlug: String): CommentAuthorship? {
        val row = client.execute(COMMENT_OWNER, Tuple.of(commentId, articleSlug)).firstOrNull() ?: return null
        return CommentAuthorship(commentId, row.getLong("author_id"))
    }

    override suspend fun delete(commentId: Long) {
        client.execute(COMMENT_DELETE, Tuple.of(commentId))
    }
}
