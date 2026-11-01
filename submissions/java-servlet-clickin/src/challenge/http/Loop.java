package challenge.http;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import challenge.JsonWriter;
import challenge.Sys;
import challenge.servlet.Container;
import challenge.servlet.Direct.Locals;
import challenge.servlet.Request;
import challenge.servlet.Response;

/**
 * Level-triggered epoll. Each loop owns its listener, sockets and request pool.
 */
public final class Loop implements Runnable {
    private static final int MAX_REQUEST = 16 * 1024 * 1024;
    private final int maxInflight = positiveEnv("MAX_INFLIGHT_PER_LOOP", 1024);
    private int inflight;
    private final Pending pending = new Pending();
    private Conn serving;
    private boolean listenerPaused;
    private boolean resuming;
    private final Sys sys = new Sys();
    private final int ep;
    private final int listener;
    private final int wake;
    private final Container container;
    private final MemorySegment io = Arena.global().allocate(65536, 8);
    private final MemorySegment events = Arena.global().allocate((long) Sys.EVENT_SIZE * 1024, 8);
    private Conn[] connections = new Conn[1024];
    private final ArrayDeque<Exchange> pool = new ArrayDeque<>();
    private final ArrayDeque<byte[]> inputPool = new ArrayDeque<>();
    private final ArrayDeque<byte[]> outputPool = new ArrayDeque<>();
    private final JsonWriter output = new JsonWriter();
    private final AtomicReference<Task> tasks = new AtomicReference<>();
    private final AtomicBoolean signalled = new AtomicBoolean();
    private Thread thread;
    private final Locals locals = new Locals();

    /**
     * Peer or local address of a connection socket; loop thread only (uses the
     * loop's syscall scratch).
     */
    public InetSocketAddress address(int fd, boolean peer) {
        assertLoopThread();
        return sys.address(fd, peer);
    }

    /**
     * Per-loop values for {@link challenge.servlet.Direct#local}; loop thread
     * only.
     */
    public Locals locals() {
        assertLoopThread();
        return locals;
    }

    static final class Conn {
        final int fd;
        byte[] input;
        byte[] output;
        int length;
        int written;
        int outputLength;
        boolean busy;
        boolean closed;
        boolean closeAfter;
        boolean dispatching;
        boolean queued;
        Conn next;
        Exchange exchange;

        Conn(int fd) {
            this.fd = fd;
        }
    }

    static final class Pending {
        private Conn head;
        private Conn tail;

        boolean isEmpty() {
            return head == null;
        }

        void add(Conn c) {
            if (c.queued) {
                return;
            }
            c.queued = true;
            c.next = null;
            if (tail == null) {
                head = c;
            } else {
                tail.next = c;
            }
            tail = c;
        }

        Conn poll() {
            Conn c = head;
            if (c == null) {
                return null;
            }
            head = c.next;
            if (head == null) {
                tail = null;
            }
            c.next = null;
            c.queued = false;
            return c;
        }
    }

    private static final class Exchange implements Runnable {
        final Loop loop;
        Conn conn;
        final Request request;
        final Response response = new Response();

        Exchange(Loop loop) {
            this.loop = loop;
            request = new Request(loop);
            request.init(response);
            response.init(request, loop.container);
        }

        public void run() {
            loop.finish(conn, this);
        }
    }

    private static int positiveEnv(String name, int fallback) {
        String value = System.getenv(name);
        int n = value == null || value.isEmpty()
                ? fallback
                : Integer.parseInt(value);
        if (n < 1) {
            throw new IllegalArgumentException(name + " must be positive");
        }
        return n;
    }

    public Loop(InetAddress host, int port, Container container) {
        this.container = container;
        ep = sys.epollCreate();
        listener = sys.listen(host, port, 65535);
        wake = sys.eventfd();
        ctl(Sys.EPOLL_CTL_ADD, listener, Sys.EPOLLIN);
        ctl(Sys.EPOLL_CTL_ADD, wake, Sys.EPOLLIN);
    }

    public void assertLoopThread() {
        if (Thread.currentThread() != thread) {
            throw new IllegalStateException("completion must run on owning loop");
        }
    }

