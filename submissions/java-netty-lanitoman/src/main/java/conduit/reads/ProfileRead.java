package conduit.reads;

import conduit.ArticleSql;
import conduit.Exchange;
import conduit.db.Row;
import conduit.json.Render;

/** GET /api/profiles/:username. Columns: i, username, bio, image, following. */
final class ProfileRead extends PerRequestRead {
    private static final String SQL = "SELECT r.i, u.username, u.bio, u.image, "
            + ArticleSql.following("r.viewer", "u.id")
            + " FROM " + REQUESTS
            + " CROSS JOIN LATERAL (SELECT * FROM users u WHERE u.username = r.key OFFSET 0) u";

    ProfileRead(int maxBatch) {
        super("profile", SQL, maxBatch);
    }

    @Override
    protected void onRow(Exchange exchange, Row row) {
        exchange.found = true;
        Render.profileResponse(exchange.json(), row, 1, row.getBoolean(4));
    }

    @Override
    protected void finish(Exchange exchange) {
        if (exchange.found) exchange.respond(200);
        else exchange.respondError(404, "profile not found");
    }
}
