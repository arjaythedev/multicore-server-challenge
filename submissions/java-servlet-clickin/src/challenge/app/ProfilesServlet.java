package challenge.app;

import java.io.IOException;

import challenge.JsonWriter;
import challenge.app.Conduit.Services;
import challenge.pg.Query;
import challenge.servlet.Direct;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import static challenge.app.Op.FOLLOW;
import static challenge.app.Op.PROFILE;
import static challenge.app.Op.UNFOLLOW;

/** {@code /api/profiles/{username}} and its {@code /follow}. */
final class ProfilesServlet extends ApiServlet {
    ProfilesServlet(Services services) {
        super(services);
    }

    /** {@code GET /api/profiles/{username}}. */
    protected void doGet(HttpServletRequest req, HttpServletResponse res) throws IOException {
        if (Direct.of(req).segmentCount() == 3) {
            targeted(PROFILE, ProfilesServlet::write, req, res);
        } else {
            notFound(res);
        }
    }

    /** {@code POST /api/profiles/{username}/follow}. */
    protected void doPost(HttpServletRequest req, HttpServletResponse res) throws IOException {
        if (follow(Direct.of(req))) {
            targeted(FOLLOW, ProfilesServlet::write, req, res);
        } else {
            notFound(res);
        }
    }

    /** {@code DELETE /api/profiles/{username}/follow}. */
    protected void doDelete(HttpServletRequest req, HttpServletResponse res) throws IOException {
        if (follow(Direct.of(req))) {
            targeted(UNFOLLOW, ProfilesServlet::write, req, res);
        } else {
            notFound(res);
        }
    }

    private static boolean follow(Direct r) {
        return r.segmentCount() == 4 && r.segmentIs(3, "follow");
    }

    private static void write(Call call, Query q) {
        if (call.missing(q, 404)) {
            return;
        }
        JsonWriter out = call.json();
        Views.raw(out, "{\"profile\":");
        Views.profile(out, q, 0, 0,
                call.op == PROFILE ? q.boolAt(0, 3) : call.op == FOLLOW);
        out.put('}');
        call.complete();
    }
}
