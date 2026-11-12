package challenge.pg;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import challenge.pg.PgConn.Config;

public final class PgConnTest {
    public static void main(String[] args) throws Exception {
        List<Unit> done = new ArrayList<>();
        PgConn conn = new PgConn(null, 0, 0, new Config("localhost", 5432, "u", "p", "d"), null,
                Stmt.freeze());
        Query first = new Query(Stmt.TAGS, false);
        Query second = new Query(Stmt.TAGS, false);
        Unit a = new Unit(done::add, u -> {}, false, false,
                first);
        Unit b = new Unit(done::add, u -> {}, false, false,
                second);
        conn.submit(a);
        conn.submit(b);
        var phase = PgConn.class.getDeclaredField("phase");
        phase.setAccessible(true);
        phase.setInt(conn, 3);
        ByteArrayOutputStream wire = new ByteArrayOutputStream();
        DataOutputStream d = new DataOutputStream(wire);
        message(
                d,
                'D',
                new byte[] {0, 1, 0, 0, 0, 3,
                        't', 'a', 'g'});
        message(d, 'C', "SELECT 1\0".getBytes(StandardCharsets.UTF_8));
        message(d, 'Z', new byte[] {'I'});
        message(
                d,
                'E',
                new byte[] {
                    'C',
                    '4',
                    '2',
                    'P',
                    '0',
                    '1',
                    0,
                    'M',
                    'm',
                    'i',
                    's',
                    's',
                    'i',
                    'n',
                    'g',
                    0,
                    0
                });
        message(d, 'Z', new byte[] {'I'});
        byte[] bytes = wire.toByteArray();
        for (int i = 0; i < bytes.length; i++) {
            conn.receive(bytes, i, 1);
        }
        if (!done.equals(List.of(a, b)) || first.rowCount() != 1 || first.commandRowCount != 1) {
            throw new AssertionError("pipeline");
        }
        if (!new String(first.bytes(), first.offset(0, 0), first.length(0, 0), StandardCharsets.UTF_8)
                .equals("tag")) {
            throw new AssertionError("row");
        }
        if (!"42P01".equals(b.sqlState) || !"missing".equals(second.errorMessage)) {
            throw new AssertionError("error fields");
        }
        Query txQuery = new Query(Stmt.TAGS, true);
        Unit tx = new Unit(done::add, u -> {}, true, true,
                txQuery);
        conn.submit(tx);
        wire.reset();
        message(d, 'C', "BEGIN\0".getBytes(StandardCharsets.UTF_8));
        message(
                d,
                'E',
                new byte[] {
                    'C',
                    '2',
                    '3',
                    '5',
                    '0',
                    '5',
                    0,
                    'M',
                    'f',
                    'a',
                    'i',
                    'l',
                    0,
                    0
                });
        message(d, 'Z', new byte[] {'E'});
        bytes = wire.toByteArray();
        conn.receive(bytes, 0, bytes.length);
        if (done.size() != 2 || conn.canAccept()) {
            throw new AssertionError("transaction completed before rollback");
        }
        wire.reset();
        message(d, 'C', "ROLLBACK\0".getBytes(StandardCharsets.UTF_8));
        message(d, 'Z', new byte[] {'I'});
        bytes = wire.toByteArray();
        conn.receive(bytes, 0, bytes.length);
        if (done.size() != 3
                || done.get(2) != tx
                || !conn.canAccept()
                || !"23505".equals(tx.sqlState)) {
            throw new AssertionError("rollback");
        }
        groups(false);
        groups(true);
        groupDisconnect();
        readRound(false);
        readRound(true);
        commentsRound();
        listAndProfileRound();
        batchParameters();
    }

