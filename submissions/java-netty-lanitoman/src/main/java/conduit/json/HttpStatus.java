package conduit.json;

import java.nio.charset.StandardCharsets;

/** Status lines of the responses this server sends. */
final class HttpStatus {
    private HttpStatus() {
    }

    private static final byte[] OK = line("200 OK");
    private static final byte[] CREATED = line("201 Created");
    private static final byte[] NO_CONTENT = line("204 No Content");
    private static final byte[] BAD_REQUEST = line("400 Bad Request");
    private static final byte[] UNAUTHORIZED = line("401 Unauthorized");
    private static final byte[] FORBIDDEN = line("403 Forbidden");
    private static final byte[] NOT_FOUND = line("404 Not Found");
    private static final byte[] CONTENT_TOO_LARGE = line("413 Content Too Large");
    private static final byte[] UNPROCESSABLE = line("422 Unprocessable Entity");
    private static final byte[] HEADERS_TOO_LARGE = line("431 Request Header Fields Too Large");
    private static final byte[] INTERNAL_ERROR = line("500 Internal Server Error");

    static byte[] line(int status) {
        return switch (status) {
            case 200 -> OK;
            case 201 -> CREATED;
            case 204 -> NO_CONTENT;
            case 400 -> BAD_REQUEST;
            case 401 -> UNAUTHORIZED;
            case 403 -> FORBIDDEN;
            case 404 -> NOT_FOUND;
            case 413 -> CONTENT_TOO_LARGE;
            case 422 -> UNPROCESSABLE;
            case 431 -> HEADERS_TOO_LARGE;
            default -> INTERNAL_ERROR;
        };
    }

    private static byte[] line(String status) {
        return ("HTTP/1.1 " + status + "\r\n").getBytes(StandardCharsets.US_ASCII);
    }
}
