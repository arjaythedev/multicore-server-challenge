package challenge.app;

import java.io.IOException;
import java.security.GeneralSecurityException;

import challenge.BcryptPool;
import challenge.Jwt;
import challenge.pg.PgDispatcher;
import challenge.servlet.Container;
import challenge.servlet.Direct;
import challenge.servlet.Direct.Local;
import jakarta.servlet.AsyncContext;
import jakarta.servlet.DispatcherType;
import jakarta.servlet.RequestDispatcher;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * The Conduit (RealWorld) API as servlets: one per resource, mapped the way a
 * web.xml would map them.
 */
public final class Conduit {
    private Conduit() {}

    /**
     * What the servlets share: the Postgres dispatcher, the bcrypt pool, the
     * JWT secret, and the per-loop {@link Jwt} (its Mac and buffers are not
     * thread-safe, and too big to keep per request).
     */
    public record Services(PgDispatcher dispatcher, BcryptPool bcrypt, String secret,
                           Local<Jwt> jwt) {
        public Services(PgDispatcher dispatcher, BcryptPool bcrypt, String secret) {
            this(dispatcher, bcrypt, secret, new Local<>(() -> {
                try {
                    return new Jwt(secret);
                } catch (GeneralSecurityException e) {
                    throw new IllegalStateException(e);
                }
            }));
        }
    }

    public static Container container(Services services) throws ServletException {
        Container c = new Container();
        UsersServlet users = new UsersServlet(services);
        c.addServlet("/api/tags", new TagsServlet(services));
        c.addServlet("/api/users/*", users);
        c.addServlet("/api/user", users);
        c.addServlet("/api/profiles/*", new ProfilesServlet(services));
        c.addServlet("/api/articles/*", new ArticlesServlet(services));
        c.addServlet("/__async", new AsyncProbeServlet());
        c.addServlet("/__echo", new EchoServlet());
        c.setErrorServlet(new ErrorServlet());
        return c;
    }

    /**
     * {@code GET /__async}: completes an async request from {@code
     * AsyncContext.start}, or with {@code ?dispatch} re-dispatches it and
     * answers from the ASYNC dispatch (used by the HTTP smoke test).
     */
    static final class AsyncProbeServlet extends HttpServlet {
        protected void doGet(HttpServletRequest req, HttpServletResponse res) throws IOException {
            if (req.getDispatcherType() == DispatcherType.ASYNC) {
                res.setContentType("text/plain");
                res.getWriter().print("dispatched");
                return;
            }
            AsyncContext async = req.startAsync();
            if (req.getQueryString() != null && req.getQueryString().equals("dispatch")) {
                async.start(async::dispatch);
            } else {
                async.start(async::complete);
            }
        }
    }

    /**
     * {@code POST /__echo}: writes the request body back, and the peer address
     * and local port as {@code X-Remote}.
     */
    static final class EchoServlet extends HttpServlet {
        protected void doPost(HttpServletRequest req, HttpServletResponse res) throws IOException {
            res.setHeader("X-Remote", req.getRemoteAddr() + " " + req.getLocalPort());
            req.getInputStream().transferTo(res.getOutputStream());
        }
    }

    /** Renders every {@code sendError} as {@code {"errors":{"body":[message]}}}. */
    static final class ErrorServlet extends HttpServlet {
        protected void service(HttpServletRequest req, HttpServletResponse res) {
            Object message = req.getAttribute(RequestDispatcher.ERROR_MESSAGE);
            res.setContentType("application/json");
            Views.errors(
                    Direct.of(req).output(),
                    message != null
                            ? message.toString()
                            : res.getStatus() == 404 ? "not found" : "error");
        }
    }
}
