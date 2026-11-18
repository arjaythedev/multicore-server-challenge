package conduit.pg;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.LockSupport;

/**
 * One Postgres connection speaking protocol v3: the extended query protocol, statements prepared once at startup,
 * binary parameters and results, and pipelining. Queries from any thread are queued; a writer thread encodes them
 * (Bind/Execute per statement, one Sync per query) and a reader thread matches the responses to them in order.
 * Many requests' queries are in flight on one connection at once.
 */
public final class PgConn {
    private final String name;
    private final Socket sock;
    private final InputStream in;
    private final OutputStream out;

    private final ConcurrentLinkedQueue<Query> queue = new ConcurrentLinkedQueue<>();
    /** Queries sent and not yet answered, in send order. */
    private final ConcurrentLinkedQueue<Query> inflight = new ConcurrentLinkedQueue<>();
    /** Queries submitted and not completed: the pool's load measure. */
    final AtomicInteger load = new AtomicInteger();
    volatile boolean dead;
    private Thread writer;

    private byte[] w = new byte[64 * 1024];
    private int wl;
    private byte[] r = new byte[64 * 1024];
    private int rpos, rlim;

    private PgConn(String name, Socket sock) throws IOException {
        this.name = name;
        this.sock = sock;
        this.in = sock.getInputStream();
        this.out = sock.getOutputStream();
    }

    /** Connects, authenticates, prepares every {@link Stmt}, and starts the I/O threads. */
    public static PgConn open(PgConfig cfg, String name) throws IOException {
        Socket s = new Socket();
        s.setTcpNoDelay(true);
        s.setKeepAlive(true);
        s.connect(new InetSocketAddress(cfg.host(), cfg.port()), 5000);
        PgConn c = new PgConn(name, s);
        try {
            c.startup(cfg);
            c.prepareAll();
        } catch (IOException | RuntimeException e) {
            s.close();
            throw e;
        }
        c.writer = new Thread(c::writeLoop, name + "-w");
        c.writer.setDaemon(true);
        Thread reader = new Thread(c::readLoop, name + "-r");
        reader.setDaemon(true);
        c.writer.start();
        reader.start();
        return c;
    }

    public void submit(Query q) {
        load.incrementAndGet();
        queue.add(q);
        if (dead) failAll(null);
        else LockSupport.unpark(writer);
    }

    // ---------- startup ----------

    private void startup(PgConfig cfg) throws IOException {
        wl = 0;
        int start = wl;
        int32(0);
        int32(196608); // protocol 3.0
        cstr("user");
        cstr(cfg.user());
        cstr("database");
        cstr(cfg.database());
        cstr("application_name");
        cstr("conduit-nio");
        cstr("client_encoding");
        cstr("UTF8");
        w[wl++] = 0;
        patch(start, wl - start);
        flush();

        Scram scram = null;
        while (true) {
            byte type = readMessage();
            int p = rpos + 5, end = rpos + 1 + int32At(rpos + 1);
            switch (type) {
                case 'R' -> {
                    int code = int32At(p);
                    switch (code) {
                        case 0 -> { // AuthenticationOk
                        }
                        case 3 -> sendPassword(cfg.password());
                        case 5 -> sendPassword(md5Password(cfg, Arrays.copyOfRange(r, p + 4, p + 8)));
                        case 10 -> {
                            String mechs = new String(r, p + 4, end - p - 4, StandardCharsets.US_ASCII);
                            if (!mechs.contains("SCRAM-SHA-256\0")) throw new IOException("no supported SASL mechanism: " + mechs);
                            scram = new Scram(cfg.password());
                            byte[] first = scram.clientFirst();
                            wl = 0;
                            w[wl++] = 'p';
                            int st = wl;
                            int32(0);
                            cstr("SCRAM-SHA-256");
                            int32(first.length);
                            bytes(first, 0, first.length);
                            patch(st, wl - st);
                            flush();
                        }
                        case 11 -> {
                            byte[] fin = scram.clientFinal(new String(r, p + 4, end - p - 4, StandardCharsets.UTF_8));
                            wl = 0;
                            w[wl++] = 'p';
                            int st = wl;
                            int32(0);
                            bytes(fin, 0, fin.length);
                            patch(st, wl - st);
                            flush();
                        }
                        case 12 -> scram.verifyServer(new String(r, p + 4, end - p - 4, StandardCharsets.UTF_8));
                        default -> throw new IOException("unsupported authentication method " + code);
                    }
                }
                case 'E' -> throw new IOException("connect: " + errorText(p, end));
                case 'Z' -> {
                    rpos = end;
                    return;
                }
                default -> { // ParameterStatus, BackendKeyData, NoticeResponse
                }
            }
            rpos = end;
        }
    }

