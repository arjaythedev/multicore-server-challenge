package conduit;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

/** Routing and request validation on the HTTP loop; everything that needs Postgres or bcrypt becomes a Job. */
final class Api {
    private static final int GET = 1, POST = 2, PUT = 3, DELETE = 4;

    private static final byte[] E401 = Http.error(401, "unauthorized");
    private static final byte[] E404 = Http.error(404, "not found");

    private static byte[] e422(String msg) {
        return Http.error(422, msg);
    }

    /** Returns the response now, or null when a job will answer later. */
    static byte[] handle(Http.Conn c, byte[] a, int mOff, int mEnd, int tOff, int tEnd, int authOff, int authLen,
                         int bodyOff, int bodyLen) {
        int method = method(a, mOff, mEnd - mOff);
        int q = tOff;
        while (q < tEnd && a[q] != '?') q++;
        // path: /api/<seg>...
        if (q - tOff < 5 || a[tOff] != '/' || a[tOff + 1] != 'a' || a[tOff + 2] != 'p' || a[tOff + 3] != 'i' || a[tOff + 4] != '/')
            return E404;
        String[] seg = new String[5];
        int ns = 0;
        int s = tOff + 5;
        for (int i = s; i <= q; i++) {
            if (i == q || a[i] == '/') {
                if (ns == 5) return E404;
                seg[ns++] = decode(a, s, i, false);
                s = i + 1;
            }
        }
        if (ns > 0 && seg[ns - 1] != null && seg[ns - 1].isEmpty()) ns--; // trailing slash
        for (int i = 0; i < ns; i++) if (seg[i] == null || seg[i].isEmpty()) return E404;
        if (ns == 0) return E404;

        // auth: 0 none presented, -1 invalid, else the user id
        long viewer = 0;
        if (authOff >= 0) {
            if (authLen > 6 && a[authOff] == 'T' && a[authOff + 1] == 'o' && a[authOff + 2] == 'k' && a[authOff + 3] == 'e'
                    && a[authOff + 4] == 'n' && a[authOff + 5] == ' ') {
                viewer = Jwt.verify(a, authOff + 6, authLen - 6);
                if (viewer == 0) viewer = -1;
            } else viewer = -1;
        }

        String s0 = seg[0];
        switch (s0) {
            case "tags":
                if (ns == 1 && method == GET) return read(new Job(Job.TAGS, c, 0));
                return E404;
            case "users":
                if (method != POST) return E404;
                if (ns == 1) return register(c, a, bodyOff, bodyLen);
                if (ns == 2 && seg[1].equals("login")) return login(c, a, bodyOff, bodyLen);
                return E404;
            case "user":
                if (ns != 1) return E404;
                if (method == GET) {
                    if (viewer <= 0) return E401;
                    Job j = new Job(Job.USER, c, viewer);
                    j.token = new String(a, authOff + 6, authLen - 6, StandardCharsets.US_ASCII);
                    return read(j);
                }
                if (method == PUT) {
                    if (viewer <= 0) return E401;
                    return updateUser(c, viewer, new String(a, authOff + 6, authLen - 6, StandardCharsets.US_ASCII), a, bodyOff, bodyLen);
                }
                return E404;
            case "profiles":
                if (ns == 2 && method == GET) {
                    if (viewer < 0) return E401;
                    Job j = new Job(Job.PROFILE, c, viewer);
                    j.key = seg[1];
                    return read(j);
                }
                if (ns == 3 && seg[2].equals("follow") && (method == POST || method == DELETE)) {
                    if (viewer <= 0) return E401;
                    Job j = new Job(method == POST ? Job.FOLLOW : Job.UNFOLLOW, c, viewer);
                    j.key = seg[1];
                    return write(j);
                }
                return E404;
            case "articles":
                return articles(c, method, seg, ns, viewer, a, q, tEnd, bodyOff, bodyLen);
            default:
                return E404;
        }
    }

