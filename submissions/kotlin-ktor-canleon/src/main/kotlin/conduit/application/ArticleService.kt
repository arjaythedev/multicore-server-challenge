package conduit.application

import conduit.domain.article.Article
import conduit.domain.article.ArticleChanges
import conduit.domain.article.ArticleFilter
import conduit.domain.article.ArticleList
import conduit.domain.article.ArticleRepository
import conduit.domain.article.NewArticle
import conduit.domain.shared.Pagination
import conduit.domain.shared.orNotFound

class ArticleService(private val articleRepository: ArticleRepository) {

    suspend fun list(viewerId: Long, filter: ArticleFilter, limit: Int, offset: Int): ArticleList {
        Pagination.assertRange(limit, offset)
        return articleRepository.findPage(viewerId, filter, limit, offset)
    }

    suspend fun feed(userId: Long, limit: Int, offset: Int): ArticleList {
        Pagination.assertRange(limit, offset)
        return articleRepository.findFeedPage(userId, limit, offset)
    }

    suspend fun get(viewerId: Long, slug: String): Article {
        return articleRepository.findBySlug(viewerId, slug).orNotFound("article")
    }

    suspend fun create(authorId: Long, article: NewArticle): Article {
        val id = articleRepository.create(authorId, article)
        return articleRepository.findById(authorId, id).orNotFound("article")
    }

    suspend fun update(userId: Long, slug: String, changes: ArticleChanges): Article {
        val ownership = articleRepository.findOwnership(slug).orNotFound("article")
        ownership.assertAuthor(userId)
        articleRepository.update(ownership.articleId, changes)
        return articleRepository.findById(userId, ownership.articleId).orNotFound("article")
    }

    suspend fun delete(userId: Long, slug: String) {
        val ownership = articleRepository.findOwnership(slug).orNotFound("article")
        ownership.assertAuthor(userId)
        articleRepository.delete(ownership.articleId)
    }

    suspend fun favorite(userId: Long, slug: String): Article {
        return articleRepository.favorite(userId, slug).orNotFound("article")
    }

    suspend fun unfavorite(userId: Long, slug: String): Article {
        return articleRepository.unfavorite(userId, slug).orNotFound("article")
    }
}
