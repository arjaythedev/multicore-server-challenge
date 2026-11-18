package conduit.net;

import conduit.http.Out;
import conduit.http.Request;

import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.SocketChannel;
import java.util.Arrays;
import java.util.concurrent.Executor;

/**
 * One client connection and the request it is serving. Kept small: there can be 100k+ of these. The read and
 * write buffers belong to the event loop; a connection only holds bytes when a request arrived split across reads
 * or a response didn't fit in the socket's send buffer.
 *
 * <p>As an {@link Executor} it runs tasks on its event loop, and drops them if the connection closed meanwhile.
 * Database and bcrypt callbacks go through it.
 */
public final class Conn extends Request implements Executor {
    final EventLoop loop;
    final SocketChannel ch;
    SelectionKey key;

    /** Received bytes not parsed yet (a partial or pipelined request), in in[0, inLen). */
    byte[] in;
    int inLen;
    /** The rest of a response the socket didn't take. */
    ByteBuffer outPending;

    /** A request is being served; further input waits in {@link #in}. */
    boolean busy;
    /** We are inside the parse-and-dispatch loop, so a synchronous reply must not start parsing again. */
    boolean dispatching;
    public boolean closed;
    long lastActive;

    /** The viewer's user id from the token, or 0 when anonymous. */
    public long viewer;
    /** The token the request presented (for GET/PUT /api/user responses), or null. */
    public String token;

    Conn(EventLoop loop, SocketChannel ch) {
        this.loop = loop;
        this.ch = ch;
    }

    void append(byte[] b, int off, int n) {
        if (in == null) in = new byte[Math.max(1024, n)];
        else if (inLen + n > in.length) in = Arrays.copyOf(in, Math.max(in.length * 2, inLen + n));
        System.arraycopy(b, off, in, inLen, n);
        inLen += n;
    }

    /** The event loop's JSON body buffer, emptied. Write the body into it, then call {@link #send}. */
    public Out json() {
        return loop.body.reset();
    }

    /** Sends the body written into {@link #json()} with this status. */
    public void send(int status) {
        loop.reply(this, status, true);
    }

    /** Sends a response with no body (204). */
    public void sendEmpty(int status) {
        loop.reply(this, status, false);
    }

    public void error(int status, String msg) {
        json().error(msg);
        send(status);
    }

    @Override
    public void execute(Runnable task) {
        loop.execute(() -> {
            if (!closed) loop.runGuarded(this, task);
        });
    }
}