    private static byte[] articles(Http.Conn c, int method, String[] seg, int ns, long viewer, byte[] a, int q, int tEnd,
                                   int bodyOff, int bodyLen) {
        if (ns == 1) {
            if (method == GET) {
                if (viewer < 0) return E401;
                return list(c, viewer, a, q, tEnd, false);
            }
            if (method == POST) {
                if (viewer <= 0) return E401;
                return createArticle(c, viewer, a, bodyOff, bodyLen);
            }
            return E404;
        }
        String slug = seg[1];
        if (ns == 2) {
            if (method == GET && slug.equals("feed")) {
                if (viewer <= 0) return E401;
                return list(c, viewer, a, q, tEnd, true);
            }
            if (method == GET) {
                if (viewer < 0) return E401;
                Job j = new Job(Job.ARTICLE, c, viewer);
                j.key = slug;
                return read(j);
            }
            if (method == PUT) {
                if (viewer <= 0) return E401;
                return updateArticle(c, viewer, slug, a, bodyOff, bodyLen);
            }
            if (method == DELETE) {
                if (viewer <= 0) return E401;
                Job j = new Job(Job.DELETE_ARTICLE, c, viewer);
                j.key = slug;
                return write(j);
            }
            return E404;
        }
        String sub = seg[2];
        if (ns == 3 && sub.equals("favorite") && (method == POST || method == DELETE)) {
            if (viewer <= 0) return E401;
            Job j = new Job(method == POST ? Job.FAV : Job.UNFAV, c, viewer);
            j.key = slug;
            return write(j);
        }
        if (sub.equals("comments")) {
            if (ns == 3 && method == GET) {
                if (viewer < 0) return E401;
                Job j = new Job(Job.COMMENTS, c, viewer);
                j.key = slug;
                return read(j);
            }
            if (ns == 3 && method == POST) {
                if (viewer <= 0) return E401;
                Map<String, Object> m = Json.wrapped(a, bodyOff, bodyLen, "comment");
                if (m == null) return e422("comment is required");
                String body = Json.required(m, "body");
                if (body == null) return e422("body is required");
                Job j = new Job(Job.CREATE_COMMENT, c, viewer);
                j.key = slug;
                j.f1 = body;
                return write(j);
            }
            if (ns == 4 && method == DELETE) {
                if (viewer <= 0) return E401;
                long id = digits(seg[3]);
                if (id < 0) return E404;
                Job j = new Job(Job.DELETE_COMMENT, c, viewer);
                j.key = slug;
                j.id = id;
                return write(j);
            }
        }
        return E404;
    }

    private static byte[] list(Http.Conn c, long viewer, byte[] a, int q, int tEnd, boolean feed) {
        long lim = 20, off = 0;
        String tag = null, author = null, fav = null;
        boolean seenLim = false, seenOff = false;
        int p = q + 1;
        while (p < tEnd) {
            int e = p;
            while (e < tEnd && a[e] != '&') e++;
            int eq = p;
            while (eq < e && a[eq] != '=') eq++;
            String k = decode(a, p, eq, true);
            String v = eq < e ? decode(a, eq + 1, e, true) : "";
            if (k == null || v == null) return e422("bad query string");
            switch (k) {
                case "limit" -> {
                    if (!seenLim) {
                        seenLim = true;
                        lim = digits(v);
                        if (lim < 1 || lim > 100) return e422("limit must be an integer from 1 to 100");
                    }
                }
                case "offset" -> {
                    if (!seenOff) {
                        seenOff = true;
                        off = digits(v);
                        if (off < 0) return e422("offset must be a non-negative integer");
                    }
                }
                case "tag" -> {
                    if (tag == null) tag = v;
                }
                case "author" -> {
                    if (author == null) author = v;
                }
                case "favorited" -> {
                    if (fav == null) fav = v;
                }
                default -> {
                }
            }
            p = e + 1;
        }
        Job j;
        if (feed) j = new Job(Job.FEED, c, viewer);
        else if (tag != null && !tag.isEmpty()) {
            j = new Job(Job.TAG, c, viewer);
            j.key = tag;
        } else if (author != null && !author.isEmpty()) {
            j = new Job(Job.AUTHOR, c, viewer);
            j.key = author;
        } else if (fav != null && !fav.isEmpty()) {
            j = new Job(Job.FAVORITED, c, viewer);
            j.key = fav;
        } else j = new Job(Job.GLOBAL, c, viewer);
        j.lim = lim;
        j.off = off;
        return read(j);
    }

    /** A plain decimal (leading zeros fine) up to 2^53, or -1. */
    private static long digits(String s) {
        int n = s.length();
        if (n == 0 || n > 16) return -1;
        long v = 0;
        for (int i = 0; i < n; i++) {
            char ch = s.charAt(i);
            if (ch < '0' || ch > '9') return -1;
            v = v * 10 + (ch - '0');
        }
        return v;
    }

    private static byte[] register(Http.Conn c, byte[] a, int off, int len) {
        Map<String, Object> m = Json.wrapped(a, off, len, "user");
        if (m == null) return e422("user is required");
        String username = Json.required(m, "username"), email = Json.required(m, "email"), password = Json.required(m, "password");
        if (username == null || email == null || password == null) return e422("username, email and password are required");
        byte[] pw = password.getBytes(StandardCharsets.UTF_8);
        if (pw.length > 72) return e422("password is longer than 72 bytes");
        Job w = new Job(Job.REGISTER, c, 0);
        w.f1 = username;
        w.f2 = email;
        Job h = new Job(Job.HASH, c, 0);
        h.password = pw;
        h.then = w;
        Lanes.BCRYPT.push(h);
        return null;
    }

