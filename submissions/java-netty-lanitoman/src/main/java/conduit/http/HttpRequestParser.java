package conduit.http;

import io.netty.buffer.ByteBuf;
import java.nio.charset.StandardCharsets;

/**
 * Parses HTTP/1.1 requests with Content-Length bodies (no chunked uploads: clients of this API never send them).
 * Only the request line and the headers this server uses are looked at.
 */
final class HttpRequestParser {
    static final int MAX_HEAD_BYTES = 64 * 1024;
    static final int MAX_BODY_BYTES = 1024 * 1024;
    private static final byte[] NO_BODY = new byte[0];

    /** A request that can't be served; the connection is answered with {@code status} and closed. */
    static final class InvalidRequest extends Exception {
        final int status;

        InvalidRequest(int status) {
            super(null, null, false, false);
            this.status = status;
        }
    }

    private HttpRequestParser() {
    }

    /**
     * Parses one request from the buffer and consumes its bytes, or returns null (consuming nothing) when the
     * request hasn't fully arrived yet.
     */
    static HttpRequest parse(ByteBuf buffer) throws InvalidRequest {
        int start = buffer.readerIndex();
        int end = buffer.writerIndex();
        int headEnd = indexOfBlankLine(buffer, start, end);
        if (headEnd < 0) {
            if (end - start > MAX_HEAD_BYTES) throw new InvalidRequest(431);
            return null;
        }

        // request line: METHOD SP target SP version CRLF
        int lineEnd = buffer.indexOf(start, headEnd + 2, (byte) '\r');
        int firstSpace = buffer.indexOf(start, lineEnd, (byte) ' ');
        int secondSpace = firstSpace < 0 ? -1 : buffer.indexOf(firstSpace + 1, lineEnd, (byte) ' ');
        if (firstSpace <= start || secondSpace <= firstSpace + 1) throw new InvalidRequest(400);
        String method = ascii(buffer, start, firstSpace);
        String target = ascii(buffer, firstSpace + 1, secondSpace);
        boolean http10 = equalsIgnoreCase(buffer, secondSpace + 1, lineEnd, "HTTP/1.0");

        // headers
        long contentLength = 0;
        String authorization = null;
        boolean closeRequested = http10;
        int position = lineEnd + 2;
        while (position < headEnd + 2) {
            int headerEnd = buffer.indexOf(position, headEnd + 2, (byte) '\r');
            int colon = buffer.indexOf(position, headerEnd, (byte) ':');
            if (colon > position) {
                int valueStart = skipSpaces(buffer, colon + 1, headerEnd);
                int valueEnd = trimSpaces(buffer, valueStart, headerEnd);
                if (equalsIgnoreCase(buffer, position, colon, "content-length")) {
                    contentLength = parseContentLength(buffer, valueStart, valueEnd);
                } else if (equalsIgnoreCase(buffer, position, colon, "authorization")) {
                    authorization = ascii(buffer, valueStart, valueEnd);
                } else if (equalsIgnoreCase(buffer, position, colon, "connection")) {
                    String value = ascii(buffer, valueStart, valueEnd).toLowerCase();
                    if (value.contains("close")) closeRequested = true;
                    else if (value.contains("keep-alive")) closeRequested = false;
                } else if (equalsIgnoreCase(buffer, position, colon, "transfer-encoding")) {
                    throw new InvalidRequest(400);
                }
            }
            position = headerEnd + 2;
        }
        if (contentLength > MAX_BODY_BYTES) throw new InvalidRequest(413);

        int bodyStart = headEnd + 4;
        if (end - bodyStart < contentLength) return null;
        byte[] body = contentLength == 0 ? NO_BODY : new byte[(int) contentLength];
        buffer.getBytes(bodyStart, body);
        buffer.readerIndex(bodyStart + (int) contentLength);

        int questionMark = target.indexOf('?');
        String path = questionMark < 0 ? target : target.substring(0, questionMark);
        String query = questionMark < 0 ? "" : target.substring(questionMark + 1);
        return new HttpRequest(method, path, query, authorization, body, !closeRequested);
    }

    /** Index of the "\r\n\r\n" that ends the head, or -1. */
    private static int indexOfBlankLine(ByteBuf buffer, int from, int to) {
        for (int i = buffer.indexOf(from, to, (byte) '\r'); i >= 0 && i + 3 < to; i = buffer.indexOf(i + 1, to, (byte) '\r')) {
            if (buffer.getByte(i + 1) == '\n' && buffer.getByte(i + 2) == '\r' && buffer.getByte(i + 3) == '\n') return i;
        }
        return -1;
    }

    private static long parseContentLength(ByteBuf buffer, int from, int to) throws InvalidRequest {
        if (from == to || to - from > 12) throw new InvalidRequest(400);
        long value = 0;
        for (int i = from; i < to; i++) {
            int digit = buffer.getByte(i) - '0';
            if (digit < 0 || digit > 9) throw new InvalidRequest(400);
            value = value * 10 + digit;
        }
        return value;
    }

    private static String ascii(ByteBuf buffer, int from, int to) {
        return buffer.toString(from, to - from, StandardCharsets.ISO_8859_1);
    }

    private static boolean equalsIgnoreCase(ByteBuf buffer, int from, int to, String lowercase) {
        if (to - from != lowercase.length()) return false;
        for (int i = 0; i < lowercase.length(); i++) {
            int b = buffer.getByte(from + i);
            if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
            if (b != Character.toLowerCase(lowercase.charAt(i))) return false;
        }
        return true;
    }

    private static int skipSpaces(ByteBuf buffer, int from, int to) {
        while (from < to && (buffer.getByte(from) == ' ' || buffer.getByte(from) == '\t')) from++;
        return from;
    }

    private static int trimSpaces(ByteBuf buffer, int from, int to) {
        while (to > from && (buffer.getByte(to - 1) == ' ' || buffer.getByte(to - 1) == '\t')) to--;
        return to;
    }
}
