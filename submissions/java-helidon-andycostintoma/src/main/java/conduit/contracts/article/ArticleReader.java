package conduit.contracts.article;

import conduit.contracts.article.readmodel.ArticleDetails;
import conduit.contracts.article.readmodel.ArticlePage;
import conduit.contracts.article.readmodel.CommentView;
import java.util.List;

public interface ArticleReader {
    ArticlePage list(long viewer, int limit, long offset, String tag, String author,
        String favorited);

    ArticlePage feed(long viewer, int limit, long offset);

    ArticleDetails bySlug(long viewer, String slug);

    ArticleDetails byId(long viewer, long id);

    List<CommentView> comments(long viewer, String slug);

    CommentView comment(long viewer, String slug, long id);
}
