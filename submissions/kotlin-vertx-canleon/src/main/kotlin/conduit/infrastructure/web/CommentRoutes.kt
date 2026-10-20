package conduit.infrastructure.web

import io.netty.handler.codec.http.HttpResponseStatus
import io.vertx.ext.web.Router
import io.vertx.kotlin.coroutines.CoroutineRouterSupport
import conduit.application.CommentService
import conduit.domain.comment.NewComment
import conduit.domain.shared.NotFoundException

fun CoroutineRouterSupport.commentRoutes(router: Router, authentication: TokenAuthentication, commentService: CommentService) {
    router.get("/api/articles/:slug/comments").handler(authentication.optional).coHandler { context ->
        val viewerId = context.viewerId
        val slug = context.pathParameter("slug")
        context.respondJson(CommentsResponse(commentService.list(viewerId, slug)))
    }

    router.post("/api/articles/:slug/comments").handler(bodyHandler).handler(authentication.required).coHandler { context ->
        val userId = context.user.id
        val slug = context.pathParameter("slug")
        val newComment = NewComment.of(context.receiveJson<NewCommentRequest>().comment.body)
        context.respondJson(CommentResponse(commentService.add(userId, slug, newComment)), HttpResponseStatus.CREATED)
    }

    router.delete("/api/articles/:slug/comments/:id").handler(authentication.required).coHandler { context ->
        val userId = context.user.id
        val slug = context.pathParameter("slug")
        // a non-integer id can't name a comment
        val commentId = parseUnsignedLong(context.pathParameter("id"))
        if (commentId < 0) throw NotFoundException("comment")
        commentService.delete(userId, slug, commentId)
        context.respondNoContent()
    }
}
