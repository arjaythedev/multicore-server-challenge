package conduit.domain.comment

import conduit.domain.profile.Profile
import conduit.domain.shared.ForbiddenException
import conduit.domain.shared.requireNotEmpty
import java.time.Instant

class Comment(val id: Long, val createdAt: Instant, val updatedAt: Instant, val body: String, val author: Profile)

/** Who wrote a comment: only the author may delete it. */
class CommentAuthorship(val commentId: Long, val authorId: Long) {
    /** Forbidden unless [userId] is the author. */
    fun assertAuthor(userId: Long) {
        if (authorId != userId) throw ForbiddenException()
    }
}

class NewComment private constructor(val body: String) {
    companion object {
        fun of(body: String?): NewComment {
            return NewComment(body.requireNotEmpty("body"))
        }
    }
}
