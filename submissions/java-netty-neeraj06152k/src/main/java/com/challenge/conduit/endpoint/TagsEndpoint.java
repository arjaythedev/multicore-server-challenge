package com.challenge.conduit.endpoint;

import com.challenge.conduit.db.PostgresClient;
import com.challenge.conduit.http.RequestContext;
import com.challenge.conduit.json.JsonStreamer;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.handler.codec.http.HttpResponseStatus;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Single Responsibility: Handles GET /api/tags
 * Implements Rule 5 compliant single-flight in-flight coalescing:
 * When multiple requests arrive while a query is in-flight, they share the
 * active database query result rather than each firing redundant queries.
 * Once completed, the flight is cleared so subsequent requests query Postgres again.
 */
public final class TagsEndpoint {

    private static final AtomicReference<CompletableFuture<byte[]>> IN_FLIGHT = new AtomicReference<>();

    public static void handle(RequestContext req, PostgresClient pgClient) {
        while (true) {
            CompletableFuture<byte[]> existing = IN_FLIGHT.get();
            if (existing != null) {
                existing.whenComplete((bytes, err) -> {
                    if (bytes != null) {
                        ByteBuf buf = req.alloc();
                        buf.writeBytes(bytes);
                        req.send(HttpResponseStatus.OK, buf);
                    } else {
                        sendEmptyTags(req);
                    }
                });
                return;
            }

            CompletableFuture<byte[]> newFlight = new CompletableFuture<>();
            if (IN_FLIGHT.compareAndSet(null, newFlight)) {
                // Winner fires the actual query to PostgreSQL
                pgClient.query("SELECT name FROM tags ORDER BY name").onComplete(ar -> {
                    byte[] responseBytes;
                    if (ar.succeeded()) {
                        ByteBuf temp = req.alloc();
                        try {
                            JsonStreamer.writeTags(temp, ar.result());
                            responseBytes = new byte[temp.readableBytes()];
                            temp.readBytes(responseBytes);
                        } finally {
                            temp.release();
                        }
                    } else {
                        ByteBuf temp = req.alloc();
                        try {
                            JsonStreamer.writeEmptyTags(temp);
                            responseBytes = new byte[temp.readableBytes()];
                            temp.readBytes(responseBytes);
                        } finally {
                            temp.release();
                        }
                    }

                    // Clear flight reference BEFORE completing callbacks so subsequent requests start a fresh query
                    IN_FLIGHT.set(null);
                    newFlight.complete(responseBytes);
                });

                newFlight.whenComplete((bytes, err) -> {
                    if (bytes != null) {
                        ByteBuf buf = req.alloc();
                        buf.writeBytes(bytes);
                        req.send(HttpResponseStatus.OK, buf);
                    } else {
                        sendEmptyTags(req);
                    }
                });
                return;
            }
        }
    }

    private static void sendEmptyTags(RequestContext req) {
        ByteBuf buf = req.alloc();
        JsonStreamer.writeEmptyTags(buf);
        req.send(HttpResponseStatus.OK, buf);
    }
}