    private static void groups(boolean fail) throws Exception {
        List<Unit> done = new ArrayList<>();
        PgConn conn = new PgConn(null, 0, 0, new Config("localhost", 5432, "u", "p", "d"), null,
                Stmt.freeze());
        conn.initGroups(3);
        var phase = PgConn.class.getDeclaredField("phase");
        phase.setAccessible(true);
        phase.setInt(conn, 3);
        Query q1 = new Query(Stmt.TAGS, true);
        Query q2 = new Query(Stmt.TAGS, true);
        Query q3 = new Query(Stmt.TAGS, true);
        Unit a = new Unit(done::add, u -> {}, true, true,
                q1);
        Unit b = new Unit(done::add, u -> {}, false, true,
                q2);
        Unit c = new Unit(done::add, u -> {}, false, true,
                q3);
        conn.addToGroup(a);
        conn.addToGroup(b);
        conn.addToGroup(c);
        conn.sendGroup();
        if (conn.idle()) {
            throw new AssertionError("group must occupy connection");
        }
        var outField = PgConn.class.getDeclaredField("out");
        outField.setAccessible(true);
        Object out = outField.get(conn);
        var dataField = out.getClass().getDeclaredField("data");
        dataField.setAccessible(true);
        var lenField = out.getClass().getDeclaredField("len");
        lenField.setAccessible(true);
        byte[] encoded = (byte[]) dataField.get(out);
        int length = lenField.getInt(out);
        int binds = 0;
        int executes = 0;
        int syncs = 0;
        for (int p = 0; p < length; ) {
            int size = (encoded[p + 1] & 255) << 24
                    | (encoded[p + 2] & 255) << 16
                    | (encoded[p + 3] & 255) << 8
                    | encoded[p + 4] & 255;
            if (encoded[p] == 'B') {
                binds++;
            }
            if (encoded[p] == 'E') {
                executes++;
            }
            if (encoded[p] == 'S') {
                syncs++;
            }
            p += size + 1;
        }
        if (binds != 3 || executes != 3 || syncs != 1) {
            throw new AssertionError("group wire messages");
        }
        ByteArrayOutputStream wire = new ByteArrayOutputStream();
        DataOutputStream d = new DataOutputStream(wire);
        message(
                d,
                'D',
                new byte[] {0, 1, 0, 0, 0, 3,
                        'o', 'l', 'd'});
        message(d, 'C', "SELECT 1\0".getBytes(StandardCharsets.UTF_8));
        if (fail) {
            message(
                    d,
                    'E',
                    new byte[] {
                        'C',
                        '2',
                        '3',
                        '5',
                        '0',
                        '5',
                        0,
                        'M',
                        'f',
                        'a',
                        'i',
                        'l',
                        0,
                        0
                    });
        } else {
            message(d, 'C', "SELECT 2\0".getBytes(StandardCharsets.UTF_8));
            message(d, 'C', "SELECT 3\0".getBytes(StandardCharsets.UTF_8));
        }
        feed(conn, wire);
        if (!done.isEmpty()) {
            throw new AssertionError("completed before commit");
        }
        wire.reset();
        message(d, 'Z', new byte[] {'I'});
        feed(conn, wire);
        if (fail) {
            if (!done.isEmpty() || q1.rowCount() != 0) {
                throw new AssertionError("group results retained after rollback");
            }
            wire.reset();
            message(
                    d,
                    'D',
                    new byte[] {0, 1, 0, 0, 0, 3,
                            'n', 'e', 'w'});
            message(d, 'C', "SELECT 1\0".getBytes(StandardCharsets.UTF_8));
            message(d, 'Z', new byte[] {'I'});
            message(
                    d,
                    'E',
                    new byte[] {
                        'C',
                        '2',
                        '3',
                        '5',
                        '0',
                        '5',
                        0,
                        'M',
                        'f',
                        'a',
                        'i',
                        'l',
                        0,
                        0
                    });
            message(d, 'Z', new byte[] {'I'});
            message(d, 'C', "SELECT 3\0".getBytes(StandardCharsets.UTF_8));
            message(d, 'Z', new byte[] {'I'});
            feed(conn, wire);
            if (!"23505".equals(b.sqlState)
                    || !"23505".equals(q2.sqlState)
                    || a.sqlState != null
                    || c.sqlState != null
                    || q1.rowCount() != 1
                    || !new String(q1.bytes(), q1.offset(0, 0), q1.length(0, 0), StandardCharsets.UTF_8)
                            .equals("new")) {
                throw new AssertionError("individual retries");
            }
        } else if (q1.rowCount() != 1 || q2.commandRowCount != 2 || q3.commandRowCount != 3) {
            throw new AssertionError("group results");
        }
        if (!done.equals(List.of(a, b, c)) || !conn.idle()) {
            throw new AssertionError("group completion");
        }
    }

