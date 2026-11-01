package challenge.app;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import challenge.JsonWriter;
import challenge.app.Conduit.Services;
import challenge.app.Inputs.Body;
import challenge.app.Inputs.Invalid;
import challenge.app.Inputs.Params;
import challenge.pg.Query;
import challenge.pg.Stmt;
import challenge.servlet.Direct;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import static challenge.app.Op.ARTICLE;
import static challenge.app.Op.ARTICLES;
import static challenge.app.Op.ARTICLES_AUTHOR;
import static challenge.app.Op.ARTICLES_FAVORITED;
import static challenge.app.Op.ARTICLES_TAG;
import static challenge.app.Op.COMMENTS;
import static challenge.app.Op.CREATE_ARTICLE;
import static challenge.app.Op.CREATE_COMMENT;
import static challenge.app.Op.DELETE_ARTICLE;
import static challenge.app.Op.DELETE_COMMENT;
import static challenge.app.Op.FAVORITE;
import static challenge.app.Op.FEED;
import static challenge.app.Op.UNFAVORITE;
import static challenge.app.Op.UPDATE_ARTICLE;

/**
 * {@code /api/articles}, the feed, one article, its favorite and its
 * comments.
 */
final class ArticlesServlet extends ApiServlet {
    /** The list op by filter parameter index. */
    private static final Op[] FILTERED = {ARTICLES, null, ARTICLES_TAG, ARTICLES_AUTHOR, ARTICLES_FAVORITED};

    ArticlesServlet(Services services) {
        super(services);
    }

    /**
     * {@code /api/articles}, {@code /feed}, {@code /{slug}} and {@code
     * /{slug}/comments}.
     */
    protected void doGet(HttpServletRequest req, HttpServletResponse res) throws IOException {
        Direct r = Direct.of(req);
        switch (r.segmentCount()) {
            case 2 -> list(ARTICLES, req, res);
            case 3 -> {
                if (r.segmentIs(2, "feed")) {
                    list(FEED, req, res);
                } else {
                    targeted(ARTICLE, ArticlesServlet::article, req, res);
                }
            }
            case 4 -> {
                if (r.segmentIs(3, "comments")) {
                    targeted(COMMENTS, ArticlesServlet::comments, req, res);
                } else {
                    notFound(res);
                }
            }
            default -> notFound(res);
        }
    }

    /**
     * {@code /api/articles}, {@code /{slug}/favorite} and {@code
     * /{slug}/comments}.
     */
    protected void doPost(HttpServletRequest req, HttpServletResponse res) throws IOException {
        Direct r = Direct.of(req);
        switch (r.segmentCount()) {
            case 2 -> create(req, res);
            case 4 -> {
                if (r.segmentIs(3, "favorite")) {
                    favorite(FAVORITE, req, res);
                } else if (r.segmentIs(3, "comments")) {
                    comment(req, res);
                } else {
                    notFound(res);
                }
            }
            default -> notFound(res);
        }
    }

    /** {@code PUT /api/articles/{slug}}: changes the given fields, author only. */
    protected void doPut(HttpServletRequest req, HttpServletResponse res) throws IOException {
        if (Direct.of(req).segmentCount() != 3) {
            notFound(res);
            return;
        }
        Call call = begin(UPDATE_ARTICLE, req, res);
        if (call == null) {
            return;
        }
        String title;
        String description;
        String text;
        try {
            Body body = Inputs.body(call.request, "article");
            title = Inputs.field(body, "title", false, true);
            description = Inputs.field(body, "description", false, true);
            text = Inputs.field(body, "body", false, true);
        } catch (Invalid e) {
            res.sendError(422, "invalid body");
            return;
        }
        call.target(call.start().int8(call.viewer))
            .text(title)
            .text(description)
            .text(text)
            .text(title == null ? null : Formats.slugify(title));
        call.submit(ArticlesServlet::updated);
    }

    /**
     * {@code /api/articles/{slug}}, {@code /{slug}/favorite} and {@code
     * /{slug}/comments/{id}}.
     */
    protected void doDelete(HttpServletRequest req, HttpServletResponse res) throws IOException {
        Direct r = Direct.of(req);
        switch (r.segmentCount()) {
            case 3 -> targeted(DELETE_ARTICLE, ArticlesServlet::deleted, req, res);
            case 4 -> {
                if (r.segmentIs(3, "favorite")) {
                    favorite(UNFAVORITE, req, res);
                } else {
                    notFound(res);
                }
            }
            case 5 -> {
                if (r.segmentIs(3, "comments")) {
                    uncomment(req, res);
                } else {
                    notFound(res);
                }
            }
            default -> notFound(res);
        }
    }

