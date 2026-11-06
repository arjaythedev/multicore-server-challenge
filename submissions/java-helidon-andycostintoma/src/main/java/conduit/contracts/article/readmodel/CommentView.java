package conduit.contracts.article.readmodel;

public record CommentView(
    long id,
    String createdAt,
    String updatedAt,
    String body,
    ProfileView author
) {
}
