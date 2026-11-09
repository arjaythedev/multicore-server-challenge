package conduit.adapters.outbound.security;

import at.favre.lib.crypto.bcrypt.BCrypt;
import at.favre.lib.crypto.bcrypt.LongPasswordStrategies;
import conduit.contracts.user.Passwords;
import java.util.Arrays;

public final class BCryptPasswords implements Passwords {
    private final BCrypt.Hasher hasher = BCrypt.with(BCrypt.Version.VERSION_2B);
    private final BCrypt.Verifyer verifier = BCrypt.verifyer(null,
        LongPasswordStrategies.truncate(BCrypt.Version.VERSION_2B));

    @Override
    public String hash(String password) {
        var characters = password.toCharArray();
        try {
            return hasher.hashToString(10, characters);
        } finally {
            Arrays.fill(characters, '\0');
        }
    }

    @Override
    public boolean matches(String password, String hash) {
        var characters = password.toCharArray();
        try {
            return verifier.verify(characters, hash).verified;
        } finally {
            Arrays.fill(characters, '\0');
        }
    }
}
