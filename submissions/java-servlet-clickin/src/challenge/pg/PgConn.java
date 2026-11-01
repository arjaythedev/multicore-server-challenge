package challenge.pg;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.net.InetAddress;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import challenge.Sys;
import challenge.pg.Stmt.Statement;

/**
 * A connection is accessed only by the dispatcher thread. SCRAM follows the
 * MIT-licensed reference; see THIRD_PARTY_LICENSE.
 */
public final class PgConn {
    public record Config(String host, int port, String user,
                         String password, String database) {
        public static Config parse(String url) {
            URI uri = URI.create(url);
            if (!"postgres".equals(uri.getScheme()) && !"postgresql".equals(uri.getScheme())) {
                throw new IllegalArgumentException("invalid postgres URL");
            }
            String info = uri.getRawUserInfo();
            String user = System.getProperty("user.name");
            String password = "";
            if (info != null) {
                int colon = info.indexOf(':');
                user = decode(colon < 0 ? info : info.substring(0, colon));
                if (colon >= 0) {
                    password = decode(info.substring(colon + 1));
                }
            }
            String path = uri.getRawPath();
            return new Config(
                    uri.getHost() == null ? "localhost" : uri.getHost(),
                    uri.getPort() < 0 ? 5432 : uri.getPort(),
                    user,
                    password,
                    path == null || path.length() < 2
                            ? user
                            : decode(path.substring(1)));
        }

        private static String decode(String s) {
            return URLDecoder.decode(s.replace("+", "%2B"), StandardCharsets.UTF_8);
        }
    }

