package conduit.contracts.article.readmodel;

public record ProfileView(
    String username,
    String bio,
    String image,
    boolean following
) {
}
