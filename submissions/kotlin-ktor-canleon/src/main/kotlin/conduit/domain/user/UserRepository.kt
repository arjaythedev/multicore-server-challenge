package conduit.domain.user

interface UserRepository {
    /** Throws a ValidationException if the username or email is already taken. */
    suspend fun insert(username: String, email: String, passwordHash: String): UserAccount

    suspend fun findCredentials(email: String): Credentials?

    suspend fun findById(id: Long): UserAccount?

    /** null arguments leave the field unchanged; null result: no such user. Throws a ValidationException on a duplicate. */
    suspend fun update(id: Long, email: String?, username: String?, passwordHash: String?, bio: String?, image: String?): UserAccount?
}
