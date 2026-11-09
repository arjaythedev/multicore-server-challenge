package conduit.usecases.queries;

import conduit.contracts.user.Tokens;
import conduit.errors.Unauthenticated;

public final class Authenticate {
    public record Session(
        long userId,
        String token
    ) {
    }

    private final Tokens tokens;

    public Authenticate(Tokens tokens) {
        this.tokens = tokens;
    }

    public Session execute(String token, boolean required) {
        if (token == null) {
            if (required) {
                throw new Unauthenticated("Authentication required");
            }
            return new Session(0, null);
        }
        return new Session(tokens.verify(token), token);
    }
}
