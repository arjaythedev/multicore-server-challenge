package conduit;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** The shared queues and the threads that drain them: read lanes, the write lane, bcrypt workers. */
final class Lanes {
    static final JobQueue READS = new JobQueue(), WRITES = new JobQueue(), BCRYPT = new JobQueue();

    record Settings(Pg.Config cfg, int readMin, long readWindowNanos, int readMax, int writeMax) {}

    private static Settings settings;

    /**
     * Session settings on our own connections (nothing server-wide). Generic plans: with the default plan cache mode
     * the array-parameter statements are re-planned on every execution. A generic plan can't see LIMIT values or
     * array sizes, so its cost estimate would cross jit_above_cost and invite parallel workers: both off.
     */
    private static final Map<String, String> SESSION = Map.of(
            "plan_cache_mode", "force_generic_plan",
            "jit", "off",
            "max_parallel_workers_per_gather", "0");

    static Pg connect(List<Sql.Stmt> stmts) throws IOException {
        Pg pg = new Pg(settings.cfg(), SESSION);
        try {
            pg.prepare(stmts);
        } catch (IOException e) {
            pg.close();
            throw e;
        }
        return pg;
    }

    static void start(Settings s, int readLanes, int writeLanes, int bcryptThreads, int bcryptLanes, long bcryptWindowNanos)
            throws IOException {
        settings = s;
        // fail fast if the database or a statement is wrong
        connect(Sql.reads()).close();
        connect(Sql.writes()).close();
        List<Thread> ts = new ArrayList<>();
        for (int i = 0; i < readLanes; i++) ts.add(new Thread(new ReadLane(s), "read-" + i));
        for (int i = 0; i < writeLanes; i++) ts.add(new Thread(new WriteLane(s), "write-" + i));
        if (bcryptLanes > 0) Hasher.lanes = Math.min(bcryptLanes, BCryptLanes.MAX);
        else {
            Thread m = new Thread(() -> {
                Hasher.lanes = Hasher.measure();
                System.out.println("bcrypt: " + Hasher.lanes + " lanes");
            }, "bcrypt-measure");
            m.setDaemon(true);
            m.start();
        }
        for (int i = 0; i < bcryptThreads; i++) ts.add(new Thread(new Hasher(bcryptWindowNanos), "bcrypt-" + i));
        for (Thread t : ts) t.start();
    }

    /**
     * bcrypt workers: verify logins (answering them) and hash new passwords (then queueing their write). Workers take
     * turns gathering: one waits up to the window for a full set of lanes while the others hash theirs, so under a
     * backlog every set is full, and a trickle of logins still shares sets. Hash threads run at a lower OS priority
     * (with -XX:ThreadPriorityPolicy=1), so hashing gives way to Postgres and the event loops.
     */
    static final class Hasher implements Runnable {
        private static final byte[] E401 = Http.error(401, "invalid email or password");
        private static final java.util.concurrent.locks.ReentrantLock TURN = new java.util.concurrent.locks.ReentrantLock();
        static volatile int lanes = 3;
        private final long windowNanos;

        Hasher(long windowNanos) {
            this.windowNanos = windowNanos;
        }

        /** Times every width on throwaway keys at a low cost and keeps the fastest per hash. */
        static int measure() {
            byte[] pw = "throwaway-password".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
            double best = Double.MAX_VALUE;
            int bestK = 1;
            for (int k = 1; k <= BCryptLanes.MAX; k++) {
                byte[][] pws = new byte[k][];
                BCrypt.Setting[] st = new BCrypt.Setting[k];
                for (int i = 0; i < k; i++) {
                    pws[i] = pw;
                    st[i] = new BCrypt.Setting("$2a$06$", 6, BCrypt.newSetting().salt());
                }
                BCrypt.Setting[] warm = new BCrypt.Setting[k];
                for (int i = 0; i < k; i++) warm[i] = new BCrypt.Setting("$2a$04$", 4, st[i].salt());
                for (int w = 0; w < 40; w++) BCrypt.hashLanes(pws, warm); // let the JIT compile this width
                long t = System.nanoTime();
                for (int r = 0; r < 4; r++) BCrypt.hashLanes(pws, st);
                double per = (System.nanoTime() - t) / 4.0 / k;
                if (per < best * 0.97) {
                    best = per;
                    bestK = k;
                }
            }
            return bestK;
        }

        @Override
        public void run() {
            Thread.currentThread().setPriority(Thread.MIN_PRIORITY);
            List<Job> jobs = new ArrayList<>(BCryptLanes.MAX);
            while (true) {
                jobs.clear();
                int k = lanes;
                TURN.lock();
                try {
                    BCRYPT.take(k, windowNanos, k, jobs);
                } catch (InterruptedException e) {
                    return;
                } finally {
                    TURN.unlock();
                }
                jobs.removeIf(j -> j.conn.closed);
                try {
                    run(jobs);
                } catch (Throwable t) {
                    t.printStackTrace();
                    for (Job j : jobs) j.conn.reply(Http.error(500, "internal error"));
                }
            }
        }

        private static void run(List<Job> jobs) {
            // one set per cost (new hashes are cost 10; a stored hash of another cost runs with its own kind)
            List<Job> set = new ArrayList<>(jobs.size());
            List<BCrypt.Setting> st = new ArrayList<>(jobs.size());
            for (Job j : jobs) {
                BCrypt.Setting x = j.kind == Job.HASH ? BCrypt.newSetting() : BCrypt.parse(j.hash);
                if (x == null) {
                    j.conn.reply(E401);
                    continue;
                }
                if (!st.isEmpty() && st.get(0).cost() != x.cost()) {
                    finish(set, st);
                    set.clear();
                    st.clear();
                }
                set.add(j);
                st.add(x);
            }
            finish(set, st);
        }

        private static void finish(List<Job> set, List<BCrypt.Setting> st) {
            if (set.isEmpty()) return;
            byte[][] pws = new byte[set.size()][];
            for (int i = 0; i < pws.length; i++) pws[i] = set.get(i).password;
            String[] h = BCrypt.hashLanes(pws, st.toArray(new BCrypt.Setting[0]));
            for (int i = 0; i < pws.length; i++) {
                Job j = set.get(i);
                if (j.kind == Job.HASH) {
                    j.then.hash = h[i];
                    WRITES.push(j.then);
                } else if (BCrypt.same(h[i], j.hash)) {
                    Buf b = new Buf(512);
                    b.ascii("{\"user\":{\"email\":").str(j.email).ascii(",\"token\":").str(Jwt.issue(j.id))
                            .ascii(",\"username\":").str(j.uname).ascii(",\"bio\":").str(j.bio)
                            .ascii(",\"image\":").str(j.image).ascii("}}");
                    j.conn.reply(Http.json(200, b));
                } else j.conn.reply(E401);
            }
        }
    }
}
