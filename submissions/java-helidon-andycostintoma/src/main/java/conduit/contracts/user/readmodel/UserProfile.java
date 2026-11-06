package conduit.contracts.user.readmodel;

public record UserProfile(
    String username,
    String bio,
    String image,
    boolean following
) {
}
