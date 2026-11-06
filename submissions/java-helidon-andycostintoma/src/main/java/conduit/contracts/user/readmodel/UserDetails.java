package conduit.contracts.user.readmodel;

public record UserDetails(
    long id,
    String email,
    String username,
    String bio,
    String image
) {
}
