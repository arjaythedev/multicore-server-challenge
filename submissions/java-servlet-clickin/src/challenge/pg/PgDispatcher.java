package challenge.pg;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.net.InetAddress;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

import challenge.Sys;
import challenge.pg.PgConn.Config;
import challenge.pg.Stmt.Statement;

/** One platform thread owns every database socket. */
public final class PgDispatcher implements AutoCloseable {
    private final UnitQueue submitted = new UnitQueue();
    private final AtomicBoolean sleeping = new AtomicBoolean();
    // while sleeping: the dispatcher wakes by itself no later than this (nanoTime), so a read whose window ends at or
    // after it needs no eventfd wake. Long.MIN_VALUE when every read connection is busy (a completion wakes it, and
    // no read could go out before), Long.MAX_VALUE when no read waits (the next one must start its window). With
    // 40-120 ms windows almost every read used to wake the dispatcher only to be queued.
    private volatile long wakesBy;
    private final AtomicInteger publishers = new AtomicInteger();
    private final Sys sys = new Sys();
    private final int epoll;
    private final int wake;
    private final PgConn[] reads;
    private final PgConn[] writes;
    private final PgConn[] all;
    private final int writeGroupMax;
    private final int readRoundMax;
    private final int gatherUs;
    /** Gather window per read lane (feed, comments, the rest), microseconds. */
    private final long[] laneGatherNs = new long[LANES];
    private final boolean coalesce;
    // waiting reads, one FIFO per lane (in submission order, so each queue is in queuedAt order), and waiting writes:
    // a wakeup reads each lane's head and size instead of scanning one mixed queue several times (that scan grew
    // with load times wakeups)
    private final ArrayDeque<Unit>[] laneQueues = newLaneQueues();
    private final ArrayDeque<Unit> writeQueue = new ArrayDeque<>();
    private final Thread thread;
    private volatile boolean closed;

    public PgDispatcher(String url) throws Exception {
        int nr = env("READ_CONNS", 8);
        // one write connection: its group commit then gathers every write that arrives during a WAL flush, so
        // there are fewer fsyncs per write (Hetzner, 80k users: about -1.5% box CPU and a lower p99 than 4)
        int nw = env("WRITE_CONNS", 1);
        writeGroupMax = env("WRITE_GROUP_MAX", 256);
        readRoundMax = env("READ_ROUND_MAX", 4096);
        // Hetzner 150k: 20 ms gathers cut Postgres CPU 52 -> 44% of the box (box 97.9 -> 90.6%), p95 498 -> 254 ms. At
        // 140k, 40 ms against 30: Postgres 85.9 -> 81.5 us/req, app +1, p95 ~115 -> ~150 ms (two runs each)
        gatherUs = env("READ_GATHER_US", 40000);
        // Feeds and comments gather on their own clocks: their batches are the costliest per request and share the
        // most within a batch, so they can wait longer than the cheap lookups that make up most reads. Hetzner 140k
        // (with tag ids, two runs each): 120 ms gave app + Postgres 136.1 us/req at p95 182 ms, against 151.1 at 144 ms
        // for 40 ms everywhere without tag ids (an earlier box of the same type);
        // 160 ms gave 136.6 at p95 232 ms.
        laneGatherNs[FEED_LANE] = 1000L * env("READ_GATHER_FEED_US", 120000);
        laneGatherNs[COMMENTS_LANE] = 1000L * env("READ_GATHER_COMMENTS_US", 120000);
        laneGatherNs[REST_LANE] = 1000L * gatherUs;
        coalesce = env("COALESCE", 1) != 0;
        if (readRoundMax < 1 || gatherUs < 0 || laneGatherNs[FEED_LANE] < 0 || laneGatherNs[COMMENTS_LANE] < 0) {
            throw new IllegalArgumentException("invalid read round configuration");
        }
        if (writeGroupMax < 1) {
            throw new IllegalArgumentException("WRITE_GROUP_MAX must be positive");
        }
        if (nr < 1 || nw < 1 || (long) nr + nw > 95) {
            throw new IllegalArgumentException("READ_CONNS and WRITE_CONNS must be positive and total at most 95");
        }
        Config config = Config.parse(url);
        InetAddress address = InetAddress.getByName(config.host());
        List<Statement> statements = Stmt.freeze();
        epoll = sys.epollCreate();
        wake = sys.eventfd();
        if (sys.epollCtl(epoll, Sys.EPOLL_CTL_ADD, wake, Sys.EPOLLIN, -1) != 0) {
            throw new IllegalStateException("eventfd epoll registration failed");
        }
        reads = new PgConn[nr];
        writes = new PgConn[nw];
        all = new PgConn[nr + nw];
        for (int i = 0; i < all.length; i++) {
            PgConn conn = new PgConn(sys, epoll, i, config, address, statements);
            all[i] = conn;
            if (i < nr) {
                if (coalesce) {
                    conn.initReads(readRoundMax);
                }
                reads[i] = conn;
            } else {
                conn.initGroups(writeGroupMax);
                writes[i - nr] = conn;
            }
        }
        thread = new Thread(this::run, "postgres-dispatcher");
        thread.start();
    }

