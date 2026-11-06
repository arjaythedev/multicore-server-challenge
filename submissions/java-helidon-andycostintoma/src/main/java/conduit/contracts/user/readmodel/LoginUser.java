package conduit.contracts.user.readmodel;

public record LoginUser(
    long id,
    String email,
    String passwordHash,
    String username,
    String bio,
    String image
) {
}
