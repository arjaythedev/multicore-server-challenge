package conduit.infrastructure.web

import io.ktor.http.HttpStatusCode
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import conduit.application.ArticleService
import conduit.application.TagService
import conduit.domain.article.ArticleChanges
import conduit.domain.article.ArticleFilter
import conduit.domain.article.NewArticle
import conduit.domain.shared.Pagination

fun Route.articleRoutes(articleService: ArticleService, tagService: TagService) {
    route("/api/tags") {
        get {
            call.respondJson(TagsResponse(tagService.all()))
        }
    }

    route("/api/articles") {
        optionalAuth {
            get {
                val viewerId = call.viewerId
                val limit = call.intQueryParameter("limit", Pagination.DEFAULT_LIMIT)
                val offset = call.intQueryParameter("offset", Pagination.DEFAULT_OFFSET)
                val filter = ArticleFilter.of(
                    tag = call.queryParameter("tag"),
                    author = call.queryParameter("author"),
                    favoritedBy = call.queryParameter("favorited"),
                )
                call.respondJson(articleService.list(viewerId, filter, limit, offset))
            }
        }

        authenticated {
            post {
                val userId = call.user.id
                val input = call.receiveJson<NewArticleRequest>().article
                val newArticle = NewArticle.of(input.title, input.description, input.body, input.tagList)
                call.respondJson(ArticleResponse(articleService.create(userId, newArticle)), HttpStatusCode.Created)
            }
        }
    }

    route("/api/articles/feed") {
        authenticated {
            get {
                val userId = call.user.id
                val limit = call.intQueryParameter("limit", Pagination.DEFAULT_LIMIT)
                val offset = call.intQueryParameter("offset", Pagination.DEFAULT_OFFSET)
                call.respondJson(articleService.feed(userId, limit, offset))
            }
        }
    }

    route("/api/articles/{slug}") {
        optionalAuth {
            get {
                val viewerId = call.viewerId
                val slug = call.pathParameter("slug")
                call.respondJson(ArticleResponse(articleService.get(viewerId, slug)))
            }
        }

        authenticated {
            put {
                val userId = call.user.id
                val slug = call.pathParameter("slug")
                val input = call.receiveJson<UpdateArticleRequest>().article
                val changes = ArticleChanges.of(input.title, input.description, input.body)
                call.respondJson(ArticleResponse(articleService.update(userId, slug, changes)))
            }

            delete {
                val userId = call.user.id
                val slug = call.pathParameter("slug")
                articleService.delete(userId, slug)
                call.respond(HttpStatusCode.NoContent)
            }
        }
    }

    route("/api/articles/{slug}/favorite") {
        authenticated {
            post {
                val userId = call.user.id
                val slug = call.pathParameter("slug")
                call.respondJson(ArticleResponse(articleService.favorite(userId, slug)))
            }

            delete {
                val userId = call.user.id
                val slug = call.pathParameter("slug")
                call.respondJson(ArticleResponse(articleService.unfavorite(userId, slug)))
            }
        }
    }
}