    private void sendPassword(String pw) throws IOException {
        wl = 0;
        w[wl++] = 'p';
        int st = wl;
        int32(0);
        cstr(pw);
        patch(st, wl - st);
        flush();
    }

    private static String md5Password(PgConfig cfg, byte[] salt) throws IOException {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            String inner = HexFormat.of().formatHex(md.digest((cfg.password() + cfg.user()).getBytes(StandardCharsets.UTF_8)));
            md.update(inner.getBytes(StandardCharsets.US_ASCII));
            md.update(salt);
            return "md5" + HexFormat.of().formatHex(md.digest());
        } catch (GeneralSecurityException e) {
            throw new IOException(e);
        }
    }

    /** Parses every statement, one Sync each, so a bad statement is reported by its SQL. */
    private void prepareAll() throws IOException {
        for (Stmt s : Stmt.ALL) {
            wl = 0;
            w[wl++] = 'P';
            int st = wl;
            int32(0);
            bytes(s.name, 0, s.name.length);
            w[wl++] = 0;
            cstr(s.sql);
            int16(s.types.length);
            for (int t : s.types) int32(t);
            patch(st, wl - st);
            w[wl++] = 'S';
            int32(4);
            flush();
            String err = null;
            while (true) {
                byte type = readMessage();
                int p = rpos + 5, end = rpos + 1 + int32At(rpos + 1);
                rpos = end;
                if (type == 'E') err = errorText(p, end);
                if (type == 'Z') break;
            }
            if (err != null) throw new IOException("prepare failed: " + err + "\n  SQL: " + s.sql);
        }
    }

    // ---------- writer ----------

    private void writeLoop() {
        try {
            while (!dead) {
                Query q = queue.poll();
                if (q == null) {
                    if (wl > 0) flush();
                    LockSupport.park(this);
                    continue;
                }
                inflight.add(q);
                encode(q);
                if (wl > 32 * 1024) flush();
            }
        } catch (Throwable e) {
            die(e);
        }
    }

    private void encode(Query q) {
        for (int i = 0; i < q.n; i++) {
            Stmt s = q.stmts[i];
            Object[] ps = q.params[i];
            w[ensure(1)] = 'B';
            wl++;
            int st = wl;
            int32(0);
            ensure(1);
            w[wl++] = 0; // unnamed portal
            bytes(s.name, 0, s.name.length);
            ensure(1);
            w[wl++] = 0;
            int16(1);
            int16(1); // all parameters binary
            int16(ps.length);
            for (Object v : ps) param(v);
            int16(1);
            int16(1); // all results binary
            patch(st, wl - st);
            ensure(10);
            w[wl++] = 'E';
            int32(9);
            w[wl++] = 0;
            int32(0);
        }
        ensure(5);
        w[wl++] = 'S';
        int32(4);
    }

    private void param(Object v) {
        if (v == null) {
            int32(-1);
        } else if (v instanceof Long l) {
            int32(8);
            int64(l);
        } else if (v instanceof String s) {
            byte[] b = s.getBytes(StandardCharsets.UTF_8);
            int32(b.length);
            bytes(b, 0, b.length);
        } else if (v instanceof String[] a) {
            int st = wl;
            int32(0);
            if (a.length == 0) {
                int32(0);
                int32(0);
                int32(Stmt.TEXT);
            } else {
                int32(1);
                int32(0);
                int32(Stmt.TEXT);
                int32(a.length);
                int32(1);
                for (String s : a) {
                    byte[] b = s.getBytes(StandardCharsets.UTF_8);
                    int32(b.length);
                    bytes(b, 0, b.length);
                }
            }
            patch(st, wl - st - 4);
        } else {
            throw new IllegalArgumentException("unsupported parameter type " + v.getClass());
        }
    }

    // ---------- reader ----------

    private void readLoop() {
        try {
            while (!dead) {
                byte type = readMessage();
                int p = rpos + 5, end = rpos + 1 + int32At(rpos + 1);
                Query q = inflight.peek();
                switch (type) {
                    case 'D' -> {
                        if (q != null && q.cur < q.n) q.rows[q.cur].add(r, p, end - p);
                    }
                    case 'C' -> {
                        if (q != null && q.cur < q.n) q.rows[q.cur++].affected = tagCount(p, end);
                    }
                    case 'E' -> {
                        String state = field(p, end, 'C');
                        if (q != null) q.fail(state == null ? "XX000" : state, errorText(p, end));
                        else System.err.println(name + ": error outside a query: " + errorText(p, end));
                    }
                    case 'Z' -> {
                        inflight.poll();
                        if (q != null) {
                            load.decrementAndGet();
                            q.complete();
                        }
                    }
                    default -> { // BindComplete, NoData, ParameterStatus, NoticeResponse, ...
                    }
                }
                rpos = end;
            }
        } catch (Throwable e) {
            die(e);
        }
    }

    /** The number at the end of a CommandComplete tag such as "INSERT 0 1" or "DELETE 3". */
    private long tagCount(int p, int end) {
        int e = end - 1; // before the terminating NUL
        int s = e;
        while (s > p && r[s - 1] >= '0' && r[s - 1] <= '9') s--;
        long v = 0;
        for (int i = s; i < e; i++) v = v * 10 + (r[i] - '0');
        return v;
    }

    private void die(Throwable e) {
        if (dead) return;
        dead = true;
        System.err.println(name + ": connection lost: " + e);
        try {
            sock.close();
        } catch (IOException ignored) {
        }
        LockSupport.unpark(writer);
        failAll(e);
    }

    private void failAll(Throwable e) {
        Query q;
        while ((q = inflight.poll()) != null || (q = queue.poll()) != null) {
            load.decrementAndGet();
            q.fail("08006", "database connection lost");
            q.complete();
        }
    }

    // ---------- buffers ----------

    /** Reads one whole message into r at rpos; returns its type byte. */
    private byte readMessage() throws IOException {
        need(5);
        need(1 + int32At(rpos + 1));
        return r[rpos];
    }

    private void need(int n) throws IOException {
        if (rlim - rpos >= n) return;
        if (rpos > 0) {
            System.arraycopy(r, rpos, r, 0, rlim - rpos);
            rlim -= rpos;
            rpos = 0;
        }
        if (n > r.length) r = Arrays.copyOf(r, Math.max(n, r.length * 2));
        while (rlim < n) {
            int k = in.read(r, rlim, r.length - rlim);
            if (k < 0) throw new EOFException("server closed the connection");
            rlim += k;
        }
    }

    private int int32At(int p) {
        return Rows.int32(r, p);
    }

    private String field(int p, int end, char code) {
        while (p < end && r[p] != 0) {
            byte f = r[p++];
            int z = p;
            while (z < end && r[z] != 0) z++;
            if (f == code) return new String(r, p, z - p, StandardCharsets.UTF_8);
            p = z + 1;
        }
        return null;
    }

    private String errorText(int p, int end) {
        return field(p, end, 'C') + " " + field(p, end, 'M');
    }

    private void flush() throws IOException {
        out.write(w, 0, wl);
        out.flush();
        wl = 0;
    }

    private int ensure(int n) {
        if (wl + n > w.length) w = Arrays.copyOf(w, Math.max(w.length * 2, wl + n));
        return wl;
    }

    private void int16(int v) {
        ensure(2);
        w[wl++] = (byte) (v >> 8);
        w[wl++] = (byte) v;
    }

    private void int32(int v) {
        ensure(4);
        w[wl++] = (byte) (v >> 24);
        w[wl++] = (byte) (v >> 16);
        w[wl++] = (byte) (v >> 8);
        w[wl++] = (byte) v;
    }

    private void int64(long v) {
        int32((int) (v >> 32));
        int32((int) v);
    }

    private void bytes(byte[] b, int off, int n) {
        ensure(n);
        System.arraycopy(b, off, w, wl, n);
        wl += n;
    }

    private void cstr(String s) {
        byte[] b = s.getBytes(StandardCharsets.UTF_8);
        bytes(b, 0, b.length);
        ensure(1);
        w[wl++] = 0;
    }

    /** Writes v as an int32 at position at (a length placeholder). */
    private void patch(int at, int v) {
        w[at] = (byte) (v >> 24);
        w[at + 1] = (byte) (v >> 16);
        w[at + 2] = (byte) (v >> 8);
        w[at + 3] = (byte) v;
    }

    /** SCRAM-SHA-256 client (RFC 5802 / 7677), without channel binding. */
    private static final class Scram {
        private final String password;
        private final String clientNonce;
        private String clientFirstBare;
        private byte[] serverSignature;

        Scram(String password) {
            this.password = password;
            byte[] nonce = new byte[18];
            new SecureRandom().nextBytes(nonce);
            this.clientNonce = Base64.getEncoder().encodeToString(nonce);
        }

        byte[] clientFirst() {
            clientFirstBare = "n=,r=" + clientNonce;
            return ("n,," + clientFirstBare).getBytes(StandardCharsets.UTF_8);
        }

        byte[] clientFinal(String serverFirst) throws IOException {
            String nonce = null, salt = null;
            int iterations = 0;
            for (String part : serverFirst.split(",")) {
                if (part.startsWith("r=")) nonce = part.substring(2);
                else if (part.startsWith("s=")) salt = part.substring(2);
                else if (part.startsWith("i=")) iterations = Integer.parseInt(part.substring(2));
            }
            if (nonce == null || salt == null || iterations <= 0 || !nonce.startsWith(clientNonce)) {
                throw new IOException("bad SCRAM server-first message");
            }
            try {
                byte[] salted = hi(password.getBytes(StandardCharsets.UTF_8), Base64.getDecoder().decode(salt), iterations);
                byte[] clientKey = hmac(salted, "Client Key");
                byte[] storedKey = MessageDigest.getInstance("SHA-256").digest(clientKey);
                String finalNoProof = "c=biws,r=" + nonce;
                String authMessage = clientFirstBare + "," + serverFirst + "," + finalNoProof;
                byte[] clientSig = hmac(storedKey, authMessage);
                byte[] proof = new byte[clientKey.length];
                for (int i = 0; i < proof.length; i++) proof[i] = (byte) (clientKey[i] ^ clientSig[i]);
                serverSignature = hmac(hmac(salted, "Server Key"), authMessage);
                return (finalNoProof + ",p=" + Base64.getEncoder().encodeToString(proof)).getBytes(StandardCharsets.UTF_8);
            } catch (GeneralSecurityException e) {
                throw new IOException(e);
            }
        }

        void verifyServer(String serverFinal) throws IOException {
            if (!serverFinal.startsWith("v=")
                    || !MessageDigest.isEqual(Base64.getDecoder().decode(serverFinal.substring(2).trim()), serverSignature)) {
                throw new IOException("SCRAM server signature mismatch");
            }
        }

        private static byte[] hi(byte[] pw, byte[] salt, int iterations) throws GeneralSecurityException {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(pw, "HmacSHA256"));
            mac.update(salt);
            byte[] u = mac.doFinal(new byte[] {0, 0, 0, 1});
            byte[] result = u.clone();
            for (int i = 1; i < iterations; i++) {
                u = mac.doFinal(u);
                for (int j = 0; j < result.length; j++) result[j] ^= u[j];
            }
            return result;
        }

        private static byte[] hmac(byte[] key, String msg) throws GeneralSecurityException {
            return hmac(key, msg.getBytes(StandardCharsets.UTF_8));
        }

        private static byte[] hmac(byte[] key, byte[] msg) throws GeneralSecurityException {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            return mac.doFinal(msg);
        }
    }
}