    private static void readRound(boolean fail) throws Exception {
        List<Unit> done = new ArrayList<>();
        PgConn conn = new PgConn(null, 0, 0, new Config("localhost", 5432, "u", "p", "d"), null,
                Stmt.freeze());
        conn.initReads(8);
        var phase = PgConn.class.getDeclaredField("phase");
        phase.setAccessible(true);
        phase.setInt(conn, 3);
        Query a = new Query(Stmt.ARTICLE, false)
                .int8(1)
                .text("one");
        Query b = new Query(Stmt.ARTICLE, false)
                .int8(2)
                .text("two");
        Query c = new Query(Stmt.ARTICLE, false)
                .int8(3)
                .text("missing");
        Query t1 = new Query(Stmt.TAGS, false);
        Query t2 = new Query(Stmt.TAGS, false);
        Query other = new Query(Stmt.USER, false).int8(9);
        Query[] queries = {a, t1, b, other, t2, c};
        Unit[] units = new Unit[queries.length];
        for (int i = 0; i < queries.length; i++) {
            units[i] = new Unit(done::add, u -> {}, false, false,
                    queries[i]);
            conn.addToGroup(units[i]);
        }
        conn.sendReadRound();
        var outField = PgConn.class.getDeclaredField("out");
        outField.setAccessible(true);
        Object out = outField.get(conn);
        var dataField = out.getClass().getDeclaredField("data");
        dataField.setAccessible(true);
        var lenField = out.getClass().getDeclaredField("len");
        lenField.setAccessible(true);
        byte[] encoded = (byte[]) dataField.get(out);
        int length = lenField.getInt(out);
        int binds = 0;
        int syncs = 0;
        for (int p = 0; p < length; ) {
            int size = (encoded[p + 1] & 255) << 24
                    | (encoded[p + 2] & 255) << 16
                    | (encoded[p + 3] & 255) << 8
                    | encoded[p + 4] & 255;
            if (encoded[p] == 'B') {
                binds++;
            }
            if (encoded[p] == 'S') {
                syncs++;
            }
            p += size + 1;
        }
        if (binds != 3 || syncs != 1) {
            throw new AssertionError("read round wire");
        }
        ByteArrayOutputStream wire = new ByteArrayOutputStream();
        DataOutputStream d = new DataOutputStream(wire);
        message(d, 'D', tagged(2, "second"));
        message(d, 'D', tagged(1, "first"));
        message(d, 'C', "SELECT 2\0".getBytes(StandardCharsets.UTF_8));
        if (fail) {
            message(
                    d,
                    'E',
                    new byte[] {
                        'C',
                        '4',
                        '2',
                        'P',
                        '0',
                        '1',
                        0,
                        'M',
                        'f',
                        'a',
                        'i',
                        'l',
                        0,
                        0
                    });
        } else {
            message(d, 'D', row("tag"));
            message(d, 'C', "SELECT 1\0".getBytes(StandardCharsets.UTF_8));
            message(d, 'D', row("user"));
            message(d, 'C', "SELECT 1\0".getBytes(StandardCharsets.UTF_8));
        }
        message(d, 'Z', new byte[] {'I'});
        feed(conn, wire);
        if (fail) {
            if (!done.isEmpty() || a.rowCount() != 0 || b.rowCount() != 0) {
                throw new AssertionError("read round not cleared");
            }
            int previousLength = length;
            for (int i = 0; i < queries.length; i++) {
                encoded = (byte[]) dataField.get(out);
                length = lenField.getInt(out);
                int retryBinds = 0;
                int retrySyncs = 0;
                for (int p = previousLength; p < length; ) {
                    int size = (encoded[p + 1] & 255) << 24
                            | (encoded[p + 2] & 255) << 16
                            | (encoded[p + 3] & 255) << 8
                            | encoded[p + 4] & 255;
                    if (encoded[p] == 'B') {
                        retryBinds++;
                    }
                    if (encoded[p] == 'S') {
                        retrySyncs++;
                    }
                    p += size + 1;
                }
                if (retryBinds != 1 || retrySyncs != 1) {
                    throw new AssertionError("individual retry wire");
                }
                previousLength = length;
                wire.reset();
                if (i == 2) {
                    message(
                            d,
                            'E',
                            new byte[] {
                                'C',
                                '4',
                                '2',
                                'P',
                                '0',
                                '1',
                                0,
                                'M',
                                'f',
                                'a',
                                'i',
                                'l',
                                0,
                                0
                            });
                } else {
                    if (i != 5) {
                        message(d, 'D', row("retry"));
                    }
                    message(d, 'C', "SELECT 1\0".getBytes(StandardCharsets.UTF_8));
                }
                message(d, 'Z', new byte[] {'I'});
                feed(conn, wire);
            }
            if (!"42P01".equals(b.sqlState) || a.rowCount() != 1 || c.rowCount() != 0) {
                throw new AssertionError("read retry results");
            }
        } else {
            if (!value(a).equals("first")
                    || !value(b).equals("second")
                    || c.rowCount() != 0
                    || !value(t1).equals("tag")
                    || !value(t2).equals("tag")
                    || !value(other).equals("user")) {
                throw new AssertionError("read routing");
            }
        }
        if (!done.equals(Arrays.asList(units)) || !conn.idle()) {
            throw new AssertionError("read completion");
        }
    }