    static final int FEED_LANE = 0;
    static final int COMMENTS_LANE = 1;
    static final int REST_LANE = 2;
    static final int LANES = 3;

    @SuppressWarnings("unchecked")
    private static ArrayDeque<Unit>[] newLaneQueues() {
        ArrayDeque<Unit>[] q = new ArrayDeque[LANES];
        for (int l = 0; l < LANES; l++) {
            q[l] = new ArrayDeque<>();
        }
        return q;
    }

    private boolean readsWaiting() {
        for (ArrayDeque<Unit> q : laneQueues) {
            if (!q.isEmpty()) {
                return true;
            }
        }
        return false;
    }

    /** The lane a read unit gathers in. */
    static int lane(Unit u) {
        int k = PgConn.kind(u);
        return k == PgConn.FEED_KIND ? FEED_LANE : k == PgConn.COMMENTS_KIND ? COMMENTS_LANE : REST_LANE;
    }

    private static int env(String key, int defaultValue) {
        return Integer.parseInt(System.getenv().getOrDefault(key, Integer.toString(defaultValue)));
    }

    public void submit(Unit unit) {
        publishers.incrementAndGet();
        try {
            if (closed) {
                throw new IllegalStateException("dispatcher closed");
            }
            if (unit.queries.length == 0) {
                throw new IllegalArgumentException("empty unit");
            }
            long now = System.nanoTime();
            unit.queuedAt = now;
            submitted.offer(unit);
            if (sleeping.get() && (unit.write || unit.tx || now + laneGatherNs[lane(unit)] < wakesBy) && sleeping.compareAndSet(true, false)) {
                Sys.wake(wake);
            }
        } finally {
            publishers.decrementAndGet();
        }
    }

    private void drain() {
        Unit unit;
        while ((unit = submitted.poll()) != null) {
            (unit.write ? writeQueue : laneQueues[lane(unit)]).add(unit);
        }
    }

    // spread(): the round's reads bucketed by kind (last bucket: units that are a statement of their own)
    private Unit[][] buckets;
    private final int[] bucketCounts = new int[PgConn.KINDS + 1];
    private final long[] loads = new long[96];
    private final PgConn[] idle = new PgConn[96];
    // Hetzner 130k: 8 (with 30 ms gathers) cut p95 210 -> 113 ms at the same CPU per request, but at the 150k knee runs
    // went bimodal, plausibly eight backends crowding the HTTP loops on a saturated box. 3 keeps the latency (locally
    // p95 42 vs 41 ms with 8, 56 serial) with fewer backends at once (Postgres exec time 28 s vs 37 s with 8, 26 serial).
    private final int spreadMax = env("READ_SPREAD", 3);

