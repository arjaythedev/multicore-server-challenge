package conduit.http;

import io.netty.channel.Channel;
import io.netty.channel.ChannelFutureListener;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import java.lang.management.ManagementFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Keeps the process from running out of file descriptors, whatever the load. Every client connection is one
 * descriptor; when the process has none left, accepting fails, and so does anything else that needs one.
 *
 * <p>At {@code max} open connections the server stops accepting: new connections wait in the listen backlog (or are
 * refused by the kernel once it is full) while the connections already open keep being served. Accepting resumes
 * once 1% of them have closed. Should accepting fail anyway (EMFILE from descriptors used elsewhere), it pauses for
 * 100 ms instead of spinning on the error.
 *
 * <p>Sits in the listening channel's pipeline, so it sees every accepted connection before it is set up.
 */
final class ConnectionLimit extends ChannelInboundHandlerAdapter {
    private static final long BACK_OFF_MILLIS = 100;

    private final int max;
    private final int resumeBelow;
    private final AtomicInteger open = new AtomicInteger();
    private final ChannelFutureListener onClose = closed -> connectionClosed();

    private Channel listener;
    /** Whether the listening channel is currently not accepting. Changed only in {@link #update}. */
    private volatile boolean paused;
    private boolean backingOff;

    ConnectionLimit(int max) {
        this.max = max;
        this.resumeBelow = max - Math.max(1, max / 100);
    }

    /** The descriptor limit, less 1% and 1000 more for everything else (Postgres, epoll, the JDK's own files). */
    static int defaultMax() {
        long limit = 100_000;
        if (ManagementFactory.getOperatingSystemMXBean() instanceof com.sun.management.UnixOperatingSystemMXBean unix) {
            limit = unix.getMaxFileDescriptorCount();
        }
        return (int) Math.max(100, Math.min(Integer.MAX_VALUE, limit - limit / 100 - 1000));
    }

    @Override
    public void handlerAdded(ChannelHandlerContext ctx) {
        listener = ctx.channel();
    }

    /** An accepted connection (the listening channel's "messages" are its new child channels). */
    @Override
    public void channelRead(ChannelHandlerContext ctx, Object message) {
        Channel connection = (Channel) message;
        connection.closeFuture().addListener(onClose);
        if (open.incrementAndGet() >= max) update();
        ctx.fireChannelRead(message);
    }

    /** Accepting failed; not passed on, so Netty doesn't log a stack trace for every failed accept. */
    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        synchronized (this) {
            if (backingOff) return;
            backingOff = true;
        }
        System.err.println("accept failed (" + cause.getMessage() + ") with " + open.get()
                + " connections open; pausing accepts for " + BACK_OFF_MILLIS + " ms");
        update();
        ctx.executor().schedule(() -> {
            synchronized (this) {
                backingOff = false;
            }
            update();
        }, BACK_OFF_MILLIS, TimeUnit.MILLISECONDS);
    }

    private void connectionClosed() {
        open.decrementAndGet();
        if (paused) update();
    }

    /** Accepts, or stops accepting, as the number of open connections and a pending back-off say. */
    private synchronized void update() {
        int threshold = paused ? resumeBelow : max;
        boolean accept = !backingOff && open.get() < threshold;
        if (accept != paused) return;
        paused = !accept;
        listener.config().setAutoRead(accept);
        if (!accept && !backingOff) {
            System.err.println(open.get() + " connections open (the limit): not accepting more until some close");
        }
    }
}
