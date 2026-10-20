package conduit.infrastructure.web

import io.ktor.http.HttpStatusCode
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import conduit.application.CommentService
import conduit.domain.comment.NewComment
import conduit.domain.shared.NotFoundException

fun Route.commentRoutes(commentService: CommentService) {
    route("/api/articles/{slug}/comments") {
        optionalAuth {
            get {
                val viewerId = call.viewerId
                val slug = call.pathParameter("slug")
                call.respondJson(CommentsResponse(commentService.list(viewerId, slug)))
            }
        }

        authenticated {
            post {
                val userId = call.user.id
                val slug = call.pathParameter("slug")
                val newComment = NewComment.of(call.receiveJson<NewCommentRequest>().comment.body)
                call.respondJson(CommentResponse(commentService.add(userId, slug, newComment)), HttpStatusCode.Created)
            }
        }
    }

    route("/api/articles/{slug}/comments/{id}") {
        authenticated {
            delete {
                val userId = call.user.id
                val slug = call.pathParameter("slug")
                // a non-integer id can't name a comment
                val commentId = parseUnsignedLong(call.pathParameter("id"))
                if (commentId < 0) throw NotFoundException("comment")
                commentService.delete(userId, slug, commentId)
                call.respond(HttpStatusCode.NoContent)
            }
        }
    }
}
