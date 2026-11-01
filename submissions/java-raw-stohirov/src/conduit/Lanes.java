package conduit;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** The shared queues and the threads that drain them: read lanes, the write lane, bcrypt workers. */
final class Lanes {
    static final JobQueue READS = new JobQueue(), WRITES = new JobQueue(), BCRYPT = new JobQueue();

    record Settings(Pg.Config cfg, int readMin, long readWindowNanos, int readMax, int writeMax, long writeWindowNanos,
                    boolean feedConn) {}

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
                try {
                    Hasher.measure();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
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
     * backlog every set is full, and a trickle of logins still shares sets.
     */
    static final class Hasher implements Runnable {
        private static final byte[] E401 = Http.error(401, "invalid email or password");
        private static final java.util.concurrent.locks.ReentrantLock TURN = new java.util.concurrent.locks.ReentrantLock();
        static volatile int lanes = 3;
        private final long windowNanos;

        Hasher(long windowNanos) {
            this.windowNanos = windowNanos;
        }

        /** Times one width of one kernel: hashes at a low cost on throwaway keys, per hash, cost 10 equivalent, in ms. */
        private static double timeOnce(int style, int k, int cost) {
            byte[] pw = "throwaway-password".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
            byte[][] pws = new byte[k][];
            BCrypt.Setting[] st = new BCrypt.Setting[k];
            for (int i = 0; i < k; i++) {
                pws[i] = pw;
                st[i] = new BCrypt.Setting(String.format("$2a$%02d$", cost), cost, BCrypt.newSetting().salt());
            }
            long t = System.nanoTime();
            BCrypt.hashLanes(pws, st, style);
            return (System.nanoTime() - t) / 1e6 / k * (1L << (10 - cost));
        }

        /** The median of one run per CPU, all at once: wider sets lose once hyperthreads share an L1, as under load. */
        private static double timeBusy(int style, int k, int cost, int threads) throws InterruptedException {
            double[] res = new double[threads];
            java.util.concurrent.CountDownLatch go = new java.util.concurrent.CountDownLatch(threads);
            Thread[] ts = new Thread[threads];
            for (int i = 0; i < threads; i++) {
                int id = i;
                ts[i] = new Thread(() -> {
                    go.countDown();
                    try {
                        go.await();
                    } catch (InterruptedException e) {
                        return;
                    }
                    res[id] = timeOnce(style, k, cost);
                });
                ts[i].setDaemon(true);
                ts[i].start();
            }
            for (Thread t : ts) t.join();
            java.util.Arrays.sort(res);
            return res[threads / 2];
        }

        /**
         * Picks the kernel and width. Native kernels are timed with every CPU busy, each combination's best of a few
         * runs. Without them, the Java kernels are timed alone in three passes, each width's fastest run counting: a
         * width isn't judged while the JIT is still compiling its kernel.
         */
        static void measure() throws InterruptedException {
            int cpus = Runtime.getRuntime().availableProcessors();
            StringBuilder log = new StringBuilder("bcrypt: ms per hash at cost 10:");
            double best = Double.MAX_VALUE;
            int bestStyle = BCrypt.JAVA, bestK = 1;
            if (BCryptNative.available()) {
                for (int style : BCryptNative.styles()) {
                    log.append(' ').append(BCryptNative.name(style)).append(':');
                    for (int k = 1; k <= BCryptLanes.MAX; k++) {
                        double t = Double.MAX_VALUE;
                        for (int r = 0; r < 3; r++) t = Math.min(t, timeBusy(style, k, 7, cpus));
                        log.append(String.format(" %d=%.1f", k, t));
                        if (t < best * 0.97) {
                            best = t;
                            bestStyle = style;
                            bestK = k;
                        }
                    }
                }
            } else {
                int max = BCryptLanes.MAX;
                double[] per = new double[max + 1];
                java.util.Arrays.fill(per, Double.MAX_VALUE);
                for (int pass = 0; pass < 3; pass++) {
                    for (int k = 1; k <= max; k++) {
                        if (pass == 0) for (int w = 0; w < 200; w++) timeOnce(BCrypt.JAVA, k, 4); // let the JIT compile it
                        for (int r = 0; r < 3; r++) per[k] = Math.min(per[k], timeOnce(BCrypt.JAVA, k, 7));
                    }
                }
                log.append(" java:");
                for (int k = 1; k <= max; k++) {
                    log.append(String.format(" %d=%.1f", k, per[k]));
                    if (per[k] < best * 0.97) {
                        best = per[k];
                        bestK = k;
                    }
                }
            }
            System.out.println(log);
            BCryptNative.style = bestStyle;
            lanes = bestK;
            System.out.println("bcrypt: " + BCryptNative.name(bestStyle) + " kernel, " + bestK + " lanes");
        }

        @Override
        public void run() {
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
