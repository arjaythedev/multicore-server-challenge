package challenge.app;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;

import challenge.JsonWriter;
import challenge.app.Conduit.Services;
import challenge.app.Inputs.Params;
import challenge.pg.Completions;
import challenge.pg.Query;
import challenge.pg.Unit;
import challenge.pg.Unit.Callback;
import challenge.servlet.Direct;
import jakarta.servlet.AsyncContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * One request's database and bcrypt work, pooled per connection exchange. The
 * servlet binds the op's statement from {@link #start} and submits it with what
 * to do next; when the work is done {@link #run} calls that on the loop thread.
 */
final class Call implements Runnable, Completions, Callback {
    /** What the servlet does with finished work: submit the next step, or respond. */
    @FunctionalInterface
    interface Then {
        void done(Call call, Query q);
    }

    final Direct request;
    final Services services;
    final Query query = new Query(0, false);
    Query secondary;
    final Query[] one = {query};
    final Query[] two = new Query[2];
    final Unit unit;
    final Params params = new Params();
    final byte[] signed = new byte[256];
    HttpServletRequest httpRequest;
    HttpServletResponse response;
    AsyncContext async;
    Op op;
    Then then;

    /** The submitted work is bcrypt's, not the database's. */
    boolean hashing;

    int tokenOffset;
    int tokenLength;
    int targetOffset;
    int targetLength;
    long viewer;
    boolean targetValid;

    // The user fields outlive the bcrypt step: they are bound after the hash.
    String username;
    String email;
    String password;
    String bio;
    String image;

    private Call(Direct request, Services services) {
        this.request = request;
        this.services = services;
        unit = new Unit(this, this, false, false, one);
    }

    /** The exchange's pooled call, created on first use. */
    static Call of(Direct req, Services services) {
        Call call = (Call) req.slot();
        if (call == null) {
            call = new Call(req, services);
            req.slot(call);
        }
        return call;
    }

    void reset(Op op, HttpServletRequest httpRequest, Direct req,
               HttpServletResponse response, long viewer) {
        this.op = op;
        this.httpRequest = httpRequest;
        this.response = response;
        this.viewer = viewer;
        username = email = password = bio = image = null;
        tokenOffset = req.authorizationOffset() < 0 ? 0 : req.authorizationOffset() + 6;
        tokenLength = req.authorizationOffset() < 0 ? 0 : req.authorizationLength() - 6;
        if (op.targeted) {
            targetOffset = req.segmentStart(2);
            targetLength = req.segmentEnd(2) - req.segmentStart(2);
            targetValid = utf8(req.bytes(), targetOffset, targetLength);
        }
    }

    /**
     * Goes async and prepares the op's statement as the unit's only query; the
     * servlet binds the returned query and submits it.
     */
    Query start() {
        async = httpRequest.startAsync();
        query.prepare(op.stmt, op.writes);
        if (secondary != null) {
            secondary.reset();
        }
        unit.prepare(false, op.writes, one);
        return query;
    }

    /**
     * {@link #start} with a second statement in the same unit, run before the
     * op's own when {@code first}; returns the second query.
     */
    Query start(int stmt, boolean first) {
        async = httpRequest.startAsync();
        query.prepare(op.stmt, op.writes);
        if (secondary == null) {
            secondary = new Query(0, true);
        }
        secondary.prepare(stmt, true);
        two[0] = first ? secondary : query;
        two[1] = first ? query : secondary;
        unit.prepare(false, op.writes, two);
        return secondary;
    }

    /**
     * Sends the bound queries to the database; {@code then} gets the op's own
     * query.
     */
    void submit(Then then) {
        this.then = then;
        hashing = false;
        services.dispatcher().submit(unit);
    }

    /**
     * Hashes {@code password}, or checks it against {@code unit.bcryptHash} when
     * that is set; {@code then} reads the outcome from {@link #unit}.
     */
    void bcrypt(String password, Then then) {
        this.then = then;
        hashing = true;
        unit.bcryptPassword = password;
        services.bcrypt().submit(unit);
    }

    /** Binds the target path segment (a username or slug). */
    Query target(Query q) {
        return targetValid ? q.text(request.bytes(), targetOffset, targetLength) : q.text(new String(request.bytes(), targetOffset, targetLength, StandardCharsets.UTF_8));
    }

    /** From the database or bcrypt thread: run the rest on the request's loop. */
    public void post(Unit ignored) {
        async.start(this);
    }

    public void done(Unit ignored) {
        run();
    }

    public void run() {
        if (unit.errorMessage != null) {
            if (hashing) {
                fail(500, "password error");
            } else {
                fail("23505".equals(unit.sqlState) ? 422 : 500, "database error");
            }
            return;
        }
        then.done(this, query);
    }

    /** Sets the JSON content type and returns the body writer. */
    JsonWriter json() {
        response.setContentType("application/json");
        return request.output();
    }

    void complete() {
        async.complete();
    }

    /** Fails with {@code status} when {@code q} returned no rows. */
    boolean missing(Query q, int status) {
        if (q.rowCount() != 0) {
            return false;
        }
        fail(status, "not found");
        return true;
    }

    void fail(int status, String message) {
        try {
            response.sendError(status, message);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        async.complete();
    }

    private static boolean utf8(byte[] b, int offset, int length) {
        int end = offset + length;
        for (int i = offset; i < end; ) {
            int c = b[i++] & 255;
            if (c < 128) {
                continue;
            }
            int n;
            int min;
            int value;
            if (c >= 0xc2 && c <= 0xdf) {
                n = 1;
                min = 0x80;
                value = c & 31;
            } else if (c >= 0xe0 && c <= 0xef) {
                n = 2;
                min = 0x800;
                value = c & 15;
            } else if (c >= 0xf0 && c <= 0xf4) {
                n = 3;
                min = 0x10000;
                value = c & 7;
            } else {
                return false;
            }
            if (end - i < n) {
                return false;
            }
            while (n-- > 0) {
                int x = b[i++] & 255;
                if ((x & 0xc0) != 0x80) {
                    return false;
                }
                value = value << 6 | (x & 63);
            }
            if (value < min
                    || value > 0x10ffff
                    || value >= 0xd800 && value <= 0xdfff) {
                return false;
            }
        }
        return true;
    }
}
