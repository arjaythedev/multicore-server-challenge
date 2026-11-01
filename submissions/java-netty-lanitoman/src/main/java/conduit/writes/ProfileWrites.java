package conduit.writes;

import conduit.Exchange;
import conduit.db.MessageWriter;
import conduit.db.Row;
import conduit.db.Statement;
import conduit.json.Render;

/** POST and DELETE /api/profiles/:username/follow: the lookup and the change in one statement. */
public final class ProfileWrites {
    private static final Statement FOLLOW = Statement.define(
            "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),"
                    + " i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING)"
                    + " SELECT username, bio, image FROM u",
            Statement.INT8, Statement.TEXT);

    private static final Statement UNFOLLOW = Statement.define(
            "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),"
                    + " d AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u))"
                    + " SELECT username, bio, image FROM u",
            Statement.INT8, Statement.TEXT);

    private ProfileWrites() {
    }

    public static void follow(Exchange exchange, String username, boolean follow) {
        new FollowQuery(exchange, username, follow).submit();
    }

    private static final class FollowQuery extends WriteQuery {
        private final String username;
        private final boolean follow;

        FollowQuery(Exchange exchange, String username, boolean follow) {
            super(exchange);
            this.username = username;
            this.follow = follow;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(follow ? FOLLOW : UNFOLLOW).int8(exchange.viewer).text(username).execute();
            out.sync();
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            exchange.found = true;
            Render.profileResponse(exchange.json(), row, 0, follow);
        }

        @Override
        protected void onSuccess() {
            if (exchange.found) exchange.respond(200);
            else exchange.respondError(404, "profile not found");
        }
    }
}
