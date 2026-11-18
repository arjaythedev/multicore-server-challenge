package challenge.servlet;

import java.io.IOException;
import java.io.PrintWriter;
import java.io.Writer;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.Charset;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Map.Entry;
import java.util.function.Supplier;

import challenge.JsonWriter;
import jakarta.servlet.DispatcherType;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletOutputStream;
import jakarta.servlet.WriteListener;
import jakarta.servlet.http.Cookie;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletResponse;

public final class Response implements HttpServletResponse {
    private final JsonWriter out = new JsonWriter();
    public int status = 200;
    public String contentType;
    public final Map<String, List<String>> headers = new LinkedHashMap<>();
    public Runnable finish;
    private Request request;
    private Container container;
    private String characterEncoding;
    private boolean encodingSet;
    private Locale locale;

    /** 0 nothing taken yet, 1 getOutputStream, 2 getWriter. */
    private int bodyMode;

    private final ServletOutputStream stream = new ServletOutputStream() {
        public void write(int b) {
            out.put(b);
        }

        public void write(byte[] b, int off, int len) {
            out.raw(b, off, len);
        }

        public boolean isReady() {
            return true;
        }

        /**
         * Output is buffered whole until the exchange completes, so it is
         * always ready.
         */
        public void setWriteListener(WriteListener l) {
            try {
                l.onWritePossible();
            } catch (IOException e) {
                l.onError(e);
            }
        }
    };
    private final PrintWriter writer = new PrintWriter(new Writer() {
        public void write(char[] c, int off, int len) {
            text(CharBuffer.wrap(c, off, len));
        }

        public void write(String str, int off, int len) {
            text(CharBuffer.wrap(str, off, off + len));
        }

        public void flush() {}

        public void close() {}
    });

    public void init(Request request, Container container) {
        this.request = request;
        this.container = container;
    }

    Container container() {
        return container;
    }

    /**
     * Clears the body and renders the error through the container's error
     * servlet, which sees the status and message as the standard {@code
     * jakarta.servlet.error.*} attributes and an ERROR dispatch type.
     */
    public void sendError(int status, String message) throws IOException {
        resetBuffer();
        contentType = null;
        this.status = status;
        HttpServlet errors = container == null ? null : container.errorServlet();
        if (errors == null) {
            return;
        }
        request.error(status, message);
        DispatcherType type = request.dispatcherType;
        request.dispatcherType = DispatcherType.ERROR;
        try {
            errors.service(request, this);
        } catch (ServletException e) {
            throw new IOException(e);
        } finally {
            request.dispatcherType = type;
        }
    }

    public void sendError(int status) throws IOException {
        sendError(status, null);
    }

    public boolean containsHeader(String name) {
        return name.equalsIgnoreCase("Content-Type") ? contentType != null : headers.keySet()
                .stream()
                .anyMatch(k -> k.equalsIgnoreCase(name));
    }

    public void setDateHeader(String name, long date) {
        setHeader(name, DateTimeFormatter.RFC_1123_DATE_TIME.format(Instant.ofEpochMilli(date)
                .atOffset(ZoneOffset.UTC)));
    }

    public void addDateHeader(String name, long date) {
        addHeader(name, DateTimeFormatter.RFC_1123_DATE_TIME.format(Instant.ofEpochMilli(date)
                .atOffset(ZoneOffset.UTC)));
    }

    public boolean isCommitted() {
        return false;
    }

    public JsonWriter jsonOut() {
        return out;
    }

    /** Status, headers and body back to the start; the exchange stays the same. */
    public void reset() {
        status = 200;
        contentType = null;
        characterEncoding = null;
        encodingSet = false;
        locale = null;
        headers.clear();
        out.reset();
        bodyMode = 0;
    }

    /**
     * {@link #reset} plus detaching from the exchange, before the response
     * object is pooled again.
     */
    public void recycle() {
        reset();
        finish = null;
    }

    public void resetBuffer() {
        out.reset();
    }

    public void setStatus(int value) {
        status = value;
    }

    public int getStatus() {
        return status;
    }

    public void setContentType(String value) {
        if (value == null) {
            contentType = null;
            return;
        }
        String charset = Request.charset(value);
        if (charset != null && bodyMode != 2) {
            characterEncoding = charset;
            encodingSet = true;
            contentType = value;
        } else if (charset == null && encodingSet) {
            contentType = value + ";charset=" + characterEncoding;
        } else {
            contentType = value;
        }
    }

    /**
     * Explicitly set (directly or through the content type), else ISO-8859-1 as
     * the spec requires.
     */
    public String getCharacterEncoding() {
        return encodingSet ? characterEncoding : "ISO-8859-1";
    }

    public void setCharacterEncoding(String encoding) {
        if (bodyMode == 2 || encoding == null) {
            return;
        }
        characterEncoding = encoding;
        encodingSet = true;
        if (contentType != null) {
            int semicolon = contentType.indexOf(';');
            contentType = (semicolon < 0 ? contentType : contentType.substring(0, semicolon))
                          + ";charset="
                          + encoding;
        }
    }

    public void setCharacterEncoding(Charset encoding) {
        setCharacterEncoding(encoding.name());
    }

    public void setLocale(Locale value) {
        locale = value;
    }

    public Locale getLocale() {
        return locale == null ? Locale.getDefault() : locale;
    }

    public String getContentType() {
        return contentType;
    }

    public void setContentLength(int length) {}

    public void setContentLengthLong(long length) {}

    public void setIntHeader(String name, int value) {
        setHeader(name, Integer.toString(value));
    }

    public void addIntHeader(String name, int value) {
        addHeader(name, Integer.toString(value));
    }

