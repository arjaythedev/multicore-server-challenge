package conduit.api;

import conduit.auth.Bcrypt;
import conduit.auth.Jwt;
import conduit.http.Json;
import conduit.http.Out;
import conduit.http.Request;
import conduit.net.Conn;
import conduit.net.EventLoop;
import conduit.pg.PgPool;
import conduit.pg.Query;
import conduit.pg.Rows;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executor;
import java.util.function.Consumer;

import static conduit.http.HttpParser.DELETE;
import static conduit.http.HttpParser.GET;
import static conduit.http.HttpParser.POST;
import static conduit.http.HttpParser.PUT;

/**
 * Routes requests and implements the 19 endpoints (SPEC.md). Everything here runs on the request's event loop:
 * database and bcrypt results come back through the connection's executor. Reads go to the read pool; anything
 * that writes goes, whole, to the write pool, so writes never queue behind reads.
 */
public final class Api implements EventLoop.Handler {
    private static final Object INVALID = new Object();

    private final PgPool read;
    private final PgPool write;
    private final Executor bcrypt;

    public Api(PgPool read, PgPool write, Executor bcrypt) {
        this.read = read;
        this.write = write;
        this.bcrypt = bcrypt;
    }

    /** Declares every SQL statement; call before opening database connections. */
    public static void declareStatements() {
        Sql.init();
    }

    // ---------- routing ----------

    @Override
    public void handle(Conn c) {
        String path = c.path;
        if (!path.startsWith("/api/")) {
            c.error(404, "not found");
            return;
        }
        String[] s = path.substring(5).split("/", -1);
        for (int i = 0; i < s.length; i++) s[i] = Request.decode(s[i], 0, s[i].length(), false);
        int m = c.method;
        int n = s.length;
        switch (s[0]) {
            case "tags" -> {
                if (n == 1 && m == GET) {
                    tags(c);
                    return;
                }
            }
            case "users" -> {
                if (n == 1 && m == POST) {
                    register(c);
                    return;
                }
                if (n == 2 && m == POST && s[1].equals("login")) {
                    login(c);
                    return;
                }
            }
            case "user" -> {
                if (n == 1 && m == GET) {
                    if (auth(c, true)) getUser(c);
                    return;
                }
                if (n == 1 && m == PUT) {
                    if (auth(c, true)) updateUser(c);
                    return;
                }
            }
            case "profiles" -> {
                if (n == 2 && m == GET) {
                    if (auth(c, false)) profile(c, s[1]);
                    return;
                }
                if (n == 3 && s[2].equals("follow") && (m == POST || m == DELETE)) {
                    if (auth(c, true)) follow(c, s[1], m == POST);
                    return;
                }
            }
            case "articles" -> {
                if (n == 1 && m == GET) {
                    if (auth(c, false)) listArticles(c);
                    return;
                }
                if (n == 1 && m == POST) {
                    if (auth(c, true)) createArticle(c);
                    return;
                }
                if (n == 2 && m == GET && s[1].equals("feed")) {
                    if (auth(c, true)) feed(c);
                    return;
                }
                if (n == 2 && m == GET) {
                    if (auth(c, false)) getArticle(c, s[1]);
                    return;
                }
                if (n == 2 && m == PUT) {
                    if (auth(c, true)) updateArticle(c, s[1]);
                    return;
                }
                if (n == 2 && m == DELETE) {
                    if (auth(c, true)) deleteArticle(c, s[1]);
                    return;
                }
                if (n == 3 && s[2].equals("favorite") && (m == POST || m == DELETE)) {
                    if (auth(c, true)) favorite(c, s[1], m == POST);
                    return;
                }
                if (n == 3 && s[2].equals("comments") && m == GET) {
                    if (auth(c, false)) comments(c, s[1]);
                    return;
                }
                if (n == 3 && s[2].equals("comments") && m == POST) {
                    if (auth(c, true)) createComment(c, s[1]);
                    return;
                }
                if (n == 4 && s[2].equals("comments") && m == DELETE) {
                    if (auth(c, true)) deleteComment(c, s[1], s[3]);
                    return;
                }
            }
            default -> {
            }
        }
        c.error(404, "not found");
    }

