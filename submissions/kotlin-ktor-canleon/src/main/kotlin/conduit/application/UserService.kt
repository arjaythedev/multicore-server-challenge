package conduit.application

import conduit.domain.user.AuthenticatedUser
import conduit.domain.user.Login
import conduit.domain.user.PasswordHasher
import conduit.domain.user.Registration
import conduit.domain.user.TokenIssuer
import conduit.domain.user.UserChanges
import conduit.domain.user.UserRepository
import conduit.domain.user.orUnauthorized

class UserService(
    private val userRepository: UserRepository,
    private val passwordHasher: PasswordHasher,
    private val tokenIssuer: TokenIssuer,
) {
    suspend fun register(registration: Registration): AuthenticatedUser {
        val account = userRepository.insert(registration.username, registration.email, passwordHasher.hash(registration.password))
        return AuthenticatedUser(account, tokenIssuer.issue(account.id))
    }

    suspend fun login(login: Login): AuthenticatedUser {
        val account = login.authenticate(userRepository.findCredentials(login.email), passwordHasher)
        return AuthenticatedUser(account, tokenIssuer.issue(account.id))
    }

    suspend fun current(userId: Long, token: String): AuthenticatedUser {
        return AuthenticatedUser(userRepository.findById(userId).orUnauthorized(), token)
    }

    suspend fun update(userId: Long, token: String, changes: UserChanges): AuthenticatedUser {
        val passwordHash = changes.password?.let { password -> passwordHasher.hash(password) }
        val account = userRepository.update(userId, changes.email, changes.username, passwordHash, changes.bio, changes.image)
        return AuthenticatedUser(account.orUnauthorized(), token)
    }
}