    public void post(Task task) {
        Objects.requireNonNull(task);
        Task head;
        do {
            head = tasks.get();
            task.next = head;
        } while (!tasks.compareAndSet(head, task));
        if (signalled.compareAndSet(false, true)) {
            Sys.wake(wake);
        }
    }

    private void drain() {
        sys.read(wake, io, 8);
        for (; ; ) {
            Task list = tasks.getAndSet(null);
            Task reverse = null;
            while (list != null) {
                Task next = list.next;
                list.next = reverse;
                reverse = list;
                list = next;
            }
            while (reverse != null) {
                Task next = reverse.next;
                reverse.next = null;
                try {
                    reverse.run();
                } catch (Throwable e) {
                    e.printStackTrace();
                }
                reverse = next;
            }
            signalled.set(false);
            if (tasks.get() == null || !signalled.compareAndSet(false, true)) {
                return;
            }
        }
    }

    private void ctl(int op, int fd, int flags) {
        if (sys.epollCtl(ep, op, fd, flags, 0) != 0) {
            throw new IllegalStateException("epoll_ctl failed for " + fd);
        }
    }

    public void run() {
        thread = Thread.currentThread();
        for (; ; ) {
            int n = sys.epollWait(ep, events, 1024, -1);
            if (n < 0) {
                if (sys.errno() == Sys.EINTR) {
                    continue;
                }
                throw new IllegalStateException("epoll_wait errno " + sys.errno());
            }
            for (int i = 0; i < n; i++) {
                int fd = Sys.eventFd(events, i);
                int flags = Sys.eventFlags(events, i);
                if (fd == listener) {
                    if (inflight < maxInflight) {
                        accept();
                    }
                    resume();
                    continue;
                }
                if (fd == wake) {
                    drain();
                    resume();
                    continue;
                }
                Conn c = fd < connections.length ? connections[fd] : null;
                if (c == null) {
                    continue;
                }
                if ((flags & (Sys.EPOLLERR | Sys.EPOLLHUP)) != 0) {
                    close(c);
                    continue;
                }
                if ((flags & Sys.EPOLLOUT) != 0) {
                    flush(c);
                    if (!c.closed && !c.busy) {
                        process(c);
                    }
                }
                if (!c.closed && !c.busy && (flags & Sys.EPOLLIN) != 0) {
                    read(c);
                }
                resume();
            }
        }
    }

    private void defer(Conn c) {
        if (c.closed || c.queued) {
            return;
        }
        pending.add(c);
        ctl(Sys.EPOLL_CTL_MOD, c.fd, 0);
    }

    private void resume() {
        if (resuming) {
            return;
        }
        resuming = true;
        try {
            while (inflight < maxInflight && !pending.isEmpty()) {
                Conn c = pending.poll();
                if (c.closed || c.busy) {
                    continue;
                }
                serving = c;
                if (c.length > 0) {
                    process(c);
                }
                if (!c.closed && !c.busy && !c.queued) {
                    if (inflight >= maxInflight) {
                        defer(c);
                    } else {
                        ctl(Sys.EPOLL_CTL_MOD, c.fd, Sys.EPOLLIN);
                        read(c);
                    }
                }
            }
            if (listenerPaused && inflight < maxInflight) {
                ctl(Sys.EPOLL_CTL_MOD, listener, Sys.EPOLLIN);
                listenerPaused = false;
            }
        } finally {
            serving = null;
            resuming = false;
        }
    }

    private void accept() {
        for (; ; ) {
            int fd = sys.accept(listener);
            if (fd < 0) {
                int e = sys.errno();
                if (e == Sys.EINTR || e == Sys.ECONNABORTED) {
                    continue;
                }
                if (e == Sys.EAGAIN) {
                    return;
                }
                throw new IllegalStateException("accept errno " + e);
            }
            if (fd >= connections.length) {
                connections = Arrays.copyOf(connections,
                        Math.max(fd + 1, connections.length * 2));
            }
            Conn c = new Conn(fd);
            connections[fd] = c;
            ctl(Sys.EPOLL_CTL_ADD, fd, Sys.EPOLLIN);
        }
    }