    /**
     * Reads the token. With no Authorization header the viewer is anonymous (0), which is a 401 when required; a
     * header that is present but not a valid "Token <jwt>" is always a 401. Returns false if it replied.
     */
    private static boolean auth(Conn c, boolean required) {
        String h = c.auth;
        if (h == null) {
            if (!required) return true;
            c.error(401, "missing token");
            return false;
        }
        long id = -1;
        if (h.startsWith("Token ")) {
            String tok = h.substring(6).trim();
            id = Jwt.verify(tok);
            c.token = tok;
        }
        if (id <= 0) {
            c.error(401, "invalid token");
            return false;
        }
        c.viewer = id;
        return true;
    }

    // ---------- tags ----------

    private void tags(Conn c) {
        read.submit(query(c, q -> {
            Rows r = q.rows(0);
            Out o = c.json().ascii("{\"tags\":[");
            for (int i = 0; i < r.count(); i++) {
                if (i > 0) o.raw((byte) ',');
                r.row(i).json(o);
            }
            o.ascii("]}");
            c.send(200);
        }).add(Sql.TAGS));
    }

    // ---------- users ----------

    private void register(Conn c) {
        Map<String, Object> u = body(c, "user");
        String username = required(u, "username"), email = required(u, "email"), password = required(u, "password");
        if (username == null || email == null || password == null) {
            c.error(422, "username, email and password are required");
            return;
        }
        if (tooLong(password)) {
            c.error(422, "password is longer than 72 bytes");
            return;
        }
        bcrypt.execute(() -> {
            String hash = Bcrypt.hash(password);
            c.execute(() -> write.submit(query(c, q -> {
                Rows r = q.rows(0).row(0);
                String token = Jwt.mint(r.int8());
                user(c.json(), token, r);
                c.send(201);
            }).add(Sql.USER_INSERT, username, email, hash)));
        });
    }

    private void login(Conn c) {
        Map<String, Object> u = body(c, "user");
        String email = required(u, "email"), password = required(u, "password");
        if (email == null || password == null) {
            c.error(422, "email and password are required");
            return;
        }
        read.submit(query(c, q -> {
            Rows r = q.rows(0);
            if (r.count() == 0) {
                c.error(401, "invalid email or password");
                return;
            }
            r.row(0);
            long id = r.int8();
            String username = r.text(), mail = r.text(), bio = r.text(), image = r.text(), hash = r.text();
            bcrypt.execute(() -> {
                boolean ok = Bcrypt.check(password, hash);
                c.execute(() -> {
                    if (!ok) {
                        c.error(401, "invalid email or password");
                        return;
                    }
                    c.json().ascii("{\"user\":{\"email\":").str(mail).ascii(",\"token\":").str(Jwt.mint(id))
                            .ascii(",\"username\":").str(username).ascii(",\"bio\":").str(bio)
                            .ascii(",\"image\":").str(image).ascii("}}");
                    c.send(200);
                });
            });
        }).add(Sql.USER_BY_EMAIL, email));
    }

    private void getUser(Conn c) {
        read.submit(query(c, q -> {
            Rows r = q.rows(0);
            if (r.count() == 0) {
                c.error(401, "user not found");
                return;
            }
            user(c.json(), c.token, r.row(0));
            c.send(200);
        }).add(Sql.USER_BY_ID, c.viewer));
    }

    private void updateUser(Conn c) {
        Map<String, Object> u = body(c, "user");
        if (u == null) {
            c.error(422, "body must be {\"user\": {...}}");
            return;
        }
        Object email = optional(u, "email", true), username = optional(u, "username", true),
                password = optional(u, "password", true), bio = optional(u, "bio", false), image = optional(u, "image", false);
        if (email == INVALID || username == INVALID || password == INVALID || bio == INVALID || image == INVALID) {
            c.error(422, "invalid user fields");
            return;
        }
        if (password != null && tooLong((String) password)) {
            c.error(422, "password is longer than 72 bytes");
            return;
        }
        Consumer<String> update = hash -> write.submit(query(c, q -> {
            Rows r = q.rows(0);
            if (r.count() == 0) {
                c.error(401, "user not found");
                return;
            }
            user(c.json(), c.token, r.row(0));
            c.send(200);
        }).add(Sql.USER_UPDATE, c.viewer, email, username, hash, bio, image));
        if (password == null) {
            update.accept(null);
        } else {
            bcrypt.execute(() -> {
                String hash = Bcrypt.hash((String) password);
                c.execute(() -> update.accept(hash));
            });
        }
    }

