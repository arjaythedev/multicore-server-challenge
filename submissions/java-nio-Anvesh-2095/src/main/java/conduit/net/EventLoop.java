package conduit.net;

import conduit.http.HttpParser;
import conduit.http.Out;

import java.io.IOException;
import java.net.StandardSocketOptions;
import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.util.Iterator;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * One selector thread: accepts connections, reads and parses requests, dispatches them to the handler, and writes
 * responses. Handlers that wait on the database or bcrypt get their callbacks back on this thread through
 * {@link #execute}, so all connection state is touched by one thread only.
 */
public final class EventLoop extends Thread implements Executor {
    /** Close connections that have been silent this long. Load-generator think time is capped at 70 s. */
    private static final long IDLE_MS = 120_000;
    private static final int MAX_BUFFERED = 2 * 1024 * 1024;

    public interface Handler {
        /** Serves c's current request; must eventually reply exactly once (now or from a callback). */
        void handle(Conn c);
    }

    private final Selector selector;
    private final ServerSocketChannel listener;
    private final Handler handler;
    private final ConcurrentLinkedQueue<Runnable> tasks = new ConcurrentLinkedQueue<>();
    private final AtomicBoolean woken = new AtomicBoolean();
    private final ByteBuffer readBuf = ByteBuffer.allocate(64 * 1024);
    /** The JSON body of the response being built. */
    final Out body = new Out(64 * 1024);
    /** Status line, headers and body, as written to the socket. */
    private final Out wire = new Out(64 * 1024);
    private long now;
    private long nextSweep;

    public EventLoop(int id, ServerSocketChannel listener, Handler handler) throws IOException {
        super("loop-" + id);
        this.selector = Selector.open();
        this.listener = listener;
        this.handler = handler;
        listener.register(selector, SelectionKey.OP_ACCEPT);
    }

    @Override
    public void execute(Runnable task) {
        tasks.add(task);
        if (woken.compareAndSet(false, true)) selector.wakeup();
    }

    @Override
    public void run() {
        now = System.currentTimeMillis();
        nextSweep = now + 10_000;
        while (true) {
            try {
                selector.select(1000);
                woken.set(false);
                now = System.currentTimeMillis();
                Iterator<SelectionKey> it = selector.selectedKeys().iterator();
                while (it.hasNext()) {
                    SelectionKey k = it.next();
                    it.remove();
                    if (!k.isValid()) continue;
                    if (k.isAcceptable()) {
                        accept();
                        continue;
                    }
                    Conn c = (Conn) k.attachment();
                    if (k.isWritable()) onWritable(c);
                    else if (k.isReadable()) onReadable(c);
                }
                Runnable t;
                while ((t = tasks.poll()) != null) t.run();
                if (now >= nextSweep) {
                    sweep();
                    nextSweep = now + 10_000;
                }
            } catch (Throwable e) {
                // never let one bad event kill the loop: the server has no restart
                e.printStackTrace();
            }
        }
    }

    private void accept() {
        for (int i = 0; i < 256; i++) {
            SocketChannel ch;
            try {
                ch = listener.accept();
            } catch (IOException e) {
                // EMFILE and the like: leave the rest in the backlog and retry on the next select
                System.err.println("accept: " + e);
                return;
            }
            if (ch == null) return;
            try {
                ch.configureBlocking(false);
                ch.setOption(StandardSocketOptions.TCP_NODELAY, true);
                Conn c = new Conn(this, ch);
                c.lastActive = now;
                c.key = ch.register(selector, SelectionKey.OP_READ, c);
            } catch (IOException e) {
                try {
                    ch.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    private void onReadable(Conn c) {
        readBuf.clear();
        int n;
        try {
            n = c.ch.read(readBuf);
        } catch (IOException e) {
            close(c);
            return;
        }
        if (n < 0) {
            close(c);
            return;
        }
        if (n == 0) return;
        c.lastActive = now;
        if (c.busy || c.inLen > 0) {
            if (c.inLen + n > MAX_BUFFERED) {
                close(c);
                return;
            }
            c.append(readBuf.array(), 0, n);
            if (!c.busy) process(c, c.in, c.inLen);
        } else {
            process(c, readBuf.array(), n);
        }
    }

    /** Parses and dispatches requests from src[0, end) until one goes asynchronous or the input runs out. */
    private void process(Conn c, byte[] src, int end) {
        int off = 0;
        c.dispatching = true;
        try {
            while (!c.busy && !c.closed && off < end) {
                int used = HttpParser.parse(src, off, end, c);
                if (used == HttpParser.INCOMPLETE) break;
                if (used < 0) {
                    c.keepAlive = false;
                    c.busy = true;
                    c.error(used == HttpParser.TOO_LARGE ? 413 : 400, "bad request");
                    return;
                }
                off += used;
                c.busy = true;
                c.viewer = 0;
                c.token = null;
                runGuarded(c, () -> handler.handle(c));
            }
        } finally {
            c.dispatching = false;
        }
        if (c.closed) return;
        int rest = end - off;
        if (src == c.in) {
            if (rest > 0 && off > 0) System.arraycopy(c.in, off, c.in, 0, rest);
            c.inLen = rest;
        } else if (rest > 0) {
            c.inLen = 0;
            c.append(src, off, rest);
        }
        if (c.inLen == 0 && c.in != null && c.in.length > 4096) c.in = null;
    }

    /** Runs a handler step; if it throws, answers 500 so the client isn't left waiting. */
    void runGuarded(Conn c, Runnable r) {
        try {
            r.run();
        } catch (Throwable e) {
            e.printStackTrace();
            if (c.busy && !c.closed && c.outPending == null) c.error(500, "internal error");
        }
    }

    void reply(Conn c, int status, boolean hasBody) {
        if (c.closed || !c.busy || c.outPending != null) return;
        Out w = wire.reset();
        w.ascii(statusLine(status));
        if (hasBody) {
            w.ascii("Content-Type: application/json\r\nContent-Length: ").num(body.len).ascii("\r\n");
        }
        if (!c.keepAlive) w.ascii("Connection: close\r\n");
        w.ascii("\r\n");
        if (hasBody) w.raw(body);
        ByteBuffer bb = ByteBuffer.wrap(w.buf, 0, w.len);
        try {
            c.ch.write(bb);
        } catch (IOException e) {
            close(c);
            return;
        }
        if (bb.hasRemaining()) {
            ByteBuffer rest = ByteBuffer.allocate(bb.remaining());
            rest.put(bb).flip();
            c.outPending = rest;
            c.key.interestOps(SelectionKey.OP_WRITE);
            return;
        }
        finish(c);
    }

    private void onWritable(Conn c) {
        try {
            c.ch.write(c.outPending);
        } catch (IOException e) {
            close(c);
            return;
        }
        if (c.outPending.hasRemaining()) return;
        c.outPending = null;
        c.key.interestOps(SelectionKey.OP_READ);
        finish(c);
    }

    /** The response is fully written: serve the next pipelined request, if any. */
    private void finish(Conn c) {
        c.busy = false;
        c.lastActive = now;
        if (!c.keepAlive) {
            close(c);
            return;
        }
        if (!c.dispatching && c.inLen > 0) process(c, c.in, c.inLen);
    }

    private void close(Conn c) {
        if (c.closed) return;
        c.closed = true;
        c.in = null;
        c.outPending = null;
        c.key.cancel();
        try {
            c.ch.close();
        } catch (IOException ignored) {
        }
    }

    private void sweep() {
        for (SelectionKey k : selector.keys()) {
            if (k.attachment() instanceof Conn c && !c.busy && now - c.lastActive > IDLE_MS) close(c);
        }
    }

    private static String statusLine(int status) {
        return switch (status) {
            case 200 -> "HTTP/1.1 200 OK\r\n";
            case 201 -> "HTTP/1.1 201 Created\r\n";
            case 204 -> "HTTP/1.1 204 No Content\r\n";
            case 400 -> "HTTP/1.1 400 Bad Request\r\n";
            case 401 -> "HTTP/1.1 401 Unauthorized\r\n";
            case 403 -> "HTTP/1.1 403 Forbidden\r\n";
            case 404 -> "HTTP/1.1 404 Not Found\r\n";
            case 405 -> "HTTP/1.1 405 Method Not Allowed\r\n";
            case 413 -> "HTTP/1.1 413 Content Too Large\r\n";
            case 422 -> "HTTP/1.1 422 Unprocessable Entity\r\n";
            case 503 -> "HTTP/1.1 503 Service Unavailable\r\n";
            default -> "HTTP/1.1 500 Internal Server Error\r\n";
        };
    }
}
