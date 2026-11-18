package conduit;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import javax.crypto.Mac;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * A PostgreSQL wire-protocol (v3) client: SCRAM-SHA-256/md5/cleartext auth, named prepared statements, pipelined
 * Bind/Execute with binary parameters and binary results. One connection per thread, blocking I/O.
 */
final class Pg implements AutoCloseable {
    static final int INT8 = 20, TEXT = 25, INT8_ARRAY = 1016, TEXT_ARRAY = 1009;

    static final class Error extends IOException {
        Error(String m) {
            super(m);
        }
    }

    /** Rows of one statement's result: every cell's bytes live in buf at (off, len); len -1 is NULL. */
    static final class Rows {
        byte[] buf = new byte[4096];
        int used;
        int ncols = -1;
        int nrows;
        int[] off = new int[256];
        int[] len = new int[256];
        String sqlstate; // set if the statement failed
        String message;

        boolean failed() {
            return sqlstate != null;
        }

        boolean isNull(int r, int c) {
            return len[r * ncols + c] < 0;
        }

        long i64(int r, int c) {
            int i = r * ncols + c;
            int o = off[i];
            int l = len[i];
            if (l == 8) return getLong(buf, o);
            if (l == 4) return getInt(buf, o);
            if (l == 2) return (short) ((buf[o] & 0xff) << 8 | (buf[o + 1] & 0xff));
            if (l == 1) return buf[o];
            return 0;
        }

        boolean bool(int r, int c) {
            int i = r * ncols + c;
            return len[i] == 1 && buf[off[i]] != 0;
        }

        /** Copies a cell (null if NULL). */
        byte[] bytes(int r, int c) {
            int i = r * ncols + c;
            return len[i] < 0 ? null : Arrays.copyOfRange(buf, off[i], off[i] + len[i]);
        }

        String str(int r, int c) {
            int i = r * ncols + c;
            return len[i] < 0 ? null : new String(buf, off[i], len[i], StandardCharsets.UTF_8);
        }

        int off(int r, int c) {
            return off[r * ncols + c];
        }

        int len(int r, int c) {
            return len[r * ncols + c];
        }

        /** Writes a cell as a JSON string (or null). */
        void json(Buf b, int r, int c) {
            int i = r * ncols + c;
            if (len[i] < 0) b.ascii("null");
            else b.str(buf, off[i], len[i]);
        }

        /** Appends one DataRow payload of length n read from in. */
        void readRow(In in, int n) throws IOException {
            if (used + n > buf.length) buf = Arrays.copyOf(buf, Math.max(buf.length * 2, used + n));
            in.readFully(buf, used, n);
            int p = used;
            int nc = (buf[p] & 0xff) << 8 | (buf[p + 1] & 0xff);
            p += 2;
            if (ncols < 0) ncols = nc;
            int base = nrows * ncols;
            if (base + ncols > off.length) {
                int cap = Math.max(off.length * 2, base + ncols);
                off = Arrays.copyOf(off, cap);
                len = Arrays.copyOf(len, cap);
            }
            for (int c = 0; c < nc; c++) {
                int l = getInt(buf, p);
                p += 4;
                off[base + c] = p;
                len[base + c] = l;
                if (l > 0) p += l;
            }
            used += n;
            nrows++;
        }
    }

    static long getLong(byte[] b, int o) {
        return (long) getInt(b, o) << 32 | (getInt(b, o + 4) & 0xffffffffL);
    }

    static int getInt(byte[] b, int o) {
        return (b[o] & 0xff) << 24 | (b[o + 1] & 0xff) << 16 | (b[o + 2] & 0xff) << 8 | (b[o + 3] & 0xff);
    }

    // ---- binary array parameters ----

    /** Builds a one-dimensional binary array value. */
    static final class Arr {
        final Buf b = new Buf(256);
        private int count;

        Arr(int elemOid) {
            b.n = 20;
            putInt(b.a, 0, 1); // ndim
            putInt(b.a, 4, 0); // has nulls (recomputed by the server)
            putInt(b.a, 8, elemOid);
            putInt(b.a, 16, 1); // lower bound
        }

        Arr i64(long v) {
            b.ensure(12);
            putInt(b.a, b.n, 8);
            putInt(b.a, b.n + 4, (int) (v >>> 32));
            putInt(b.a, b.n + 8, (int) v);
            b.n += 12;
            count++;
            return this;
        }

        Arr text(byte[] s) {
            b.ensure(4 + s.length);
            putInt(b.a, b.n, s.length);
            b.n += 4;
            b.raw(s);
            count++;
            return this;
        }

        Arr text(String s) {
            return s == null ? nul() : text(s.getBytes(StandardCharsets.UTF_8));
        }

        Arr nul() {
            b.ensure(4);
            putInt(b.a, b.n, -1);
            b.n += 4;
            count++;
            return this;
        }

