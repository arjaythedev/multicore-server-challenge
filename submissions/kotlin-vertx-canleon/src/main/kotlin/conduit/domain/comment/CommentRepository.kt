package conduit.domain.comment

interface CommentRepository {
    /** The newest 100 comments of the article with this slug, newest first; null if there's no such article. */
    suspend fun findByArticleSlug(viewerId: Long, articleSlug: String): List<Comment>?

    /** Adds the comment to the article with this slug; null if there's no such article. */
    suspend fun add(articleSlug: String, authorId: Long, comment: NewComment): Comment?

    /** null if there's no such comment on the article with this slug. */
    suspend fun findAuthorship(commentId: Long, articleSlug: String): CommentAuthorship?

    suspend fun delete(commentId: Long)
}
