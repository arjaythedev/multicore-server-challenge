package conduit.application

import conduit.domain.comment.Comment
import conduit.domain.comment.CommentRepository
import conduit.domain.comment.NewComment
import conduit.domain.shared.orNotFound

class CommentService(private val commentRepository: CommentRepository) {

    suspend fun list(viewerId: Long, slug: String): List<Comment> {
        return commentRepository.findByArticleSlug(viewerId, slug).orNotFound("article")
    }

    suspend fun add(authorId: Long, slug: String, comment: NewComment): Comment {
        return commentRepository.add(slug, authorId, comment).orNotFound("article")
    }

    suspend fun delete(userId: Long, slug: String, commentId: Long) {
        val authorship = commentRepository.findAuthorship(commentId, slug).orNotFound("comment")
        authorship.assertAuthor(userId)
        commentRepository.delete(authorship.commentId)
    }
}