    /** {"user": {...}} from columns username, email, bio, image. */
    private static void user(Out o, String token, Rows r) {
        o.ascii("{\"user\":{\"username\":");
        r.json(o);
        o.ascii(",\"email\":");
        r.json(o);
        o.ascii(",\"bio\":");
        r.json(o);
        o.ascii(",\"image\":");
        r.json(o);
        o.ascii(",\"token\":").str(token).ascii("}}");
    }

    // ---------- profiles ----------

    private void profile(Conn c, String username) {
        read.submit(query(c, q -> {
            Rows r = q.rows(0);
            if (r.count() == 0) {
                c.error(404, "profile not found");
                return;
            }
            Out o = c.json().ascii("{\"profile\":");
            profile(o, r.row(0));
            o.raw((byte) '}');
            c.send(200);
        }).add(Sql.PROFILE, c.viewer, username));
    }

    private void follow(Conn c, String username, boolean on) {
        write.submit(query(c, q -> {
            Rows r = q.rows(1);
            if (r.count() == 0) {
                c.error(404, "profile not found");
                return;
            }
            Out o = c.json().ascii("{\"profile\":");
            profile(o, r.row(0), on);
            o.raw((byte) '}');
            c.send(200);
        }).add(on ? Sql.FOLLOW : Sql.UNFOLLOW, c.viewer, username).add(Sql.PROFILE_PLAIN, username));
    }

    /** A profile from columns username, bio, image, following. */
    private static void profile(Out o, Rows r) {
        profileStart(o, r);
        o.ascii(",\"following\":").bool(r.bool()).raw((byte) '}');
    }

    /** A profile from columns username, bio, image, with a known following value. */
    private static void profile(Out o, Rows r, boolean following) {
        profileStart(o, r);
        o.ascii(",\"following\":").bool(following).raw((byte) '}');
    }

    private static void profileStart(Out o, Rows r) {
        o.ascii("{\"username\":");
        r.json(o);
        o.ascii(",\"bio\":");
        r.json(o);
        o.ascii(",\"image\":");
        r.json(o);
    }

    // ---------- articles ----------

    private void listArticles(Conn c) {
        long limit = number(c.param("limit"), 20, 1, 100);
        long offset = number(c.param("offset"), 0, 0, Long.MAX_VALUE);
        if (limit < 0 || offset < 0) {
            c.error(422, "limit must be 1-100 and offset >= 0");
            return;
        }
        String tag = c.param("tag"), author = c.param("author"), favorited = c.param("favorited");
        Query q = articleList(c);
        if (tag != null && !tag.isEmpty()) {
            q.add(Sql.LIST_TAG, c.viewer, limit, offset, tag).add(Sql.COUNT_TAG, tag);
        } else if (author != null && !author.isEmpty()) {
            q.add(Sql.LIST_AUTHOR, c.viewer, limit, offset, author).add(Sql.COUNT_AUTHOR, author);
        } else if (favorited != null && !favorited.isEmpty()) {
            q.add(Sql.LIST_FAVORITED, c.viewer, limit, offset, favorited).add(Sql.COUNT_FAVORITED, favorited);
        } else {
            q.add(Sql.LIST_ALL, c.viewer, limit, offset).add(Sql.COUNT_ALL);
        }
        read.submit(q);
    }

    private void feed(Conn c) {
        long limit = number(c.param("limit"), 20, 1, 100);
        long offset = number(c.param("offset"), 0, 0, Long.MAX_VALUE);
        if (limit < 0 || offset < 0) {
            c.error(422, "limit must be 1-100 and offset >= 0");
            return;
        }
        read.submit(articleList(c).add(Sql.FEED, c.viewer, limit, offset).add(Sql.COUNT_FEED, c.viewer));
    }

    /** A query whose statement 0 is a page of articles and statement 1 the capped count. */
    private static Query articleList(Conn c) {
        return query(c, q -> {
            Rows r = q.rows(0);
            Out o = c.json().ascii("{\"articles\":[");
            for (int i = 0; i < r.count(); i++) {
                if (i > 0) o.raw((byte) ',');
                article(o, r.row(i), false);
            }
            o.ascii("],\"articlesCount\":").num(q.rows(1).row(0).int8()).raw((byte) '}');
            c.send(200);
        });
    }

    private void getArticle(Conn c, String slug) {
        read.submit(query(c, q -> sendArticle(c, q.rows(0), 200)).add(Sql.ARTICLE_BY_SLUG, c.viewer, slug));
    }

