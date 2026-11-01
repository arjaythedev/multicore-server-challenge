package challenge.app;

import java.io.IOException;

import challenge.app.Call.Then;
import challenge.app.Conduit.Services;
import challenge.app.Op.Auth;
import challenge.servlet.Direct;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * Base for the API servlets: the shared {@link Services} and {@link #begin} for
 * an op's pooled {@link Call}. Each servlet overrides {@code doGet}, {@code
 * doPost}, ... and routes its own paths, so {@link HttpServlet} answers 405 and
 * {@code Allow} for the rest.
 */
abstract class ApiServlet extends HttpServlet {
    final Services services;

    ApiServlet(Services services) {
        this.services = services;
    }

    /**
     * Authenticates for {@code op} and returns the exchange's pooled call reset
     * for it; or sends 401 and returns null.
     */
    Call begin(Op op, HttpServletRequest req, HttpServletResponse res) throws IOException {
        Direct r = Direct.of(req);
        long viewer = 0;
        if (op.auth != Auth.NONE) {
            viewer = Inputs.viewer(r, r.local(services.jwt()), op.auth == Auth.REQUIRED);
            if (viewer < 0) {
                res.sendError(401, "unauthorized");
                return null;
            }
        }
        Call call = Call.of(r, services);
        call.reset(op, req, r, res, viewer);
        return call;
    }

    /**
     * An op whose statement takes only the viewer and the target segment (a
     * username or slug).
     */
    void targeted(Op op, Then then, HttpServletRequest req,
                  HttpServletResponse res)
            throws IOException {
        Call call = begin(op, req, res);
        if (call == null) {
            return;
        }
        call.target(call.start().int8(call.viewer));
        call.submit(then);
    }

    static void notFound(HttpServletResponse res) throws IOException {
        res.sendError(404, "not found");
    }
}
