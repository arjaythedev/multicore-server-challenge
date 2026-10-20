package conduit.domain.user

import conduit.domain.shared.UnauthorizedException
import conduit.domain.shared.ValidationException
import conduit.domain.shared.requireNotEmpty
import conduit.domain.shared.requireNotEmptyIfGiven

class UserAccount(val id: Long, val username: String, val email: String, val bio: String?, val image: String?)

/** A logged-in user and their token: what register, login and the current-user endpoints return. */
class AuthenticatedUser(val account: UserAccount, val token: String)

/** A stored account with its password hash: what a login is checked against. */
class Credentials(val account: UserAccount, val passwordHash: String)

object Password {
    private const val MAX_BYTES = 72

    /** bcrypt only hashes 72 bytes, so longer passwords are refused rather than silently truncated. */
    fun validated(password: String): String {
        if (password.toByteArray().size > MAX_BYTES) throw ValidationException("password is too long")
        return password
    }
}

class Registration private constructor(val username: String, val email: String, val password: String) {
    companion object {
        fun of(username: String?, email: String?, password: String?): Registration {
            return Registration(username.requireNotEmpty("username"), email.requireNotEmpty("email"), Password.validated(password.requireNotEmpty("password")))
        }
    }
}

class Login private constructor(val email: String, val password: String) {

    /** The account, if [credentials] exist for this email and the password matches them. */
    suspend fun authenticate(credentials: Credentials?, passwordHasher: PasswordHasher): UserAccount {
        if (credentials == null || !passwordHasher.matches(password, credentials.passwordHash)) {
            throw UnauthorizedException("email or password is invalid")
        }
        return credentials.account
    }

    companion object {
        fun of(email: String?, password: String?): Login {
            return Login(email.requireNotEmpty("email"), password.requireNotEmpty("password"))
        }
    }
}

/** null fields stay unchanged; given email, username and password must not be empty. */
class UserChanges private constructor(
    val email: String?,
    val username: String?,
    val password: String?,
    val bio: String?,
    val image: String?,
) {
    companion object {
        fun of(email: String?, username: String?, password: String?, bio: String?, image: String?): UserChanges {
            val validPassword = password.requireNotEmptyIfGiven("password")?.let(Password::validated)
            return UserChanges(email.requireNotEmptyIfGiven("email"), username.requireNotEmptyIfGiven("username"), validPassword, bio, image)
        }
    }
}

/** A valid token whose user no longer exists is treated like an invalid token. */
fun UserAccount?.orUnauthorized(): UserAccount {
    return this ?: throw UnauthorizedException()
}