    /**
     * The article list or the feed, paged. A tag, author or favorited filter
     * (query parameter 2, 3 or 4) picks the list's statement.
     */
    private void list(Op op, HttpServletRequest req, HttpServletResponse res) throws IOException {
        Call call = begin(op, req, res);
        if (call == null) {
            return;
        }
        Params params = call.params;
        int limit;
        int offset;
        try {
            params.parse(call.request);
            limit = params.page(0, 20, 1, 100);
            offset = params.page(1, 0, 0, Integer.MAX_VALUE);
        } catch (Invalid | IllegalArgumentException e) {
            res.sendError(422, "invalid parameters");
            return;
        }
        int p = call.op == FEED
                ? 0
                : params.length(2) > 0
                        ? 2
                        : params.length(3) > 0
                                ? 3
                                : params.length(4) > 0 ? 4 : 0;
        call.op = call.op == FEED ? FEED : FILTERED[p];
        Query q = call.start()
                      .int8(call.viewer)
                      .int4(limit)
                      .int4(offset);
        if (p != 0) {
            q.text(params.bytes(), params.offset(p), params.length(p));
        }
        call.submit(ArticlesServlet::articles);
    }

    /** Inserts the tags, then the article. */
    private void create(HttpServletRequest req, HttpServletResponse res) throws IOException {
        Call call = begin(CREATE_ARTICLE, req, res);
        if (call == null) {
            return;
        }
        String title;
        String description;
        String text;
        String[] tags;
        try {
            Body body = Inputs.body(call.request, "article");
            title = Inputs.field(body, "title", true, true);
            description = Inputs.field(body, "description", true, true);
            text = Inputs.field(body, "body", true, true);
            tags = Inputs.stringArray(body, "tagList");
        } catch (Invalid e) {
            res.sendError(422, "invalid body");
            return;
        }
        tags = tags == null ? new String[0] : tags;
        call.start(Stmt.INSERT_TAGS, true).textArray(tags);
        call.query.int8(call.viewer)
            .text(title)
            .text(description)
            .text(text)
            .textArray(tags)
            .text(Formats.slugify(title));
        call.submit(ArticlesServlet::created);
    }

    /** Favorites or unfavorites, then reads the article back. */
    private void favorite(Op op, HttpServletRequest req, HttpServletResponse res) throws IOException {
        Call call = begin(op, req, res);
        if (call == null) {
            return;
        }
        call.target(call.start(Stmt.ARTICLE, false).int8(call.viewer));
        call.target(call.query.int8(call.viewer));
        call.submit(ArticlesServlet::favorited);
    }

    private void comment(HttpServletRequest req, HttpServletResponse res) throws IOException {
        Call call = begin(CREATE_COMMENT, req, res);
        if (call == null) {
            return;
        }
        String text;
        try {
            text = Inputs.field(Inputs.body(call.request, "comment"), "body", true, true);
        } catch (Invalid e) {
            res.sendError(422, "invalid body");
            return;
        }
        call.target(call.start().int8(call.viewer)).text(text);
        call.submit(ArticlesServlet::commented);
    }

    /** Deletes the comment, author only; a non-numeric id is not found. */
    private void uncomment(HttpServletRequest req, HttpServletResponse res) throws IOException {
        Call call = begin(DELETE_COMMENT, req, res);
        if (call == null) {
            return;
        }
        Direct r = call.request;
        long id;
        try {
            id = Long.parseLong(new String(r.bytes(), r.segmentStart(4), r.segmentEnd(4) - r.segmentStart(4),
                    StandardCharsets.UTF_8));
        } catch (NumberFormatException e) {
            notFound(res);
            return;
        }
        call.target(call.start().int8(call.viewer)).int8(id);
        call.submit(ArticlesServlet::deleted);
    }

    private static void articles(Call call, Query q) {
        Views.articles(call.json(), q);
        call.complete();
    }

    private static void article(Call call, Query q) {
        if (!call.missing(q, 404)) {
            write(call, q);
        }
    }

    private static void created(Call call, Query q) {
        if (!call.missing(q, 401)) {
            call.response.setStatus(201);
            write(call, q);
        }
    }

    private static void updated(Call call, Query q) {
        if (call.missing(q, 404)) {
            return;
        }
        if (q.isNull(0, 0)) {
            call.fail(403, "forbidden");
        } else {
            write(call, q);
        }
    }

    private static void favorited(Call call, Query q) {
        if (!call.missing(call.secondary, 404)) {
            write(call, call.secondary);
        }
    }

    private static void deleted(Call call, Query q) {
        if (call.missing(q, 404)) {
            return;
        }
        if (!q.boolAt(0, 0)) {
            call.fail(403, "forbidden");
        } else {
            call.response.setStatus(204);
            call.complete();
        }
    }

    private static void comments(Call call, Query q) {
        if (!call.missing(q, 404)) {
            Views.comments(call.json(), q);
            call.complete();
        }
    }

    private static void commented(Call call, Query q) {
        if (call.missing(q, 404)) {
            return;
        }
        call.response.setStatus(201);
        JsonWriter out = call.json();
        Views.raw(out, "{\"comment\":");
        Views.comment(out, q, 0, false);
        out.put('}');
        call.complete();
    }

    private static void write(Call call, Query q) {
        JsonWriter out = call.json();
        Views.raw(out, "{\"article\":");
        Views.article(out, q, 0, true);
        out.put('}');
        call.complete();
    }
}