    private void createArticle(Conn c) {
        Map<String, Object> a = body(c, "article");
        String title = required(a, "title"), description = required(a, "description"), body = required(a, "body");
        String[] tags = tagList(a);
        if (title == null || description == null || body == null || tags == null) {
            c.error(422, "title, description and body are required; tagList must be non-empty strings");
            return;
        }
        Query q = query(c, done -> sendArticle(c, done.rows(done.size() - 1), 201))
                .add(Sql.ARTICLE_INSERT, c.viewer, title, description, body);
        if (tags.length > 0) q.add(Sql.TAGS_UPSERT, (Object) tags).add(Sql.ARTICLE_TAGS_INSERT, (Object) tags);
        write.submit(q.add(Sql.ARTICLE_JUST_INSERTED, c.viewer));
    }

    private void updateArticle(Conn c, String slug) {
        Map<String, Object> a = body(c, "article");
        if (a == null) {
            c.error(422, "body must be {\"article\": {...}}");
            return;
        }
        Object title = optional(a, "title", true), description = optional(a, "description", true),
                body = optional(a, "body", true);
        if (title == INVALID || description == INVALID || body == INVALID) {
            c.error(422, "title, description and body must be non-empty strings");
            return;
        }
        write.submit(query(c, q -> {
            Rows r = q.rows(0);
            if (r.count() == 0) {
                c.error(404, "article not found");
                return;
            }
            long id = r.row(0).int8();
            if (r.int8() != c.viewer) {
                c.error(403, "not the author");
                return;
            }
            write.submit(query(c, u -> sendArticle(c, u.rows(1), 200))
                    .add(Sql.ARTICLE_UPDATE, id, title, description, body)
                    .add(Sql.ARTICLE_BY_ID, c.viewer, id));
        }).add(Sql.ARTICLE_OWNER, slug));
    }

    private void deleteArticle(Conn c, String slug) {
        write.submit(query(c, q -> {
            Rows r = q.rows(0);
            if (r.count() == 0) c.error(404, "article not found");
            else if (r.row(0).skip().int8() != c.viewer) c.error(403, "not the author");
            else c.sendEmpty(204);
        }).add(Sql.ARTICLE_OWNER, slug).add(Sql.ARTICLE_DELETE, slug, c.viewer));
    }

    private void favorite(Conn c, String slug, boolean on) {
        write.submit(query(c, q -> sendArticle(c, q.rows(1), 200))
                .add(on ? Sql.FAVORITE : Sql.UNFAVORITE, c.viewer, slug)
                .add(Sql.ARTICLE_BY_SLUG, c.viewer, slug));
    }

    /** {"article": {...}} with body from the first row, or 404 if there is none. */
    private static void sendArticle(Conn c, Rows r, int status) {
        if (r.count() == 0) {
            c.error(404, "article not found");
            return;
        }
        Out o = c.json().ascii("{\"article\":");
        article(o, r.row(0), true);
        o.raw((byte) '}');
        c.send(status);
    }

    /** An article from the columns listed in {@link Sql}. */
    private static void article(Out o, Rows r, boolean withBody) {
        o.ascii("{\"slug\":");
        r.json(o);
        o.ascii(",\"title\":");
        r.json(o);
        o.ascii(",\"description\":");
        r.json(o);
        if (withBody) {
            o.ascii(",\"body\":");
            r.json(o);
        }
        o.ascii(",\"createdAt\":");
        r.jsonTimestamp(o);
        o.ascii(",\"updatedAt\":");
        r.jsonTimestamp(o);
        o.ascii(",\"tagList\":");
        r.jsonTextArray(o);
        o.ascii(",\"favoritesCount\":").num(r.int8());
        o.ascii(",\"favorited\":").bool(r.bool());
        o.ascii(",\"author\":");
        profile(o, r);
        o.raw((byte) '}');
    }

    // ---------- comments ----------

    private void comments(Conn c, String slug) {
        read.submit(query(c, q -> {
            if (q.rows(0).count() == 0) {
                c.error(404, "article not found");
                return;
            }
            Rows r = q.rows(1);
            Out o = c.json().ascii("{\"comments\":[");
            for (int i = 0; i < r.count(); i++) {
                if (i > 0) o.raw((byte) ',');
                commentStart(o, r.row(i));
                profile(o, r);
                o.raw((byte) '}');
            }
            o.ascii("]}");
            c.send(200);
        }).add(Sql.ARTICLE_EXISTS, slug).add(Sql.COMMENTS, c.viewer, slug));
    }