    private static byte[] login(Http.Conn c, byte[] a, int off, int len) {
        Map<String, Object> m = Json.wrapped(a, off, len, "user");
        if (m == null) return e422("user is required");
        String email = Json.required(m, "email"), password = Json.required(m, "password");
        if (email == null || password == null) return e422("email and password are required");
        Job j = new Job(Job.LOGIN, c, 0);
        j.key = email;
        j.password = password.getBytes(StandardCharsets.UTF_8);
        return read(j);
    }

    private static byte[] updateUser(Http.Conn c, long viewer, String token, byte[] a, int off, int len) {
        Map<String, Object> m = Json.wrapped(a, off, len, "user");
        if (m == null) return e422("user is required");
        String email = Json.optional(m, "email", false), username = Json.optional(m, "username", false),
                password = Json.optional(m, "password", false), bio = Json.optional(m, "bio", true),
                image = Json.optional(m, "image", true);
        if (email == Json.INVALID || username == Json.INVALID || password == Json.INVALID || bio == Json.INVALID
                || image == Json.INVALID) return e422("invalid user fields");
        Job w = new Job(Job.UPDATE_USER, c, viewer);
        w.token = token;
        w.f1 = email;
        w.f2 = username;
        w.f3 = bio;
        w.f4 = image;
        if (password != null) {
            byte[] pw = password.getBytes(StandardCharsets.UTF_8);
            if (pw.length > 72) return e422("password is longer than 72 bytes");
            Job h = new Job(Job.HASH, c, viewer);
            h.password = pw;
            h.then = w;
            Lanes.BCRYPT.push(h);
            return null;
        }
        return write(w);
    }

    private static byte[] createArticle(Http.Conn c, long viewer, byte[] a, int off, int len) {
        Map<String, Object> m = Json.wrapped(a, off, len, "article");
        if (m == null) return e422("article is required");
        String title = Json.required(m, "title"), description = Json.required(m, "description"), body = Json.required(m, "body");
        if (title == null || description == null || body == null) return e422("title, description and body are required");
        Object tl = m.get("tagList");
        String[] tags = new String[0];
        if (tl != null && tl != Json.NULL) {
            if (!(tl instanceof List<?> l)) return e422("tagList must be an array of strings");
            tags = new String[l.size()];
            for (int i = 0; i < tags.length; i++) {
                if (!(l.get(i) instanceof String t) || t.isEmpty()) return e422("tagList must be an array of non-empty strings");
                tags[i] = t;
            }
        }
        Job j = new Job(Job.CREATE_ARTICLE, c, viewer);
        j.f1 = title;
        j.f2 = description;
        j.f3 = body;
        j.tags = tags;
        return write(j);
    }

    private static byte[] updateArticle(Http.Conn c, long viewer, String slug, byte[] a, int off, int len) {
        Map<String, Object> m = Json.wrapped(a, off, len, "article");
        if (m == null) return e422("article is required");
        String title = Json.optional(m, "title", false), description = Json.optional(m, "description", false),
                body = Json.optional(m, "body", false);
        if (title == Json.INVALID || description == Json.INVALID || body == Json.INVALID) return e422("invalid article fields");
        Job j = new Job(Job.UPDATE_ARTICLE, c, viewer);
        j.key = slug;
        j.f1 = title;
        j.f2 = description;
        j.f3 = body;
        return write(j);
    }

    private static byte[] read(Job j) {
        Lanes.READS.push(j);
        return null;
    }

    private static byte[] write(Job j) {
        Lanes.WRITES.push(j);
        return null;
    }

    private static int method(byte[] a, int off, int len) {
        if (len == 3 && a[off] == 'G' && a[off + 1] == 'E' && a[off + 2] == 'T') return GET;
        if (len == 4 && a[off] == 'P' && a[off + 1] == 'O') return POST;
        if (len == 3 && a[off] == 'P' && a[off + 1] == 'U' && a[off + 2] == 'T') return PUT;
        if (len == 6 && a[off] == 'D') return DELETE;
        return 0;
    }

    /** Percent-decodes a[from, to) as UTF-8 ('+' is a space in query strings). Null on a bad escape. */
    private static String decode(byte[] a, int from, int to, boolean query) {
        boolean plain = true;
        for (int i = from; i < to; i++) {
            if (a[i] == '%' || (query && a[i] == '+')) {
                plain = false;
                break;
            }
        }
        if (plain) return new String(a, from, to - from, StandardCharsets.UTF_8);
        ByteArrayOutputStream o = new ByteArrayOutputStream(to - from);
        for (int i = from; i < to; i++) {
            byte b = a[i];
            if (b == '%') {
                if (i + 2 >= to) return null;
                int h = Character.digit(a[i + 1], 16), l = Character.digit(a[i + 2], 16);
                if (h < 0 || l < 0) return null;
                o.write(h << 4 | l);
                i += 2;
            } else if (query && b == '+') o.write(' ');
            else o.write(b);
        }
        return o.toString(StandardCharsets.UTF_8);
    }
}