        byte[] done() {
            putInt(b.a, 12, count);
            if (count == 0) {
                // an empty array has ndim 0
                byte[] e = new byte[12];
                putInt(e, 8, getInt(b.a, 8));
                return e;
            }
            return b.toBytes();
        }
    }

    static void putInt(byte[] b, int o, int v) {
        b[o] = (byte) (v >>> 24);
        b[o + 1] = (byte) (v >>> 16);
        b[o + 2] = (byte) (v >>> 8);
        b[o + 3] = (byte) v;
    }

    static byte[] i64(long v) {
        byte[] b = new byte[8];
        putInt(b, 0, (int) (v >>> 32));
        putInt(b, 4, (int) v);
        return b;
    }

    static byte[] text(String s) {
        return s == null ? null : s.getBytes(StandardCharsets.UTF_8);
    }

    /** Elements of a binary int4/int8 array value. */
    static int arrayInts(byte[] b, int off, int len, long[] out) {
        if (len < 12) return 0;
        int ndim = getInt(b, off);
        if (ndim == 0) return 0;
        int n = getInt(b, off + 12);
        int p = off + 12 + 8 * ndim;
        int k = 0;
        for (int i = 0; i < n && k < out.length; i++) {
            int l = getInt(b, p);
            p += 4;
            if (l == 4) out[k++] = getInt(b, p);
            else if (l == 8) out[k++] = getLong(b, p);
            if (l > 0) p += l;
        }
        return k;
    }

    // ---- connection ----

    record Config(String host, int port, String user, String password, String database) {
        static Config parse(String url) {
            URI u = URI.create(url);
            String user = "postgres", pass = "";
            String ui = u.getRawUserInfo();
            if (ui != null) {
                int c = ui.indexOf(':');
                user = URLDecoder.decode(c < 0 ? ui : ui.substring(0, c), StandardCharsets.UTF_8);
                if (c >= 0) pass = URLDecoder.decode(ui.substring(c + 1), StandardCharsets.UTF_8);
            }
            String db = u.getPath() == null || u.getPath().length() <= 1 ? user : u.getPath().substring(1);
            return new Config(u.getHost() == null ? "127.0.0.1" : u.getHost(), u.getPort() < 0 ? 5432 : u.getPort(),
                    user, pass, db);
        }
    }

    /** A socket's input with its own buffer: one thread reads, so no locking per byte. */
    static final class In {
        private final InputStream s;
        private final byte[] b = new byte[1 << 16];
        private int p, l;

        In(InputStream s) {
            this.s = s;
        }

        private boolean fill() throws IOException {
            p = 0;
            l = s.read(b, 0, b.length);
            if (l < 0) l = 0;
            return l > 0;
        }

        int read() throws IOException {
            if (p == l && !fill()) return -1;
            return b[p++] & 0xff;
        }

        int readInt() throws IOException {
            if (l - p >= 4) {
                int v = getInt(b, p);
                p += 4;
                return v;
            }
            int a = read(), c = read(), d = read(), e = read();
            if ((a | c | d | e) < 0) throw new EOFException("postgres closed the connection");
            return a << 24 | c << 16 | d << 8 | e;
        }

        void readFully(byte[] out, int off, int n) throws IOException {
            while (n > 0) {
                if (p == l && !fill()) throw new EOFException("postgres closed the connection");
                int m = Math.min(n, l - p);
                System.arraycopy(b, p, out, off, m);
                p += m;
                off += m;
                n -= m;
            }
        }

        void skip(int n) throws IOException {
            while (n > 0) {
                if (p == l && !fill()) throw new EOFException("postgres closed the connection");
                int m = Math.min(n, l - p);
                p += m;
                n -= m;
            }
        }
    }

    private final Socket sock;
    private final In in;
    private final OutputStream out;
    final Buf w = new Buf(1 << 16);

    Pg(Config cfg, Map<String, String> settings) throws IOException {
        sock = new Socket();
        sock.setTcpNoDelay(true);
        sock.connect(new InetSocketAddress(cfg.host(), cfg.port()), 10_000);
        in = new In(sock.getInputStream());
        out = sock.getOutputStream();
        startup(cfg, settings);
    }

    @Override
    public void close() {
        try {
            sock.close();
        } catch (IOException ignored) {
        }
    }

    // message building

    private int msgStart;

    private void begin(char type) {
        w.b(type);
        msgStart = w.n;
        w.ensure(4);
        w.n += 4;
    }

    private void end() {
        putInt(w.a, msgStart, w.n - msgStart);
    }

    private void int32(int v) {
        w.ensure(4);
        putInt(w.a, w.n, v);
        w.n += 4;
    }

    private void int16(int v) {
        w.ensure(2);
        w.a[w.n++] = (byte) (v >>> 8);
        w.a[w.n++] = (byte) v;
    }