    private static void commentsRound() throws Exception {
        List<Unit> done = new ArrayList<>();
        PgConn conn = new PgConn(null, 0, 0, new Config("localhost", 5432, "u", "p", "d"), null,
                Stmt.freeze());
        conn.initReads(3);
        var phase = PgConn.class.getDeclaredField("phase");
        phase.setAccessible(true);
        phase.setInt(conn, 3);
        Query[] q = {new Query(Stmt.COMMENTS, false)
                .int8(1)
                .text("empty"),
        new Query(Stmt.COMMENTS, false)
                .int8(2)
                .text("missing"),
                new Query(Stmt.COMMENTS, false)
                .int8(3)
                .text("populated")};
        for (Query query : q) {
            conn.addToGroup(new Unit(done::add, u -> {}, false, false,
                    query));
        }
        conn.sendReadRound();
        ByteArrayOutputStream wire = new ByteArrayOutputStream();
        DataOutputStream d = new DataOutputStream(wire);
        // shared rows: article 10 without comments, article 11 with two (authors 5 and 6), then one row per request,
        // then each author once
        message(d, 'D', new Row().int4(0).int8(10).nul().nul().nul().nul().nul().nul().nul().nul().nul().bytes());
        message(d, 'D', new Row().int4(0).int8(11).int8(21).text("new").int8(1).int8(1).nul().nul().nul().int8(5).nul().bytes());
        message(d, 'D', new Row().int4(0).int8(11).int8(20).text("old").int8(0).int8(0).nul().nul().nul().int8(6).nul().bytes());
        message(d, 'D', new Row().int4(1).int8(10).nul().nul().nul().nul().nul().nul().nul().nul().int8s().bytes());
        message(d, 'D', new Row().int4(3).int8(11).nul().nul().nul().nul().nul().nul().nul().nul().int8s(6).bytes());
        message(d, 'D', new Row().int4(-1).int8(6).nul().nul().nul().nul().text("bob").nul().nul().nul().nul().bytes());
        message(d, 'D', new Row().int4(-1).int8(5).nul().nul().nul().nul().text("ann").nul().nul().nul().nul().bytes());
        message(d, 'C', "SELECT 7\0".getBytes(StandardCharsets.UTF_8));
        message(d, 'Z', new byte[] {'I'});
        feed(conn, wire);
        if (done.size() != 3
                || q[0].rowCount() != 1
                || !q[0].isNull(0, 0)
                || q[0].columns(0) != 8
                || q[0].boolAt(0, 7)
                || q[1].rowCount() != 0
                || q[2].rowCount() != 2
                || q[2].int8At(0, 0) != 21
                || !text(q[2], 0, 1).equals("new")
                || !text(q[2], 1, 1).equals("old")
                || !text(q[2], 1, 4).equals("bob")
                || q[2].boolAt(0, 7)
                || !q[2].boolAt(1, 7)) {
            throw new AssertionError("comments routing");
        }
    }

