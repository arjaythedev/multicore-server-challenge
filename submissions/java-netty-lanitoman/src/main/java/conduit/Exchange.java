package conduit;

import conduit.http.HttpConnection;
import conduit.json.JsonWriter;
import conduit.json.Keys;
import io.netty.buffer.ByteBufAllocator;

/**
 * One request being served: who asks (the viewer), what for (key, page), and the response being written. Created on
 * the connection's event loop; afterwards it is handled by one thread at a time (a Postgres connection's event loop,
 * a password worker), each handing it on to the next, until exactly one respond call sends the response.
 */
public final class Exchange {
    private final HttpConnection connection;
    private final boolean keepAlive;

    /** The authenticated user's id, or 0 for an anonymous request. */
    public long viewer;
    /** The token the request presented (GET/PUT /api/user echo it back). */
    public String token;
    /** The slug, username or list filter value the request is about. */
    public String key;
    public int limit = 20;
    public long offset;

    /** When the request joined its batch's queue (System.nanoTime), to send the longest-waiting kind first. */
    public long queuedAt;
    /** Set when a row for this request arrived (the thing it asked for exists). */
    public boolean found;

    private JsonWriter json;

    public Exchange(HttpConnection connection, boolean keepAlive) {
        this.connection = connection;
        this.keepAlive = keepAlive;
    }

    /** The response body being written. */
    public JsonWriter json() {
        if (json == null) json = new JsonWriter(ByteBufAllocator.DEFAULT, 1024);
        return json;
    }

    public boolean clientIsGone() {
        return !connection.isOpen();
    }

    public void respond(int status) {
        connection.send(json(), status, keepAlive);
    }

    public void respondNoContent() {
        connection.send(json(), 204, keepAlive);
    }

    /** {"errors": {"body": ["message"]}} with the given status, replacing anything written so far. */
    public void respondError(int status, String message) {
        JsonWriter writer = json();
        writer.reset();
        writer.beginObject()
                .key(Keys.ERRORS).beginObject()
                .key(Keys.BODY).beginArray().value(message).endArray()
                .endObject()
                .endObject();
        respond(status);
    }
}