    private void cstr(String s) {
        w.raw(s.getBytes(StandardCharsets.UTF_8));
        w.b(0);
    }

    void flush() throws IOException {
        out.write(w.a, 0, w.n);
        out.flush();
        w.n = 0;
    }

    private void startup(Config cfg, Map<String, String> settings) throws IOException {
        Map<String, String> p = new LinkedHashMap<>();
        p.put("user", cfg.user());
        p.put("database", cfg.database());
        p.put("client_encoding", "UTF8");
        p.put("DateStyle", "ISO");
        p.put("TimeZone", "UTC");
        p.putAll(settings);
        msgStart = w.n;
        int32(0);
        int32(196608);
        for (var e : p.entrySet()) {
            cstr(e.getKey());
            cstr(e.getValue());
        }
        w.b(0);
        putInt(w.a, msgStart, w.n - msgStart);
        flush();

        String clientNonce = null, clientFirstBare = null;
        byte[] serverSignature = null;
        while (true) {
            int t = in.read();
            int n = in.readInt() - 4;
            byte[] m = body(n);
            switch (t) {
                case 'R' -> {
                    int code = getInt(m, 0);
                    switch (code) {
                        case 0 -> {
                        }
                        case 3 -> {
                            begin('p');
                            cstr(cfg.password());
                            end();
                            flush();
                        }
                        case 5 -> {
                            byte[] salt = Arrays.copyOfRange(m, 4, 8);
                            String inner = md5hex((cfg.password() + cfg.user()).getBytes(StandardCharsets.UTF_8));
                            byte[] x = new byte[32 + 4];
                            System.arraycopy(inner.getBytes(StandardCharsets.US_ASCII), 0, x, 0, 32);
                            System.arraycopy(salt, 0, x, 32, 4);
                            begin('p');
                            cstr("md5" + md5hex(x));
                            end();
                            flush();
                        }
                        case 10 -> {
                            byte[] nb = new byte[18];
                            new SecureRandom().nextBytes(nb);
                            clientNonce = Base64.getEncoder().encodeToString(nb);
                            clientFirstBare = "n=,r=" + clientNonce;
                            byte[] first = ("n,," + clientFirstBare).getBytes(StandardCharsets.UTF_8);
                            begin('p');
                            cstr("SCRAM-SHA-256");
                            int32(first.length);
                            w.raw(first);
                            end();
                            flush();
                        }
                        case 11 -> {
                            String serverFirst = new String(m, 4, m.length - 4, StandardCharsets.UTF_8);
                            String r = null, s = null;
                            int iters = 0;
                            for (String part : serverFirst.split(",")) {
                                if (part.startsWith("r=")) r = part.substring(2);
                                else if (part.startsWith("s=")) s = part.substring(2);
                                else if (part.startsWith("i=")) iters = Integer.parseInt(part.substring(2));
                            }
                            if (r == null || s == null || !r.startsWith(clientNonce)) throw new Error("bad SCRAM server-first");
                            byte[] salted = pbkdf2(cfg.password(), Base64.getDecoder().decode(s), iters);
                            byte[] clientKey = hmac(salted, "Client Key".getBytes(StandardCharsets.US_ASCII));
                            byte[] storedKey = sha256(clientKey);
                            String finalBare = "c=biws,r=" + r;
                            String authMsg = clientFirstBare + "," + serverFirst + "," + finalBare;
                            byte[] sig = hmac(storedKey, authMsg.getBytes(StandardCharsets.UTF_8));
                            byte[] proof = clientKey.clone();
                            for (int i = 0; i < proof.length; i++) proof[i] ^= sig[i];
                            byte[] serverKey = hmac(salted, "Server Key".getBytes(StandardCharsets.US_ASCII));
                            serverSignature = hmac(serverKey, authMsg.getBytes(StandardCharsets.UTF_8));
                            byte[] fin = (finalBare + ",p=" + Base64.getEncoder().encodeToString(proof))
                                    .getBytes(StandardCharsets.UTF_8);
                            begin('p');
                            w.raw(fin);
                            end();
                            flush();
                        }
                        case 12 -> {
                            String fin = new String(m, 4, m.length - 4, StandardCharsets.UTF_8);
                            if (serverSignature == null || !fin.equals("v=" + Base64.getEncoder().encodeToString(serverSignature)))
                                throw new Error("bad SCRAM server signature");
                        }
                        default -> throw new Error("unsupported auth method " + code);
                    }
                }
                case 'E' -> throw new Error("connect: " + errorText(m));
                case 'Z' -> {
                    return;
                }
                default -> {
                    // ParameterStatus, BackendKeyData, NoticeResponse
                }
            }
        }
    }

