package conduit.contracts.article;

import conduit.domain.Article;
import java.util.List;

public interface ArticleRepository {
    long nextArticleId();

    long articleId(String slug);

    Article article(String slug);

    void insert(Article article, List<String> tags);

    void update(Article article);

    void deleteArticle(long id);
}
