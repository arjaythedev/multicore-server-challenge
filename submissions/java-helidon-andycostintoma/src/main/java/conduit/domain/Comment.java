package conduit.domain;

import conduit.errors.Forbidden;
import conduit.errors.InvalidInput;

public final class Comment {
    private final long id;
    private final long articleId;
    private final long authorId;
    private final String body;

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

    public record Input(
        long articleId,
        long authorId,
        String body
    ) {
    }

    public static Comment create(Input input) {
        requireBody(input.body());
        return new Comment(new Props(0, input.articleId(), input.authorId(), input.body()));
    }

    public static void requireBody(String body) {
        if (body == null || body.isEmpty()) {
            throw new InvalidInput("Comment body is required");
        }
    }

    public static Comment reconstitute(Props props) {
        return new Comment(props);
    }

    public void authorize(long viewer) {
        if (viewer != authorId) {
            throw new Forbidden("Only the author may delete this comment");
        }
    }

    private Comment(Props props) {
        this.id = props.id();
        this.articleId = props.articleId();
        this.authorId = props.authorId();
        this.body = props.body();
    }
}
