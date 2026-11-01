package conduit.pg;

import java.io.IOException;

/**
 * A fixed set of pipelined connections. Each query goes to the live connection with the fewest queries in flight.
 * A background thread replaces connections that died.
 */
public final class PgPool {
    private final PgConfig cfg;
    private final String name;
    private volatile PgConn[] conns;

    /** Opens size connections, retrying for up to waitMs while Postgres isn't accepting them yet. */
    public PgPool(PgConfig cfg, String name, int size, long waitMs) throws IOException, InterruptedException {
        this.cfg = cfg;
        this.name = name;
        PgConn[] cs = new PgConn[size];
        long deadline = System.currentTimeMillis() + waitMs;
        for (int i = 0; i < size; i++) {
            while (true) {
                try {
                    cs[i] = PgConn.open(cfg, name + i);
                    break;
                } catch (IOException e) {
                    if (System.currentTimeMillis() > deadline || e.getMessage() != null && e.getMessage().startsWith("prepare failed")) throw e;
                    System.err.println(name + ": waiting for Postgres: " + e.getMessage());
                    Thread.sleep(500);
                }
            }
        }
        conns = cs;
        Thread t = new Thread(this::maintain, name + "-maint");
        t.setDaemon(true);
        t.start();
    }

    public void submit(Query q) {
        PgConn best = null;
        int bestLoad = Integer.MAX_VALUE;
        for (PgConn c : conns) {
            if (c.dead) continue;
            int l = c.load.get();
            if (l < bestLoad) {
                best = c;
                bestLoad = l;
                if (l == 0) break;
            }
        }
        if (best == null) {
            q.fail("08006", "no database connection");
            q.complete();
            return;
        }
        best.submit(q);
    }

    private void maintain() {
        while (true) {
            try {
                Thread.sleep(1000);
                PgConn[] cs = conns;
                for (int i = 0; i < cs.length; i++) {
                    if (!cs[i].dead) continue;
                    try {
                        PgConn fresh = PgConn.open(cfg, name + i);
                        PgConn[] next = conns.clone();
                        next[i] = fresh;
                        conns = next;
                        System.err.println(name + i + ": reconnected");
                    } catch (IOException e) {
                        System.err.println(name + i + ": reconnect failed: " + e.getMessage());
                    }
                }
            } catch (InterruptedException e) {
                return;
            } catch (Throwable e) {
                e.printStackTrace();
            }
        }
    }
}