    private static void listAndProfileRound() throws Exception {
        List<Unit> done = new ArrayList<>();
        PgConn conn = new PgConn(null, 0, 0, new Config("localhost", 5432, "u", "p", "d"), null,
                Stmt.freeze());
        conn.initReads(4);
        var phase = PgConn.class.getDeclaredField("phase");
        phase.setAccessible(true);
        phase.setInt(conn, 3);
        Query[] q = {new Query(Stmt.ARTICLES, false)
                .int8(1)
                .int4(2)
                .int4(0),
        new Query(Stmt.PROFILE, false)
                .int8(1)
                .text("alice"),
        new Query(Stmt.ARTICLES, false)
                .int8(2)
                .int4(2)
                .int4(99),
                new Query(Stmt.PROFILE, false)
                .int8(2)
                .text("missing")};
        for (Query query : q) {
            conn.addToGroup(new Unit(done::add, u -> {}, false, false,
                    query));
        }
        conn.sendReadRound();
        ByteArrayOutputStream wire = new ByteArrayOutputStream();
        DataOutputStream d = new DataOutputStream(wire);
        // shared rows: articles 102 (author 5) and 101 (author 6); request 1 lists both, request 2 (unit 3) an empty page
        // article 102 has tags 1 and 3 (named "zeta" and "beta": id order is not name order), 101 none; the tags table
        // comes last, in name order
        message(d, 'D', listShared(102, 5, 1, 3));
        message(d, 'D', listShared(101, 6));
        message(d, 'D', listRequest(1, new long[] {102, 101}, new long[] {101}, new long[] {5}, 7));
        message(d, 'D', listRequest(2, new long[] {}, new long[] {}, new long[] {}, 7));
        message(d, 'D', tagRow(3, "beta"));
        message(d, 'D', tagRow(2, "mid"));
        message(d, 'D', tagRow(1, "zeta"));
        message(d, 'C', "SELECT 7\0".getBytes(StandardCharsets.UTF_8));
        message(d, 'D', tagged(1, "alice"));
        message(d, 'C', "SELECT 1\0".getBytes(StandardCharsets.UTF_8));
        message(d, 'Z', new byte[] {'I'});
        feed(conn, wire);
        if (done.size() != 4
                || q[0].rowCount() != 2
                || q[0].columns(0) != 14
                || q[0].int8At(0, 0) != 102
                || !text(q[0], 0, 1).equals("s102")
                || q[0].int8At(1, 0) != 101
                || q[0].int8At(0, 7) != 3
                || q[0].boolAt(0, 8)
                || !q[0].boolAt(1, 8)
                || !q[0].boolAt(0, 12)
                || q[0].boolAt(1, 12)
                || !text(q[0], 1, 9).equals("u6")
                || !tagNames(q[0], 0).equals("[beta, zeta]")
                || q[0].length(1, 6) != 12
                || q[0].int8At(1, 13) != 7
                || q[2].rowCount() != 1
                || q[2].columns(0) != 14
                || !q[2].isNull(0, 0)
                || q[2].length(0, 6) != 12
                || q[2].int8At(0, 7) != 0
                || q[2].boolAt(0, 8)
                || q[2].boolAt(0, 12)
                || q[2].int8At(0, 13) != 7
                || !value(q[1]).equals("alice")
                || q[3].rowCount() != 0) {
            throw new AssertionError("list and profile routing");
        }
    }

