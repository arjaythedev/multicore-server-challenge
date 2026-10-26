package conduit.writes;

import conduit.Exchange;
import conduit.RequestBody;
import conduit.db.MessageWriter;
import conduit.db.Row;
import conduit.db.Statement;
import conduit.json.Keys;
import conduit.json.Render;

/** POST /api/articles/:slug/comments and DELETE /api/articles/:slug/comments/:id. */
public final class CommentWrites {
    // $1 viewer, $2 slug, $3 body: the article lookup, the insert and the author's profile in one statement
    private static final Statement INSERT_COMMENT = Statement.define(
            "WITH c AS (INSERT INTO comments (article_id, author_id, body)"
                    + "           SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2"
                    + "           RETURNING id, body, created_at, updated_at, author_id)"
                    + " SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image"
                    + "   FROM c JOIN users u ON u.id = c.author_id",
            Statement.INT8, Statement.TEXT, Statement.TEXT);

    // $1 viewer, $2 slug, $3 comment id: only the author's own comment on that article matches
    private static final Statement DELETE_COMMENT = Statement.define(
            "DELETE FROM comments c USING articles a"
                    + " WHERE c.id = $3 AND a.id = c.article_id AND a.slug = $2 AND c.author_id = $1",
            Statement.INT8, Statement.TEXT, Statement.INT8);

    /** After a delete matched nothing: does the comment exist on that article (403) or not (404)? */
    private static final Statement COMMENT_EXISTS = Statement.define(
            "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $2 AND a.slug = $1",
            Statement.TEXT, Statement.INT8);

    private CommentWrites() {
    }

    public static void create(Exchange exchange, String slug, byte[] body) throws RequestBody.Invalid {
        String text = RequestBody.parse(body, "comment").required("body");
        new CreateComment(exchange, slug, text).submit();
    }

    private static final class CreateComment extends WriteQuery {
        private final String slug, body;

        CreateComment(Exchange exchange, String slug, String body) {
            super(exchange);
            this.slug = slug;
            this.body = body;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(INSERT_COMMENT).int8(exchange.viewer).text(slug).text(body).execute();
            out.sync();
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            exchange.found = true;
            exchange.json().beginObject().key(Keys.COMMENT);
            Render.commentOpen(exchange.json(), row, 0);
            Render.commentClose(exchange.json(), false);           // nobody follows themselves here
            exchange.json().endObject();
        }

        @Override
        protected void onSuccess() {
            if (exchange.found) exchange.respond(201);
            else exchange.respondError(404, "article not found");
        }
    }

    public static void delete(Exchange exchange, String slug, long commentId) {
        new DeleteComment(exchange, slug, commentId).submit();
    }

    private static final class DeleteComment extends WriteQuery {
        private final String slug;
        private final long commentId;
        private boolean deleted;

        DeleteComment(Exchange exchange, String slug, long commentId) {
            super(exchange);
            this.slug = slug;
            this.commentId = commentId;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(DELETE_COMMENT).int8(exchange.viewer).text(slug).int8(commentId).execute();
            out.sync();
        }

        @Override
        public void onCommandComplete(int statementIndex, String tag) {
            deleted = !tag.equals("DELETE 0");
        }

        @Override
        protected void onSuccess() {
            if (deleted) exchange.respondNoContent();
            else new ExplainNoMatch(exchange, slug, commentId).submit();
        }
    }

    private static final class ExplainNoMatch extends WriteQuery {
        private final String slug;
        private final long commentId;

        ExplainNoMatch(Exchange exchange, String slug, long commentId) {
            super(exchange);
            this.slug = slug;
            this.commentId = commentId;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(COMMENT_EXISTS).text(slug).int8(commentId).execute();
            out.sync();
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            exchange.found = true;
        }

        @Override
        protected void onSuccess() {
            if (exchange.found) exchange.respondError(403, "only the author can delete this comment");
            else exchange.respondError(404, "comment not found");
        }
    }
}