    private static String md5hex(byte[] b) {
        try {
            byte[] d = MessageDigest.getInstance("MD5").digest(b);
            StringBuilder sb = new StringBuilder();
            for (byte x : d) sb.append(String.format("%02x", x & 0xff));
            return sb.toString();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static byte[] sha256(byte[] b) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(b);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static byte[] hmac(byte[] key, byte[] msg) {
        try {
            Mac m = Mac.getInstance("HmacSHA256");
            m.init(new SecretKeySpec(key, "HmacSHA256"));
            return m.doFinal(msg);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static byte[] pbkdf2(String password, byte[] salt, int iters) {
        try {
            SecretKeyFactory f = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256");
            return f.generateSecret(new PBEKeySpec(password.toCharArray(), salt, iters, 256)).getEncoded();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static String errorText(byte[] m) {
        String code = "", msg = "";
        int i = 0;
        while (i < m.length && m[i] != 0) {
            byte f = m[i++];
            int s = i;
            while (i < m.length && m[i] != 0) i++;
            String v = new String(m, s, i - s, StandardCharsets.UTF_8);
            i++;
            if (f == 'C') code = v;
            else if (f == 'M') msg = v;
        }
        return code + " " + msg;
    }

    private byte[] body(int n) throws IOException {
        byte[] b = new byte[n];
        in.readFully(b, 0, n);
        return b;
    }

    // ---- statements ----

    /** Parses named statements (one round trip for all of them). */
    void prepare(List<Sql.Stmt> stmts) throws IOException {
        for (Sql.Stmt s : stmts) {
            begin('P');
            cstr(s.name());
            cstr(s.sql());
            int16(s.types().length);
            for (int t : s.types()) int32(t);
            end();
        }
        sync();
        flush();
        List<Rows> r = read(0);
        for (Rows x : r) if (x.failed()) throw new Error("prepare: " + x.sqlstate + " " + x.message);
    }

    /** Bind + Execute of a named statement; every parameter and result column is binary. Null params are NULL. */
    void exec(String name, byte[]... params) {
        begin('B');
        w.b(0); // unnamed portal
        cstr(name);
        int16(1);
        int16(1);
        int16(params.length);
        for (byte[] p : params) {
            if (p == null) int32(-1);
            else {
                int32(p.length);
                w.raw(p);
            }
        }
        int16(1);
        int16(1);
        end();
        begin('E');
        w.b(0);
        int32(0);
        end();
        execs++;
    }

    private int execs;

    void sync() {
        begin('S');
        end();
    }

    /** Sends what is buffered (ending with a Sync) and reads one result per exec until ReadyForQuery. */
    List<Rows> run() throws IOException {
        sync();
        flush();
        int n = execs;
        execs = 0;
        return read(n);
    }

    /** Closes the statements buffered so far with a Sync, as one implicit transaction; returns how many there were. */
    int cut() {
        sync();
        int n = execs;
        execs = 0;
        return n;
    }

    /** Reads the results of one cut. Cuts are read in the order they were sent, after flush(). */
    List<Rows> receive(int n) throws IOException {
        return read(n);
    }

    /**
     * Reads results for n executes up to ReadyForQuery. After an error, the remaining executes are skipped by the
     * server; their Rows stay empty with sqlstate "skipped".
     */
    private List<Rows> read(int n) throws IOException {
        List<Rows> res = new ArrayList<>(n);
        for (int i = 0; i < n; i++) res.add(new Rows());
        int cur = 0;
        boolean failed = false;
        while (true) {
            int t = in.read();
            if (t < 0) throw new EOFException("postgres closed the connection");
            int len = in.readInt() - 4;
            switch (t) {
                case 'D' -> res.get(cur).readRow(in, len);
                case 'C', 'I' -> {
                    in.skip(len);
                    cur++;
                }
                case 'E' -> {
                    byte[] m = body(len);
                    if (cur < n) {
                        String txt = errorText(m);
                        int sp = txt.indexOf(' ');
                        res.get(cur).sqlstate = txt.substring(0, sp);
                        res.get(cur).message = txt.substring(sp + 1);
                        cur++;
                    } else if (!failed) {
                        throw new Error(errorText(m));
                    }
                    failed = true;
                }
                case 'Z' -> {
                    in.read(); // transaction status
                    for (int i = cur; i < n; i++) res.get(i).sqlstate = "skipped";
                    return res;
                }
                default -> in.skip(len); // '1', '2', 'n', 'N', 'S', 's', 't'
            }
        }
    }

    /**
     * Sends what is buffered as segments, each already ended by {@link #sync()}, and reads each segment's results.
     * Every segment is its own implicit transaction: an error in one doesn't affect the others.
     */
    List<List<Rows>> runSegments(int[] execsPerSegment) throws IOException {
        flush();
        execs = 0;
        List<List<Rows>> out = new ArrayList<>(execsPerSegment.length);
        for (int n : execsPerSegment) out.add(read(n));
        return out;
    }
}
