package challenge.servlet;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Objects;

import jakarta.servlet.RequestDispatcher;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * Mapping precedence, servlet path / path info, HttpServlet method dispatch and
 * the error servlet.
 */
public final class ContainerTest {
    /**
     * Writes "name servletPath pathInfo method" so the test can see who ran and
     * what it saw.
     */
    static final class Named extends HttpServlet {
        final String name;
        int inits;

        Named(String name) {
            this.name = name;
        }

        public void init() {
            inits++;
        }

        protected void doGet(HttpServletRequest req, HttpServletResponse res) throws IOException {
            res.setContentType("text/plain");
            byte[] b = (name
                    + " "
                    + req.getServletPath()
                    + " "
                    + req.getPathInfo()
                    + " "
                    + req.getMethod()).getBytes(StandardCharsets.UTF_8);
            res.getOutputStream().write(b, 0, b.length);
        }
    }

    static final class Errors extends HttpServlet {
        protected void service(HttpServletRequest req, HttpServletResponse res) throws IOException {
            byte[] b = ("error " + req.getAttribute(RequestDispatcher.ERROR_STATUS_CODE)).getBytes(StandardCharsets.UTF_8);
            res.getOutputStream().write(b, 0, b.length);
        }
    }

    private static Response run(Container c, String method, String path) throws Exception {
        byte[] bytes = (method + " " + path + " HTTP/1.1\r\n\r\n").getBytes(StandardCharsets.UTF_8);
        Request req = new Request(null);
        Response res = new Response();
        req.init(res);
        res.init(req, c);
        req.data = bytes;
        req.pathStart = method.length() + 1;
        req.pathEnd = req.pathStart + path.length();
        req.queryStart = -1;
        c.service(req, res);
        return res;
    }

    private static void check(Container c, String method, String path,
            int status, String body)
            throws Exception {
        Response res = run(c, method, path);
        String actual = new String(
                res.jsonOut().bytes(),
                0,
                res.jsonOut().length(),
                StandardCharsets.UTF_8);
        if (res.status != status || !Objects.equals(actual, body)) {
            throw new AssertionError(method
                    + " "
                    + path
                    + ": got "
                    + res.status
                    + " "
                    + actual);
        }
    }

    public static void main(String[] args) throws Exception {
        Container c = new Container();
        Named shared = new Named("shared");
        c.addServlet("/a", new Named("exact"));
        c.addServlet("/a/*", new Named("prefix"));
        c.addServlet("/a/b/*", new Named("deeper"));
        c.addServlet("/x/y", shared);
        c.addServlet("/z/*", shared);
        c.setErrorServlet(new Errors());
        check(c, "GET", "/a", 200, "exact /a null GET");
        check(c, "GET", "/a/q", 200, "prefix /a /q GET");
        check(c, "GET", "/a/b", 200, "deeper /a/b null GET");
        check(c, "GET", "/a/b/c/d", 200, "deeper /a/b /c/d GET");
        check(c, "GET", "/x/y", 200, "shared /x/y null GET");
        check(c, "GET", "/z/1", 200, "shared /z /1 GET");
        check(c, "GET", "/ab", 404, "error 404");
        check(c, "GET", "/x", 404, "error 404");
        check(c, "GET", "/x/y/z", 404, "error 404");
        check(c, "GET", "/a//b", 404, "error 404");
        // HttpServlet's own dispatch: HEAD runs doGet (Loop drops the body), POST has no doPost.
        check(c, "HEAD", "/a", 200, "exact /a null HEAD");
        check(c, "POST", "/a", 405, "error 405");
        check(c, "BREW", "/a", 501, "error 501");
        if (shared.inits != 1) {
            throw new AssertionError("init ran " + shared.inits + " times");
        }
        c.addServlet("/", new Named("default"));
        check(c, "GET", "/ab", 200, "default /ab null GET");
        System.out.println("challenge.servlet.ContainerTest passed");
    }
}
