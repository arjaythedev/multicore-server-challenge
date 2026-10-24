package conduit;

import java.util.Map;

import io.avaje.http.api.Controller;
import io.avaje.http.api.Delete;
import io.avaje.http.api.Get;
import io.avaje.http.api.Post;
import io.avaje.jex.http.Context;

/** Comments on an article. */
@Controller
class CommentController {

    private final CommentDao comments;
    private final ArticleDao articles;
    private final Auth auth;
    private final Body body;

    CommentController(CommentDao comments, ArticleDao articles, Auth auth, Body body) {
        this.comments = comments;
        this.articles = articles;
        this.auth = auth;
        this.body = body;
    }

    private long articleId(String slug) {
        Long id = articles.idBySlug(slug);
        if (id == null) {
            throw ApiException.notFound("article");
        }
        return id;
    }

    @Get("/api/articles/{slug}/comments")
    Dto.CommentList list(String slug, Context ctx) {
        long viewer = auth.viewer(ctx);
        long articleId = articleId(slug);
        return new Dto.CommentList(comments.list(viewer, articleId).stream()
                .map(r -> new Dto.Comment(r.id(), Dto.timestamp(r.createdAt()), Dto.timestamp(r.updatedAt()),
                        r.body(), new Dto.Profile(r.username(), r.bio(), r.image(), r.following())))
                .toList());
    }

    @Post("/api/articles/{slug}/comments")
    Dto.CommentResponse create(String slug, Context ctx) {
        Auth.User caller = auth.user(ctx);
        String text = Body.required(body.object(ctx, "comment"), "body");
        long articleId = articleId(slug);
        CommentDao.NewCommentRow r = comments.insert(articleId, caller.id(), text);
        return new Dto.CommentResponse(new Dto.Comment(r.id(), Dto.timestamp(r.createdAt()),
                Dto.timestamp(r.updatedAt()), r.body(), new Dto.Profile(r.username(), r.bio(), r.image(), false)));
    }

    @Delete("/api/articles/{slug}/comments/{id}")
    void delete(String slug, String id, Context ctx) {
        Auth.User caller = auth.user(ctx);
        long commentId = Body.parseUint(id);
        Long author = commentId < 0 ? null : comments.authorOf(commentId, slug);
        if (author == null) {
            throw ApiException.notFound("comment");
        }
        if (author != caller.id()) {
            throw ApiException.forbidden();
        }
        comments.delete(commentId);
    }
}
