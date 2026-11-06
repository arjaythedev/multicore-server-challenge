package conduit.adapters.outbound.security;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class BCryptPasswordsTest {
    private final BCryptPasswords passwords = new BCryptPasswords();

    @Test
    void usesCostTenFreshSaltsAndChecksPassword() {
        var first = passwords.hash("password");
        var second = passwords.hash("password");

        assertTrue(first.startsWith("$2b$10$"));
        assertNotEquals(first, second);
        assertTrue(passwords.matches("password", first));
        assertFalse(passwords.matches("wrong", first));
        assertFalse(passwords.matches("password", "invalid hash"));
    }

    @Test
    void handlesUtf8AndRejectsHashingPasswordsBeyondBcryptKeyLength() {
        for (var password : new String[]{"héllo世界", "x".repeat(72), "界".repeat(24)}) {
            assertTrue(passwords.matches(password, passwords.hash(password)));
        }
        assertThrows(IllegalArgumentException.class, () -> passwords.hash("x".repeat(73)));
    }
}