    private void createComment(Conn c, String slug) {
        String text = required(body(c, "comment"), "body");
        if (text == null) {
            c.error(422, "comment body is required");
            return;
        }
        write.submit(query(c, q -> {
            Rows r = q.rows(0);
            if (r.count() == 0) {
                c.error(404, "article not found");
                return;
            }
            Out o = c.json().ascii("{\"comment\":");
            commentStart(o, r.row(0));
            profile(o, r, false);
            o.ascii("}}");
            c.send(201);
        }).add(Sql.COMMENT_INSERT, slug, c.viewer, text));
    }

    private void deleteComment(Conn c, String slug, String idText) {
        long id = number(idText, -1, 1, Long.MAX_VALUE);
        if (id < 0) {
            c.error(404, "comment not found");
            return;
        }
        write.submit(query(c, q -> {
            Rows r = q.rows(0);
            if (r.count() == 0) c.error(404, "comment not found");
            else if (r.row(0).int8() != c.viewer) c.error(403, "not the author");
            else c.sendEmpty(204);
        }).add(Sql.COMMENT_OWNER, id, slug).add(Sql.COMMENT_DELETE, id, slug, c.viewer));
    }

    /** Opens a comment object from columns id, body, created_at, updated_at, up to its "author" value. */
    private static void commentStart(Out o, Rows r) {
        o.ascii("{\"id\":").num(r.int8());
        o.ascii(",\"body\":");
        r.json(o);
        o.ascii(",\"createdAt\":");
        r.jsonTimestamp(o);
        o.ascii(",\"updatedAt\":");
        r.jsonTimestamp(o);
        o.ascii(",\"author\":");
    }

    // ---------- helpers ----------

    /**
     * A query whose callback runs on c's event loop. A unique violation (23505) becomes 422 and any other
     * database error 500, so callbacks only see successful results.
     */
    private static Query query(Conn c, Consumer<Query> done) {
        return new Query(c, q -> {
            if (!q.failed()) {
                done.accept(q);
            } else if ("23505".equals(q.sqlState)) {
                c.error(422, "already taken");
            } else {
                System.err.println("db error: " + q.sqlState + " " + q.error);
                c.error(q.sqlState.equals("08006") ? 503 : 500, "database error");
            }
        });
    }

    /** The object under key in a {"key": {...}} body, or null if the body isn't shaped like that. */
    private static Map<String, Object> body(Conn c, String key) {
        try {
            return Json.object(Json.parse(c.body), key);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    /** A required non-empty string field, or null if it is missing, null, empty or not a string. */
    private static String required(Map<String, Object> m, String key) {
        return m != null && m.get(key) instanceof String s && !s.isEmpty() ? s : null;
    }

    /** An optional string field: null if absent or JSON null (unchanged), INVALID if not a string (or empty). */
    private static Object optional(Map<String, Object> m, String key, boolean nonEmpty) {
        Object v = m.get(key);
        if (v == null || v == Json.NULL) return null;
        if (!(v instanceof String s) || (nonEmpty && s.isEmpty())) return INVALID;
        return s;
    }

    /** tagList as an array: empty if absent or null, null if it isn't an array of non-empty strings. */
    private static String[] tagList(Map<String, Object> m) {
        if (m == null) return null;
        Object v = m.get("tagList");
        if (v == null || v == Json.NULL) return new String[0];
        if (!(v instanceof List<?> l)) return null;
        String[] out = new String[l.size()];
        for (int i = 0; i < out.length; i++) {
            if (!(l.get(i) instanceof String s) || s.isEmpty()) return null;
            out[i] = s;
        }
        return out;
    }

    /** bcrypt uses at most 72 bytes of a password; longer ones are refused rather than silently cut. */
    private static boolean tooLong(String password) {
        return password.getBytes(StandardCharsets.UTF_8).length > 72;
    }

    /**
     * Parses a decimal integer made only of digits (leading zeros allowed) in [min, max]. Returns def when v is
     * null, and -1 when it is invalid or out of range.
     */
    private static long number(String v, long def, long min, long max) {
        if (v == null) return def;
        if (v.isEmpty() || v.length() > 18) return -1;
        long x = 0;
        for (int i = 0; i < v.length(); i++) {
            char ch = v.charAt(i);
            if (ch < '0' || ch > '9') return -1;
            x = x * 10 + (ch - '0');
        }
        return x < min || x > max ? -1 : x;
    }
}
