package conduit.contracts.user;

public interface Passwords {
    String hash(String password);

    boolean matches(String password, String hash);
}
