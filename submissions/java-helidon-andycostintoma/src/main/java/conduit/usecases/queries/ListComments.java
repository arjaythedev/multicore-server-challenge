package conduit.usecases.queries;

import conduit.contracts.article.ArticleReader;
import conduit.contracts.article.readmodel.CommentView;
import java.util.List;

public final class ListComments {
    private final ArticleReader reader;

    public ListComments(ArticleReader reader) {
        this.reader = reader;
    }

    public List<CommentView> execute(long viewer, String slug) {
        return reader.comments(viewer, slug);
    }
}
