package conduit;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * Group commit. The lane takes every waiting write and sends them as one pipeline ending in a single Sync: Postgres
 * runs it as one implicit transaction with one WAL flush, and each response is released only after that commit.
 * Consecutive favorites, unfavorites, follows, unfollows or new comments run as one statement over arrays. If any
 * statement fails, the whole group rolls back and every write is retried in its own transaction (still one round
 * trip: one Sync per write), so one bad write can't fail the others. A group whose commit outcome is unknown
 * (connection lost) is never retried.
 */
final class WriteLane implements Runnable {
    private static final byte[] E500 = Http.error(500, "internal error");
    private static final byte[] E401 = Http.error(401, "unauthorized");
    private static final byte[] E403 = Http.error(403, "forbidden");
    private static final byte[] E404_ARTICLE = Http.error(404, "article not found");
    private static final byte[] E404_PROFILE = Http.error(404, "profile not found");
    private static final byte[] E404_COMMENT = Http.error(404, "comment not found");
    private static final byte[] E422_TAKEN = Http.error(422, "username or email is already taken");

    private final Lanes.Settings s;
    private Pg pg;

    WriteLane(Lanes.Settings s) {
        this.s = s;
    }

    /** A run of writes answered by the same statements: either one write, or a merged run of one kind. */
    private record Unit(int kind, List<Job> jobs) {}

    private static boolean mergeable(int kind) {
        return kind == Job.FAV || kind == Job.UNFAV || kind == Job.FOLLOW || kind == Job.UNFOLLOW || kind == Job.CREATE_COMMENT;
    }

    @Override
    public void run() {
        List<Job> jobs = new ArrayList<>();
        while (true) {
            jobs.clear();
            try {
                Lanes.WRITES.takeAny(s.writeMax(), Long.MAX_VALUE, jobs);
            } catch (InterruptedException e) {
                return;
            }
            List<Http.Resp> out = new ArrayList<>(jobs.size());
            List<Job> reads = new ArrayList<>();
            try {
                if (pg == null) pg = Lanes.connect(Sql.writes());
                group(jobs, out, reads);
            } catch (Throwable e) {
                System.err.println("write group failed: " + e);
                if (pg != null) pg.close();
                pg = null;
                out.clear();
                reads.clear();
                for (Job j : jobs) out.add(new Http.Resp(j.conn, E500));
            }
            Http.deliver(out);
            Lanes.READS.pushAll(reads);
        }
    }

    private void group(List<Job> jobs, List<Http.Resp> out, List<Job> reads) throws IOException {
        List<Unit> units = new ArrayList<>();
        for (Job j : jobs) {
            Unit last = units.isEmpty() ? null : units.get(units.size() - 1);
            if (last != null && last.kind == j.kind && mergeable(j.kind)) last.jobs.add(j);
            else {
                List<Job> l = new ArrayList<>(4);
                l.add(j);
                units.add(new Unit(j.kind, l));
            }
        }
        int total = 0;
        int[] count = new int[units.size()];
        for (int u = 0; u < units.size(); u++) {
            count[u] = bind(units.get(u));
            total += count[u];
        }
        List<Pg.Rows> res = pg.run();
        boolean ok = true;
        for (Pg.Rows r : res) ok &= !r.failed();
        if (ok) {
            int at = 0;
            for (int u = 0; u < units.size(); u++) {
                finish(units.get(u), res.get(at), out, reads);
                at += count[u];
            }
            return;
        }
        // rolled back: retry each write in its own transaction, all in one round trip
        int[] segs = new int[jobs.size()];
        List<Unit> singles = new ArrayList<>(jobs.size());
        for (int i = 0; i < jobs.size(); i++) {
            Job j = jobs.get(i);
            Unit u = new Unit(j.kind, List.of(j));
            singles.add(u);
            segs[i] = bind(u);
            pg.sync();
        }
        List<List<Pg.Rows>> rs = pg.runSegments(segs);
        for (int i = 0; i < singles.size(); i++) {
            Unit u = singles.get(i);
            Pg.Rows first = rs.get(i).isEmpty() ? null : rs.get(i).get(0);
            Pg.Rows failed = null;
            for (Pg.Rows r : rs.get(i)) if (r.failed() && !"skipped".equals(r.sqlstate)) failed = r;
            if (failed != null) {
                Job j = u.jobs.get(0);
                String st = failed.sqlstate;
                if (st.startsWith("23") || st.startsWith("22")) out.add(new Http.Resp(j.conn, st.equals("23505") ? E422_TAKEN
                        : Http.error(422, "invalid input")));
                else {
                    System.err.println("write failed: " + st + " " + failed.message);
                    out.add(new Http.Resp(j.conn, E500));
                }
            } else finish(u, first, out, reads);
        }
    }

