package conduit.http;

/**
 * A parsed HTTP request: what the router needs and nothing more.
 *
 * @param method        GET, POST, PUT, DELETE, ...
 * @param path          the path as sent (still percent-encoded), without the query string
 * @param query         the query string without '?', or "" when there is none
 * @param authorization the Authorization header, or null when there is none
 * @param body          the request body (empty when there is none)
 * @param keepAlive     false when the client asked to close the connection after the response
 */
public record HttpRequest(String method, String path, String query, String authorization, byte[] body,
                          boolean keepAlive) {
}
