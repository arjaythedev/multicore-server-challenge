package challenge.tools;

import java.nio.charset.StandardCharsets;
import java.util.concurrent.LinkedBlockingQueue;

import challenge.pg.Completions;
import challenge.pg.PgDispatcher;
import challenge.pg.Query;
import challenge.pg.Stmt;
import challenge.pg.Unit;

public final class PgSmoke {
    public static void main(String[] args) throws Exception {
        String url = System.getenv("DATABASE_URL");
        if (url == null) {
            throw new IllegalArgumentException("DATABASE_URL is required");
        }
        LinkedBlockingQueue<Unit> completed = new LinkedBlockingQueue<>();
        Completions owner = completed::add;
        try (PgDispatcher dispatcher = new PgDispatcher(url)) {
            Unit first = null;
            for (int i = 0; i < 1000; i++) {
                Unit unit = new Unit(owner, u -> {}, false, false,
                        new Query(Stmt.TAGS, false));
                if (i == 0) {
                    first = unit;
                }
                dispatcher.submit(unit);
            }
            int count = 0;
            while (count < 1000) {
                Unit u = completed.take();
                u.callback.done(u);
                if (u.errorMessage != null) {
                    throw new IllegalStateException(u.sqlState + ": " + u.errorMessage);
                }
                count++;
                if (u == first) {
                    Query q = u.queries[0];
                    for (int row = 0; row < q.rowCount(); row++) {
                        System.out.println(new String(q.bytes(), q.offset(row, 0), q.length(row, 0),
                                StandardCharsets.UTF_8));
                    }
                }
            }
            System.out.println("completed: " + count);
        }
    }
}
