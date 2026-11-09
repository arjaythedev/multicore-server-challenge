package conduit.contracts.user;

public interface Tokens {
    String issue(long userId);

    long verify(String token);
}
