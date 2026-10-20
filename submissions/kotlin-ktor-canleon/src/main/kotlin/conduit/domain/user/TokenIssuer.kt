package conduit.domain.user

/** Issues the token a client authenticates with (HS256 JWT in infrastructure). */
interface TokenIssuer {
    fun issue(userId: Long): String
}
