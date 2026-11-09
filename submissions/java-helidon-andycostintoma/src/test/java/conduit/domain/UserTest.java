package conduit.domain;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import conduit.errors.InvalidInput;
import org.junit.jupiter.api.Test;

class UserTest {
    @Test
    void registersWithUnassignedIdentityAndNullableProfile() {
        var user = User.register(new User.Input("alice", "alice@example.com", "secret"),
            _ -> "hash");
        assertEquals(0, user.id());
        assertEquals("hash", user.passwordHash());
        assertNull(user.bio());
        assertNull(user.image());
    }

    @Test
    void rejectsInvalidRegistrationBeforeHashing() {
        assertThrows(InvalidInput.class,
            () -> User.register(new User.Input("", "email", "secret"), UserTest::unexpectedHash));
        assertThrows(InvalidInput.class,
            () -> User.register(new User.Input("alice", null, "secret"), UserTest::unexpectedHash));
        assertThrows(InvalidInput.class,
            () -> User.register(new User.Input("alice", "email", ""), UserTest::unexpectedHash));
    }

    @Test
    void nullUpdatesPreserveAllExistingFields() {
        var user = User.reconstitute(new User.Props(1, "alice", "email", "hash", "bio", "image"));
        var updated = user.update(new User.UpdateInput(null, null, null, null, null), null);
        assertUpdated(updated, "alice", "hash", "bio", "image");
    }

    @Test
    void changesRejectEmptyIdentityFields() {
        assertThrows(InvalidInput.class, () -> new User.UpdateInput("", null, null, null, null));
        assertThrows(InvalidInput.class, () -> new User.UpdateInput(null, "", null, null, null));
        assertThrows(InvalidInput.class, () -> new User.UpdateInput(null, null, "", null, null));
    }

    @Test
    void passwordLimitCountsUtf8BytesRatherThanCharacters() {
        assertDoesNotThrow(() -> changePassword("x".repeat(72)));
        assertDoesNotThrow(() -> changePassword("界".repeat(24)));
        assertThrows(InvalidInput.class, () -> changePassword("x".repeat(73)));
        assertThrows(InvalidInput.class, () -> changePassword("界".repeat(25)));
        assertThrows(InvalidInput.class,
            () -> User.register(new User.Input("alice", "email", null), UserTest::unexpectedHash));
    }

    @Test
    void updatesReplaceOnlyProvidedFieldsAndKeepIdentity() {
        var user = User.reconstitute(new User.Props(1, "alice", "email", "hash", "bio", "image"));
        var updated = user.update(new User.UpdateInput("bob", null, "secret", "", "new-image"),
            "new-hash");
        assertUpdated(updated, "bob", "new-hash", "", "new-image");
        assertEquals("alice", user.username());
    }

    private static void assertUpdated(User user, String username, String passwordHash, String bio,
        String image) {
        assertEquals(1, user.id());
        assertEquals(username, user.username());
        assertEquals("email", user.email());
        assertEquals(passwordHash, user.passwordHash());
        assertEquals(bio, user.bio());
        assertEquals(image, user.image());
    }

    private static User.UpdateInput changePassword(String password) {
        return new User.UpdateInput(null, null, password, null, null);
    }

    private static String unexpectedHash(String password) {
        throw new AssertionError("invalid registration hashed a password");
    }
}
