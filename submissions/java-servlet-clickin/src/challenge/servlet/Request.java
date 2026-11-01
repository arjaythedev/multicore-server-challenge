package challenge.servlet;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.UnsupportedEncodingException;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.security.Principal;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Collections;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Locale.LanguageRange;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;

import challenge.JsonWriter;
import challenge.WordTable;
import challenge.http.Loop;
import challenge.servlet.Direct.Local;
import challenge.servlet.Direct.Locals;
import jakarta.servlet.AsyncContext;
import jakarta.servlet.DispatcherType;
import jakarta.servlet.ReadListener;
import jakarta.servlet.RequestDispatcher;
import jakarta.servlet.ServletConnection;
import jakarta.servlet.ServletContext;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletInputStream;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletRequestWrapper;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.Cookie;
import jakarta.servlet.http.HttpServletMapping;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;
import jakarta.servlet.http.HttpUpgradeHandler;
import jakarta.servlet.http.MappingMatch;
import jakarta.servlet.http.Part;
import jakarta.servlet.http.PushBuilder;

public final class Request implements HttpServletRequest, Direct {
    /**
     * Method names returned by getMethod(), indexed by {@link #method}; 0 is
     * any other token.
     */
    static final String[] METHOD_NAMES = {null, "GET", "HEAD", "POST", "PUT", "DELETE",
            "OPTIONS", "TRACE", "PATCH", "CONNECT"};

    static final WordTable METHODS = new WordTable(Arrays.copyOfRange(METHOD_NAMES, 1, METHOD_NAMES.length));
    static final int HEAD = 2;
    public byte[] data;
    public int pathStart;
    public int pathEnd;
    public int queryStart;
    public int queryEnd;
    public int authStart = -1;
    public int authEnd;
    public int bodyStart;
    public int bodyLength;
    public boolean gzip;
    public boolean close;
    public boolean multipleAuthorization;
    private int[] headerOffsets = new int[64];
    private int headerCount;
    private final Map<String, Object> attributes = new HashMap<>();
    private Map<String, String[]> parameters;
    private final Loop loop;
    private Response response;
    private Async async;
    private boolean started;
    boolean redispatch;
    final int[] segmentStarts = new int[6];
    final int[] segmentEnds = new int[6];

    /**
     * Path segment count from the container's split, or -1 for a path the
     * container will not map.
     */
    int segmentCount;

    int method;
    int servletPathEnd;
    private Object slot;
    private Locals locals;

    /** Socket of the connection this request came on; set by the loop. */
    public int fd = -1;

    MappingMatch match;
    String pattern;
    String servletName;
    DispatcherType dispatcherType = DispatcherType.REQUEST;
    int errorStatus;
    String errorMessage;
    private static final AtomicInteger CREATED = new AtomicInteger();
    private final int index = CREATED.incrementAndGet();
    private long serial;
    private String characterEncoding;
    private Cookie[] cookies;
    private InetSocketAddress remote;
    private InetSocketAddress local;
    private int bodyRead;

    /** 0 nothing taken yet, 1 getInputStream, 2 getReader. */
    private int bodyMode;

    private BufferedReader reader;
    private final ServletInputStream input = new ServletInputStream() {
        public int read() {
            return bodyRead < bodyLength ? data[bodyStart + bodyRead++] & 255 : -1;
        }

        public int read(byte[] b, int off, int len) {
            if (bodyRead >= bodyLength) {
                return len == 0 ? 0 : -1;
            }
            int n = Math.min(len, bodyLength - bodyRead);
            System.arraycopy(data, bodyStart + bodyRead, b, off, n);
            bodyRead += n;
            return n;
        }

        public int available() {
            return bodyLength - bodyRead;
        }

        public boolean isFinished() {
            return bodyRead >= bodyLength;
        }

        public boolean isReady() {
            return true;
        }

        /**
         * The whole body is in memory before the servlet runs, so the listener
         * is called back immediately.
         */
        public void setReadListener(ReadListener l) {
            try {
                if (bodyRead < bodyLength) {
                    l.onDataAvailable();
                }
                l.onAllDataRead();
            } catch (IOException e) {
                l.onError(e);
            }
        }
    };
    private final ServletConnection connection = new ServletConnection() {
        public String getConnectionId() {
            return Integer.toString(fd);
        }

        public String getProtocol() {
            return "HTTP/1.1";
        }

        public String getProtocolConnectionId() {
            return "";
        }

        public boolean isSecure() {
            return false;
        }
    };

