package conduit.domain;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import conduit.errors.Forbidden;
import conduit.errors.InvalidInput;
import org.junit.jupiter.api.Test;

class CommentTest {
    @Test
    void validatesBodyAndAuthorPermission() {
        assertThrows(InvalidInput.class, () -> Comment.create(new Comment.Input(1, 2, "")));
        assertThrows(InvalidInput.class, () -> Comment.create(new Comment.Input(1, 2, null)));
        var comment = Comment.reconstitute(new Comment.Props(0, 1, 2, "text"));
        var created = Comment.create(new Comment.Input(1, 2, "text"));
        assertEquals(0, created.id());
        assertEquals(1, created.articleId());
        assertEquals(2, created.authorId());
        assertEquals("text", created.body());
        assertThrows(Forbidden.class, () -> comment.authorize(3));
        assertDoesNotThrow(() -> comment.authorize(2));
    }
}
