package conduit.reads;

import conduit.Exchange;
import conduit.db.Row;
import conduit.json.Render;

/** GET /api/user: the token's user, with the token it presented. Columns: i, id, username, email, bio, image. */
final class UserRead extends PerRequestRead {
    private static final String SQL = "SELECT r.i, u.id, u.username, u.email, u.bio, u.image"
            + " FROM " + REQUESTS
            + " CROSS JOIN LATERAL (SELECT * FROM users u WHERE u.id = r.viewer OFFSET 0) u";

    UserRead(int maxBatch) {
        super("user", SQL, maxBatch);
    }

    @Override
    protected void onRow(Exchange exchange, Row row) {
        exchange.found = true;
        Render.userResponse(exchange.json(), row, 1, exchange.token);
    }

    @Override
    protected void finish(Exchange exchange) {
        if (exchange.found) exchange.respond(200);
        else exchange.respondError(401, "unknown user");
    }
}
