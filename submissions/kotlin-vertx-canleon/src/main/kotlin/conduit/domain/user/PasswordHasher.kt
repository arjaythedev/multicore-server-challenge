package conduit.domain.user

/** Hashes and checks passwords (bcrypt cost 10 in infrastructure). */
interface PasswordHasher {
    suspend fun hash(password: String): String

    suspend fun matches(password: String, hash: String): Boolean
}
