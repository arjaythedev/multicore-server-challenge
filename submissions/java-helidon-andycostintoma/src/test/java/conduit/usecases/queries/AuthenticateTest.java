package conduit.usecases.queries;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;

import conduit.contracts.user.Tokens;
import conduit.errors.Unauthenticated;
import org.junit.jupiter.api.Test;

class AuthenticateTest {
    @Test
    void optionalMissingAuthorizationIsAnonymous() {
        var auth = new Authenticate(new FakeTokens());
        assertEquals(new Authenticate.Session(0, null), auth.execute(null, false));
    }

    @Test
    void requiredMissingTokenIsUnauthenticated() {
        var tokens = new FakeTokens();
        assertThrows(Unauthenticated.class, () -> new Authenticate(tokens).execute(null, true));
        assertEquals(0, tokens.calls);
    }

    @Test
    void optionalPresentTokenIsStillVerified() {
        var tokens = new FakeTokens();
        tokens.failure = new Unauthenticated("Invalid token");
        assertThrows(Unauthenticated.class, () -> new Authenticate(tokens).execute("bad", false));
    }

    @Test
    void verifiesEveryRequestAndPreservesPresentedToken() {
        var tokens = new FakeTokens();
        var auth = new Authenticate(tokens);
        for (var request = 0; request < 2; request++) {
            assertEquals(new Authenticate.Session(42, "signed"), auth.execute("signed", true));
        }
        assertEquals(2, tokens.calls);
    }

    @Test
    void returnsTokenVerificationFailure() {
        var tokens = new FakeTokens();
        var failure = new Unauthenticated("Invalid token");
        tokens.failure = failure;

        assertSame(failure, assertThrows(Unauthenticated.class,
            () -> new Authenticate(tokens).execute("signed", true)));
    }

    @Test
    void unexpectedTokenVerificationFailurePropagates() {
        var tokens = new FakeTokens();
        tokens.failure = new IllegalArgumentException("unexpected bug");

        assertSame(tokens.failure, assertThrows(IllegalArgumentException.class,
            () -> new Authenticate(tokens).execute("signed", true)));
    }

    private static final class FakeTokens implements Tokens {
        private int calls;
        private RuntimeException failure;

        @Override
        public String issue(long id) {
            return "signed";
        }

        @Override
        public long verify(String token) {
            calls++;
            if (failure != null) {
                throw failure;
            }
            return 42;
        }
    }
}
