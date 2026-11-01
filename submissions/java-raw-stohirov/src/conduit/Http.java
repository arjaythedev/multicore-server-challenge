package conduit;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.StandardSocketOptions;
import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * HTTP/1.1 with keep-alive on java.nio selector loops. Each loop owns its connections; a connection has at most one
 * request in flight (later pipelined bytes wait in its buffer). Answers computed on other threads come back through
 * the loop's inbox, one selector wakeup per batch.
 */
final class Http {
    static final int MAX_HEADER = 16 * 1024, MAX_BODY = 1 << 20;

    static final class Conn {
        final SocketChannel ch;
        final Loop loop;
        SelectionKey key;
        byte[] in;
        int inLen;
        boolean busy;
        boolean closeAfter;
        /** set by the loop; read by lanes to drop work whose client is gone */
        volatile boolean closed;
        ByteBuffer out;

        Conn(SocketChannel ch, Loop loop) {
            this.ch = ch;
            this.loop = loop;
        }

        /** Answers this connection's request from any thread. */
        void reply(byte[] resp) {
            loop.post(new Resp(this, resp));
        }
    }

    record Resp(Conn conn, byte[] data) {}

    /** Delivers answers from a batch, waking each loop once. */
    static void deliver(List<Resp> rs) {
        if (rs.isEmpty()) return;
        if (rs.size() == 1) {
            Resp r = rs.get(0);
            r.conn.loop.post(r);
            return;
        }
        Loop[] loops = Http.loops;
        @SuppressWarnings("unchecked")
        List<Resp>[] per = new List[loops.length];
        for (Resp r : rs) {
            int i = r.conn.loop.index;
            if (per[i] == null) per[i] = new ArrayList<>();
            per[i].add(r);
        }
        for (int i = 0; i < loops.length; i++) if (per[i] != null) loops[i].post(per[i]);
    }

    static Loop[] loops;

    static void start(String host, int port, int n) throws IOException {
        boolean reuse = System.getProperty("os.name").toLowerCase().contains("linux")
                && !"0".equals(System.getenv("HTTP_REUSEPORT"));
        loops = new Loop[n];
        for (int i = 0; i < n; i++) {
            ServerSocketChannel ssc = null;
            if (reuse || i == 0) {
                ssc = ServerSocketChannel.open();
                ssc.setOption(StandardSocketOptions.SO_REUSEADDR, true);
                if (reuse) ssc.setOption(StandardSocketOptions.SO_REUSEPORT, true);
                ssc.bind(new InetSocketAddress(host, port), 65535);
                ssc.configureBlocking(false);
            }
            loops[i] = new Loop(i, ssc, !reuse);
        }
        for (Loop l : loops) {
            Thread t = new Thread(l, "http-" + l.index);
            t.setDaemon(false);
            t.start();
        }
    }

    static final class Loop implements Runnable {
        final int index;
        final Selector sel;
        final ServerSocketChannel ssc;
        final boolean distribute;
        SelectionKey acceptKey;
        long acceptPausedUntil;
        int nextLoop;
        final ConcurrentLinkedQueue<Object> inbox = new ConcurrentLinkedQueue<>();
        /** reads parsed this pass, queued together: one lock per pass instead of one per request */
        final ArrayList<Job> reads = new ArrayList<>();
        final AtomicBoolean woken = new AtomicBoolean();
        final ByteBuffer rbuf = ByteBuffer.allocateDirect(64 * 1024);
        final byte[] scratch = new byte[64 * 1024];

        Loop(int index, ServerSocketChannel ssc, boolean distribute) throws IOException {
            this.index = index;
            this.sel = Selector.open();
            this.ssc = ssc;
            this.distribute = distribute;
            if (ssc != null) acceptKey = ssc.register(sel, SelectionKey.OP_ACCEPT);
        }