    public Request(Loop loop) {
        this.loop = loop;
    }

    public void init(Response response) {
        this.response = response;
        this.async = new Async(this, response);
    }

    public void reset() {
        data = null;
        serial++;
        dispatcherType = DispatcherType.REQUEST;
        errorStatus = 0;
        errorMessage = null;
        characterEncoding = null;
        cookies = null;
        remote = local = null;
        bodyRead = bodyMode = 0;
        reader = null;
        headerCount = 0;
        attributes.clear();
        parameters = null;
        started = false;
        redispatch = false;
        authStart = -1;
        gzip = close = multipleAuthorization = false;
    }

    public void header(int nameStart, int nameEnd, int valueStart,
                       int valueEnd) {
        if (headerCount + 4 > headerOffsets.length) {
            headerOffsets = Arrays.copyOf(headerOffsets, headerOffsets.length * 2);
        }
        headerOffsets[headerCount++] = nameStart;
        headerOffsets[headerCount++] = nameEnd;
        headerOffsets[headerCount++] = valueStart;
        headerOffsets[headerCount++] = valueEnd;
    }

    public boolean multipleAuthorization() {
        return multipleAuthorization;
    }

    public int segmentCount() {
        return segmentCount;
    }

    public int segmentStart(int index) {
        return segmentStarts[index];
    }

    public int segmentEnd(int index) {
        return segmentEnds[index];
    }

    public Object slot() {
        return slot;
    }

    public void slot(Object value) {
        slot = value;
    }

    /** The loop's values; a request without a loop (unit tests) keeps its own. */
    public <T> T local(Local<T> key) {
        if (loop != null) {
            return loop.locals().get(key);
        }
        if (locals == null) {
            locals = new Locals();
        }
        return locals.get(key);
    }

    public JsonWriter output() {
        return response.jsonOut();
    }

    Response response() {
        return response;
    }

    Loop loop() {
        return loop;
    }

    public byte[] bytes() {
        return data;
    }

    public int pathOffset() {
        return pathStart;
    }

    public int pathLength() {
        return pathEnd - pathStart;
    }

    public int queryOffset() {
        return queryStart;
    }

    public int queryLength() {
        return queryEnd - queryStart;
    }

    public int authorizationOffset() {
        return authStart;
    }

    public int authorizationLength() {
        return authStart < 0 ? 0 : authEnd - authStart;
    }

    public int bodyOffset() {
        return bodyStart;
    }

    public int bodyLength() {
        return bodyLength;
    }

    /** The unwrapped container request behind any {@link ServletRequestWrapper}s. */
    static Request of(ServletRequest request) {
        while (request instanceof ServletRequestWrapper w) {
            request = w.getRequest();
        }
        return (Request) request;
    }

    public boolean isHead() {
        return method == HEAD;
    }

    public String getMethod() {
        String name = METHOD_NAMES[method];
        return name != null ? name : new String(data, 0, pathStart - 1, StandardCharsets.ISO_8859_1);
    }

    public String getProtocol() {
        return "HTTP/1.1";
    }

    public String getScheme() {
        return "http";
    }

    public String getContextPath() {
        return "";
    }

    public String getServletPath() {
        return new String(data, pathStart, servletPathEnd - pathStart, StandardCharsets.UTF_8);
    }

    public String getPathInfo() {
        return servletPathEnd == pathEnd ? null : new String(data, servletPathEnd, pathEnd - servletPathEnd, StandardCharsets.UTF_8);
    }

