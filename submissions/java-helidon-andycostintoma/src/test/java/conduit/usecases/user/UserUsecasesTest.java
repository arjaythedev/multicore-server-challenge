package conduit.usecases.user;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import conduit.contracts.UnitOfWork;
import conduit.contracts.follow.FollowStore;
import conduit.contracts.user.LoginReader;
import conduit.contracts.user.Passwords;
import conduit.contracts.user.UserReader;
import conduit.contracts.user.UserRepository;
import conduit.contracts.user.readmodel.LoginUser;
import conduit.contracts.user.readmodel.UserDetails;
import conduit.contracts.user.readmodel.UserProfile;
import conduit.domain.User;
import conduit.errors.Conflict;
import conduit.errors.InvalidInput;
import conduit.errors.NotFound;
import conduit.errors.Unauthenticated;
import conduit.usecases.commands.FollowUser;
import conduit.usecases.commands.Login;
import conduit.usecases.commands.RegisterUser;
import conduit.usecases.commands.UnfollowUser;
import conduit.usecases.commands.UpdateUser;
import conduit.usecases.queries.GetProfile;
import conduit.usecases.queries.GetUser;
import java.util.HashSet;
import java.util.Set;
import java.util.function.Function;
import org.junit.jupiter.api.Test;

class UserUsecasesTest {
    private final Store store = new Store();
    private final TestPasswords passwords = new TestPasswords();
    private final RegisterUser registerUser = new RegisterUser(store, passwords, id -> {
        assertFalse(store.active);
        return "token-" + id;
    });
    private final Login login = new Login(store, passwords, id -> {
        assertFalse(store.active);
        return "token-" + id;
    });
    private final GetUser getUser = new GetUser(store.reader);
    private final UpdateUser updateUser = new UpdateUser(store, passwords);
    private final GetProfile getProfile = new GetProfile(store.reader);
    private final FollowUser followUser = new FollowUser(store);
    private final UnfollowUser unfollowUser = new UnfollowUser(store);

    @Test
    void registrationHashesAndCommitsBeforeIssuingToken() {
        var result = registerUser
            .execute(new RegisterUser.Request("alice", "alice@example.com", "secret"));
        assertEquals("hashed:secret", store.user.passwordHash());
        assertEquals("token-1", result.token());
        assertEquals("alice@example.com", result.email());
        assertEquals(1, store.commits);
        assertEquals(1, passwords.hashCalls);
    }

    @Test
    void registrationConflictDoesNotCommitOrIssueToken() {
        store.writeFailure = "Username or email already exists";
        var operation = new RegisterUser(store, passwords, _ -> {
            throw new AssertionError("Token must not be issued after a conflict");
        });
        var thrown = assertThrows(Conflict.class,
            () -> operation.execute(new RegisterUser.Request("alice", "email", "secret")));
        assertEquals("Username or email already exists", thrown.getMessage());
        assertEquals(0, store.commits);
        assertFalse(store.active);
    }

    @Test
    void updateConflictDoesNotCommitOrChangeStoredUser() {
        seed();
        var original = store.user;
        store.writeFailure = "Username or email already exists";
        assertThrows(Conflict.class, () -> updateUser.execute(1, "token",
            new UpdateUser.Request("duplicate", null, "new-secret", null, null)));
        assertSame(original, store.user);
        assertEquals(0, store.commits);
        assertFalse(store.active);
    }

    @Test
    void unexpectedTokenFailurePropagatesAfterRegistrationCommits() {
        var failure = new IllegalStateException("Token signing failed");
        var operation = new RegisterUser(store, passwords, _ -> {
            assertFalse(store.active);
            throw failure;
        });
        assertSame(failure, assertThrows(IllegalStateException.class,
            () -> operation.execute(new RegisterUser.Request("alice", "email", "secret"))));
        assertEquals(1, store.commits);
    }

    @Test
    void unexpectedLoginTokenFailurePropagatesWithoutWriting() {
        seed();
        var failure = new IllegalStateException("Token signing failed");
        var operation = new Login(store, passwords, _ -> {
            throw failure;
        });
        assertSame(failure, assertThrows(IllegalStateException.class,
            () -> operation.execute(new Login.Request("email", "secret"))));
        assertEquals(0, store.starts);
    }