        void post(Object o) {
            inbox.add(o);
            if (!woken.get() && woken.compareAndSet(false, true)) sel.wakeup();
        }

        @Override
        public void run() {
            while (true) {
                try {
                    long timeout = acceptPausedUntil != 0 ? 100 : 0;
                    sel.select(this::onKey, timeout);
                    woken.set(false);
                    drainInbox();
                    if (!reads.isEmpty()) {
                        Lanes.READS.pushAll(reads);
                        reads.clear();
                    }
                    if (acceptPausedUntil != 0 && System.nanoTime() >= acceptPausedUntil) {
                        acceptPausedUntil = 0;
                        acceptKey.interestOps(SelectionKey.OP_ACCEPT);
                    }
                } catch (Throwable t) {
                    t.printStackTrace();
                }
            }
        }

        @SuppressWarnings("unchecked")
        private void drainInbox() {
            Object o;
            while ((o = inbox.poll()) != null) {
                if (o instanceof Resp r) send(r.conn, r.data);
                else if (o instanceof List<?> l) for (Resp r : (List<Resp>) l) send(r.conn, r.data);
                else if (o instanceof SocketChannel ch) register(ch);
            }
        }

        private void onKey(SelectionKey k) {
            if (!k.isValid()) return;
            if (k == acceptKey) {
                accept();
                return;
            }
            Conn c = (Conn) k.attachment();
            try {
                int ready = k.readyOps();
                if ((ready & SelectionKey.OP_WRITE) != 0) writeMore(c);
                if ((ready & SelectionKey.OP_READ) != 0 && !c.closed) read(c);
            } catch (IOException | RuntimeException e) {
                close(c);
            }
        }

        private void accept() {
            for (int i = 0; i < 256; i++) {
                SocketChannel ch;
                try {
                    ch = ssc.accept();
                } catch (IOException e) {
                    // out of descriptors or memory: stop accepting for 100 ms, keep serving open connections
                    acceptKey.interestOps(0);
                    acceptPausedUntil = System.nanoTime() + 100_000_000L;
                    return;
                }
                if (ch == null) return;
                if (distribute) {
                    Loop l = loops[nextLoop++ % loops.length];
                    if (l == this) register(ch);
                    else l.post(ch);
                } else register(ch);
            }
        }

        private void register(SocketChannel ch) {
            try {
                ch.configureBlocking(false);
                ch.setOption(StandardSocketOptions.TCP_NODELAY, true);
                Conn c = new Conn(ch, this);
                c.key = ch.register(sel, SelectionKey.OP_READ, c);
            } catch (IOException e) {
                try {
                    ch.close();
                } catch (IOException ignored) {
                }
            }
        }

        private void close(Conn c) {
            if (c.closed) return;
            c.closed = true;
            c.in = null;
            c.out = null;
            if (c.key != null) c.key.cancel();
            try {
                c.ch.close();
            } catch (IOException ignored) {
            }
        }

        private void read(Conn c) throws IOException {
            ByteBuffer rb = rbuf;
            rb.clear();
            int n = c.ch.read(rb);
            if (n < 0) {
                close(c);
                return;
            }
            if (n == 0) return;
            rb.flip();
            if (c.inLen == 0 && !c.busy) {
                rb.get(scratch, 0, n);
                parse(c, scratch, 0, n);
            } else {
                append(c, rb, n);
                if (!c.busy) {
                    byte[] a = c.in;
                    int l = c.inLen;
                    c.in = null;
                    c.inLen = 0;
                    parse(c, a, 0, l);
                }
            }
        }

        private static void append(Conn c, ByteBuffer rb, int n) {
            if (c.in == null) c.in = new byte[Math.max(1024, c.inLen + n)];
            else if (c.inLen + n > c.in.length) c.in = java.util.Arrays.copyOf(c.in, Math.max(c.in.length * 2, c.inLen + n));
            rb.get(c.in, c.inLen, n);
            c.inLen += n;
        }

