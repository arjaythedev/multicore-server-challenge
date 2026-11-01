package challenge.servlet;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.Locale;
import java.util.Objects;

import jakarta.servlet.DispatcherType;
import jakarta.servlet.RequestDispatcher;
import jakarta.servlet.http.Cookie;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.MappingMatch;

/** The standard request/response API beyond what HttpServlet itself calls. */
public final class ServletApiTest {
    private static void check(boolean b, String what) {
        if (!b) {
            throw new AssertionError(what);
        }
    }

    private static void equal(Object actual, Object expected) {
        if (!Objects.equals(actual, expected)) {
            throw new AssertionError("expected " + expected + ", got " + actual);
        }
    }

    /**
     * A request as the loop would leave it: offsets into one buffer, headers
     * recorded by position.
     */
    static Request request(Container c, String method, String target,
                           String headers, String body) {
        String head = method + " " + target + " HTTP/1.1\r\n" + headers + "\r\n";
        byte[] bytes = (head + body).getBytes(StandardCharsets.UTF_8);
        Request r = new Request(null);
        Response res = new Response();
        r.init(res);
        res.init(r, c);
        r.data = bytes;
        r.pathStart = method.length() + 1;
        int q = target.indexOf('?');
        r.pathEnd = r.pathStart + (q < 0 ? target.length() : q);
        r.queryStart = q < 0 ? -1 : r.pathStart + q + 1;
        r.queryEnd = q < 0 ? -1 : r.pathStart + target.length();
        int p = head.indexOf("\r\n") + 2;
        while (p < head.length() - 2) {
            int eol = head.indexOf("\r\n", p);
            int colon = head.indexOf(':', p);
            int v = colon + 1;
            while (head.charAt(v) == ' ') {
                v++;
            }
            r.header(p, colon, v, eol);
            p = eol + 2;
        }
        r.bodyStart = head.getBytes(StandardCharsets.UTF_8).length;
        r.bodyLength = bytes.length - r.bodyStart;
        return r;
    }

    static String body(Response res) {
        return new String(
                res.jsonOut().bytes(),
                0,
                res.jsonOut().length(),
                StandardCharsets.UTF_8);
    }

    public static void main(String[] args) throws Exception {
        Container c = new Container();
        HttpServlet probe = new HttpServlet() {
            protected void doPost(HttpServletRequest req, HttpServletResponse res) throws IOException {
                res.setContentType("text/plain");
                res.setCharacterEncoding("UTF-8");
                res.getWriter().print(req.getReader().readLine() + " " + req.getHttpServletMapping().getMatchValue());
            }
        };
        c.addServlet("/p/*", probe);
        c.setErrorServlet(new HttpServlet() {
            protected void service(HttpServletRequest req, HttpServletResponse res) throws IOException {
                res.getWriter().print(req.getDispatcherType()
                        + " "
                        + req.getAttribute(RequestDispatcher.ERROR_STATUS_CODE)
                        + " "
                        + req.getAttribute(RequestDispatcher.ERROR_MESSAGE));
            }
        });

        // Body as a reader in the declared charset; writer output encoded as UTF-8.
        Request r = request(c, "POST", "/p/x/y", "Content-Type: text/plain; charset=ISO-8859-1\r\n", "café");
        r.data[r.bodyStart + 3] = (byte) 0xe9;
        r.bodyLength = 4;
        Response res = r.response();
        c.service(r, res);
        equal(body(res), "café x/y");
        equal(res.getContentType(), "text/plain;charset=UTF-8");
        equal(r.getCharacterEncoding(), "ISO-8859-1");

        // Mapping, URL and server name from Host.
        r = request(c, "GET", "/p/a?k=v", "Host: example.com:8080\r\nCookie: a=1; b=\"two\"\r\nAccept-Language: ko-KR;q=0.9, en;q=0.8\r\nX-N: 42\r\n", "");
        c.map(r);
        equal(r.getHttpServletMapping().getMappingMatch(), MappingMatch.PATH);
        equal(r.getHttpServletMapping().getPattern(), "/p/*");
        equal(r.getServletPath(), "/p");
        equal(r.getPathInfo(), "/a");
        equal(r.getServerName(), "example.com");
        equal(r.getServerPort(), 8080);
        equal(r.getRequestURL().toString(), "http://example.com:8080/p/a");
        equal(r.getIntHeader("X-N"), 42);
        equal(r.getIntHeader("X-Missing"), -1);
        Cookie[] cookies = r.getCookies();
        equal(cookies.length, 2);
        equal(cookies[1].getName() + "=" + cookies[1].getValue(), "b=two");
        equal(r.getLocale(), Locale.forLanguageTag("ko-KR"));
        equal(Collections.list(r.getLocales()).size(), 2);
        equal(r.getDispatcherType(), DispatcherType.REQUEST);
        equal(r.getSession(false), null);
        equal(r.getRequestDispatcher("/x"), null);
        equal(r.getServletContext().getMajorVersion(), 6);
        r.getServletContext().setAttribute("k", "v");
        equal(r.getServletContext().getAttribute("k"), "v");

        // Input stream and reader exclude each other, as do output stream and writer.
        r = request(c, "POST", "/p", "", "abc");
        r.getInputStream();
        try {
            r.getReader();
            throw new AssertionError("reader after stream");
        } catch (IllegalStateException expected) {
        }
        res = new Response();
        res.getWriter();
        try {
            res.getOutputStream();
            throw new AssertionError("stream after writer");
        } catch (IllegalStateException expected) {
        }

        // sendError: ERROR dispatch with the standard attributes, then back to REQUEST.
        r = request(c, "GET", "/nothing", "", "");
        res = r.response();
        c.service(r, res);
        equal(body(res), "ERROR 404 null");
        equal(r.getDispatcherType(), DispatcherType.REQUEST);
        r.setAttribute(RequestDispatcher.ERROR_STATUS_CODE, 500);
        equal(r.getAttribute(RequestDispatcher.ERROR_STATUS_CODE), 500);
        r.removeAttribute(RequestDispatcher.ERROR_STATUS_CODE);
        equal(r.getAttribute(RequestDispatcher.ERROR_STATUS_CODE), null);
        equal(Request.charset("application/json"), null);
        equal(Request.charset("text/plain;charset=UTF-8"), "UTF-8");
        equal(Request.charset("text/plain; a=b; Charset=\"latin1\"; c=d"), "latin1");

        // Response headers, cookies, redirects, reset.
        res = new Response();
        res.setIntHeader("X-A", 1);
        res.addIntHeader("X-A", 2);
        equal(res.getHeader("x-a"), "1");
        equal(res.getHeaders("X-A").size(), 2);
        Cookie cookie = new Cookie("s", "1");
        cookie.setPath("/");
        cookie.setHttpOnly(true);
        res.addCookie(cookie);
        String setCookie = res.getHeader("Set-Cookie");
        check(setCookie.startsWith("s=1") && setCookie.contains("; Path=/") && setCookie.contains("; HttpOnly"),
                setCookie);
        res.sendRedirect("/elsewhere");
        equal(res.getStatus(), 302);
        equal(res.getHeader("Location"), "/elsewhere");
        Runnable marker = () -> {};
        res.finish = marker;
        res.reset();
        check(res.finish == marker && res.getHeader("Location") == null && res.getStatus() == 200,
                "reset keeps the exchange");
        res.recycle();
        check(res.finish == null, "recycle detaches");
        equal(res.getCharacterEncoding(), "ISO-8859-1");
        System.out.println("challenge.servlet.ServletApiTest passed");
    }
}
