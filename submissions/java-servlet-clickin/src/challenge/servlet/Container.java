package challenge.servlet;

import java.io.IOException;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;
import java.lang.reflect.Proxy;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.concurrent.ConcurrentHashMap;

import jakarta.servlet.ServletConfig;
import jakarta.servlet.ServletContext;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.MappingMatch;

/**
 * Servlet mapping and dispatch. Patterns follow the Servlet spec subset this
 * container supports: exact ({@code /a/b}), path prefix ({@code /a/b/*}) and
 * default ({@code /}). Exact beats prefix, the longest prefix wins, then
 * default.
 *
 * <p>Lookup is a hash of the request path's first N segments (one probe per
 * registered depth, deepest first) and an equality check on the stored pattern
 * bytes, so dispatch cost does not grow with the number of servlets.
 */
public final class Container {
    private static final VarHandle LONG = MethodHandles.byteArrayViewVarHandle(long[].class, ByteOrder.LITTLE_ENDIAN);
    private static final long SLASHES = 0x2f2f2f2f2f2f2f2fL;
    private static final long LOW7 = 0x7f7f7f7f7f7f7f7fL;

    private static final class Entry {
        final byte[] bytes;
        final int length;
        HttpServlet exact;
        HttpServlet prefix;
        String exactPattern;
        String prefixPattern;

        Entry(byte[] path) {
            length = path.length;
            bytes = Arrays.copyOf(path, path.length + 8);
        }
    }

    private final List<Entry> entries = new ArrayList<>();
    private final Map<String, Object> attributes = new ConcurrentHashMap<>();

    /**
     * The one context: root path, version, attributes and logging. Everything a
     * deployment descriptor or dynamic registration would provide (other
     * servlets, filters, listeners, resources, sessions) is not available here
     * and throws.
     */
    private final ServletContext context = (ServletContext) Proxy.newProxyInstance(Container.class.getClassLoader(), new Class<?>[] {ServletContext.class},
            (proxy, method, a) -> switch (method.getName()) {
                        case "getContextPath", "getServletContextName" -> "";
                        case "getServerInfo" -> "challenge/1";
                        case "getMajorVersion", "getEffectiveMajorVersion" -> 6;
                        case "getMinorVersion", "getEffectiveMinorVersion" -> 1;
                        case "getContext" -> "/".equals(a[0]) || "".equals(a[0])
                                ? proxy
                                : null;
                        case "getAttribute" -> attributes.get((String) a[0]);
                        case "getAttributeNames" -> Collections.enumeration(attributes.keySet());
                        case "setAttribute" -> a[1] == null ? attributes.remove((String) a[0]) : attributes.put((String) a[0], a[1]);
                        case "removeAttribute" -> attributes.remove((String) a[0]);
                        case "getInitParameter", "getMimeType", "getRequestDispatcher", "getNamedDispatcher", "getResource", "getResourceAsStream", "getRealPath" ->
                                null;
                        case "getInitParameterNames" -> Collections.emptyEnumeration();
                        case "getRequestCharacterEncoding" -> "UTF-8";
                        case "getResponseCharacterEncoding" -> null;
                        case "getClassLoader" -> Container.class.getClassLoader();
                        case "getVirtualServerName" -> "localhost";
                        case "log" -> {
                            System.err.println(a[0]);
                            if (a.length > 1 && a[1] instanceof Throwable t) {
                                t.printStackTrace();
                            }
                            yield null;
                        }
                        case "hashCode" -> System.identityHashCode(proxy);
                        case "equals" -> proxy == a[0];
                        case "toString" -> "ServletContext[/]";
                        default -> throw new UnsupportedOperationException("ServletContext." + method.getName());
                    });

    private HttpServlet defaultServlet;
    private HttpServlet errorServlet;
    private Entry[] table = new Entry[1];
    private int[] depths = {};
    private long multiplier;
    private int shift = 64;

    /**
     * Registers a servlet for an exact, prefix ({@code /*}) or default ({@code
     * /}) pattern, initializing it on first registration; one servlet may serve
     * several patterns.
     */
    public void addServlet(String pattern, HttpServlet servlet) throws ServletException {
        if (!pattern.startsWith("/")) {
            throw new IllegalArgumentException("unsupported pattern: " + pattern);
        }
        if (servlet.getServletConfig() == null) {
            servlet.init(config(servlet.getClass().getSimpleName()));
        }
        if (pattern.equals("/")) {
            defaultServlet = servlet;
            return;
        }
        boolean prefix = pattern.endsWith("/*");
        String path = prefix ? pattern.substring(0, pattern.length() - 2) : pattern;
        if (path.isEmpty()
                || path.endsWith("/")
                || path.contains("//")
                || path.contains("*")) {
            throw new IllegalArgumentException("unsupported pattern: " + pattern);
        }
        byte[] bytes = path.getBytes(StandardCharsets.UTF_8);
        Entry entry = entries.stream()
                             .filter(e -> Arrays.equals(e.bytes, 0, e.length, bytes, 0, bytes.length))
                             .findFirst()
                             .orElse(null);
        if (entry == null) {
            entries.add(entry = new Entry(bytes));
        }
        if (prefix) {
            entry.prefix = servlet;
            entry.prefixPattern = pattern;
        } else {
            entry.exact = servlet;
            entry.exactPattern = pattern;
        }
        rebuild();
    }

    /**
     * Servlet that renders {@code sendError} responses, like an error-page
     * mapping.
     */
    public void setErrorServlet(HttpServlet servlet) throws ServletException {
        servlet.init(config(servlet.getClass().getSimpleName()));
        errorServlet = servlet;
    }

