package conduit.adapters.inbound.http.article;

import conduit.adapters.inbound.http.article.handlers.AddCommentHandler;
import conduit.adapters.inbound.http.article.handlers.CreateArticleHandler;
import conduit.adapters.inbound.http.article.handlers.DeleteArticleHandler;
import conduit.adapters.inbound.http.article.handlers.DeleteCommentHandler;
import conduit.adapters.inbound.http.article.handlers.FavoriteArticleHandler;
import conduit.adapters.inbound.http.article.handlers.GetArticleHandler;
import conduit.adapters.inbound.http.article.handlers.ListArticlesHandler;
import conduit.adapters.inbound.http.article.handlers.ListCommentsHandler;
import conduit.adapters.inbound.http.article.handlers.ListFeedHandler;
import conduit.adapters.inbound.http.article.handlers.UnfavoriteArticleHandler;
import conduit.adapters.inbound.http.article.handlers.UpdateArticleHandler;
import io.helidon.webserver.http.HttpRouting;

public final class ArticleRoutes {
    private final CreateArticleHandler createArticle;
    private final UpdateArticleHandler updateArticle;
    private final DeleteArticleHandler deleteArticle;
    private final FavoriteArticleHandler favoriteArticle;
    private final UnfavoriteArticleHandler unfavoriteArticle;
    private final AddCommentHandler addComment;
    private final DeleteCommentHandler deleteComment;
    private final GetArticleHandler getArticle;
    private final ListArticlesHandler listArticles;
    private final ListFeedHandler listFeed;
    private final ListCommentsHandler listComments;

    public ArticleRoutes(CreateArticleHandler createArticle, UpdateArticleHandler updateArticle,
        DeleteArticleHandler deleteArticle, FavoriteArticleHandler favoriteArticle,
        UnfavoriteArticleHandler unfavoriteArticle, AddCommentHandler addComment,
        DeleteCommentHandler deleteComment, GetArticleHandler getArticle,
        ListArticlesHandler listArticles, ListFeedHandler listFeed,
        ListCommentsHandler listComments) {
        this.createArticle = createArticle;
        this.updateArticle = updateArticle;
        this.deleteArticle = deleteArticle;
        this.favoriteArticle = favoriteArticle;
        this.unfavoriteArticle = unfavoriteArticle;
        this.addComment = addComment;
        this.deleteComment = deleteComment;
        this.getArticle = getArticle;
        this.listArticles = listArticles;
        this.listFeed = listFeed;
        this.listComments = listComments;
    }

    public void register(HttpRouting.Builder routes) {
        routes.get("/api/articles/feed", listFeed::handle)
            .get("/api/articles", listArticles::handle).post("/api/articles", createArticle::handle)
            .get("/api/articles/{slug}", getArticle::handle)
            .put("/api/articles/{slug}", updateArticle::handle)
            .delete("/api/articles/{slug}", deleteArticle::handle)
            .post("/api/articles/{slug}/favorite", favoriteArticle::handle)
            .delete("/api/articles/{slug}/favorite", unfavoriteArticle::handle)
            .get("/api/articles/{slug}/comments", listComments::handle)
            .post("/api/articles/{slug}/comments", addComment::handle)
            .delete("/api/articles/{slug}/comments/{id}", deleteComment::handle);
    }
}