    public String getHeader(String name) {
        if (name.equalsIgnoreCase("Content-Type")) {
            return contentType;
        }
        for (var e : headers.entrySet()) {
            if (e.getKey().equalsIgnoreCase(name)) {
                return e.getValue().get(0);
            }
        }
        return null;
    }

    public Collection<String> getHeaders(String name) {
        if (name.equalsIgnoreCase("Content-Type")) {
            return contentType == null ? List.of() : List.of(contentType);
        }
        for (var e : headers.entrySet()) {
            if (e.getKey().equalsIgnoreCase(name)) {
                return List.copyOf(e.getValue());
            }
        }
        return List.of();
    }

    public Collection<String> getHeaderNames() {
        List<String> names = new ArrayList<>(headers.keySet());
        if (contentType != null) {
            names.add("Content-Type");
        }
        return names;
    }

    /**
     * {@code Set-Cookie} from the cookie's name, value and attributes (Servlet
     * 6 keeps Path, Domain, Secure, ... there).
     */
    public void addCookie(Cookie cookie) {
        StringBuilder b = new StringBuilder(cookie.getName())
                .append('=')
                .append(cookie.getValue() == null ? "" : cookie.getValue());
        for (Entry<String, String> a : cookie.getAttributes().entrySet()) {
            b.append("; ").append(a.getKey());
            if (!a.getValue().isEmpty()) {
                b.append('=').append(a.getValue());
            }
        }
        addHeader("Set-Cookie", b.toString());
    }

    public void sendRedirect(String location, int status, boolean clearBuffer) {
        if (clearBuffer) {
            resetBuffer();
        }
        this.status = status;
        setHeader("Location", location);
    }

    public void sendRedirect(String location, int status) {
        sendRedirect(location, status, true);
    }

    public void sendRedirect(String location, boolean clearBuffer) {
        sendRedirect(location, 302, clearBuffer);
    }

    public void sendRedirect(String location) {
        sendRedirect(location, 302, true);
    }

    /** No sessions, so URLs are never rewritten. */
    public String encodeURL(String url) {
        return url;
    }

    public String encodeRedirectURL(String url) {
        return url;
    }

    public int getBufferSize() {
        return out.bytes().length;
    }

    /**
     * The buffer grows as needed and nothing is sent before completion, so
     * there is nothing to size.
     */
    public void setBufferSize(int size) {}

    /**
     * Responses carry a Content-Length and go out in one write when the
     * exchange completes, so a flush cannot send part of one early; the
     * response stays uncommitted until then.
     */
    public void flushBuffer() {}

    /** Trailers need chunked encoding, which this container does not send. */
    public void setTrailerFields(Supplier<Map<String, String>> supplier) {
        throw new IllegalStateException("trailers need chunked transfer encoding");
    }

    public Supplier<Map<String, String>> getTrailerFields() {
        return null;
    }

    public void setHeader(String name, String value) {
        if (name.equalsIgnoreCase("Content-Type")) {
            contentType = value;
            return;
        }
        if (name.equalsIgnoreCase("Content-Length")) {
            return;
        }
        headers.entrySet().removeIf(e -> e.getKey().equalsIgnoreCase(name));
        headers.put(name, new ArrayList<>(List.of(value)));
    }

    public void addHeader(String name, String value) {
        if (name.equalsIgnoreCase("Content-Type") || name.equalsIgnoreCase("Content-Length")) {
            setHeader(name, value);
            return;
        }
        String key = headers.keySet()
                            .stream()
                            .filter(k -> k.equalsIgnoreCase(name))
                            .findFirst()
                            .orElse(name);
        headers.computeIfAbsent(key, k -> new ArrayList<>()).add(value);
    }

    public ServletOutputStream getOutputStream() {
        if (bodyMode == 2) {
            throw new IllegalStateException("getWriter() already called");
        }
        bodyMode = 1;
        return stream;
    }

    public PrintWriter getWriter() {
        if (bodyMode == 1) {
            throw new IllegalStateException("getOutputStream() already called");
        }
        bodyMode = 2;
        return writer;
    }

    /**
     * Encodes writer output into the body: UTF-8 and ISO-8859-1 directly, other
     * charsets through the JDK encoder.
     */
    private void text(CharBuffer chars) {
        String enc = getCharacterEncoding();
        if (enc.equalsIgnoreCase("UTF-8")) {
            while (chars.hasRemaining()) {
                char c = chars.get();
                if (c < 0x80) {
                    out.put(c);
                } else if (c < 0x800) {
                    out.put(0xc0 | c >> 6);
                    out.put(0x80 | c & 63);
                } else if (Character.isHighSurrogate(c) && chars.hasRemaining() && Character.isLowSurrogate(chars.get(chars.position()))) {
                    int cp = Character.toCodePoint(c, chars.get());
                    out.put(0xf0 | cp >> 18);
                    out.put(0x80 | cp >> 12 & 63);
                    out.put(0x80 | cp >> 6 & 63);
                    out.put(0x80 | cp & 63);
                } else if (Character.isSurrogate(c)) {
                    out.put('?');
                } else {
                    out.put(0xe0 | c >> 12);
                    out.put(0x80 | c >> 6 & 63);
                    out.put(0x80 | c & 63);
                }
            }
        } else if (enc.equalsIgnoreCase("ISO-8859-1")) {
            while (chars.hasRemaining()) {
                char c = chars.get();
                out.put(c < 256 ? c : '?');
            }
        } else {
            ByteBuffer b = Charset.forName(enc).encode(chars);
            out.raw(b.array(), b.arrayOffset() + b.position(), b.remaining());
        }
    }
}