    /**
     * Takes the round's reads (in queue order, up to a tx read, at most
     * READ_ROUND_MAX) and spreads them over the idle read connections from
     * reads[from] on, one kind's batch whole on one connection, heaviest kinds
     * first onto the least loaded connection. A round's statements run one
     * after another on a backend and every unit waits for the round's Sync, so
     * one connection per kind cuts a round to its slowest statement (locally 21
     * -> ~9 ms at 20 ms gathers, with 7 of 8 read connections idle before).
     */
    private void spread(int from, int lane) {
        if (buckets == null) {
            buckets = new Unit[PgConn.KINDS + 1][readRoundMax];
        }
        int n = 0;
        for (int c = from;
             c < reads.length && n < spreadMax;
             c++) {
            if (reads[c].idle()) {
                idle[n] = reads[c];
                loads[n++] = 0;
            }
        }
        Arrays.fill(bucketCounts, 0);
        int taken = 0;
        ArrayDeque<Unit> queue = laneQueues[lane];
        // in queue order, up to (not including) a tx read
        while (taken < readRoundMax && !queue.isEmpty() && !queue.peekFirst().tx) {
            Unit u = queue.removeFirst();
            int k = PgConn.kind(u);
            int b = k < 0 ? PgConn.KINDS : k;
            buckets[b][bucketCounts[b]++] = u;
            taken++;
        }
        for (; ; ) {
            int heaviest = -1;
            long heaviestCost = -1;
            for (int b = 0; b <= PgConn.KINDS; b++) {
                if (bucketCounts[b] == 0) {
                    continue;
                }
                // a batch statement costs ~0.3 ms beyond its rows
                long cost = 300 + (long) bucketCounts[b] * PgConn.cost(b == PgConn.KINDS ? -1 : b);
                if (cost > heaviestCost) {
                    heaviest = b;
                    heaviestCost = cost;
                }
            }
            if (heaviest < 0) {
                break;
            }
            int target = 0;
            for (int i = 1; i < n; i++) {
                if (loads[i] < loads[target]) {
                    target = i;
                }
            }
            loads[target] += heaviestCost;
            PgConn conn = idle[target];
            Unit[] bucket = buckets[heaviest];
            for (int i = 0, end = bucketCounts[heaviest];
                 i < end;
                 i++) {
                Unit u = bucket[i];
                bucket[i] = null;
                try {
                    conn.addToGroup(u);
                } catch (RuntimeException e) {
                    u.sqlState = "XX000";
                    u.errorMessage = e.toString();
                    u.owner.post(u);
                }
            }
            bucketCounts[heaviest] = 0;
        }
        for (int i = 0; i < n; i++) {
            if (idle[i].groupSize() != 0) {
                idle[i].sendReadRound();
            }
        }
    }

    // dueLane(): per lane, the oldest waiting read and how many reads wait
    private final Unit[] laneFirst = new Unit[LANES];
    private final int[] laneCount = new int[LANES];

    private void scanLanes() {
        for (int l = 0; l < LANES; l++) {
            laneFirst[l] = laneQueues[l].peekFirst();
            laneCount[l] = laneQueues[l].size();
        }
    }

    /** The lane whose round is due (window elapsed or round full), the one waiting longest; -1 if none. */
    private int dueLane(long now) {
        scanLanes();
        int best = -1;
        for (int l = 0; l < LANES; l++) {
            Unit f = laneFirst[l];
            if (f != null && (laneCount[l] >= readRoundMax || now - f.queuedAt >= laneGatherNs[l])
                    && (best < 0 || f.queuedAt < laneFirst[best].queuedAt)) {
                best = l;
            }
        }
        return best;
    }

    /** Nanoseconds until the next lane's window elapses (0 if one already has), or -1 if no read waits. */
    private long untilDue(long now) {
        scanLanes();
        long min = -1;
        for (int l = 0; l < LANES; l++) {
            Unit f = laneFirst[l];
            if (f != null) {
                long left = laneCount[l] >= readRoundMax ? 0 : Math.max(0, laneGatherNs[l] - (now - f.queuedAt));
                min = min < 0 ? left : Math.min(min, left);
            }
        }
        return min;
    }