        /** Parses and handles requests from a[off, off+len) while the connection is free; keeps the rest. */
        private void parse(Conn c, byte[] a, int off, int len) {
            int end = off + len;
            while (off < end && !c.busy && !c.closed) {
                int used = request(c, a, off, end);
                if (used == 0) break; // incomplete
                if (used < 0) {
                    close(c);
                    return;
                }
                off += used;
            }
            if (c.closed) return;
            int rest = end - off;
            if (rest > 0) {
                if (rest > MAX_HEADER + MAX_BODY) {
                    close(c);
                    return;
                }
                byte[] keep = new byte[Math.max(1024, rest)];
                System.arraycopy(a, off, keep, 0, rest);
                c.in = keep;
                c.inLen = rest;
            }
        }

        /** Handles one request starting at off. Returns bytes used, 0 if incomplete, -1 to close. */
        private int request(Conn c, byte[] a, int off, int end) {
            // header end
            int he = -1;
            int lim = Math.min(end, off + MAX_HEADER);
            for (int i = off + 3; i < lim; i++) {
                if (a[i] == '\n' && a[i - 1] == '\r' && a[i - 2] == '\n' && a[i - 3] == '\r') {
                    he = i + 1;
                    break;
                }
            }
            if (he < 0) return end - off >= MAX_HEADER ? -1 : 0;
            // request line
            int p = off;
            int sp1 = indexOf(a, p, he, (byte) ' ');
            if (sp1 < 0) return -1;
            int sp2 = indexOf(a, sp1 + 1, he, (byte) ' ');
            if (sp2 < 0) return -1;
            int eol = indexOf(a, sp2 + 1, he, (byte) '\r');
            boolean http10 = eol - sp2 - 1 == 8 && a[eol - 1] == '0' && a[eol - 3] == '1';
            int clen = 0;
            int authOff = -1, authLen = 0;
            boolean close = http10;
            p = eol + 2;
            while (p < he - 2) {
                int le = indexOf(a, p, he, (byte) '\r');
                int colon = indexOf(a, p, le, (byte) ':');
                if (colon > p) {
                    int nlen = colon - p;
                    int vs = colon + 1;
                    while (vs < le && (a[vs] == ' ' || a[vs] == '\t')) vs++;
                    int ve = le;
                    while (ve > vs && (a[ve - 1] == ' ' || a[ve - 1] == '\t')) ve--;
                    if (nlen == 14 && eqIgnoreCase(a, p, "content-length")) {
                        long v = 0;
                        if (ve == vs) return -1;
                        for (int i = vs; i < ve; i++) {
                            int d = a[i] - '0';
                            if (d < 0 || d > 9) return -1;
                            v = v * 10 + d;
                            if (v > MAX_BODY) return -1;
                        }
                        clen = (int) v;
                    } else if (nlen == 13 && eqIgnoreCase(a, p, "authorization")) {
                        authOff = vs;
                        authLen = ve - vs;
                    } else if (nlen == 10 && eqIgnoreCase(a, p, "connection")) {
                        if (ve - vs == 5 && eqIgnoreCase(a, vs, "close")) close = true;
                        else if (ve - vs == 10 && eqIgnoreCase(a, vs, "keep-alive")) close = false;
                    } else if (nlen == 17 && eqIgnoreCase(a, p, "transfer-encoding")) {
                        return -1; // chunked request bodies are not supported
                    }
                }
                p = le + 2;
            }
            if (end - he < clen) return 0;
            c.closeAfter = close;
            c.busy = true;
            byte[] resp = Api.handle(c, a, off, sp1, sp1 + 1, sp2, authOff, authLen, he, clen);
            if (resp != null) send(c, resp);
            return he + clen - off;
        }

        private static int indexOf(byte[] a, int from, int to, byte b) {
            for (int i = from; i < to; i++) if (a[i] == b) return i;
            return -1;
        }

