package conduit;

import conduit.http.HttpRequest;
import conduit.reads.Reads;
import conduit.security.Jwt;
import conduit.writes.ArticleWrites;
import conduit.writes.CommentWrites;
import conduit.writes.ProfileWrites;
import conduit.writes.UserWrites;

/**
 * Maps requests to endpoints. Runs on the connection's event loop: it authenticates the token, validates the input
 * and hands the request to its batched read, its write statement or a bcrypt worker. Problems found here (401, 404,
 * 422) are answered right away.
 */
public final class Router {
    private Router() {
    }

    public static void route(Exchange exchange, HttpRequest request) {
        try {
            dispatch(exchange, request);
        } catch (RequestBody.Invalid invalid) {
            exchange.respondError(422, invalid.getMessage());
        } catch (RuntimeException e) {
            e.printStackTrace();
            exchange.respondError(500, "internal error");
        }
    }

    private static void dispatch(Exchange exchange, HttpRequest request) throws RequestBody.Invalid {
        String path = request.path();
        if (!path.startsWith("/api/")) {
            notFound(exchange);
            return;
        }
        String rest = path.substring(5);
        if (rest.endsWith("/")) rest = rest.substring(0, rest.length() - 1);
        String[] segments = rest.split("/", 5);
        String method = request.method();

        switch (segments[0]) {
            case "articles" -> articles(exchange, request, method, segments);
            case "tags" -> {
                if (segments.length == 1 && method.equals("GET")) Reads.tags.submit(exchange);
                else notFound(exchange);
            }
            case "profiles" -> profiles(exchange, request, method, segments);
            case "user" -> {
                boolean get = method.equals("GET");
                if (segments.length != 1 || !(get || method.equals("PUT"))) {
                    notFound(exchange);
                } else if (signedIn(exchange, request)) {
                    if (get) Reads.user.submit(exchange);
                    else UserWrites.update(exchange, request.body());
                }
            }
            case "users" -> {
                if (method.equals("POST") && segments.length == 1) UserWrites.register(exchange, request.body());
                else if (method.equals("POST") && segments.length == 2 && segments[1].equals("login")) {
                    UserWrites.login(exchange, request.body());
                } else notFound(exchange);
            }
            default -> notFound(exchange);
        }
    }

    private static void articles(Exchange exchange, HttpRequest request, String method, String[] segments)
            throws RequestBody.Invalid {
        int count = segments.length;
        if (count == 1) {
            if (method.equals("GET")) {
                if (maybeSignedIn(exchange, request)) listArticles(exchange, request.query());
            } else if (method.equals("POST")) {
                if (signedIn(exchange, request)) ArticleWrites.create(exchange, request.body());
            } else notFound(exchange);
            return;
        }
        String slug = UrlDecoding.pathSegment(segments[1]);
        if (count == 2) {
            if (method.equals("GET") && segments[1].equals("feed")) {
                if (!signedIn(exchange, request)) return;
                if (parsePage(exchange, request.query())) Reads.feed.submit(exchange);
                else invalidPage(exchange);
            } else if (method.equals("GET")) {
                if (maybeSignedIn(exchange, request)) {
                    exchange.key = slug;
                    Reads.article.submit(exchange);
                }
            } else if (method.equals("PUT")) {
                if (signedIn(exchange, request)) ArticleWrites.update(exchange, slug, request.body());
            } else if (method.equals("DELETE")) {
                if (signedIn(exchange, request)) ArticleWrites.delete(exchange, slug);
            } else notFound(exchange);
            return;
        }
        String child = segments[2];
        if (child.equals("comments") && count == 3 && method.equals("GET")) {
            if (maybeSignedIn(exchange, request)) {
                exchange.key = slug;
                Reads.comments.submit(exchange);
            }
        } else if (child.equals("comments") && count == 3 && method.equals("POST")) {
            if (signedIn(exchange, request)) CommentWrites.create(exchange, slug, request.body());
        } else if (child.equals("comments") && count == 4 && method.equals("DELETE")) {
            if (!signedIn(exchange, request)) return;
            long commentId = parseId(segments[3]);
            if (commentId > 0) CommentWrites.delete(exchange, slug, commentId);
            else exchange.respondError(404, "comment not found");
        } else if (child.equals("favorite") && count == 3 && (method.equals("POST") || method.equals("DELETE"))) {
            if (signedIn(exchange, request)) ArticleWrites.favorite(exchange, slug, method.equals("POST"));
        } else {
            notFound(exchange);
        }
    }

