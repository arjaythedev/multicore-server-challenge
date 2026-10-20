package conduit.infrastructure.security

import conduit.domain.user.PasswordHasher
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext
import org.bouncycastle.crypto.generators.OpenBSDBCrypt
import java.security.SecureRandom
import java.util.concurrent.Executors

/**
 * bcrypt cost 10 for new hashes; verification uses the cost stored in the hash. Bouncy Castle's OpenBSDBCrypt was the
 * fastest of the plain Java implementations we measured (51 ms per verify vs 56-61 ms for jBCrypt and at.favre).
 *
 * A check takes ~50 ms of CPU, so it runs on its own small thread pool ([threads], half the cores): request threads
 * never block on it, and a burst of logins can't take every core away from Postgres.
 */
class BcryptPasswordHasher(threads: Int) : PasswordHasher {
    private val random = SecureRandom()
    private val dispatcher: CoroutineDispatcher = Executors.newFixedThreadPool(threads) { task ->
        Thread(task, "bcrypt").apply { isDaemon = true }
    }.asCoroutineDispatcher()

    override suspend fun hash(password: String): String {
        return withContext(dispatcher) {
            val salt = ByteArray(16)
            random.nextBytes(salt)
            OpenBSDBCrypt.generate("2a", password.toCharArray(), salt, 10)
        }
    }

    override suspend fun matches(password: String, hash: String): Boolean {
        return withContext(dispatcher) {
            try {
                OpenBSDBCrypt.checkPassword(hash, password.toCharArray())
            } catch (exception: IllegalArgumentException) {
                // a malformed stored hash, or a password over bcrypt's 72-byte limit
                false
            }
        }
    }
}
