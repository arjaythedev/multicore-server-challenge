package conduit.contracts.article.readmodel;

import java.util.List;

public record ArticleDetails(
    String slug,
    String title,
    String description,
    String body,
    List<String> tagList,
    String createdAt,
    String updatedAt,
    boolean favorited,
    long favoritesCount,
    ProfileView author
) {
}
