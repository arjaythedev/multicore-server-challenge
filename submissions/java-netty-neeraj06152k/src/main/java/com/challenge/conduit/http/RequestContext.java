package com.challenge.conduit.http;

import io.netty.buffer.ByteBuf;
import io.netty.channel.ChannelHandlerContext;
import io.netty.handler.codec.http.*;

/**
 * Reusable execution context for handling an inbound HTTP request.
 * Contains zero-allocation helpers to send responses.
 */
public record RequestContext(
        ChannelHandlerContext ctx,
        FullHttpRequest request,
        String path,
        HttpMethod method,
        long viewerId
) {
    public void send(HttpResponseStatus status, ByteBuf content) {
        FullHttpResponse res = new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, status, content);
        res.headers().set(HttpHeaderNames.CONTENT_TYPE, "application/json");
        res.headers().setInt(HttpHeaderNames.CONTENT_LENGTH, content.readableBytes());
        res.headers().set(HttpHeaderNames.CONNECTION, HttpHeaderValues.KEEP_ALIVE);
        ctx.writeAndFlush(res);
    }

    public ByteBuf alloc() {
        return ctx.alloc().buffer();
    }
}
