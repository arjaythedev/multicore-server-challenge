package conduit.contracts.article.readmodel;

import java.util.List;

public record ArticleSummary(
    String slug,
    String title,
    String description,
    List<String> tagList,
    String createdAt,
    String updatedAt,
    boolean favorited,
    long favoritesCount,
    ProfileView author
) {
}