    ServletContext context() {
        return context;
    }

    HttpServlet errorServlet() {
        return errorServlet;
    }

    private void rebuild() {
        TreeSet<Integer> found = new TreeSet<>(Collections.reverseOrder());
        for (Entry e : entries) {
            found.add(depth(e));
        }
        depths = found.stream()
                      .mapToInt(Integer::intValue)
                      .toArray();
        for (int bits = Math.max(1, 64 - Long.numberOfLeadingZeros(entries.size() * 4L)); ; bits++) {
            for (long m = 0x9e3779b97f4a7c15L, tries = 0;
                 tries < 100_000;
                 m += 2, tries++) {
                Entry[] candidate = new Entry[1 << bits];
                boolean ok = true;
                for (Entry e : entries) {
                    int h = hash(e.bytes, 0, e.length, m, 64 - bits);
                    if (candidate[h] != null) {
                        ok = false;
                        break;
                    }
                    candidate[h] = e;
                }
                if (ok) {
                    table = candidate;
                    multiplier = m;
                    shift = 64 - bits;
                    return;
                }
            }
        }
    }

    private static int depth(Entry e) {
        int n = 0;
        for (int i = 0; i < e.length; i++) {
            n += e.bytes[i] == '/' ? 1 : 0;
        }
        return n;
    }

    /**
     * Word-at-a-time hash of b[from, from+length); reads up to 7 bytes past the
     * end.
     */
    private static int hash(byte[] b, int from, int length,
                            long m, int shift) {
        long h = length;
        for (int i = 0; i < length; i += 8) {
            long w = (long) LONG.get(b, from + i) & (-1L >>> ((8 - Math.min(length - i, 8)) << 3));
            h = (h ^ w) * m;
        }
        return (int) (h >>> shift);
    }

    /**
     * Maps the request to a servlet and runs it, or sends 404 when nothing is
     * mapped.
     */
    public void service(Request req, Response res) throws ServletException, IOException {
        HttpServlet servlet = map(req);
        if (servlet == null) {
            res.sendError(404);
            return;
        }
        servlet.service(req, res);
    }

    /**
     * The servlet mapped to the request's path, or null. Also records the path
     * split and the servlet path on it.
     */
    public HttpServlet map(Request req) {
        byte[] b = req.bytes();
        int[] end = req.segmentEnds;
        int count = segments(req, req.segmentStarts, end);
        req.segmentCount = count;
        req.method = Request.METHODS.id(b, 0, req.pathStart - 1);
        HttpServlet servlet = defaultServlet;
        int servletPathEnd = req.pathEnd;
        req.match = MappingMatch.DEFAULT;
        req.pattern = "/";
        for (int depth : depths) {
            if (depth > count) {
                continue;
            }
            int length = end[depth - 1] - req.pathStart;
            Entry e = table[hash(b, req.pathStart, length, multiplier, shift)];
            if (e == null || e.length != length || !Arrays.equals(b, req.pathStart, req.pathStart + length, e.bytes, 0,
                    length)) {
                continue;
            }
            if (depth == count && e.exact != null) {
                servlet = e.exact;
                req.match = MappingMatch.EXACT;
                req.pattern = e.exactPattern;
                break;
            }
            if (e.prefix != null) {
                servlet = e.prefix;
                servletPathEnd = end[depth - 1];
                req.match = MappingMatch.PATH;
                req.pattern = e.prefixPattern;
                break;
            }
        }
        req.servletPathEnd = servletPathEnd;
        req.servletName = servlet == null ? null : servlet.getServletName();
        return servlet;
    }

    // Branchless split: '/' bytes are found 8 at a time (exact zero-byte test on w^SLASHES), stored to end[] with
    // unconditional writes, and every invalid case is folded into a mask. Only the word loop's trip count depends on
    // the input. Reading 8 bytes at any i<limit stays in bounds: Loop only accepts request lines ending " HTTP/1.1".
    // More than 4 slashes in one word implies an empty segment, so leftover bits mark the path invalid.
    public static int segments(Request r, int[] start, int[] end) {
        byte[] b = r.bytes();
        int p = r.pathOffset() + 1;
        int limit = r.pathOffset() + r.pathLength();
        int last = end.length - 1;
        int n = 0;
        long leftover = 0;
        for (int i = p; i < limit; i += 8) {
            long x = (long) LONG.get(b, i) ^ SLASHES;
            long m = ~(((x & LOW7) + LOW7) | x | LOW7) & (-1L >>> ((8 - Math.min(limit - i, 8)) << 3));
            for (int k = 0; k < 4; k++) {
                end[Math.min(n, last)] = i + (Long.numberOfTrailingZeros(m) >>> 3);
                n += (int) ((m | -m) >>> 63);
                m &= m - 1;
            }
            leftover |= m;
        }
        end[Math.min(n, last)] = limit;
        start[0] = p;
        for (int k = 1; k < start.length; k++) {
            start[k] = end[k - 1] + 1;
        }
        int count = (n + 1) & ((p - limit) >> 31);
        int invalid = (int) ((leftover | -leftover) >> 63) | ((start.length - count) >> 31);
        for (int k = 0; k < start.length; k++) {
            int d = end[k] - start[k];
            invalid |= ~((d | -d) >> 31) & ((k - count) >> 31);
        }
        return count | invalid;
    }

    private ServletConfig config(String name) {
        return new ServletConfig() {
            public String getServletName() {
                return name;
            }

            public ServletContext getServletContext() {
                return context;
            }

            public String getInitParameter(String key) {
                return null;
            }

            public Enumeration<String> getInitParameterNames() {
                return Collections.emptyEnumeration();
            }
        };
    }
}