    public Enumeration<String> getHeaders(String name) {
        List<String> values = new ArrayList<>();
        for (int i = 0; i < headerCount; i += 4) {
            if (nameIs(i, name)) {
                values.add(new String(data, headerOffsets[i + 2], headerOffsets[i + 3] - headerOffsets[i + 2], StandardCharsets.ISO_8859_1));
            }
        }
        return Collections.enumeration(values);
    }

    public Enumeration<String> getHeaderNames() {
        Set<String> names = new LinkedHashSet<>();
        for (int i = 0; i < headerCount; i += 4) {
            names.add(new String(data, headerOffsets[i], headerOffsets[i + 1] - headerOffsets[i], StandardCharsets.ISO_8859_1));
        }
        return Collections.enumeration(names);
    }

    public long getDateHeader(String name) {
        String value = getHeader(name);
        if (value == null) {
            return -1;
        }
        try {
            return ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME)
                    .toInstant()
                    .toEpochMilli();
        } catch (DateTimeParseException e) {
            throw new IllegalArgumentException(e);
        }
    }

    private boolean nameIs(int i, String name) {
        int a = headerOffsets[i];
        if (headerOffsets[i + 1] - a != name.length()) {
            return false;
        }
        for (int j = 0; j < name.length(); j++) {
            if (Character.toLowerCase((char) (data[a + j] & 255)) != Character.toLowerCase(name.charAt(j))) {
                return false;
            }
        }
        return true;
    }

    public String getRequestURI() {
        return new String(data, pathStart, pathEnd - pathStart, StandardCharsets.ISO_8859_1);
    }

    public String getQueryString() {
        return queryStart < 0 ? null : new String(data, queryStart, queryEnd - queryStart, StandardCharsets.ISO_8859_1);
    }

    public String getHeader(String name) {
        String result = null;
        for (int i = 0; i < headerCount; i += 4) {
            if (nameIs(i, name)) {
                String value = new String(data, headerOffsets[i + 2], headerOffsets[i + 3] - headerOffsets[i + 2], StandardCharsets.ISO_8859_1);
                result = result == null ? value : result + ", " + value;
            }
        }
        return result;
    }

    public int getContentLength() {
        return bodyLength;
    }

    public long getContentLengthLong() {
        return bodyLength;
    }

    // The two error attributes sendError sets live in fields (no boxing, no map nodes per error response). Setting
    // or removing them through the API drops the field and falls back to the ordinary map.
    public Object getAttribute(String name) {
        if (errorStatus != 0 && name.equals(RequestDispatcher.ERROR_STATUS_CODE)) {
            return errorStatus;
        }
        if (errorMessage != null && name.equals(RequestDispatcher.ERROR_MESSAGE)) {
            return errorMessage;
        }
        return attributes.get(name);
    }

    public void setAttribute(String name, Object value) {
        if (value == null) {
            removeAttribute(name);
            return;
        }
        forgetError(name);
        attributes.put(name, value);
    }

    public void removeAttribute(String name) {
        forgetError(name);
        attributes.remove(name);
    }

    private void forgetError(String name) {
        if (name.equals(RequestDispatcher.ERROR_STATUS_CODE)) {
            errorStatus = 0;
        } else if (name.equals(RequestDispatcher.ERROR_MESSAGE)) {
            errorMessage = null;
        }
    }

    /**
     * Called by sendError: the status and message become the standard error
     * attributes.
     */
    void error(int status, String message) {
        attributes.remove(RequestDispatcher.ERROR_STATUS_CODE);
        attributes.remove(RequestDispatcher.ERROR_MESSAGE);
        errorStatus = status;
        errorMessage = message;
    }

    public Enumeration<String> getAttributeNames() {
        List<String> names = new ArrayList<>(attributes.keySet());
        if (errorStatus != 0) {
            names.add(RequestDispatcher.ERROR_STATUS_CODE);
        }
        if (errorMessage != null) {
            names.add(RequestDispatcher.ERROR_MESSAGE);
        }
        return Collections.enumeration(names);
    }

    public String getParameter(String name) {
        String[] v = getParameterMap().get(name);
        return v == null ? null : v[0];
    }

    public String[] getParameterValues(String name) {
        return getParameterMap().get(name);
    }

    public Enumeration<String> getParameterNames() {
        return Collections.enumeration(getParameterMap().keySet());
    }

    public Map<String, String[]> getParameterMap() {
        if (parameters == null) {
            parameters = new LinkedHashMap<>();
            String q = getQueryString();
            if (q != null && !q.isEmpty()) {
                for (String pair : q.split("&", -1)) {
                    int i = pair.indexOf('=');
                    String k = URLDecoder.decode(i < 0 ? pair : pair.substring(0, i), StandardCharsets.UTF_8);
                    String v = URLDecoder.decode(i < 0 ? "" : pair.substring(i + 1), StandardCharsets.UTF_8);
                    parameters.compute(k,
                            (x, old) -> {
                                if (old == null) {
                                    return new String[] {v};
                                }
                                String[] n = Arrays.copyOf(old, old.length + 1);
                                n[old.length] = v;
                                return n;
                            });
                }
            }
        }
        return Collections.unmodifiableMap(parameters);
    }

    public AsyncContext startAsync() {
        if (started) {
            throw new IllegalStateException();
        }
        started = true;
        return async;
    }

    public AsyncContext startAsync(ServletRequest r, ServletResponse s) {
        if (r != this || s != response) {
            throw new UnsupportedOperationException();
        }
        return startAsync();
    }

    public boolean isAsyncStarted() {
        return started;
    }

    /**
     * Async mode, or an {@code AsyncContext.dispatch()} still to run: the
     * exchange is not done when service returns.
     */
    public boolean asyncPending() {
        return started || redispatch;
    }

    public boolean isAsyncSupported() {
        return true;
    }

    public AsyncContext getAsyncContext() {
        if (!started) {
            throw new IllegalStateException();
        }
        return async;
    }

    void completed() {
        if (!started) {
            throw new IllegalStateException();
        }
        started = false;
    }

    public ServletInputStream getInputStream() {
        if (bodyMode == 2) {
            throw new IllegalStateException("getReader() already called");
        }
        bodyMode = 1;
        return input;
    }

    public BufferedReader getReader() throws UnsupportedEncodingException {
        if (bodyMode == 1) {
            throw new IllegalStateException("getInputStream() already called");
        }
        if (reader == null) {
            Charset charset;
            try {
                charset = Charset.forName(getCharacterEncoding());
            } catch (IllegalArgumentException e) {
                throw new UnsupportedEncodingException(getCharacterEncoding());
            }
            bodyMode = 2;
            reader = new BufferedReader(new InputStreamReader(input, charset));
        }
        return reader;
    }

    /**
     * Explicitly set, else the Content-Type charset, else UTF-8 (this
     * container's default request encoding).
     */
    public String getCharacterEncoding() {
        if (characterEncoding != null) {
            return characterEncoding;
        }
        String charset = charset(getContentType());
        return charset != null ? charset : "UTF-8";
    }

    public void setCharacterEncoding(String encoding) throws UnsupportedEncodingException {
        if (bodyMode == 2) {
            return;
        }
        if (!Charset.isSupported(encoding)) {
            throw new UnsupportedEncodingException(encoding);
        }
        characterEncoding = encoding;
    }

    public void setCharacterEncoding(Charset encoding) {
        if (bodyMode != 2) {
            characterEncoding = encoding.name();
        }
    }

    /** The charset parameter of a Content-Type value, or null. */
    static String charset(String contentType) {
        if (contentType == null) {
            return null;
        }
        // Scanned in place: setContentType("application/json") runs on every response and must not allocate.
        for (int semi = contentType.indexOf(';');
             semi >= 0;
             semi = contentType.indexOf(';', semi + 1)) {
            int p = semi + 1;
            while (p < contentType.length() && contentType.charAt(p) == ' ') {
                p++;
            }
            if (contentType.regionMatches(true, p, "charset=", 0, 8)) {
                int end = contentType.indexOf(';', p);
                String v = contentType.substring(p + 8,
                        end < 0 ? contentType.length() : end)
                                      .strip();
                return v.length() > 1 && v.startsWith("\"") && v.endsWith("\"")
                        ? v.substring(1, v.length() - 1)
                        : v;
            }
        }
        return null;
    }

    public String getContentType() {
        return getHeader("Content-Type");
    }

    public int getIntHeader(String name) {
        String value = getHeader(name);
        return value == null ? -1 : Integer.parseInt(value.strip());
    }

    public Cookie[] getCookies() {
        if (cookies == null) {
            List<Cookie> list = new ArrayList<>();
            for (Enumeration<String> e = getHeaders("Cookie"); e.hasMoreElements(); ) {
                for (String pair : e.nextElement().split(";")) {
                    int eq = pair.indexOf('=');
                    String name = (eq < 0 ? pair : pair.substring(0, eq)).strip();
                    if (name.isEmpty()) {
                        continue;
                    }
                    String value = eq < 0 ? "" : pair.substring(eq + 1).strip();
                    if (value.length() > 1 && value.startsWith("\"") && value.endsWith("\"")) {
                        value = value.substring(1, value.length() - 1);
                    }
                    try {
                        list.add(new Cookie(name, value));
                    } catch (IllegalArgumentException ignored) {
                        // not a valid cookie name: skipped, as Tomcat does
                    }
                }
            }
            cookies = list.toArray(new Cookie[0]);
        }
        return cookies.length == 0 ? null : cookies.clone();
    }

    /** Accept-Language tags by descending q, or the server default locale. */
    public Enumeration<Locale> getLocales() {
        String header = getHeader("Accept-Language");
        List<Locale> locales = new ArrayList<>();
        if (header != null) {
            try {
                for (LanguageRange range : LanguageRange.parse(header)) {
                    if (!range.getRange().equals("*")) {
                        locales.add(Locale.forLanguageTag(range.getRange()));
                    }
                }
            } catch (IllegalArgumentException ignored) {
                // malformed header: fall back to the default
            }
        }
        if (locales.isEmpty()) {
            locales.add(Locale.getDefault());
        }
        return Collections.enumeration(locales);
    }

    public Locale getLocale() {
        return getLocales().nextElement();
    }

    private InetSocketAddress remote() {
        if (remote == null && loop != null && fd >= 0) {
            remote = loop.address(fd, true);
        }
        return remote;
    }

    private InetSocketAddress local() {
        if (local == null && loop != null && fd >= 0) {
            local = loop.address(fd, false);
        }
        return local;
    }

    public String getRemoteAddr() {
        InetSocketAddress a = remote();
        return a == null ? null : a.getAddress().getHostAddress();
    }

    /**
     * The address, not a reverse lookup (like Tomcat's default
     * enableLookups=false).
     */
    public String getRemoteHost() {
        return getRemoteAddr();
    }

    public int getRemotePort() {
        InetSocketAddress a = remote();
        return a == null ? -1 : a.getPort();
    }

    public String getLocalAddr() {
        InetSocketAddress a = local();
        return a == null ? null : a.getAddress().getHostAddress();
    }

    public String getLocalName() {
        return getLocalAddr();
    }

    public int getLocalPort() {
        InetSocketAddress a = local();
        return a == null ? -1 : a.getPort();
    }

    /** Host header without the port, else the local address. */
    public String getServerName() {
        String host = getHeader("Host");
        if (host == null || host.isEmpty()) {
            return getLocalName();
        }
        int colon = host.startsWith("[") ? host.indexOf("]:") + 1 : host.lastIndexOf(':');
        return colon > 0 ? host.substring(0, colon) : host;
    }

    public int getServerPort() {
        String host = getHeader("Host");
        if (host == null || host.isEmpty()) {
            return getLocalPort();
        }
        int colon = host.startsWith("[") ? host.indexOf("]:") + 1 : host.lastIndexOf(':');
        if (colon <= 0) {
            return 80;
        }
        try {
            return Integer.parseInt(host.substring(colon + 1));
        } catch (NumberFormatException e) {
            return 80;
        }
    }

    public StringBuffer getRequestURL() {
        StringBuffer url = new StringBuffer("http://").append(getServerName());
        int port = getServerPort();
        if (port != 80) {
            url.append(':').append(port);
        }
        return url.append(getRequestURI());
    }

    public boolean isSecure() {
        return false;
    }

    public DispatcherType getDispatcherType() {
        return dispatcherType;
    }

    public HttpServletMapping getHttpServletMapping() {
        String path = getServletPath();
        String value = switch (match) {
            case EXACT -> path.substring(1);
            case PATH -> {
                String info = getPathInfo();
                yield info == null ? "" : info.substring(1);
            }
            default -> "";
        };
        MappingMatch m = match;
        String p = pattern;
        String name = servletName;
        return new HttpServletMapping() {
            public String getMatchValue() {
                return value;
            }

            public String getPattern() {
                return p;
            }

            public String getServletName() {
                return name;
            }

            public MappingMatch getMappingMatch() {
                return m;
            }
        };
    }

    public ServletContext getServletContext() {
        return response.container().context();
    }

    /** No request dispatching in this container; the spec allows null. */
    public RequestDispatcher getRequestDispatcher(String path) {
        return null;
    }

    public String getRequestId() {
        return index + "-" + serial;
    }

    public String getProtocolRequestId() {
        return "";
    }

    public ServletConnection getServletConnection() {
        return connection;
    }

    public String getPathTranslated() {
        return null;
    }

    public String getAuthType() {
        return null;
    }

    public String getRemoteUser() {
        return null;
    }

    public Principal getUserPrincipal() {
        return null;
    }

    public boolean isUserInRole(String role) {
        return false;
    }

    /** No login mechanism is configured: the request stays unauthenticated. */
    public boolean authenticate(HttpServletResponse res) throws IOException {
        res.sendError(401);
        return false;
    }

    public void login(String user, String password) throws ServletException {
        throw new ServletException("no login mechanism configured");
    }

    public void logout() {}

    /** No sessions: there is never a current one, and none can be created. */
    public HttpSession getSession(boolean create) {
        if (create) {
            throw new IllegalStateException("sessions are not supported");
        }
        return null;
    }

    public HttpSession getSession() {
        return getSession(true);
    }

    public String getRequestedSessionId() {
        return null;
    }

    public boolean isRequestedSessionIdValid() {
        return false;
    }

    public boolean isRequestedSessionIdFromCookie() {
        return false;
    }

    public boolean isRequestedSessionIdFromURL() {
        return false;
    }

    public String changeSessionId() {
        throw new IllegalStateException("no session");
    }

    /**
     * No multipart configuration on any servlet, which the spec answers with
     * IllegalStateException.
     */
    public Collection<Part> getParts() {
        throw new IllegalStateException("no multipart configuration");
    }

    public Part getPart(String name) {
        throw new IllegalStateException("no multipart configuration");
    }

    /** Chunked trailers are read and dropped by the parser. */
    public Map<String, String> getTrailerFields() {
        return Map.of();
    }

    public boolean isTrailerFieldsReady() {
        return true;
    }

    /** Server push is HTTP/2 only; the spec answers null when it is unavailable. */
    @Deprecated
    public PushBuilder newPushBuilder() {
        return null;
    }

    public <T extends HttpUpgradeHandler> T upgrade(Class<T> handler) throws ServletException {
        throw new ServletException("protocol upgrade is not supported");
    }
}
