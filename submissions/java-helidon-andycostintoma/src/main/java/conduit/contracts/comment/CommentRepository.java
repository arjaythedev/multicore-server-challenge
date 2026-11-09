package conduit.contracts.comment;

import conduit.domain.Comment;

public interface CommentRepository {
    Comment comment(String slug, long id);

    Comment insertComment(Comment comment);

    void deleteComment(long id);
}