    private void plan() {
        if (coalesce) {
            for (int c = 0; c < reads.length; c++) {
                PgConn conn = reads[c];
                if (!conn.idle()) {
                    continue;
                }
                int lane = dueLane(System.nanoTime());
                if (lane < 0) {
                    break;
                }
                Unit first = laneFirst[lane];
                if (first.tx) {
                    laneQueues[lane].removeFirst();
                    try {
                        conn.submit(first);
                    } catch (RuntimeException e) {
                        first.sqlState = "XX000";
                        first.errorMessage = e.toString();
                        first.owner.post(first);
                    }
                    continue;
                }
                spread(c, lane);
            }
        } else {
            for (ArrayDeque<Unit> queue : laneQueues) {
                int count = queue.size();
                while (count-- > 0) {
                    Unit unit = queue.remove();
                    PgConn best = null;
                    for (PgConn conn : reads) {
                        if (conn.canAccept()
                                && (!unit.tx || conn.idle())
                                && (best == null || conn.inFlight() < best.inFlight())) {
                            best = conn;
                        }
                    }
                    if (best == null) {
                        queue.add(unit);
                        continue;
                    }
                    try {
                        best.submit(unit);
                    } catch (RuntimeException e) {
                        unit.sqlState = "XX000";
                        unit.errorMessage = e.toString();
                        unit.owner.post(unit);
                    }
                }
            }
        }
        for (PgConn conn : writes) {
            if (!conn.idle()) {
                continue;
            }
            while (!writeQueue.isEmpty() && conn.groupSize() < writeGroupMax) {
                Unit unit = writeQueue.remove();
                try {
                    conn.addToGroup(unit);
                } catch (RuntimeException e) {
                    unit.sqlState = "XX000";
                    unit.errorMessage = e.toString();
                    unit.owner.post(unit);
                }
            }
            if (conn.groupSize() != 0) {
                conn.sendGroup();
            }
        }
    }

    private void run() {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment events = arena.allocate((long) Sys.EVENT_SIZE * (all.length + 1), 8);
            MemorySegment io = arena.allocate(65536, 8);
            while (!closed) {
                drain();
                plan();
                for (PgConn conn : all) {
                    conn.ensureConnected();
                    conn.flush(io);
                }
                int timeout = 1000;
                long by = Long.MAX_VALUE;
                if (coalesce) {
                    boolean free = false;
                    for (PgConn conn : reads) {
                        if (conn.idle()) {
                            free = true;
                            break;
                        }
                    }
                    if (!free) {
                        by = Long.MIN_VALUE;
                    } else if (readsWaiting()) {
                        long now = System.nanoTime();
                        long left = untilDue(now);
                        if (left >= 0) {
                            timeout = (int) Math.min(1000, (left + 999_999) / 1_000_000);
                            by = now + left;
                        }
                    }
                }
                wakesBy = by;
                sleeping.set(true);
                if (submitted.hasPending() || closed) {
                    sleeping.set(false);
                    continue;
                }
                int n = sys.epollWait(epoll, events, all.length + 1, timeout);
                sleeping.set(false);
                if (n < 0) {
                    if (sys.errno() == Sys.EINTR) {
                        continue;
                    }
                    throw new IllegalStateException("epoll wait errno " + sys.errno());
                }
                for (int i = 0; i < n; i++) {
                    int tag = Sys.eventTag(events, i);
                    if (tag == -1) {
                        // one read takes the whole eventfd counter
                        sys.read(wake, io, 8);
                    } else {
                        all[tag].event(Sys.eventFlags(events, i), io);
                    }
                }
            }
        } finally {
            closed = true;
            while (publishers.get() != 0) {
                Thread.onSpinWait();
            }
            for (PgConn conn : all) {
                conn.fail("dispatcher stopped");
            }
            drain();
            for (ArrayDeque<Unit> queue : laneQueues) {
                stop(queue);
            }
            stop(writeQueue);
            Sys.close(wake);
            Sys.close(epoll);
        }
    }

    private static void stop(ArrayDeque<Unit> queue) {
        for (Unit u : queue) {
            u.sqlState = "08006";
            u.errorMessage = "dispatcher stopped";
            u.owner.post(u);
        }
    }

    @Override
    public void close() {
        closed = true;
        if (sleeping.compareAndSet(true, false)) {
            Sys.wake(wake);
        }
    }
}