    /** Binds a unit's statements; returns how many executes it added. */
    private int bind(Unit u) {
        Job j = u.jobs.get(0);
        switch (u.kind) {
            case Job.REGISTER -> pg.exec("register", Pg.text(j.f1), Pg.text(j.f2), Pg.text(j.hash));
            case Job.UPDATE_USER -> pg.exec("upduser", Pg.i64(j.viewer), Pg.text(j.f1), Pg.text(j.f2), Pg.text(j.hash),
                    Pg.text(j.f3), Pg.text(j.f4));
            case Job.FAV, Job.UNFAV, Job.FOLLOW, Job.UNFOLLOW -> {
                Pg.Arr ids = new Pg.Arr(Pg.INT8), keys = new Pg.Arr(Pg.TEXT);
                for (Job x : u.jobs) {
                    ids.i64(x.viewer);
                    keys.text(x.key);
                }
                String stmt = switch (u.kind) {
                    case Job.FAV -> "fav_n";
                    case Job.UNFAV -> "unfav_n";
                    case Job.FOLLOW -> "follow_n";
                    default -> "unfollow_n";
                };
                pg.exec(stmt, ids.done(), keys.done());
            }
            case Job.CREATE_COMMENT -> {
                Pg.Arr ids = new Pg.Arr(Pg.INT8), slugs = new Pg.Arr(Pg.TEXT), bodies = new Pg.Arr(Pg.TEXT);
                for (Job x : u.jobs) {
                    ids.i64(x.viewer);
                    slugs.text(x.key);
                    bodies.text(x.f1);
                }
                pg.exec("newcmt_n", ids.done(), slugs.done(), bodies.done());
            }
            case Job.CREATE_ARTICLE -> {
                pg.exec("newart", Pg.i64(j.viewer), Pg.text(j.f1), Pg.text(j.f2), Pg.text(j.f3));
                if (j.tags.length > 0) {
                    Pg.Arr t = new Pg.Arr(Pg.TEXT);
                    for (String x : j.tags) t.text(x);
                    byte[] arr = t.done();
                    pg.exec("newtags", arr);
                    pg.exec("arttags", arr);
                    return 3;
                }
            }
            case Job.UPDATE_ARTICLE -> pg.exec("updart", Pg.text(j.key), Pg.text(j.f1), Pg.text(j.f2), Pg.text(j.f3), Pg.i64(j.viewer));
            case Job.DELETE_ARTICLE -> pg.exec("delart", Pg.text(j.key), Pg.i64(j.viewer));
            case Job.DELETE_COMMENT -> pg.exec("delcmt", Pg.i64(j.id), Pg.text(j.key), Pg.i64(j.viewer));
            default -> throw new IllegalStateException("not a write: " + u.kind);
        }
        return 1;
    }