    @Test
    void invalidRegistrationDoesNotHashOrWrite() {
        assertThrows(InvalidInput.class,
            () -> registerUser.execute(new RegisterUser.Request("alice", "", "secret")));
        assertThrows(InvalidInput.class,
            () -> registerUser.execute(new RegisterUser.Request("alice", "email", "")));
        assertThrows(InvalidInput.class,
            () -> registerUser.execute(new RegisterUser.Request("", "email", "secret")));
        assertThrows(InvalidInput.class,
            () -> registerUser.execute(new RegisterUser.Request(null, "email", "secret")));
        assertThrows(InvalidInput.class,
            () -> registerUser.execute(new RegisterUser.Request("alice", "email", "界".repeat(25))));
        assertEquals(0, passwords.hashCalls);
        assertEquals(0, store.commits);
        assertEquals(0, store.starts);
    }

    @Test
    void loginRequiresMatchingPasswordAndDoesNotWrite() {
        assertThrows(Unauthenticated.class,
            () -> login.execute(new Login.Request("missing", "secret")));
        seed();
        assertThrows(Unauthenticated.class,
            () -> login.execute(new Login.Request("email", "wrong")));
        assertEquals("token-1", login.execute(new Login.Request("email", "secret")).token());
        assertEquals(0, store.commits);
    }

    @Test
    void loginRequiresNonEmptyInputs() {
        assertThrows(InvalidInput.class, () -> login.execute(new Login.Request(null, "secret")));
        assertThrows(InvalidInput.class, () -> login.execute(new Login.Request("email", "")));
        assertEquals(0, store.credentialLookups);
        assertEquals(0, passwords.matchCalls);
        assertEquals(0, store.starts);
    }

    @Test
    void currentPreservesPresentedTokenAndRejectsMissingUser() {
        assertThrows(Unauthenticated.class, () -> getUser.execute(1, "presented"));
        seed();
        var result = getUser.execute(1, "presented");
        assertEquals("presented", result.token());
        assertEquals("bio", result.bio());
        assertEquals(0, store.credentialLookups);
    }

    @Test
    void updateKeepsNullFieldsAndOnlyHashesProvidedPassword() {
        seed();
        var unchanged = updateUser.execute(1, "presented",
            new UpdateUser.Request(null, null, null, null, null));
        assertEquals("bio", unchanged.bio());
        assertEquals("hashed:secret", store.user.passwordHash());
        assertEquals(0, passwords.hashCalls);
        var updated = updateUser.execute(1, "presented",
            new UpdateUser.Request("new-email", "bob", "new-secret", "", "new-image"));
        assertEquals("presented", updated.token());
        assertEquals("bob", updated.username());
        assertEquals("new-email", updated.email());
        assertEquals("", updated.bio());
        assertEquals("new-image", updated.image());
        assertEquals("hashed:new-secret", store.user.passwordHash());
        assertEquals(2, store.commits);
        assertEquals(1, passwords.hashCalls);
    }

    @Test
    void missingUpdateUserRollsBack() {
        assertThrows(Unauthenticated.class, () -> updateUser.execute(1, "token",
            new UpdateUser.Request(null, null, null, null, null)));
        assertEquals(0, store.commits);
        assertFalse(store.active);
    }

    @Test
    void invalidUpdateDoesNotHashOrWrite() {
        seed();
        var original = store.user;
        for (var request : new UpdateUser.Request[]{
                new UpdateUser.Request(null, "", "secret", null, null),
                new UpdateUser.Request("", null, "secret", null, null),
                new UpdateUser.Request(null, null, "", null, null),
                new UpdateUser.Request(null, null, "界".repeat(25), null, null)}) {
            assertThrows(InvalidInput.class, () -> updateUser.execute(1, "token", request));
        }
        assertSame(original, store.user);
        assertEquals(0, passwords.hashCalls);
        assertEquals(0, store.commits);
        assertEquals(0, store.starts);
    }

