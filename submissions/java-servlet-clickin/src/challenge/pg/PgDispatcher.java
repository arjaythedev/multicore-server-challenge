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
    private final boolean coalesce;
    private final ArrayDeque<Unit> waiting = new ArrayDeque<>();
    private final Thread thread;
    private volatile boolean closed;

    public PgDispatcher(String url) throws Exception {
        int nr = env("READ_CONNS", 8);
        // one write connection: its group commit then gathers every write that arrives during a WAL flush, so
        // there are fewer fsyncs per write (Hetzner, 80k users: about -1.5% box CPU and a lower p99 than 4)
        int nw = env("WRITE_CONNS", 1);
        writeGroupMax = env("WRITE_GROUP_MAX", 256);
        readRoundMax = env("READ_ROUND_MAX", 4096);
        // Hetzner 150k: 20 ms gathers cut Postgres CPU 52 -> 44% of the box (box 97.9 -> 90.6%), p95 498 -> 254 ms
        gatherUs = env("READ_GATHER_US", 20000);
        coalesce = env("COALESCE", 1) != 0;
        if (readRoundMax < 1 || gatherUs < 0) {
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
            submitted.offer(unit);
            if (sleeping.compareAndSet(true, false)) {
                Sys.wake(wake);
            }
        } finally {
            publishers.decrementAndGet();
        }
    }

    private void drain() {
        Unit unit;
        while ((unit = submitted.poll()) != null) {
            unit.queuedAt = System.nanoTime();
            waiting.add(unit);
        }
    }

    // spread(): the round's reads bucketed by kind (last bucket: units that are a statement of their own)
    private Unit[][] buckets;
    private final int[] bucketCounts = new int[PgConn.KINDS + 1];
    private final long[] loads = new long[96];
    private final PgConn[] idle = new PgConn[96];
    // 1 by default: on Hetzner 130k, 8 cut p95 210 -> 113 ms at the same CPU, but whether it holds at the knee is unsettled
    private final int spreadMax = env("READ_SPREAD", 1);

    /**
     * Takes the round's reads (in queue order, up to a tx read, at most
     * READ_ROUND_MAX) and spreads them over the idle read connections from
     * reads[from] on, one kind's batch whole on one connection, heaviest kinds
     * first onto the least loaded connection. A round's statements run one
     * after another on a backend and every unit waits for the round's Sync, so
     * one connection per kind cuts a round to its slowest statement (locally 21
     * -> ~9 ms at 20 ms gathers, with 7 of 8 read connections idle before).
     */
    private void spread(int from) {
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
        boolean blocked = false;
        int count = waiting.size();
        while (count-- > 0) {
            Unit u = waiting.remove();
            if (u.tx && !u.write) {
                blocked = true;
            }
            if (u.write || blocked || taken == readRoundMax) {
                waiting.add(u);
                continue;
            }
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

    private void plan() {
        int count = waiting.size();
        if (coalesce) {
            for (int c = 0; c < reads.length; c++) {
                PgConn conn = reads[c];
                if (!conn.idle()) {
                    continue;
                }
                Unit first = null;
                int readCount = 0;
                int queued = waiting.size();
                while (queued-- > 0) {
                    Unit u = waiting.remove();
                    if (!u.write) {
                        if (first == null) {
                            first = u;
                        }
                        readCount++;
                    }
                    waiting.add(u);
                }
                if (first == null || (readCount < readRoundMax && System.nanoTime() - first.queuedAt < (long) gatherUs * 1000)) {
                    continue;
                }
                if (first.tx) {
                    waiting.remove(first);
                    try {
                        conn.submit(first);
                    } catch (RuntimeException e) {
                        first.sqlState = "XX000";
                        first.errorMessage = e.toString();
                        first.owner.post(first);
                    }
                    continue;
                }
                spread(c);
                break;
            }
        } else {
            while (count-- > 0) {
                Unit unit = waiting.remove();
                PgConn best = null;
                if (unit.write) {
                    waiting.add(unit);
                    continue;
                }
                for (PgConn conn : reads) {
                    if (conn.canAccept()
                            && (!unit.tx || conn.idle())
                            && (best == null || conn.inFlight() < best.inFlight())) {
                        best = conn;
                    }
                }
                if (best == null) {
                    waiting.add(unit);
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
        for (PgConn conn : writes) {
            if (!conn.idle()) {
                continue;
            }
            count = waiting.size();
            while (count-- > 0 && conn.groupSize() < writeGroupMax) {
                Unit unit = waiting.remove();
                if (!unit.write) {
                    waiting.add(unit);
                    continue;
                }
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
                sleeping.set(true);
                if (submitted.hasPending() || closed) {
                    sleeping.set(false);
                    continue;
                }
                int timeout = 1000;
                if (coalesce && gatherUs > 0 && !waiting.isEmpty()) {
                    boolean free = false;
                    for (PgConn conn : reads) {
                        if (conn.idle()) {
                            free = true;
                            break;
                        }
                    }
                    if (free) {
                        int queued = waiting.size();
                        boolean found = false;
                        while (queued-- > 0) {
                            Unit u = waiting.remove();
                            if (!found && !u.write) {
                                long left = (long) gatherUs * 1000 - (System.nanoTime() - u.queuedAt);
                                timeout = (int) Math.min(1000, Math.max(0, (left + 999_999) / 1_000_000));
                                found = true;
                            }
                            waiting.add(u);
                        }
                    }
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
                        while (sys.read(wake, io, 8) > 0) {}
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
            for (Unit u : waiting) {
                u.sqlState = "08006";
                u.errorMessage = "dispatcher stopped";
                u.owner.post(u);
            }
            Sys.close(wake);
            Sys.close(epoll);
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
