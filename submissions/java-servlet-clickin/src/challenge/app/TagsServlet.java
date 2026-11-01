package challenge.app;

import java.io.IOException;

import challenge.app.Conduit.Services;
import challenge.pg.Query;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import static challenge.app.Op.TAGS;

/** {@code GET /api/tags} (mapped exactly, so there is no path to route). */
final class TagsServlet extends ApiServlet {
    TagsServlet(Services services) {
        super(services);
    }

    protected void doGet(HttpServletRequest req, HttpServletResponse res) throws IOException {
        Call call = begin(TAGS, req, res);
        call.start();
        call.submit(TagsServlet::write);
    }

    private static void write(Call call, Query q) {
        Views.tags(call.json(), q);
        call.complete();
    }
}
