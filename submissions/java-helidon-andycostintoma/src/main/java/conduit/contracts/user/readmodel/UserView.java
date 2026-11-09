package conduit.contracts.user.readmodel;

public record UserView(
    String email,
    String token,
    String username,
    String bio,
    String image
) {
}
