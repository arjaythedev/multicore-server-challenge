package conduit.writes;

import conduit.db.PgPool;
import java.lang.invoke.MethodHandles;

/** Wiring for the write endpoints. */
public final class Writes {
    private Writes() {
    }

    /**
     * Initializes the write endpoint classes, which defines their statements. Must run before the connections open:
     * each connection prepares every statement defined at that point.
     */
    public static void defineStatements() throws IllegalAccessException {
        MethodHandles.Lookup lookup = MethodHandles.lookup();
        lookup.ensureInitialized(UserWrites.class);
        lookup.ensureInitialized(ProfileWrites.class);
        lookup.ensureInitialized(ArticleWrites.class);
        lookup.ensureInitialized(CommentWrites.class);
    }

    /** The connections that writes and logins run on. */
    public static void start(PgPool writeConnections) {
        WriteQuery.usePool(writeConnections);
    }
}
