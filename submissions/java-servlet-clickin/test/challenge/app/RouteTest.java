package challenge.app;

import java.nio.charset.StandardCharsets;

import challenge.Jwt;
import challenge.app.Conduit.Services;
import challenge.servlet.Container;
import challenge.servlet.Request;
import challenge.servlet.Response;

import static challenge.app.Op.ARTICLE;
import static challenge.app.Op.ARTICLES;
import static challenge.app.Op.COMMENTS;
import static challenge.app.Op.CREATE_ARTICLE;
import static challenge.app.Op.CREATE_COMMENT;
import static challenge.app.Op.DELETE_ARTICLE;
import static challenge.app.Op.DELETE_COMMENT;
import static challenge.app.Op.FAVORITE;
import static challenge.app.Op.FEED;
import static challenge.app.Op.FOLLOW;
import static challenge.app.Op.LOGIN;
import static challenge.app.Op.PROFILE;
import static challenge.app.Op.REGISTER;
import static challenge.app.Op.TAGS;
import static challenge.app.Op.UNFAVORITE;
import static challenge.app.Op.UNFOLLOW;
import static challenge.app.Op.UPDATE;
import static challenge.app.Op.UPDATE_ARTICLE;
import static challenge.app.Op.USER;

/**
 * Requests through the container to the op each API servlet routes them to,
 * with a valid token so every op gets past authentication.
 */
public final class RouteTest {
    private static final String NOT_ALLOWED = "405";
    private static final Container CONTAINER;
    private static final String TOKEN;

    static {
        try {
            CONTAINER = Conduit.container(new Services(null, null, "secret"));
            byte[] out = new byte[256];
            int n = new Jwt("secret").sign(1, System.currentTimeMillis() / 1000, out, 0);
            TOKEN = "Token " + new String(out, 0, n, StandardCharsets.US_ASCII);
        } catch (Exception e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    /**
     * The op the servlet began, "405" when the servlet does not handle the
     * method (501 for an unknown one), or null for 404.
     */
    private static Object route(String method, String path) throws Exception {
        String head = method + " " + path + " HTTP/1.1\r\nAuthorization: ";
        byte[] bytes = (head + TOKEN + "\r\n\r\n").getBytes(StandardCharsets.UTF_8);
        Request req = new Request(null);
        Response res = new Response();
        req.init(res);
        res.init(req, CONTAINER);
        req.data = bytes;
        req.pathStart = method.length() + 1;
        req.pathEnd = req.pathStart + path.length();
        req.queryStart = -1;
        req.authStart = head.length();
        req.authEnd = head.length() + TOKEN.length();
        try {
            CONTAINER.service(req, res);
        } catch (NullPointerException e) {
            // No database: the op got as far as submitting its work.
        }
        if (res.status == 405 || res.status == 501) {
            return NOT_ALLOWED;
        }
        return req.slot() instanceof Call call ? call.op : null;
    }

    private static void check(String method, String path, Object expected) throws Exception {
        Object actual = route(method, path);
        if (actual != expected) {
            throw new AssertionError(method
                    + " "
                    + path
                    + ": expected "
                    + expected
                    + ", got "
                    + actual);
        }
    }

    public static void main(String[] args) throws Exception {
        check("GET", "/api/tags", TAGS);
        check("POST", "/api/users", REGISTER);
        check("POST", "/api/users/login", LOGIN);
        check("GET", "/api/user", USER);
        check("PUT", "/api/user", UPDATE);
        check("GET", "/api/profiles/jake", PROFILE);
        check("POST", "/api/profiles/jake/follow", FOLLOW);
        check("DELETE", "/api/profiles/jake/follow", UNFOLLOW);
        check("GET", "/api/articles", ARTICLES);
        check("POST", "/api/articles", CREATE_ARTICLE);
        check("GET", "/api/articles/feed", FEED);
        check("GET", "/api/articles/how-to", ARTICLE);
        check("PUT", "/api/articles/how-to", UPDATE_ARTICLE);
        check("DELETE", "/api/articles/how-to", DELETE_ARTICLE);
        check("POST", "/api/articles/how-to/favorite", FAVORITE);
        check("DELETE", "/api/articles/how-to/favorite", UNFAVORITE);
        check("GET", "/api/articles/how-to/comments", COMMENTS);
        check("POST", "/api/articles/how-to/comments", CREATE_COMMENT);
        check("DELETE", "/api/articles/how-to/comments/7", DELETE_COMMENT);
        // Slugs and usernames that collide with keywords are still slugs.
        check("GET", "/api/articles/login", ARTICLE);
        check("PUT", "/api/articles/feed", UPDATE_ARTICLE);
        check("GET", "/api/articles/comments", ARTICLE);
        check("GET", "/api/profiles/follow", PROFILE);
        check("GET", "/api/profiles/articles", PROFILE);
        check("POST", "/api/profiles/feed/follow", FOLLOW);
        check("GET", "/api/articles/favorite/comments", COMMENTS);
        check("DELETE", "/api/articles/x/comments/comments", DELETE_COMMENT);
        // Near misses: prefixes, extensions, case, wrong count, wrong root (404).
        // A method the servlet does not override is HttpServlet's 405 (501 for unknown methods) instead of 404.
        check("GET", "/api/tag", null);
        check("GET", "/api/tagsx", null);
        check("GET", "/api/Tags", null);
        check("GET", "/api/articlesx", null);
        check("GET", "/api/feed", null);
        check("GET", "/api/users", null);
        check("POST", "/api/users/logins", null);
        check("GET", "/api/users/login", null);
        check("POST", "/api/tags", NOT_ALLOWED);
        check("PATCH", "/api/user", NOT_ALLOWED);
        check("GETX", "/api/tags", NOT_ALLOWED);
        check("GE", "/api/tags", NOT_ALLOWED);
        check("GET", "/apix/tags", null);
        check("GET", "/ap/tags", null);
        check("GET", "/x/api/tags", null);
        check("GET", "/api", null);
        check("GET", "/api/tags/x", null);
        check("DELETE", "/api/articles/x/comments", null);
        check("GET", "/api/articles/x/comments/7", null);
        check("POST", "/api/profiles/jake/unfollow", null);
        check("POST", "/api/articles/x/favorites", null);
        check("DELETE", "/api/articles/x/y/comments", null);
        check("GET", "/api/articles/a/b/c/d", null);
        check("GET", "/api/articles//comments", null);
        check("DELETE", "/api/user", NOT_ALLOWED);
        check("DELETE", "/api/tags", NOT_ALLOWED);
        check("PUT", "/api/profiles/jake", NOT_ALLOWED);
        // Method present, path shape unknown to it: still 404.
        check("POST", "/api/user", null);
        check("PUT", "/api/users", null);
        check("HEAD", "/api/tags", TAGS);
        check("HEAD", "/api/articles/how-to", ARTICLE);
        System.out.println("challenge.app.RouteTest passed");
    }
}
