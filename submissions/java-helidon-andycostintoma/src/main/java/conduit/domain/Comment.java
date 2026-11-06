package conduit.domain;

import conduit.errors.Forbidden;
import conduit.errors.InvalidInput;

public final class Comment {
    private final long id;
    private final long articleId;
    private final long authorId;
    private final String body;

    private Comment(Props props) {
        this.id = props.id();
        this.articleId = props.articleId();
        this.authorId = props.authorId();
        this.body = props.body();
    }

    public long id() {
        return id;
    }

    public long articleId() {
        return articleId;
    }

    public long authorId() {
        return authorId;
    }

    public String body() {
        return body;
    }

    public record Props(
        long id,
        long articleId,
        long authorId,
        String body
    ) {
    }

    public static Comment create(long articleId, long authorId, String body) {
        if (body == null || body.isEmpty()) {
            throw new InvalidInput("Comment body is required");
        }
        return new Comment(new Props(0, articleId, authorId, body));
    }

    public static Comment reconstitute(Props props) {
        return new Comment(props);
    }

    public void authorize(long viewer) {
        if (viewer != authorId) {
            throw new Forbidden("Only the author may delete this comment");
        }
    }
}
