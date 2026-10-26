package conduit.http;

import conduit.Exchange;
import conduit.Router;
import conduit.json.JsonWriter;
import io.netty.buffer.ByteBuf;
import io.netty.channel.ChannelFutureListener;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;

/**
 * One client connection. Requests are served one at a time, in order (HTTP/1.1 keep-alive; a pipelining client gets
 * its responses in order too). Bytes that arrive while a request is being served wait in {@link #received}.
 *
 * <p>Everything here runs on the connection's event loop, except {@link #send}, which any thread may call: the
 * response is then handed to the event loop.
 */
public final class HttpConnection extends ChannelInboundHandlerAdapter {
    private ChannelHandlerContext context;
    /** Received bytes not parsed yet; null when there are none (an idle connection holds no buffer). */
    private ByteBuf received;
    /** A request is being served; the next one waits until its response is written. */
    private boolean busy;
    /** Inside serveBufferedRequests(): a response sent synchronously must not start the loop again. */
    private boolean serving;

    @Override
    public void handlerAdded(ChannelHandlerContext ctx) {
        context = ctx;
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object message) {
        ByteBuf bytes = (ByteBuf) message;
        if (received == null) {
            received = bytes;
        } else {
            ByteBuf joined = ctx.alloc().buffer(received.readableBytes() + bytes.readableBytes());
            joined.writeBytes(received).writeBytes(bytes);
            received.release();
            bytes.release();
            received = joined;
        }
        serveBufferedRequests();
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) {
        releaseReceived();
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        // connection reset by the client and the like: nothing to report
        ctx.close();
    }

    public boolean isOpen() {
        return context.channel().isActive();
    }

    private void serveBufferedRequests() {
        serving = true;
        try {
            while (!busy && received != null) {
                HttpRequest request;
                try {
                    request = HttpRequestParser.parse(received);
                } catch (HttpRequestParser.InvalidRequest invalid) {
                    releaseReceived();
                    busy = true;
                    Exchange exchange = new Exchange(this, false);
                    exchange.respondError(invalid.status, "invalid request");
                    return;
                }
                if (request == null) return;              // wait for the rest of the request
                if (!received.isReadable()) releaseReceived();
                busy = true;
                Router.route(new Exchange(this, request.keepAlive()), request);
            }
        } finally {
            serving = false;
        }
    }

    /** Sends a finished response (exactly once per request), from any thread. */
    public void send(JsonWriter response, int status, boolean keepAlive) {
        if (context.executor().inEventLoop()) write(response, status, keepAlive);
        else context.executor().execute(() -> write(response, status, keepAlive));
    }

    private void write(JsonWriter response, int status, boolean keepAlive) {
        if (!context.channel().isActive()) {
            response.release();
            return;
        }
        ByteBuf bytes = response.toHttpResponse(status, !keepAlive);
        if (!keepAlive) {
            context.writeAndFlush(bytes).addListener(ChannelFutureListener.CLOSE);
            return;
        }
        context.writeAndFlush(bytes, context.voidPromise());
        busy = false;
        if (!serving && received != null) serveBufferedRequests();
    }

    private void releaseReceived() {
        if (received != null) {
            received.release();
            received = null;
        }
    }
}
