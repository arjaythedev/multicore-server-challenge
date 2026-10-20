package conduit.infrastructure.postgres

import conduit.domain.article.Article
import conduit.domain.article.ArticleChanges
import conduit.domain.article.ArticleFilter
import conduit.domain.article.ArticleList
import conduit.domain.article.ArticleOwnership
import conduit.domain.article.ArticleRepository
import conduit.domain.article.NewArticle
import io.vertx.sqlclient.Row
import io.vertx.sqlclient.RowSet
import io.vertx.sqlclient.SqlClient
import io.vertx.sqlclient.Tuple

class PostgresArticleRepository(private val client: SqlClient) : ArticleRepository {

    override suspend fun findPage(viewerId: Long, filter: ArticleFilter, limit: Int, offset: Int): ArticleList {
        val (sql, filterValue) = when (filter) {
            ArticleFilter.All -> PAGE_ALL to null
            is ArticleFilter.Tag -> PAGE_BY_TAG to filter.name
            is ArticleFilter.Author -> PAGE_BY_AUTHOR to filter.username
            is ArticleFilter.FavoritedBy -> PAGE_FAVORITED_BY to filter.username
        }
        // [filter value (count),] viewer id, viewer id, [filter value (page),] offset, limit
        val arguments = Tuple.tuple()
        if (filterValue != null) {
            arguments.addString(filterValue)
        }
        arguments.addLong(viewerId).addLong(viewerId)
        if (filterValue != null) {
            arguments.addString(filterValue)
        }
        arguments.addInteger(offset).addInteger(limit)
        return client.execute(sql, arguments).toArticlePage()
    }

    override suspend fun findFeedPage(userId: Long, limit: Int, offset: Int): ArticleList {
        val arguments = Tuple.of(userId, userId, limit.toLong(), offset.toLong(), userId, offset, limit)
        return client.execute(PAGE_FEED, arguments).toArticlePage()
    }

    override suspend fun findBySlug(viewerId: Long, slug: String): Article? {
        return client.execute(ARTICLE_BY_SLUG, Tuple.of(viewerId, viewerId, slug)).firstOrNull()?.toArticle(withBody = true)
    }

    override suspend fun findById(viewerId: Long, id: Long): Article? {
        return client.execute(ARTICLE_BY_ID, Tuple.of(viewerId, viewerId, id)).firstOrNull()?.toArticle(withBody = true)
    }

    override suspend fun findOwnership(slug: String): ArticleOwnership? {
        val row = client.execute(ARTICLE_OWNER, Tuple.of(slug)).firstOrNull() ?: return null
        return ArticleOwnership(row.getLong("id"), row.getLong("author_id"))
    }

    override suspend fun create(authorId: Long, article: NewArticle): Long {
        val tagNames = article.tags.toTypedArray()
        if (tagNames.isNotEmpty()) {
            // Its own statement: if the article insert then fails, the new tags stay unused, which is harmless.
            client.execute(TAGS_INSERT, Tuple.of(tagNames))
        }
        val arguments = Tuple.of(article.title, authorId, article.title, article.description, article.body, tagNames)
        return client.execute(ARTICLE_INSERT, arguments).first().getLong("id")
    }

    override suspend fun update(articleId: Long, changes: ArticleChanges) {
        val arguments = Tuple.tuple()
            .addString(changes.title)
            .addString(changes.description)
            .addString(changes.body)
            .addString(changes.title)
            .addString(changes.title)
            .addLong(articleId)
        client.execute(ARTICLE_UPDATE, arguments)
    }

    override suspend fun delete(articleId: Long) {
        client.execute(ARTICLE_DELETE, Tuple.of(articleId))
    }

    override suspend fun favorite(userId: Long, slug: String): Article? {
        return setFavorite(FAVORITE_BY_SLUG, userId, slug)
    }

    override suspend fun unfavorite(userId: Long, slug: String): Article? {
        return setFavorite(UNFAVORITE_BY_SLUG, userId, slug)
    }

    /** [sql] is FAVORITE_BY_SLUG or UNFAVORITE_BY_SLUG: both take slug, user id, user id. */
    private suspend fun setFavorite(sql: String, userId: Long, slug: String): Article? {
        return client.execute(sql, Tuple.of(slug, userId, userId)).firstOrNull()?.toArticle(withBody = true)
    }

    /** Rows of a PAGE_* statement: every row carries articles_count; a row with a NULL id stands for an empty page. */
    private fun RowSet<Row>.toArticlePage(): ArticleList {
        val articles = ArrayList<Article>(size())
        var totalCount = 0L
        for (row in this) {
            totalCount = row.getLong("articles_count")
            if (row.getLong("id") != null) {
                articles.add(row.toArticle(withBody = false))
            }
        }
        return ArticleList(articles, totalCount)
    }
}
