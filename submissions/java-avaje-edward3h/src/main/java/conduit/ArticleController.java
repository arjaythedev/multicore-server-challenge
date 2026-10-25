package conduit;

import java.util.List;

import io.avaje.http.api.Controller;
import io.avaje.http.api.Delete;
import io.avaje.http.api.Get;
import io.avaje.http.api.Post;
import io.avaje.http.api.Produces;
import io.avaje.http.api.Put;
import io.helidon.webserver.http.ServerRequest;

/** Articles, the feed, and favorites. */
@Controller
class ArticleController implements ApiController {

    private final ArticleDao articles;
    private final Auth auth;

    ArticleController(ArticleDao articles, Auth auth) {
        this.articles = articles;
        this.auth = auth;
    }

    private record Page(long limit, long offset) {
    }

    /** limit (default 20, 1..100) and offset (default 0, >= 0); a parameter that is present, even empty, must be valid. */
    private static Page page(ServerRequest req) {
        String limit = query(req, "limit");
        String offset = query(req, "offset");
        long l = limit == null ? 20 : Body.parseUint(limit);
        long o = offset == null ? 0 : Body.parseUint(offset);
        if (l < 1 || l > 100 || o < 0) {
            throw ApiException.invalid("limit must be 1-100 and offset >= 0");
        }
        return new Page(l, o);
    }

    private static String query(ServerRequest req, String name) {
        return req.query().first(name).orElse(null);
    }

    private static boolean given(String s) {
        return s != null && !s.isEmpty();
    }

    private static Dto.Profile author(String username, String bio, String image, boolean following) {
        return new Dto.Profile(username, bio, image, following);
    }

    private static Dto.ArticleList summaries(List<ArticleDao.ArticleRow> rows, long count) {
        return new Dto.ArticleList(rows.stream()
                .map(r -> new Dto.ArticleSummary(r.slug(), r.title(), r.description(), r.tagList(),
                        Dto.timestamp(r.createdAt()), Dto.timestamp(r.updatedAt()), r.favorited(),
                        r.favoritesCount(), author(r.username(), r.bio(), r.image(), r.following())))
                .toList(), count);
    }

    private static Dto.ArticleResponse full(ArticleDao.ArticleFullRow r) {
        if (r == null) {
            throw ApiException.notFound("article");
        }
        return new Dto.ArticleResponse(new Dto.Article(r.slug(), r.title(), r.description(), r.body(), r.tagList(),
                Dto.timestamp(r.createdAt()), Dto.timestamp(r.updatedAt()), r.favorited(), r.favoritesCount(),
                author(r.username(), r.bio(), r.image(), r.following())));
    }

    @Access(Access.Level.OPTIONAL)
    @Get("/api/articles")
    Dto.ArticleList list(ServerRequest req) {
        long viewer = auth.viewer(req);
        Page p = page(req);
        String tag = query(req, "tag");
        String author = query(req, "author");
        String favorited = query(req, "favorited");
        if (given(tag)) {
            return summaries(articles.listByTag(viewer, p.limit(), p.offset(), tag), articles.countByTag(tag));
        } else if (given(author)) {
            return summaries(articles.listByAuthor(viewer, p.limit(), p.offset(), author),
                    articles.countByAuthor(author));
        } else if (given(favorited)) {
            return summaries(articles.listFavorited(viewer, p.limit(), p.offset(), favorited),
                    articles.countFavorited(favorited));
        }
        return summaries(articles.listAll(viewer, p.limit(), p.offset()), articles.countAll());
    }

    @Get("/api/articles/feed")
    Dto.ArticleList feed(ServerRequest req) {
        Auth.User caller = auth.user(req);
        Page p = page(req);
        return summaries(articles.feed(caller.id(), p.limit(), p.offset()), articles.countFeed(caller.id()));
    }

    @Access(Access.Level.OPTIONAL)
    @Get("/api/articles/{slug}")
    Dto.ArticleResponse get(String slug, ServerRequest req) {
        return full(articles.findBySlug(auth.viewer(req), slug));
    }

    @Post("/api/articles")
    Dto.ArticleResponse create(ServerRequest req, Requests.CreateArticle request) {
        Auth.User caller = auth.user(req);
        Requests.CreateArticle.NewArticle article = Body.inner(request, Requests.CreateArticle::article, "article");
        String title = Body.required(article.title(), "title");
        String description = Body.required(article.description(), "description");
        String text = Body.required(article.body(), "body");
        List<String> tags = Body.stringList(article.tagList(), "tagList");

        long id = articles.call(d -> {
            long newId = d.insert(caller.id(), title, description, text);
            if (!tags.isEmpty()) {
                d.insertTags(tags);
                d.tagArticle(newId, tags);
            }
            return newId;
        });
        return full(articles.findById(caller.id(), id));
    }

    @Put("/api/articles/{slug}")
    Dto.ArticleResponse update(String slug, ServerRequest req, Requests.UpdateArticle request) {
        Auth.User caller = auth.user(req);
        Requests.UpdateArticle.Changes article = Body.inner(request, Requests.UpdateArticle::article, "article");
        String title = Body.optionalNonEmpty(article.title(), "title");
        String description = Body.optionalNonEmpty(article.description(), "description");
        String text = Body.optionalNonEmpty(article.body(), "body");
        ArticleDao.OwnerRow owner = owner(caller, slug);
        articles.update(owner.id(), title, description, text);
        return full(articles.findById(caller.id(), owner.id()));
    }

    @Delete("/api/articles/{slug}")
    void delete(String slug, ServerRequest req) {
        Auth.User caller = auth.user(req);
        articles.delete(owner(caller, slug).id());
    }

    @Post("/api/articles/{slug}/favorite")
    @Produces(statusCode = 200)
    Dto.ArticleResponse favorite(String slug, ServerRequest req) {
        return setFavorite(auth.user(req), slug, true);
    }

    @Delete("/api/articles/{slug}/favorite")
    @Produces(statusCode = 200)
    Dto.ArticleResponse unfavorite(String slug, ServerRequest req) {
        return setFavorite(auth.user(req), slug, false);
    }

    private Dto.ArticleResponse setFavorite(Auth.User caller, String slug, boolean favorite) {
        Long id = articles.idBySlug(slug);
        if (id == null) {
            throw ApiException.notFound("article");
        }
        if (favorite) {
            articles.favorite(caller.id(), id);
        } else {
            articles.unfavorite(caller.id(), id);
        }
        return full(articles.findById(caller.id(), id));
    }

    /** SELECT id, author_id FROM articles WHERE slug = $1: 404 if none, 403 if not the caller's. */
    private ArticleDao.OwnerRow owner(Auth.User caller, String slug) {
        ArticleDao.OwnerRow owner = articles.owner(slug);
        if (owner == null) {
            throw ApiException.notFound("article");
        }
        if (owner.authorId() != caller.id()) {
            throw ApiException.forbidden();
        }
        return owner;
    }
}