    private static void profiles(Exchange exchange, HttpRequest request, String method, String[] segments) {
        int count = segments.length;
        if (count < 2) {
            notFound(exchange);
            return;
        }
        String username = UrlDecoding.pathSegment(segments[1]);
        if (count == 2 && method.equals("GET")) {
            if (maybeSignedIn(exchange, request)) {
                exchange.key = username;
                Reads.profile.submit(exchange);
            }
        } else if (count == 3 && segments[2].equals("follow") && (method.equals("POST") || method.equals("DELETE"))) {
            if (signedIn(exchange, request)) ProfileWrites.follow(exchange, username, method.equals("POST"));
        } else {
            notFound(exchange);
        }
    }

    // ---------- lists ----------

    /** GET /api/articles: one filter applies, the first present of tag, author, favorited. */
    private static void listArticles(Exchange exchange, String query) {
        if (!parsePage(exchange, query)) {
            invalidPage(exchange);
            return;
        }
        String tag = queryParameter(query, "tag", true);
        String author = queryParameter(query, "author", true);
        String favorited = queryParameter(query, "favorited", true);
        if (tag != null) {
            exchange.key = tag;
            Reads.tagList.submit(exchange);
        } else if (author != null) {
            exchange.key = author;
            Reads.authorList.submit(exchange);
        } else if (favorited != null) {
            exchange.key = favorited;
            Reads.favoritedList.submit(exchange);
        } else {
            Reads.globalList.submit(exchange);
        }
    }

    /** limit (1..100, default 20) and offset (>= 0, default 0): decimal digits only. */
    private static boolean parsePage(Exchange exchange, String query) {
        String limit = queryParameter(query, "limit", false);
        String offset = queryParameter(query, "offset", false);
        exchange.limit = 20;
        exchange.offset = 0;
        if (limit != null) {
            long value = parseDigits(limit);
            if (value < 1 || value > 100) return false;
            exchange.limit = (int) value;
        }
        if (offset != null) {
            long value = parseDigits(offset);
            if (value < 0) return false;
            // far beyond any page anyway; keeps limit + offset from overflowing in SQL
            exchange.offset = Math.min(value, Long.MAX_VALUE / 4);
        }
        return true;
    }

    private static void invalidPage(Exchange exchange) {
        exchange.respondError(422, "limit must be 1-100 and offset a non-negative integer");
    }

    /**
     * The decoded value of the first occurrence of {@code name} in the query string, or null. With
     * {@code skipEmpty} an empty value counts as absent (an empty filter is ignored; an empty limit is invalid).
     */
    private static String queryParameter(String query, String name, boolean skipEmpty) {
        int position = 0;
        while (position < query.length()) {
            int end = query.indexOf('&', position);
            if (end < 0) end = query.length();
            int equals = query.indexOf('=', position);
            int nameEnd = equals >= 0 && equals < end ? equals : end;
            if (UrlDecoding.queryValue(query.substring(position, nameEnd)).equals(name)) {
                String value = nameEnd < end ? UrlDecoding.queryValue(query.substring(nameEnd + 1, end)) : "";
                if (!(skipEmpty && value.isEmpty())) return value;
            }
            position = end + 1;
        }
        return null;
    }

    /** A non-negative decimal integer (digits only, no sign, leading zeros allowed); -1 if invalid or too large. */
    private static long parseDigits(String text) {
        if (text.isEmpty()) return -1;
        long value = 0;
        for (int i = 0; i < text.length(); i++) {
            int digit = text.charAt(i) - '0';
            if (digit < 0 || digit > 9) return -1;
            if (value > (Long.MAX_VALUE - digit) / 10) return -1;
            value = value * 10 + digit;
        }
        return value;
    }

    private static long parseId(String text) {
        long id = parseDigits(text);
        return id > 0 ? id : -1;
    }

    // ---------- authentication ----------

    /** Auth required: a valid token, otherwise 401. */
    private static boolean signedIn(Exchange exchange, HttpRequest request) {
        if (authenticate(exchange, request) > 0) return true;
        exchange.respondError(401, "a valid token is required");
        return false;
    }

    /** Auth optional: no header means anonymous; a header with an invalid token gets 401. */
    private static boolean maybeSignedIn(Exchange exchange, HttpRequest request) {
        if (authenticate(exchange, request) >= 0) return true;
        exchange.respondError(401, "invalid token");
        return false;
    }

    /**
     * Verifies the "Authorization: Token <jwt>" header (signature, algorithm and expiry, every time). Returns the
     * user id, 0 without a header, or -1 for an invalid one.
     */
    private static long authenticate(Exchange exchange, HttpRequest request) {
        String header = request.authorization();
        if (header == null) return 0;
        if (!header.startsWith("Token ")) return -1;
        String token = header.substring(6).trim();
        long userId = Jwt.verify(token);
        if (userId <= 0) return -1;
        exchange.viewer = userId;
        exchange.token = token;
        return userId;
    }

    private static void notFound(Exchange exchange) {
        exchange.respondError(404, "not found");
    }
}