    private final Sys sys;
    private final int epoll;
    private final int tag;
    private final Config config;
    private final InetAddress address;
    private final List<Statement> statements;
    private final byte[][] statementNames;
    private static final byte[] BEGIN = "begin".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] COMMIT = "commit".getBytes(StandardCharsets.US_ASCII);
    private final ArrayDeque<Unit> pending = new ArrayDeque<>();
    private final Buffer out = new Buffer();
    private final Buffer in = new Buffer();
    private int sent;
    private int phase;
    private int queryIndex;
    private int fd = -1;
    private long lastAttempt;
    private Unit transaction;
    private Unit[] group;
    private int groupSize;
    private int groupIndex;
    private boolean retrying;
    private boolean readRound;
    private int[][] roundIndexes;
    private int[] roundCounts;
    private Query[] readBatches;

    /**
     * Reads that coalesce within a round: same-kind units share one batched
     * statement (TAGS shares one result).
     */
    enum Read {
        TAGS(Stmt.TAGS, -1, new int[] {}, new int[] {}),
        ARTICLE(Stmt.ARTICLE, Stmt.ARTICLE_BATCH, new int[] {1, 0},
                new int[] {Stmt.TEXT, Stmt.INT8}),
        COMMENTS(Stmt.COMMENTS, Stmt.COMMENTS_BATCH, new int[] {1, 0},
                new int[] {Stmt.TEXT, Stmt.INT8}),
        ARTICLES(Stmt.ARTICLES, Stmt.ARTICLES_BATCH, new int[] {1, 2, 0},
                new int[] {Stmt.INT4, Stmt.INT4, Stmt.INT8}),
        FEED(Stmt.FEED, Stmt.FEED_BATCH, new int[] {0, 1, 2},
                new int[] {Stmt.INT8, Stmt.INT4, Stmt.INT4}),
        PROFILE(Stmt.PROFILE, Stmt.PROFILE_BATCH, new int[] {1, 0},
                new int[] {Stmt.TEXT, Stmt.INT8}),
        ARTICLES_TAG(
                Stmt.ARTICLES_TAG,
                Stmt.ARTICLES_TAG_BATCH,
                new int[] {3, 1, 2, 0},
                new int[] {Stmt.TEXT, Stmt.INT4, Stmt.INT4, Stmt.INT8}),
        ARTICLES_AUTHOR(
                Stmt.ARTICLES_AUTHOR,
                Stmt.ARTICLES_AUTHOR_BATCH,
                new int[] {3, 1, 2, 0},
                new int[] {Stmt.TEXT, Stmt.INT4, Stmt.INT4, Stmt.INT8}),
        ARTICLES_FAVORITED(
                Stmt.ARTICLES_FAVORITED,
                Stmt.ARTICLES_FAVORITED_BATCH,
                new int[] {3, 1, 2, 0},
                new int[] {Stmt.TEXT, Stmt.INT4, Stmt.INT4, Stmt.INT8}),
        USER(Stmt.USER, Stmt.USER_BATCH, new int[] {0}, new int[] {Stmt.INT8});

        /**
         * single: per-unit statement; batch: coalesced statement or -1;
         * params/types: unit parameter order and batch array OIDs.
         */
        final int single;

        final int batch;

        final int[] params;
        final int[] types;

        Read(int single, int batch, int[] params,
             int[] types) {
            this.single = single;
            this.batch = batch;
            this.params = params;
            this.types = types;
        }
    }

    private static final Read[] READS = Read.values();
    private static final int SHARED = Read.TAGS.ordinal();

    /**
     * Statement id to Read ordinal + 1 (0: not coalesced), so kind() is a load
     * instead of a compare chain.
     */
    private static final byte[] KIND = new byte[Stmt.count()];

    static {
        for (Read r : READS) {
            KIND[r.single] = (byte) (r.ordinal() + 1);
        }
    }

    private Scram scram;
    private String error;
    private String state;
    private boolean failed;
    private boolean connected;
    private static final int SO_ERROR = 4;

    public PgConn(Sys sys, int epoll, int tag,
                  Config config, InetAddress address, List<Statement> statements) {
        this.sys = sys;
        this.epoll = epoll;
        this.tag = tag;
        this.config = config;
        this.address = address;
        this.statements = statements;
        statementNames = new byte[statements.size()][];
        for (int i = 0; i < statementNames.length; i++) {
            statementNames[i] = ("s" + i).getBytes(StandardCharsets.US_ASCII);
        }
    }

    public int inFlight() {
        return pending.size();
    }

    public boolean canAccept() {
        return transaction == null;
    }

    public boolean idle() {
        return pending.isEmpty() && groupSize == 0;
    }

    void initGroups(int max) {
        group = new Unit[max];
    }

    int groupSize() {
        return groupSize;
    }

    void initReads(int max) {
        initGroups(max);
        roundIndexes = new int[READS.length][max];
        roundCounts = new int[READS.length];
        readBatches = new Query[READS.length];
        for (Read r : READS) {
            if (r.batch >= 0) {
                Query q = readBatches[r.ordinal()] = new Query(r.batch, false);
                q.reserveBatch(max);
            }
        }
    }

    void sendReadRound() {
        readRound = true;
        Arrays.fill(roundCounts, 0);
        for (int i = 0; i < groupSize; i++) {
            int kind = kind(group[i]);
            if (kind >= 0) {
                roundIndexes[kind][roundCounts[kind]++] = i;
            }
        }
        if (phase == 3) {
            encodeReadRound();
        }
    }

    private int kind(Unit u) {
        if (u.tx || u.queries.length != 1) {
            return -1;
        }
        return KIND[u.queries[0].statementId] - 1;
    }

    private boolean skipped(int i) {
        int k = kind(group[i]);
        return k >= 0 && roundCounts[k] > 1 && roundIndexes[k][0] != i;
    }

    private void nextRead() {
        groupIndex++;
        while (groupIndex < groupSize && skipped(groupIndex)) {
            groupIndex++;
        }
        queryIndex = 0;
    }

    private void encodeReadRound() {
        for (int i = 0; i < groupSize; i++) {
            if (skipped(i)) {
                continue;
            }
            int k = kind(group[i]);
            if (k >= 0 && k != SHARED && roundCounts[k] > 1) {
                Query q = readBatches[k];
                q.batchParams(group, roundIndexes[k], roundCounts[k], READS[k].params, READS[k].types);
                bind(statementNames[q.statementId], q);
            } else {
                encodeGroupUnit(group[i]);
            }
        }
        sync();
    }

    private void readRow(byte[] data, int at, int end) {
        int k = kind(group[groupIndex]);
        if (k == SHARED && roundCounts[SHARED] > 1) {
            for (int i = 0; i < roundCounts[SHARED]; i++) {
                group[roundIndexes[SHARED][i]].queries[0].appendRow(data, at, end - at);
            }
        } else if (k >= 0 && roundCounts[k] > 1) {
            if (end - at < 10 || getInt(data, at + 2) != 4) {
                throw new IllegalStateException("invalid read row tag");
            }
            int index = getInt(data, at + 6) - 1;
            if (index < 0 || index >= roundCounts[k]) {
                throw new IllegalStateException("read row tag out of range");
            }
            group[roundIndexes[k][index]].queries[0].appendTaggedRow(data, at, end - at);
        } else {
            group[groupIndex].queries[queryIndex].appendRow(data, at, end - at);
        }
    }

    private void readReady(byte status) {
        if (status != 'I') {
            throw new IllegalStateException("read round did not return to idle");
        }
        if (failed) {
            for (int i = 0; i < groupSize; i++) {
                for (Query q : group[i].queries) {
                    q.clearResults();
                }
            }
            retrying = true;
            groupIndex = queryIndex = 0;
            failed = false;
            encodeGroupUnit(group[0]);
            sync();
        } else {
            if (groupIndex != groupSize) {
                throw new IllegalStateException("incomplete read round");
            }
            for (int i = 0; i < groupSize; i++) {
                Unit u = group[i];
                group[i] = null;
                u.owner.post(u);
            }
            groupSize = groupIndex = queryIndex = 0;
            readRound = false;
        }
    }

    private void validate(Unit unit) {
        if (unit.queries.length == 0) {
            throw new IllegalArgumentException("empty database unit");
        }
        for (Query query : unit.queries) {
            if (query.statementId < 0 || query.statementId >= statements.size() || query.parameterCount() != statements.get(query.statementId).parameterCount()) {
                throw new IllegalArgumentException("statement or parameter count");
            }
        }
    }

    void addToGroup(Unit unit) {
        validate(unit);
        group[groupSize++] = unit;
    }

    void sendGroup() {
        if (phase == 3) {
            encodeGroup();
        }
    }

    public void submit(Unit unit) {
        validate(unit);
        if (unit.tx) {
            if (!pending.isEmpty()) {
                throw new IllegalStateException("transaction requires idle connection");
            }
            transaction = unit;
        } else if (transaction != null) {
            throw new IllegalStateException("transaction in progress");
        }
        pending.add(unit);
        if (phase == 3) {
            encode(unit);
        }
    }

    public void ensureConnected() {
        if (fd >= 0 || idle() || System.nanoTime() - lastAttempt < 1_000_000_000L) {
            return;
        }
        lastAttempt = System.nanoTime();
        try {
            fd = sys.connectNonBlocking(address, config.port());
            if (fd < 0) {
                fd = -1;
                fail("connect failed");
                return;
            }
            if (sys.epollCtl(epoll, Sys.EPOLL_CTL_ADD, fd, Sys.EPOLLIN | Sys.EPOLLOUT, tag) != 0) {
                throw new IllegalStateException("epoll add failed");
            }
            phase = 0;
            connected = false;
        } catch (RuntimeException e) {
            fail(e.toString());
        }
    }

    public void event(int flags, MemorySegment io) {
        if (fd < 0) {
            return;
        }
        try {
            if (!connected && (flags & (Sys.EPOLLOUT | Sys.EPOLLERR | Sys.EPOLLHUP)) != 0) {
                int err = sys.getInt(fd, 1, SO_ERROR);
                if (err != 0) {
                    throw new IllegalStateException("connect errno " + err);
                }
                connected = true;
                startup();
            }
            if ((flags & Sys.EPOLLIN) != 0) {
                read(io);
            }
            if ((flags & (Sys.EPOLLERR | Sys.EPOLLHUP)) != 0) {
                throw new IllegalStateException("database connection closed");
            }
        } catch (Exception e) {
            fail(e.toString());
        }
    }

    public void flush(MemorySegment io) {
        if (fd < 0 || !connected) {
            return;
        }
        try {
            while (sent < out.len) {
                int count = (int) Math.min(io.byteSize(), out.len - sent);
                MemorySegment.copy(out.data, sent, io, ValueLayout.JAVA_BYTE, 0, count);
                long n = sys.write(fd, io, count);
                if (n < 0) {
                    if (sys.errno() == Sys.EINTR) {
                        continue;
                    }
                    if (sys.errno() == Sys.EAGAIN) {
                        break;
                    }
                    throw new IllegalStateException("write errno " + sys.errno());
                }
                if (n == 0) {
                    break;
                }
                sent += (int) n;
            }
            if (sent == out.len) {
                sent = 0;
                out.len = 0;
            }
            int flags = Sys.EPOLLIN | (out.len != 0 ? Sys.EPOLLOUT : 0);
            if (sys.epollCtl(epoll, Sys.EPOLL_CTL_MOD, fd, flags, tag) != 0) {
                throw new IllegalStateException("epoll mod failed");
            }
        } catch (Exception e) {
            fail(e.toString());
        }
    }

    private void startup() {
        int at = out.len;
        out.i32(0);
        out.i32(196608);
        out.cstr("user");
        out.cstr(config.user());
        out.cstr("database");
        out.cstr(config.database());
        out.cstr("client_encoding");
        out.cstr("UTF8");
        out.u8(0);
        out.patch(at, out.len - at);
    }

    private void read(MemorySegment io) throws Exception {
        for (; ; ) {
            long n = sys.read(fd, io, io.byteSize());
            if (n < 0) {
                if (sys.errno() == Sys.EINTR) {
                    continue;
                }
                if (sys.errno() == Sys.EAGAIN) {
                    break;
                }
                throw new IllegalStateException("read errno " + sys.errno());
            }
            if (n == 0) {
                throw new IllegalStateException("database closed connection");
            }
            in.ensure((int) n);
            MemorySegment.copy(io, ValueLayout.JAVA_BYTE, 0, in.data, in.len,
                    (int) n);
            in.len += (int) n;
            parse();
        }
    }

    void receive(byte[] bytes, int offset, int length) throws Exception {
        in.ensure(length);
        System.arraycopy(bytes, offset, in.data, in.len, length);
        in.len += length;
        parse();
    }

    private void parse() throws Exception {
        int p = 0;
        while (in.len - p >= 5) {
            int size = getInt(in.data, p + 1);
            if (size < 4 || size > 64 * 1024 * 1024) {
                throw new IllegalStateException("invalid postgres message size");
            }
            if (in.len - p < size + 1) {
                break;
            }
            int at = p + 5;
            int end = p + size + 1;
            byte type = in.data[p];
            if (type == 'E') {
                errorFields(in.data, at, end);
                if (phase < 3 || phase == 4) {
                    throw new IllegalStateException("database setup or rollback: " + error);
                }
                failed = true;
                Unit u = current();
                if ((groupSize == 0 || retrying)
                        && u != null
                        && u.errorMessage == null) {
                    u.sqlState = state;
                    u.errorMessage = error;
                    if (queryIndex >= 0 && queryIndex < u.queries.length) {
                        u.queries[queryIndex].sqlState = state;
                        u.queries[queryIndex].errorMessage = error;
                    }
                }
            } else if (phase == 0 && type == 'R') {
                auth(at, end);
            } else if (type == 'Z') {
                if (end - at != 1) {
                    throw new IllegalStateException("invalid ReadyForQuery");
                }
                ready(in.data[at]);
            } else if (phase == 3
                    && readRound
                    && !retrying
                    && groupIndex < groupSize
                    && (type == 'D' || type == 'C' || type == 'I')) {
                if (type == 'D') {
                    readRow(in.data, at, end);
                } else {
                    int k = kind(group[groupIndex]);
                    if (k >= 0 && roundCounts[k] > 1) {
                        for (int i = 0; i < roundCounts[k]; i++) {
                            Query q = group[roundIndexes[k][i]].queries[0];
                            q.commandRowCount = q.rowCount();
                        }
                        nextRead();
                    } else {
                        Query q = group[groupIndex].queries[queryIndex];
                        int space = type == 'C' ? end - 2 : at - 1;
                        while (space >= at && in.data[space] != ' ') {
                            space--;
                        }
                        if (space >= at && space + 1 < end - 1) {
                            long n = 0;
                            boolean valid = true;
                            for (int i = space + 1; i < end - 1; i++) {
                                int d = in.data[i] - '0';
                                if (d < 0 || d > 9 || n > (Long.MAX_VALUE - d) / 10) {
                                    valid = false;
                                    break;
                                }
                                n = n * 10 + d;
                            }
                            if (valid) {
                                q.commandRowCount = n;
                            }
                        }
                        if (++queryIndex == group[groupIndex].queries.length) {
                            nextRead();
                        }
                    }
                }
            } else if (phase == 3 && current() != null) {
                Unit u = current();
                if (type == 'D' && queryIndex >= 0 && queryIndex < u.queries.length) {
                    u.queries[queryIndex].appendRow(in.data, at, end - at);
                } else if (type == 'C' || type == 'I') {
                    if (groupSize == 0 && u.tx && queryIndex == -1) {
                        queryIndex = 0;
                    } else if (queryIndex < u.queries.length) {
                        int space = type == 'C' ? end - 2 : at - 1;
                        while (space >= at && in.data[space] != ' ') {
                            space--;
                        }
                        if (space >= at && space + 1 < end - 1) {
                            long count = 0;
                            boolean valid = true;
                            for (int i = space + 1; i < end - 1; i++) {
                                int d = in.data[i] - '0';
                                if (d < 0 || d > 9 || count > (Long.MAX_VALUE - d) / 10) {
                                    valid = false;
                                    break;
                                }
                                count = count * 10 + d;
                            }
                            if (valid) {
                                u.queries[queryIndex].commandRowCount = count;
                            }
                        }
                        queryIndex++;
                        if (groupSize != 0 && !retrying && queryIndex == u.queries.length) {
                            groupIndex++;
                            queryIndex = 0;
                        }
                    }
                }
            }
            p = end;
        }
        System.arraycopy(in.data, p, in.data, 0, in.len - p);
        in.len -= p;
    }

    private Unit current() {
        return groupSize != 0
                ? (groupIndex < groupSize ? group[groupIndex] : null)
                : pending.peek();
    }

    private void ready(byte status) {
        if (phase == 0) {
            phase = 1;
            simple("SET jit = off; SET max_parallel_workers_per_gather = 0");
        } else if (phase == 1) {
            phase = 2;
            for (int i = 0; i < statements.size(); i++) {
                Statement s = statements.get(i);
                parseStatement("s" + i, s.sql(), s.parameterOids());
            }
            parseStatement("begin", "BEGIN", new int[0]);
            parseStatement("commit", "COMMIT", new int[0]);
            sync();
        } else if (phase == 2) {
            phase = 3;
            if (groupSize != 0) {
                if (readRound) {
                    encodeReadRound();
                } else {
                    encodeGroup();
                }
            } else {
                for (Unit u : pending) {
                    encode(u);
                }
            }
        } else if (phase == 4) {
            phase = 3;
            complete();
        } else if (phase == 3) {
            if (groupSize != 0) {
                if (readRound && !retrying) {
                    readReady(status);
                } else {
                    groupReady(status);
                }
                return;
            }
            if (transaction != null && failed) {
                phase = 4;
                simple("ROLLBACK");
            } else {
                complete();
            }
        }
    }

    private void groupReady(byte status) {
        if (status != 'I') {
            throw new IllegalStateException("write group did not return to idle");
        }
        if (!retrying && failed) {
            for (int i = 0; i < groupSize; i++) {
                for (Query q : group[i].queries) {
                    q.clearResults();
                }
            }
            retrying = true;
            groupIndex = 0;
            queryIndex = 0;
            failed = false;
            encodeGroupUnit(group[0]);
            sync();
        } else if (retrying) {
            Unit u = group[groupIndex];
            group[groupIndex++] = null;
            queryIndex = 0;
            failed = false;
            u.owner.post(u);
            if (groupIndex < groupSize) {
                encodeGroupUnit(group[groupIndex]);
                sync();
            } else {
                groupSize = groupIndex = 0;
                retrying = false;
                readRound = false;
            }
        } else {
            if (groupIndex != groupSize) {
                throw new IllegalStateException("incomplete write group");
            }
            for (int i = 0; i < groupSize; i++) {
                Unit u = group[i];
                group[i] = null;
                u.owner.post(u);
            }
            groupSize = groupIndex = queryIndex = 0;
        }
    }

    private void encodeGroupUnit(Unit unit) {
        for (Query q : unit.queries) {
            bind(statementNames[q.statementId], q);
        }
    }

    private void encodeGroup() {
        for (int i = 0; i < groupSize; i++) {
            encodeGroupUnit(group[i]);
        }
        sync();
    }

    private void complete() {
        Unit u = pending.poll();
        if (u == null) {
            throw new IllegalStateException("unexpected ReadyForQuery");
        }
        if (u == transaction) {
            transaction = null;
        }
        failed = false;
        queryIndex = 0;
        u.owner.post(u);
    }

    private void encode(Unit unit) {
        if (unit.tx) {
            bind(BEGIN, null);
        }
        for (Query q : unit.queries) {
            bind(statementNames[q.statementId], q);
        }
        if (unit.tx) {
            bind(COMMIT, null);
        }
        sync();
        if (pending.peek() == unit && unit.tx) {
            queryIndex = -1;
        }
    }

    private void parseStatement(String name, String sql, int[] types) {
        out.u8('P');
        int at = out.len;
        out.i32(0);
        out.cstr(name);
        out.cstr(sql);
        out.i16(types.length);
        for (int type : types) {
            out.i32(type);
        }
        out.patch(at, out.len - at);
    }

    private void bind(byte[] name, Query q) {
        out.u8('B');
        int at = out.len;
        out.i32(0);
        out.u8(0);
        out.bytes(name, name.length);
        out.u8(0);
        out.i16(1);
        out.i16(1);
        out.i16(q == null ? 0 : q.parameterCount());
        if (q != null) {
            out.bytes(q.parameterBytes(), q.parameterLength());
        }
        out.i16(1);
        out.i16(1);
        out.patch(at, out.len - at);
        out.u8('E');
        out.i32(9);
        out.u8(0);
        out.i32(0);
    }

    private void sync() {
        out.u8('S');
        out.i32(4);
    }

    private void simple(String sql) {
        out.u8('Q');
        int at = out.len;
        out.i32(0);
        out.cstr(sql);
        out.patch(at, out.len - at);
    }

    private void password(byte[] data, boolean nul) {
        out.u8('p');
        out.i32(4 + data.length + (nul ? 1 : 0));
        out.bytes(data, data.length);
        if (nul) {
            out.u8(0);
        }
    }

    private void auth(int at, int end) throws Exception {
        int kind = getInt(in.data, at);
        at += 4;
        switch (kind) {
            case 0 -> {}
            case 3 -> password(config.password().getBytes(StandardCharsets.UTF_8), true);
            case 5 -> {
                MessageDigest md = MessageDigest.getInstance("MD5");
                String inner = HexFormat.of().formatHex(md.digest((config.password() + config.user()).getBytes(StandardCharsets.UTF_8)));
                md.update(inner.getBytes(StandardCharsets.US_ASCII));
                md.update(in.data, at, 4);
                password(("md5" + HexFormat.of().formatHex(md.digest())).getBytes(StandardCharsets.US_ASCII), true);
            }
            case 10 -> {
                String mechanisms = new String(in.data, at, end - at, StandardCharsets.US_ASCII);
                if (!Arrays.asList(mechanisms.split("\0")).contains("SCRAM-SHA-256")) {
                    throw new IllegalStateException("SCRAM-SHA-256 unavailable");
                }
                scram = new Scram(config.password());
                byte[] first = scram.first();
                out.u8('p');
                out.i32(4 + 14 + 4 + first.length);
                out.cstr("SCRAM-SHA-256");
                out.i32(first.length);
                out.bytes(first, first.length);
            }
            case 11 -> {
                if (scram == null) {
                    throw new IllegalStateException("unexpected SASL continue");
                }
                password(scram.next(new String(in.data, at, end - at, StandardCharsets.UTF_8)), false);
            }
            case 12 -> {
                if (scram == null || !scram.verify(new String(in.data, at, end - at, StandardCharsets.UTF_8))) {
                    throw new IllegalStateException("SCRAM server signature mismatch");
                }
            }
            default -> throw new IllegalStateException("unsupported auth " + kind);
        }
    }

    private void errorFields(byte[] b, int p, int end) {
        state = error = null;
        while (p < end && b[p] != 0) {
            int field = b[p++];
            int start = p;
            while (p < end && b[p] != 0) {
                p++;
            }
            String value = new String(b, start, p - start, StandardCharsets.UTF_8);
            if (field == 'C') {
                state = value;
            } else if (field == 'M') {
                error = value;
            }
            p++;
        }
    }

    public void fail(String message) {
        if (fd >= 0) {
            Sys.close(fd);
        }
        fd = -1;
        connected = false;
        phase = 0;
        in.len = out.len = sent = 0;
        queryIndex = 0;
        failed = false;
        transaction = null;
        Unit u;
        while ((u = pending.poll()) != null) {
            if (u.errorMessage == null) {
                u.sqlState = "08006";
                u.errorMessage = message;
            }
            u.owner.post(u);
        }
        for (int i = 0; i < groupSize; i++) {
            if ((u = group[i]) != null) {
                group[i] = null;
                if (u.errorMessage == null) {
                    u.sqlState = "08006";
                    u.errorMessage = message;
                }
                u.owner.post(u);
            }
        }
        groupSize = groupIndex = 0;
        retrying = false;
        readRound = false;
    }

    private static int getInt(byte[] b, int p) {
        return (b[p] & 255) << 24
                | (b[p + 1] & 255) << 16
                | (b[p + 2] & 255) << 8
                | b[p + 3] & 255;
    }

    private static final class Buffer {
        byte[] data = new byte[8192];
        int len;

        void ensure(int n) {
            int need = Math.addExact(len, n);
            if (need > data.length) {
                data = Arrays.copyOf(data, Math.max(need, data.length * 2));
            }
        }

        void u8(int x) {
            ensure(1);
            data[len++] = (byte) x;
        }

        void i16(int x) {
            u8(x >>> 8);
            u8(x);
        }

        void i32(int x) {
            u8(x >>> 24);
            u8(x >>> 16);
            u8(x >>> 8);
            u8(x);
        }

        void patch(int p, int x) {
            for (int i = 0; i < 4; i++) {
                data[p + i] = (byte) (x >>> (24 - 8 * i));
            }
        }

        void bytes(byte[] b, int n) {
            ensure(n);
            System.arraycopy(b, 0, data, len, n);
            len += n;
        }

        void cstr(String s) {
            byte[] b = s.getBytes(StandardCharsets.UTF_8);
            bytes(b, b.length);
            u8(0);
        }
    }

    private static final class Scram {
        final byte[] password;
        final String nonce;
        final String bare;
        byte[] signature;

        Scram(String password) {
            this.password = password.getBytes(StandardCharsets.UTF_8);
            byte[] b = new byte[18];
            new SecureRandom().nextBytes(b);
            nonce = Base64.getEncoder().encodeToString(b);
            bare = "n=,r=" + nonce;
        }

        byte[] first() {
            return ("n,," + bare).getBytes(StandardCharsets.US_ASCII);
        }

        byte[] next(String server) throws Exception {
            String r = null;
            String salt = null;
            int iterations = 0;
            for (String part : server.split(",")) {
                if (part.startsWith("r=")) {
                    r = part.substring(2);
                } else if (part.startsWith("s=")) {
                    salt = part.substring(2);
                } else if (part.startsWith("i=")) {
                    iterations = Integer.parseInt(part.substring(2));
                }
            }
            if (r == null
                    || !r.startsWith(nonce)
                    || r.length() == nonce.length()
                    || salt == null
                    || iterations < 1
                    || iterations > 10_000_000) {
                throw new IllegalStateException("invalid SCRAM challenge");
            }
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(password.length == 0 ? new byte[] {0} : password, "HmacSHA256"));
            mac.update(Base64.getDecoder().decode(salt));
            byte[] u = mac.doFinal(new byte[] {0, 0, 0, 1});
            byte[] salted = u.clone();
            for (int i = 1; i < iterations; i++) {
                u = mac.doFinal(u);
                for (int j = 0; j < u.length; j++) {
                    salted[j] ^= u[j];
                }
            }
            byte[] key = hmac(salted, "Client Key".getBytes(StandardCharsets.US_ASCII));
            byte[] stored = MessageDigest.getInstance("SHA-256").digest(key);
            String finalBare = "c=biws,r=" + r;
            byte[] auth = (bare + "," + server + "," + finalBare).getBytes(StandardCharsets.UTF_8);
            byte[] proof = hmac(stored, auth);
            for (int i = 0; i < proof.length; i++) {
                proof[i] ^= key[i];
            }
            signature = hmac(hmac(salted, "Server Key".getBytes(StandardCharsets.US_ASCII)), auth);
            return (finalBare + ",p=" + Base64.getEncoder().encodeToString(proof)).getBytes(StandardCharsets.US_ASCII);
        }

        boolean verify(String s) {
            return s.startsWith("v=") && signature != null && MessageDigest.isEqual(signature, Base64.getDecoder().decode(s.substring(2)));
        }

        static byte[] hmac(byte[] key, byte[] value) throws Exception {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            return mac.doFinal(value);
        }
    }
}