    private static byte[] listShared(long id, long author, int... tagIds) throws Exception {
        return new Row().int4(0)
                .int8(id)
                .text("s" + id)
                .text("t")
                .text("d")
                .int8(1)
                .int8(2)
                .int4s(tagIds)
                .int8(3)
                .text("u" + author)
                .nul()
                .nul()
                .int8(author)
                .nul()
                .nul()
                .nul()
                .nul()
                .bytes();
    }

    private static byte[] listRequest(int tag, long[] ids, long[] favorited, long[] followed, long count) throws Exception {
        Row row = new Row().int4(tag);
        for (int i = 0; i < 12; i++) {
            row.nul();
        }
        return row.int8s(ids).int8s(favorited).int8s(followed).int8(count).bytes();
    }

    private static byte[] tagRow(int id, String name) throws Exception {
        Row r = new Row().int4(-1).int8(id).text(name);
        for (int i = 0; i < 14; i++) {
            r.nul();
        }
        return r.bytes();
    }

    private static String tagNames(Query q, int row) {
        List<String> names = new ArrayList<>();
        for (int i = 0; i < q.arrayCount(row, 6); i++) {
            int at = q.arrayElementOffset(row, 6, i);
            names.add(new String(q.bytes(), at, q.arrayElementLength(at), StandardCharsets.UTF_8));
        }
        return names.toString();
    }

    private static String text(Query q, int row, int column) {
        return new String(q.bytes(), q.offset(row, column), q.length(row, column), StandardCharsets.UTF_8);
    }

    /** A binary DataRow body, built column by column. */
    private static final class Row {
        private final ByteArrayOutputStream b = new ByteArrayOutputStream();
        private final DataOutputStream d = new DataOutputStream(b);
        private int columns;

        Row int4(int v) throws Exception {
            d.writeInt(4);
            d.writeInt(v);
            columns++;
            return this;
        }

        Row int8(long v) throws Exception {
            d.writeInt(8);
            d.writeLong(v);
            columns++;
            return this;
        }

        Row text(String v) throws Exception {
            byte[] bytes = v.getBytes(StandardCharsets.UTF_8);
            d.writeInt(bytes.length);
            d.write(bytes);
            columns++;
            return this;
        }

        Row nul() throws Exception {
            d.writeInt(-1);
            columns++;
            return this;
        }

        Row emptyTextArray() throws Exception {
            d.writeInt(12);
            d.writeInt(0);
            d.writeInt(0);
            d.writeInt(25);
            columns++;
            return this;
        }

        Row int4s(int... values) throws Exception {
            if (values.length == 0) {
                d.writeInt(12);
                d.writeInt(0);
                d.writeInt(0);
                d.writeInt(23);
            } else {
                d.writeInt(20 + 8 * values.length);
                d.writeInt(1);
                d.writeInt(0);
                d.writeInt(23);
                d.writeInt(values.length);
                d.writeInt(1);
                for (int v : values) {
                    d.writeInt(4);
                    d.writeInt(v);
                }
            }
            columns++;
            return this;
        }

        Row int8s(long... values) throws Exception {
            if (values.length == 0) {
                d.writeInt(12);
                d.writeInt(0);
                d.writeInt(0);
                d.writeInt(20);
            } else {
                d.writeInt(20 + 12 * values.length);
                d.writeInt(1);
                d.writeInt(0);
                d.writeInt(20);
                d.writeInt(values.length);
                d.writeInt(1);
                for (long v : values) {
                    d.writeInt(8);
                    d.writeLong(v);
                }
            }
            columns++;
            return this;
        }

        byte[] bytes() {
            byte[] body = b.toByteArray();
            byte[] out = new byte[body.length + 2];
            out[0] = (byte) (columns >>> 8);
            out[1] = (byte) columns;
            System.arraycopy(body, 0, out, 2, body.length);
            return out;
        }
    }