    private void read(Conn c) {
        while (!c.busy && !c.closed && !c.queued) {
            if (inflight >= maxInflight || (!pending.isEmpty() && c != serving)) {
                defer(c);
                return;
            }
            long n = sys.read(c.fd, io, io.byteSize());
            if (n == 0) {
                close(c);
                return;
            }
            if (n < 0) {
                if (sys.errno() == Sys.EINTR) {
                    continue;
                }
                if (sys.errno() != Sys.EAGAIN) {
                    close(c);
                }
                return;
            }
            if (c.length + n > MAX_REQUEST) {
                bad(c);
                return;
            }
            int size = c.length + (int) n;
            if (c.input == null) {
                c.input = takeInput(size);
            } else if (size > c.input.length) {
                byte[] old = c.input;
                c.input = Arrays.copyOf(old, Math.max(size, old.length * 2));
                recycleInput(old);
            }
            MemorySegment.copy(io, ValueLayout.JAVA_BYTE, 0, c.input, c.length,
                    (int) n);
            c.length = size;
            process(c);
        }
    }

    private void process(Conn c) {
        while (!c.closed
                && !c.busy
                && !c.queued
                && c.length > 0) {
            if (inflight >= maxInflight || (!pending.isEmpty() && c != serving)) {
                defer(c);
                return;
            }
            Exchange ex = pool.pollFirst();
            if (ex == null) {
                ex = new Exchange(this);
            }
            ex.request.reset();
            ex.response.recycle();
            ex.request.fd = c.fd;
            ex.request.data = c.input;
            int consumed = parse(ex.request, c.length);
            if (consumed == 0) {
                pool.addFirst(ex);
                return;
            }
            if (consumed < 0) {
                pool.addFirst(ex);
                bad(c);
                return;
            }
            inflight++;
            if (inflight == maxInflight && !listenerPaused) {
                ctl(Sys.EPOLL_CTL_MOD, listener, 0);
                listenerPaused = true;
            }
            c.busy = true;
            c.exchange = ex;
            c.closeAfter = ex.request.close;
            int remain = c.length - consumed;
            byte[] rest = remain == 0 ? null : takeInput(remain);
            if (rest != null) {
                System.arraycopy(c.input, consumed, rest, 0, remain);
            }
            c.input = rest;
            c.length = remain;
            ctl(Sys.EPOLL_CTL_MOD, c.fd, 0);
            ex.conn = c;
            ex.response.finish = ex;
            c.dispatching = true;
            try {
                container.service(ex.request, ex.response);
            } catch (Throwable e) {
                e.printStackTrace();
                if (c.busy) {
                    ex.response.reset();
                    ex.response.setStatus(500);
                    ex.response.finish = ex;
                }
            }
            c.dispatching = false;
            if (c.exchange == ex && !ex.request.asyncPending()) {
                finish(c, ex);
            }
            if (!c.closed && !c.busy && !pending.isEmpty()) {
                defer(c);
                return;
            }
        }
    }

    private void finish(Conn c, Exchange ex) {
        assertLoopThread();
        if (c.exchange != ex) {
            throw new IllegalStateException("exchange already completed");
        }
        if (!c.closed) {
            Response r = ex.response;
            int len = r.status == 204 ? 0 : r.jsonOut().length();
            output.reset();
            output.raw("HTTP/1.1 ");
            output.number(r.status);
            output.put(' ');
            output.raw(reason(r.status));
            output.raw("\r\nContent-Length: ");
            output.number(len);
            output.raw("\r\n");
            if (r.contentType != null) {
                output.raw("Content-Type: ");
                latin1(output, r.contentType);
                output.raw("\r\n");
            }
            for (var e : r.headers.entrySet()) {
                for (String value : e.getValue()) {
                    if (e.getKey().equalsIgnoreCase("Connection") && value.equalsIgnoreCase("close")) {
                        c.closeAfter = true;
                    }
                    latin1(output, e.getKey());
                    output.raw(": ");
                    latin1(output, value);
                    output.raw("\r\n");
                }
            }
            if (c.closeAfter) {
                output.raw("Connection: close\r\n");
            }
            output.raw("\r\n");
            if (!ex.request.isHead()) {
                output.raw(r.jsonOut().bytes(), 0,
                        len);
            }
            int sent = write(c, output.bytes(), 0, output.length());
            if (!c.closed && sent < output.length()) {
                int remaining = output.length() - sent;
                c.output = takeOutput(remaining);
                System.arraycopy(output.bytes(), sent, c.output, 0, remaining);
                c.outputLength = remaining;
                c.written = 0;
            }
        }
        byte[] input = ex.request.data;
        ex.request.reset();
        recycleInput(input);
        ex.response.recycle();
        ex.conn = null;
        pool.addFirst(ex);
        c.exchange = null;
        c.busy = false;
        inflight--;
        if (!c.closed) {
            flush(c);
            if (!c.dispatching
                    && !c.closed
                    && !c.busy
                    && c.output == null) {
                process(c);
            }
        }
    }