        private static boolean eqIgnoreCase(byte[] a, int off, String lower) {
            for (int i = 0; i < lower.length(); i++) {
                int ch = a[off + i];
                if (ch >= 'A' && ch <= 'Z') ch += 32;
                if (ch != lower.charAt(i)) return false;
            }
            return true;
        }

        /** Writes an answer on this loop's thread, then resumes parsing what the client sent meanwhile. */
        private void send(Conn c, byte[] data) {
            if (c.closed) return;
            c.busy = false;
            try {
                ByteBuffer bb = ByteBuffer.wrap(data);
                c.ch.write(bb);
                if (bb.hasRemaining()) {
                    c.out = bb;
                    c.busy = true; // wait for the write to finish before the next request
                    c.key.interestOps(SelectionKey.OP_READ | SelectionKey.OP_WRITE);
                    return;
                }
            } catch (IOException e) {
                close(c);
                return;
            }
            afterSend(c);
        }

        private void writeMore(Conn c) throws IOException {
            ByteBuffer bb = c.out;
            if (bb == null) {
                c.key.interestOps(SelectionKey.OP_READ);
                return;
            }
            c.ch.write(bb);
            if (bb.hasRemaining()) return;
            c.out = null;
            c.busy = false;
            c.key.interestOps(SelectionKey.OP_READ);
            afterSend(c);
        }

        private void afterSend(Conn c) {
            if (c.closeAfter) {
                close(c);
                return;
            }
            if (c.inLen > 0) {
                byte[] a = c.in;
                int l = c.inLen;
                c.in = null;
                c.inLen = 0;
                parse(c, a, 0, l);
            }
        }
    }

    // ---- responses ----

    private static final byte[] CT = "\r\nContent-Type: application/json\r\nContent-Length: ".getBytes(StandardCharsets.US_ASCII);
    private static final byte[][] STATUS = new byte[600][];

    static {
        String[][] s = {{"200", "OK"}, {"201", "Created"}, {"204", "No Content"}, {"400", "Bad Request"},
                {"401", "Unauthorized"}, {"403", "Forbidden"}, {"404", "Not Found"}, {"413", "Payload Too Large"},
                {"422", "Unprocessable Entity"}, {"500", "Internal Server Error"}, {"503", "Service Unavailable"}};
        for (String[] x : s) STATUS[Integer.parseInt(x[0])] = ("HTTP/1.1 " + x[0] + " " + x[1]).getBytes(StandardCharsets.US_ASCII);
    }

    static final byte[] NO_CONTENT = "HTTP/1.1 204 No Content\r\n\r\n".getBytes(StandardCharsets.US_ASCII);

    /** A JSON response with its headers. */
    static byte[] json(int status, Buf body) {
        return json(status, body.a, body.n);
    }

    static byte[] json(int status, byte[] body, int n) {
        byte[] st = STATUS[status];
        int digits = n < 10 ? 1 : n < 100 ? 2 : n < 1000 ? 3 : n < 10000 ? 4 : n < 100000 ? 5 : n < 1000000 ? 6 : 7;
        byte[] r = new byte[st.length + CT.length + digits + 4 + n];
        int p = 0;
        System.arraycopy(st, 0, r, p, st.length);
        p += st.length;
        System.arraycopy(CT, 0, r, p, CT.length);
        p += CT.length;
        for (int i = digits - 1, v = n; i >= 0; i--, v /= 10) r[p + i] = (byte) ('0' + v % 10);
        p += digits;
        r[p++] = '\r';
        r[p++] = '\n';
        r[p++] = '\r';
        r[p++] = '\n';
        System.arraycopy(body, 0, r, p, n);
        return r;
    }

    static byte[] error(int status, String msg) {
        Buf b = new Buf(64 + msg.length());
        b.ascii("{\"errors\":{\"body\":[").str(msg).ascii("]}}");
        return json(status, b);
    }
}
