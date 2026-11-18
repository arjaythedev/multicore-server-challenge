package challenge.app;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import challenge.JsonWriter;
import challenge.app.Conduit.Services;
import challenge.app.Inputs.Body;
import challenge.app.Inputs.Invalid;
import challenge.pg.Query;
import challenge.servlet.Direct;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import static challenge.app.Op.LOGIN;
import static challenge.app.Op.REGISTER;
import static challenge.app.Op.UPDATE;
import static challenge.app.Op.USER;

/**
 * {@code /api/users}, {@code /api/users/login} and {@code /api/user}. Register
 * and a password update hash before the database; login checks the password
 * against the stored hash after it.
 */
final class UsersServlet extends ApiServlet {
    UsersServlet(Services services) {
        super(services);
    }

    /** {@code GET /api/user}: the current user. */
    protected void doGet(HttpServletRequest req, HttpServletResponse res) throws IOException {
        if (!user(Direct.of(req))) {
            notFound(res);
            return;
        }
        Call call = begin(USER, req, res);
        if (call == null) {
            return;
        }
        call.start().int8(call.viewer);
        call.submit(UsersServlet::found);
    }

    /** {@code POST /api/users} registers, {@code POST /api/users/login} logs in. */
    protected void doPost(HttpServletRequest req, HttpServletResponse res) throws IOException {
        Direct r = Direct.of(req);
        int n = r.segmentCount();
        if (n == 2 && r.segmentIs(1, "users")) {
            credentials(REGISTER, req, res);
        } else if (n == 3 && r.segmentIs(1, "users") && r.segmentIs(2, "login")) {
            credentials(LOGIN, req, res);
        } else {
            notFound(res);
        }
    }

    /**
     * {@code PUT /api/user}: updates the given fields, hashing a new password
     * first.
     */
    protected void doPut(HttpServletRequest req, HttpServletResponse res) throws IOException {
        if (!user(Direct.of(req))) {
            notFound(res);
            return;
        }
        Call call = begin(UPDATE, req, res);
        if (call == null) {
            return;
        }
        try {
            Body body = Inputs.body(call.request, "user");
            call.username = Inputs.field(body, "username", false, true);
            call.email = Inputs.field(body, "email", false, true);
            call.password = Inputs.password(body, false);
            call.bio = Inputs.field(body, "bio", false, false);
            call.image = Inputs.field(body, "image", false, false);
        } catch (Invalid e) {
            res.sendError(422, "invalid body");
            return;
        }
        call.start();
        if (call.password != null) {
            call.bcrypt(call.password, UsersServlet::hashedForUpdate);
        } else {
            update(call, null);
        }
    }

    /** {@code /api/user}, not {@code /api/users}: both map here. */
    private static boolean user(Direct r) {
        return r.segmentCount() == 2 && r.segmentIs(1, "user");
    }

    /**
     * Register or login: hashes the new password, or looks the user up by email
     * first.
     */
    private void credentials(Op op, HttpServletRequest req, HttpServletResponse res) throws IOException {
        Call call = begin(op, req, res);
        try {
            Body body = Inputs.body(call.request, "user");
            if (op == REGISTER) {
                call.username = Inputs.field(body, "username", true, true);
            }
            call.email = Inputs.field(body, "email", true, true);
            call.password = Inputs.password(body, true);
        } catch (Invalid e) {
            res.sendError(422, "invalid body");
            return;
        }
        Query q = call.start();
        if (op == REGISTER) {
            call.bcrypt(call.password, UsersServlet::hashedForRegister);
        } else {
            q.text(call.email);
            call.submit(UsersServlet::foundForLogin);
        }
    }

    private static void hashedForRegister(Call call, Query q) {
        q.text(call.username)
         .text(call.email)
         .text(call.unit.bcryptHash);
        call.submit(UsersServlet::found);
    }

    private static void foundForLogin(Call call, Query q) {
        if (call.missing(q, 401)) {
            return;
        }
        call.unit.bcryptHash = new String(q.bytes(), q.offset(0, 5), q.length(0, 5),
                StandardCharsets.UTF_8);
        call.bcrypt(call.password, UsersServlet::checked);
    }

    private static void checked(Call call, Query q) {
        if (call.unit.bcryptMatches) {
            write(call, q);
        } else {
            call.fail(401, "invalid credentials");
        }
    }

    private static void hashedForUpdate(Call call, Query q) {
        update(call, call.unit.bcryptHash);
    }

    private static void update(Call call, String hash) {
        call.query.int8(call.viewer)
            .text(call.email)
            .text(call.username)
            .text(hash)
            .text(call.bio)
            .text(call.image);
        call.submit(UsersServlet::found);
    }

    private static void found(Call call, Query q) {
        if (!call.missing(q, 401)) {
            write(call, q);
        }
    }

    /**
     * The user with a fresh token for register and login, or the request's own
     * token.
     */
    private static void write(Call call, Query q) {
        Op op = call.op;
        byte[] token = call.request.bytes();
        int at = call.tokenOffset;
        int len = call.tokenLength;
        if (op == REGISTER || op == LOGIN) {
            at = 0;
            len = call.request.local(call.services.jwt()).sign(q.int8At(0, 0), System.currentTimeMillis() / 1000, call.signed, 0);
            token = call.signed;
        }
        if (op == REGISTER) {
            call.response.setStatus(201);
        }
        JsonWriter out = call.json();
        Views.raw(out, "{\"user\":");
        Views.user(out, q, 0, token, at, len);
        out.put('}');
        call.complete();
    }
}
