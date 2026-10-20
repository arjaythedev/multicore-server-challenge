package conduit.infrastructure.web

import io.netty.handler.codec.http.HttpResponseStatus
import io.vertx.ext.web.Router
import io.vertx.kotlin.coroutines.CoroutineRouterSupport
import conduit.application.ArticleService
import conduit.application.TagService
import conduit.domain.article.ArticleChanges
import conduit.domain.article.ArticleFilter
import conduit.domain.article.NewArticle
import conduit.domain.shared.Pagination

fun CoroutineRouterSupport.articleRoutes(
    router: Router,
    authentication: TokenAuthentication,
    articleService: ArticleService,
    tagService: TagService,
) {
    router.get("/api/tags").coHandler { context ->
        context.respondJson(TagsResponse(tagService.all()))
    }

    router.get("/api/articles").handler(authentication.optional).coHandler { context ->
        val viewerId = context.viewerId
        val limit = context.intQueryParameter("limit", Pagination.DEFAULT_LIMIT)
        val offset = context.intQueryParameter("offset", Pagination.DEFAULT_OFFSET)
        val filter = ArticleFilter.of(
            tag = context.queryParameter("tag"),
            author = context.queryParameter("author"),
            favoritedBy = context.queryParameter("favorited"),
        )
        context.respondJson(articleService.list(viewerId, filter, limit, offset))
    }

    router.post("/api/articles").handler(bodyHandler).handler(authentication.required).coHandler { context ->
        val userId = context.user.id
        val input = context.receiveJson<NewArticleRequest>().article
        val newArticle = NewArticle.of(input.title, input.description, input.body, input.tagList)
        context.respondJson(ArticleResponse(articleService.create(userId, newArticle)), HttpResponseStatus.CREATED)
    }

    // declared before /api/articles/:slug, which would otherwise take "feed" as a slug
    router.get("/api/articles/feed").handler(authentication.required).coHandler { context ->
        val userId = context.user.id
        val limit = context.intQueryParameter("limit", Pagination.DEFAULT_LIMIT)
        val offset = context.intQueryParameter("offset", Pagination.DEFAULT_OFFSET)
        context.respondJson(articleService.feed(userId, limit, offset))
    }

    router.get("/api/articles/:slug").handler(authentication.optional).coHandler { context ->
        val viewerId = context.viewerId
        val slug = context.pathParameter("slug")
        context.respondJson(ArticleResponse(articleService.get(viewerId, slug)))
    }

    router.put("/api/articles/:slug").handler(bodyHandler).handler(authentication.required).coHandler { context ->
        val userId = context.user.id
        val slug = context.pathParameter("slug")
        val input = context.receiveJson<UpdateArticleRequest>().article
        val changes = ArticleChanges.of(input.title, input.description, input.body)
        context.respondJson(ArticleResponse(articleService.update(userId, slug, changes)))
    }

    router.delete("/api/articles/:slug").handler(authentication.required).coHandler { context ->
        val userId = context.user.id
        val slug = context.pathParameter("slug")
        articleService.delete(userId, slug)
        context.respondNoContent()
    }

    router.post("/api/articles/:slug/favorite").handler(authentication.required).coHandler { context ->
        val userId = context.user.id
        val slug = context.pathParameter("slug")
        context.respondJson(ArticleResponse(articleService.favorite(userId, slug)))
    }

    router.delete("/api/articles/:slug/favorite").handler(authentication.required).coHandler { context ->
        val userId = context.user.id
        val slug = context.pathParameter("slug")
        context.respondJson(ArticleResponse(articleService.unfavorite(userId, slug)))
    }
}
