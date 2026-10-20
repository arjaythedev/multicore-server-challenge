package conduit.domain.article

interface ArticleRepository {
    /** One page, newest first, without bodies, and the total (capped at 1,000). An unknown tag or user gives an empty list. */
    suspend fun findPage(viewerId: Long, filter: ArticleFilter, limit: Int, offset: Int): ArticleList

    /** One page of articles by the authors [userId] follows, newest first, without bodies, and the total (capped at 1,000). */
    suspend fun findFeedPage(userId: Long, limit: Int, offset: Int): ArticleList

    suspend fun findBySlug(viewerId: Long, slug: String): Article?

    suspend fun findById(viewerId: Long, id: Long): Article?

    suspend fun findOwnership(slug: String): ArticleOwnership?

    /** The article and its tags; returns the new id. */
    suspend fun create(authorId: Long, article: NewArticle): Long

    suspend fun update(articleId: Long, changes: ArticleChanges)

    suspend fun delete(articleId: Long)

    /** Favorites the article (idempotent) and returns it as the user now sees it; null if there's no such article. */
    suspend fun favorite(userId: Long, slug: String): Article?

    /** Removes the favorite (idempotent) and returns the article as the user now sees it; null if there's no such article. */
    suspend fun unfavorite(userId: Long, slug: String): Article?
}