    private static void batchParameters() throws Exception {
        Query batch = new Query(Stmt.ARTICLES_AUTHOR_BATCH, false);
        Unit[] units = {
            new Unit(
                    u -> {},
                    u -> {},
                    false,
                    false,
                    new Query(Stmt.ARTICLES_AUTHOR, false)
                            .int8(42)
                            .int4(10)
                            .int4(3)
                            .text("alice")),
            new Unit(
                    u -> {},
                    u -> {},
                    false,
                    false,
                    new Query(Stmt.ARTICLES_AUTHOR, false)
                            .int8(0)
                            .int4(5)
                            .int4(9)
                            .text("bob"))
        };
        batch.batchParams(
                units,
                new int[] {0, 1},
                2,
                new int[] {3, 1, 2, 0},
                new int[] {25, 23, 23, 20});
        var input = new DataInputStream(new ByteArrayInputStream(batch.parameterBytes(), 0, batch.parameterLength()));
        String[][] expected = {{"alice", "bob"}, {"10", "5"}, {"3", "9"},
                {"42", "0"}};
        int[] types = {25, 23, 23, 20};
        for (int col = 0; col < 4; col++) {
            int length = input.readInt();
            byte[] bytes = input.readNBytes(length);
            var array = new DataInputStream(new ByteArrayInputStream(bytes));
            if (array.readInt() != 1
                    || array.readInt() != 1
                    || array.readInt() != types[col]
                    || array.readInt() != 2
                    || array.readInt() != 1) {
                throw new AssertionError("array header");
            }
            for (int i = 0; i < 2; i++) {
                int n = array.readInt();
                String value = col == 0
                        ? new String(array.readNBytes(n), StandardCharsets.UTF_8)
                        : col == 3 ? Long.toString(array.readLong()) : Integer.toString(array.readInt());
                if (!value.equals(expected[col][i])) {
                    throw new AssertionError("batch parameter");
                }
            }
            if (array.available() != 0) {
                throw new AssertionError("array length");
            }
        }
        if (input.available() != 0) {
            throw new AssertionError("batch length");
        }
    }

    private static byte[] row(String value) throws Exception {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        DataOutputStream d = new DataOutputStream(b);
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        d.writeShort(1);
        d.writeInt(bytes.length);
        d.write(bytes);
        return b.toByteArray();
    }

    private static byte[] tagged(int tag, String value) throws Exception {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        DataOutputStream d = new DataOutputStream(b);
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        d.writeShort(2);
        d.writeInt(4);
        d.writeInt(tag);
        d.writeInt(bytes.length);
        d.write(bytes);
        return b.toByteArray();
    }

    private static String value(Query q) {
        return new String(q.bytes(), q.offset(0, 0), q.length(0, 0),
                StandardCharsets.UTF_8);
    }

    private static void feed(PgConn conn, ByteArrayOutputStream wire) throws Exception {
        byte[] bytes = wire.toByteArray();
        for (int i = 0; i < bytes.length; i++) {
            conn.receive(bytes, i, 1);
        }
    }

    private static void groupDisconnect() throws Exception {
        List<Unit> done = new ArrayList<>();
        PgConn conn = new PgConn(null, 0, 0, new Config("localhost", 5432, "u", "p", "d"), null,
                Stmt.freeze());
        conn.initGroups(2);
        Unit a = new Unit(done::add, u -> {}, false, true,
                new Query(Stmt.TAGS, true));
        Unit b = new Unit(done::add, u -> {}, false, true,
                new Query(Stmt.TAGS, true));
        conn.addToGroup(a);
        conn.addToGroup(b);
        conn.sendGroup();
        conn.fail("connection lost");
        if (!done.equals(List.of(a, b))
                || !"08006".equals(a.sqlState)
                || !"08006".equals(b.sqlState)
                || !conn.idle()) {
            throw new AssertionError("group disconnect");
        }
    }

    private static void message(DataOutputStream d, char type, byte[] payload) throws Exception {
        d.writeByte(type);
        d.writeInt(payload.length + 4);
        d.write(payload);
    }
}