    private void flush(Conn c) {
        if (c.output == null) {
            if (c.closeAfter) {
                close(c);
            } else if (inflight >= maxInflight || !pending.isEmpty()) {
                defer(c);
            } else {
                ctl(Sys.EPOLL_CTL_MOD, c.fd, Sys.EPOLLIN);
            }
            return;
        }
        c.written += write(c, c.output, c.written, c.outputLength - c.written);
        if (c.closed) {
            return;
        }
        if (c.written < c.outputLength) {
            c.busy = true;
            ctl(Sys.EPOLL_CTL_MOD, c.fd, Sys.EPOLLOUT);
            return;
        }
        recycleOutput(c.output);
        c.output = null;
        c.busy = false;
        if (c.closeAfter) {
            close(c);
            return;
        }
        if (inflight >= maxInflight || !pending.isEmpty()) {
            defer(c);
        } else {
            ctl(Sys.EPOLL_CTL_MOD, c.fd, Sys.EPOLLIN);
        }
    }

    private void bad(Conn c) {
        c.closeAfter = true;
        output.reset();
        output.raw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        int n = output.length();
        c.output = takeOutput(n);
        System.arraycopy(output.bytes(), 0, c.output, 0, n);
        c.outputLength = n;
        c.written = 0;
        flush(c);
    }

    private void close(Conn c) {
        if (c.closed) {
            return;
        }
        c.closed = true;
        connections[c.fd] = null;
        Sys.close(c.fd);
        recycleInput(c.input);
        recycleOutput(c.output);
        c.input = null;
        c.output = null;
    }

    private int write(Conn c, byte[] b, int off,
                      int len) {
        int sent = 0;
        while (sent < len) {
            int count = (int) Math.min(io.byteSize(), len - sent);
            MemorySegment.copy(b, off + sent, io, ValueLayout.JAVA_BYTE, 0,
                    count);
            long n = sys.write(c.fd, io, count);
            if (n < 0) {
                if (sys.errno() == Sys.EINTR) {
                    continue;
                }
                if (sys.errno() != Sys.EAGAIN) {
                    close(c);
                }
                break;
            }
            if (n == 0) {
                break;
            }
            sent += (int) n;
        }
        return sent;
    }

    private byte[] takeOutput(int size) {
        byte[] b = outputPool.pollFirst();
        if (b != null) {
            if (b.length >= size) {
                return b;
            }
            recycleOutput(b);
        }
        return new byte[Math.max(4096, size)];
    }

    private void recycleOutput(byte[] b) {
        if (b != null && b.length <= 65536 && outputPool.size() < 256) {
            outputPool.addFirst(b);
        }
    }