    /** Answers a committed unit from its first result. */
    private static void finish(Unit u, Pg.Rows r, List<Http.Resp> out, List<Job> reads) {
        switch (u.kind) {
            case Job.FAV, Job.UNFAV, Job.FOLLOW, Job.UNFOLLOW, Job.CREATE_COMMENT -> {
                int n = u.jobs.size();
                int[] row = new int[n];
                java.util.Arrays.fill(row, -1);
                for (int i = 0; i < r.nrows; i++) {
                    long k = r.i64(i, 0);
                    if (k >= 1 && k <= n) row[(int) k - 1] = i;
                }
                for (int i = 0; i < n; i++) {
                    Job j = u.jobs.get(i);
                    int x = row[i];
                    if (u.kind == Job.FAV || u.kind == Job.UNFAV) {
                        if (x < 0) out.add(new Http.Resp(j.conn, E404_ARTICLE));
                        else reads.add(articleRead(j, r.i64(x, 1), 200));
                    } else if (u.kind == Job.CREATE_COMMENT) {
                        if (x < 0) {
                            out.add(new Http.Resp(j.conn, E404_ARTICLE));
                            continue;
                        }
                        Buf b = new Buf(512);
                        b.ascii("{\"comment\":{\"id\":").num(r.i64(x, 1));
                        b.ascii(",\"createdAt\":").ts(r.i64(x, 3));
                        b.ascii(",\"updatedAt\":").ts(r.i64(x, 4));
                        b.ascii(",\"body\":");
                        r.json(b, x, 2);
                        b.ascii(",\"author\":{\"username\":");
                        r.json(b, x, 5);
                        b.ascii(",\"bio\":");
                        r.json(b, x, 6);
                        b.ascii(",\"image\":");
                        r.json(b, x, 7);
                        b.ascii(",\"following\":false}}}");
                        out.add(new Http.Resp(j.conn, Http.json(201, b)));
                    } else {
                        if (x < 0) {
                            out.add(new Http.Resp(j.conn, E404_PROFILE));
                            continue;
                        }
                        Buf b = new Buf(256);
                        b.ascii("{\"profile\":{\"username\":");
                        r.json(b, x, 1);
                        b.ascii(",\"bio\":");
                        r.json(b, x, 2);
                        b.ascii(",\"image\":");
                        r.json(b, x, 3);
                        b.ascii(",\"following\":").bool(u.kind == Job.FOLLOW).ascii("}}");
                        out.add(new Http.Resp(j.conn, Http.json(200, b)));
                    }
                }
            }
            default -> {
                Job j = u.jobs.get(0);
                boolean has = r != null && r.nrows > 0;
                switch (u.kind) {
                    case Job.REGISTER -> {
                        if (!has) out.add(new Http.Resp(j.conn, E422_TAKEN));
                        else out.add(new Http.Resp(j.conn, Http.json(201, user(r, Jwt.issue(r.i64(0, 0))))));
                    }
                    case Job.UPDATE_USER -> {
                        if (!has) out.add(new Http.Resp(j.conn, E401));
                        else out.add(new Http.Resp(j.conn, Http.json(200, user(r, j.token))));
                    }
                    case Job.CREATE_ARTICLE -> {
                        if (!has) out.add(new Http.Resp(j.conn, E500));
                        else reads.add(articleRead(j, r.i64(0, 0), 201));
                    }
                    case Job.UPDATE_ARTICLE -> {
                        if (!has) out.add(new Http.Resp(j.conn, E404_ARTICLE));
                        else if (r.i64(0, 1) != j.viewer) out.add(new Http.Resp(j.conn, E403));
                        else reads.add(articleRead(j, r.i64(0, 0), 200));
                    }
                    case Job.DELETE_ARTICLE, Job.DELETE_COMMENT -> {
                        if (!has) out.add(new Http.Resp(j.conn, u.kind == Job.DELETE_ARTICLE ? E404_ARTICLE : E404_COMMENT));
                        else if (r.i64(0, 0) != j.viewer) out.add(new Http.Resp(j.conn, E403));
                        else out.add(new Http.Resp(j.conn, Http.NO_CONTENT));
                    }
                    default -> out.add(new Http.Resp(j.conn, E500));
                }
            }
        }
    }

    /** [id, username, email, bio, image] -> {"user": ...} */
    private static Buf user(Pg.Rows r, String token) {
        Buf b = new Buf(512);
        b.ascii("{\"user\":{\"email\":");
        r.json(b, 0, 2);
        b.ascii(",\"token\":").str(token).ascii(",\"username\":");
        r.json(b, 0, 1);
        b.ascii(",\"bio\":");
        r.json(b, 0, 3);
        b.ascii(",\"image\":");
        r.json(b, 0, 4);
        b.ascii("}}");
        return b;
    }

    /** After the commit, the article is read through the read lanes, in a new snapshot. */
    private static Job articleRead(Job w, long id, int status) {
        Job j = new Job(Job.ARTICLE_ID, w.conn, w.viewer);
        j.id = id;
        j.status = status;
        return j;
    }
}
