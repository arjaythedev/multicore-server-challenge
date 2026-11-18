package dev.moose.conduit.http;

import dev.moose.conduit.json.JsonWriter;

import java.nio.charset.StandardCharsets;

public record HttpReply(int status, byte[] body) {

    public static final HttpReply NO_CONTENT = new HttpReply(204, null);
    public static final HttpReply UNAUTHORIZED = error(401, "unauthorized");
    public static final HttpReply FORBIDDEN = error(403, "forbidden");
    public static final HttpReply NOT_FOUND = error(404, "not found");
    public static final HttpReply INVALID = error(422, "invalid request");
    public static final HttpReply TAKEN = error(422, "has already been taken");
    public static final HttpReply INTERNAL = error(500, "internal error");

    public static HttpReply ok(JsonWriter out) {
        return new HttpReply(200, out.toBytes());
    }

    public static HttpReply created(JsonWriter out) {
        return new HttpReply(201, out.toBytes());
    }

    private static HttpReply error(int status, String message) {
        return new HttpReply(status, ("{\"errors\":{\"body\":[\"" + message + "\"]}}").getBytes(StandardCharsets.UTF_8));
    }

}