    private static void latin1(JsonWriter out, String s) {
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch <= 255) {
                out.put(ch);
            } else {
                out.put('?');
                if (Character.isHighSurrogate(ch) && i + 1 < s.length() && Character.isLowSurrogate(s.charAt(i + 1))) {
                    i++;
                }
            }
        }
    }

    private byte[] takeInput(int size) {
        byte[] b = inputPool.pollFirst();
        if (b != null) {
            if (b.length >= size) {
                return b;
            }
            recycleInput(b);
        }
        return new byte[Math.max(4096, size)];
    }

    private void recycleInput(byte[] b) {
        if (b != null && b.length <= 65536 && inputPool.size() < 256) {
            inputPool.addFirst(b);
        }
    }

    private static String reason(int s) {
        return switch (s) {
            case 200 -> "OK";
            case 201 -> "Created";
            case 204 -> "No Content";
            case 400 -> "Bad Request";
            case 401 -> "Unauthorized";
            case 403 -> "Forbidden";
            case 404 -> "Not Found";
            case 422 -> "Unprocessable Content";
            case 500 -> "Internal Server Error";
            default -> "Response";
        };
    }

    // Returns the wire length, zero for incomplete input, or -1 for malformed input.
    private static int parse(Request r, int end) {
        byte[] b = r.data;
        int headerEnd = -1;
        for (int i = 3; i < end; i++) {
            if (b[i - 3] == '\r'
                    && b[i - 2] == '\n'
                    && b[i - 1] == '\r'
                    && b[i] == '\n') {
                headerEnd = i + 1;
                break;
            }
        }
        if (headerEnd < 0) {
            return end > 65536 ? -1 : 0;
        }
        int line = index(b, 0, headerEnd, (byte) '\r');
        if (line < 0 || line + 1 >= headerEnd || b[line + 1] != '\n') {
            return -1;
        }
        int sp = index(b, 0, line, (byte) ' ');
        int sp2 = sp < 0 ? -1 : index(b, sp + 1, line, (byte) ' ');
        if (sp <= 0
                || sp2 <= sp + 1
                || sp2 + 9 != line
                || !equal(b, sp2 + 1, line, "HTTP/1.1")) {
            return -1;
        }
        for (int i = 0; i < sp; i++) {
            if (!token(b[i])) {
                return -1;
            }
        }
        r.pathStart = sp + 1;
        if (b[r.pathStart] != '/') {
            return -1;
        }
        int q = index(b, r.pathStart, sp2, (byte) '?');
        r.pathEnd = q < 0 ? sp2 : q;
        r.queryStart = q < 0 ? -1 : q + 1;
        r.queryEnd = q < 0 ? -1 : sp2;
        for (int i = r.pathStart;
             i < sp2;
             i++) {
            if ((b[i] & 255) <= 32 || (b[i] & 255) == 127) {
                return -1;
            }
        }
        int p = line + 2;
        long length = 0;
        boolean hasLength = false;
        boolean chunked = false;
        boolean hasTransfer = false;
        while (p < headerEnd - 2) {
            int e = index(b, p, headerEnd, (byte) '\r');
            if (e < 0 || e + 1 >= headerEnd || b[e + 1] != '\n') {
                return -1;
            }
            int colon = index(b, p, e, (byte) ':');
            if (colon <= p) {
                return -1;
            }
            for (int i = p; i < colon; i++) {
                if (!token(b[i])) {
                    return -1;
                }
            }
            int v = colon + 1;
            while (v < e && (b[v] == ' ' || b[v] == '\t')) {
                v++;
            }
            int z = e;
            while (z > v && (b[z - 1] == ' ' || b[z - 1] == '\t')) {
                z--;
            }
            for (int i = v; i < z; i++) {
                if ((b[i] & 255) < 32 && b[i] != '\t' || (b[i] & 255) == 127) {
                    return -1;
                }
            }
            if (equalIgnoreCase(b, p, colon, "Content-Length")) {
                if (hasLength || v == z) {
                    return -1;
                }
                hasLength = true;
                for (int i = v; i < z; i++) {
                    int d = b[i] - '0';
                    if (d < 0 || d > 9 || length > (MAX_REQUEST - d) / 10) {
                        return -1;
                    }
                    length = length * 10 + d;
                }
            }
            if (equalIgnoreCase(b, p, colon, "Transfer-Encoding")) {
                if (hasTransfer) {
                    return -1;
                }
                hasTransfer = true;
                chunked = equalIgnoreCase(b, v, z, "chunked");
                if (!chunked) {
                    return -1;
                }
            }
            if (equalIgnoreCase(b, p, colon, "Authorization")) {
                if (r.authStart >= 0) {
                    r.multipleAuthorization = true;
                }
                r.authStart = v;
                r.authEnd = z;
            }
            if (equalIgnoreCase(b, p, colon, "Connection") && containsToken(b, v, z, "close", false)) {
                r.close = true;
            }
            if (equalIgnoreCase(b, p, colon, "Accept-Encoding") && containsToken(b, v, z, "gzip", true)) {
                r.gzip = true;
            }
            r.header(p, colon, v, z);
            p = e + 2;
        }
        if (chunked && hasLength) {
            return -1;
        }
        r.bodyStart = headerEnd;
        if (!chunked) {
            r.bodyLength = (int) length;
            return end - headerEnd < length ? 0 : headerEnd + (int) length;
        }
        int pos = headerEnd;
        int total = 0;
        while (true) {
            int e = index(b, pos, end, (byte) '\r');
            if (e < 0) {
                return 0;
            }
            if (e + 1 >= end) {
                return 0;
            }
            if (b[e + 1] != '\n') {
                return -1;
            }
            int semi = index(b, pos, e, (byte) ';');
            int stop = semi < 0 ? e : semi;
            if (stop == pos) {
                return -1;
            }
            int size = 0;
            for (int i = pos; i < stop; i++) {
                int d = Character.digit((char) (b[i] & 255), 16);
                if (d < 0 || size > (MAX_REQUEST - d) / 16) {
                    return -1;
                }
                size = size * 16 + d;
            }
            if (size > MAX_REQUEST - total) {
                return -1;
            }
            pos = e + 2;
            if (size == 0) {
                while (true) {
                    e = index(b, pos, end, (byte) '\r');
                    if (e < 0 || e + 1 >= end) {
                        return 0;
                    }
                    if (b[e + 1] != '\n') {
                        return -1;
                    }
                    if (e == pos) {
                        int wire = e + 2;
                        compactChunks(b, headerEnd, wire);
                        r.bodyLength = total;
                        return wire;
                    }
                    if (index(b, pos, e, (byte) ':') <= pos) {
                        return -1;
                    }
                    pos = e + 2;
                }
            }
            if (end - pos < size + 2) {
                return 0;
            }
            if (b[pos + size] != '\r' || b[pos + size + 1] != '\n') {
                return -1;
            }
            total += size;
            pos += size + 2;
        }
    }

    private static void compactChunks(byte[] b, int from, int end) {
        int pos = from;
        int out = from;
        while (pos < end) {
            int e = index(b, pos, end, (byte) '\r');
            int semi = index(b, pos, e, (byte) ';');
            int stop = semi < 0 ? e : semi;
            int size = 0;
            for (int i = pos; i < stop; i++) {
                size = size * 16 + Character.digit((char) (b[i] & 255), 16);
            }
            pos = e + 2;
            if (size == 0) {
                return;
            }
            System.arraycopy(b, pos, b, out, size);
            out += size;
            pos += size + 2;
        }
    }

    private static int index(byte[] b, int from, int to,
            byte value) {
        for (int i = from; i < to; i++) {
            if (b[i] == value) {
                return i;
            }
        }
        return -1;
    }

    private static boolean equal(byte[] b, int from, int to,
            String s) {
        if (to - from != s.length()) {
            return false;
        }
        for (int i = 0; i < s.length(); i++) {
            if ((b[from + i] & 255) != s.charAt(i)) {
                return false;
            }
        }
        return true;
    }

    private static boolean equalIgnoreCase(byte[] b, int from, int to,
            String s) {
        if (to - from != s.length()) {
            return false;
        }
        for (int i = 0; i < s.length(); i++) {
            int c = b[from + i] & 255;
            if (c >= 'A' && c <= 'Z') {
                c += 32;
            }
            int d = s.charAt(i);
            if (d >= 'A' && d <= 'Z') {
                d += 32;
            }
            if (c != d) {
                return false;
            }
        }
        return true;
    }

    private static boolean containsToken(byte[] b, int from, int to,
            String token, boolean parameters) {
        for (int p = from; p < to; ) {
            int end = p;
            while (end < to && b[end] != ',') {
                end++;
            }
            int a = p;
            int z = end;
            while (a < z && (b[a] & 255) <= 32) {
                a++;
            }
            while (z > a && (b[z - 1] & 255) <= 32) {
                z--;
            }
            if (parameters) {
                int semi = index(b, a, z, (byte) ';');
                if (semi >= 0) {
                    z = semi;
                    while (z > a && (b[z - 1] & 255) <= 32) {
                        z--;
                    }
                }
            }
            if (equalIgnoreCase(b, a, z, token)) {
                return true;
            }
            p = end + 1;
        }
        return false;
    }

    private static boolean token(byte b) {
        int c = b & 255;
        return c > 32 && c < 127 && "()<>@,;:\\\"/[]?={}\t".indexOf(c) < 0;
    }
}