    @Test
    void profileUsesViewerAndReportsMissingProfile() {
        assertThrows(NotFound.class, () -> getProfile.execute("alice", 0));
        seed();
        assertFalse(getProfile.execute("alice", 0).following());
        followUser.execute("alice", 2);
        assertTrue(getProfile.execute("alice", 2).following());
        assertFalse(getProfile.execute("alice", 3).following());
    }

    @Test
    void followsAreIdempotentCommittedAndAllowSelfFollow() {
        seed();
        assertTrue(followUser.execute("alice", 1).following());
        assertTrue(followUser.execute("alice", 1).following());
        assertTrue(getProfile.execute("alice", 1).following());
        assertFalse(unfollowUser.execute("alice", 1).following());
        assertFalse(unfollowUser.execute("alice", 1).following());
        assertFalse(getProfile.execute("alice", 1).following());
        assertEquals(4, store.commits);
    }

    @Test
    void missingFollowTargetDoesNotCommit() {
        assertThrows(NotFound.class, () -> followUser.execute("missing", 1));
        assertThrows(NotFound.class, () -> unfollowUser.execute("missing", 1));
        assertEquals(0, store.commits);
    }

    private void seed() {
        store.user = User
            .reconstitute(new User.Props(1, "alice", "email", "hashed:secret", "bio", null));
    }

    private final class TestPasswords implements Passwords {
        private int hashCalls;
        private int matchCalls;

        @Override
        public String hash(String password) {
            assertFalse(store.active, "Password hashing must happen before the transaction starts");
            hashCalls++;
            return "hashed:" + password;
        }

        @Override
        public boolean matches(String password, String hash) {
            assertFalse(store.active);
            matchCalls++;
            return ("hashed:" + password).equals(hash);
        }
    }

    private static final class Store
        implements
            LoginReader,
            UserRepository,
            UnitOfWork,
            FollowStore {
        private User user;
        private String writeFailure;
        private final Set<String> follows = new HashSet<>();
        private boolean active;
        private int commits;
        private int starts;
        private int credentialLookups;
        private final UserReader reader = new UserReader() {
            @Override
            public UserDetails byId(long id) {
                assertFalse(active);
                var target = user != null && user.id() == id ? user : null;
                return target == null
                    ? null
                    : new UserDetails(target.id(), target.email(), target.username(), target.bio(),
                        target.image());
            }

            @Override
            public UserProfile profile(String username, long viewer) {
                assertFalse(active);
                var target = user != null && user.username().equals(username) ? user : null;
                return target == null
                    ? null
                    : new UserProfile(target.username(), target.bio(), target.image(),
                        follows.contains(viewer + ":" + target.id()));
            }
        };

        @Override
        public <T> T run(Function<Context, T> work) {
            assertFalse(active);
            starts++;
            active = true;
            try {
                var result = work.apply(new Context(this, null, null, this, null));
                commits++;
                return result;
            } finally {
                active = false;
            }
        }

        @Override
        public User byId(long id) {
            assertTrue(active);
            return user != null && user.id() == id ? user : null;
        }

        @Override
        public LoginUser byEmail(String email) {
            assertFalse(active);
            credentialLookups++;
            return user != null && user.email().equals(email)
                ? new LoginUser(user.id(), user.email(), user.passwordHash(), user.username(),
                    user.bio(), user.image())
                : null;
        }

        @Override
        public User byUsername(String username) {
            assertTrue(active);
            return user != null && user.username().equals(username) ? user : null;
        }

        @Override
        public User insert(User draft) {
            assertTrue(active);
            assertEquals(0, draft.id());
            if (writeFailure != null) {
                throw new Conflict(writeFailure);
            }
            user = User.reconstitute(new User.Props(1, draft.username(), draft.email(),
                draft.passwordHash(), draft.bio(), draft.image()));
            return user;
        }

        @Override
        public User save(User updated) {
            assertTrue(active);
            if (writeFailure != null) {
                throw new Conflict(writeFailure);
            }
            user = updated;
            return user;
        }

        @Override
        public void add(long follower, long followee) {
            assertTrue(active);
            follows.add(follower + ":" + followee);
        }

        @Override
        public void remove(long follower, long followee) {
            assertTrue(active);
            follows.remove(follower + ":" + followee);
        }
    }
}
