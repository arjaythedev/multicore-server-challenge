package conduit.auth

/** JWT HS256 with the claims the spec requires: {"sub":"<id>","iat":<now>,"exp":<now+30d>}. No caching (rule 7). */
object Jwt {
    /** Must be called once at startup with JWT_SECRET. */
    fun init(secret: String): Unit = TODO("auth: Jwt.init")

    /** A fresh token for [userId], issued at [nowSec] (Unix seconds), expiring 30 days later. */
    fun sign(userId: Long, nowSec: Long): String = TODO("auth: Jwt.sign")

    /**
     * Verifies signature (HS256, constant-time compare), header alg == "HS256" (any other alg, including "none",
     * is rejected), `exp` > [nowSec], and `sub` = decimal user id string > 0. Returns the user id, or 0 if invalid.
     */
    fun verify(token: String, nowSec: Long): Long = TODO("auth: Jwt.verify")
}

/**
 * bcrypt cost 10 (rule 7), run on a small pool of low-priority threads so logins never take CPU from requests.
 * Several queued jobs are computed together with interleaved lanes (bcrypt's S-box lookups are latency-bound,
 * so 2-4 independent hashes in one loop run in about the time of one).
 */
object Passwords {
    /** Starts [threads] bcrypt workers. [batchWindowMs]: how long a worker waits to collect lanes before starting. */
    fun start(threads: Int, batchWindowMs: Long): Unit = TODO("auth: Passwords.start")

    /** A new "$2b$10$..." hash with a fresh 16-byte random salt. Always suspends; resumes on a bcrypt thread. */
    suspend fun hash(password: String): String = TODO("auth: Passwords.hash")

    /** Verifies [password] against a stored $2a/$2b/$2y hash. Always suspends; resumes on a bcrypt thread. */
    suspend fun verify(password: String, hash: String): Boolean = TODO("auth: Passwords.verify")
}
