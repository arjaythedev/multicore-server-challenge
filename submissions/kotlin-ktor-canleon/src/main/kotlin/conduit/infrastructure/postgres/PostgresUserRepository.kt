package conduit.infrastructure.postgres

import conduit.domain.user.Credentials
import conduit.domain.user.UserAccount
import conduit.domain.user.UserRepository
import io.vertx.sqlclient.SqlClient
import io.vertx.sqlclient.Tuple

class PostgresUserRepository(private val client: SqlClient) : UserRepository {

    override suspend fun insert(username: String, email: String, passwordHash: String): UserAccount {
        return translateUniqueViolation {
            client.execute(USER_INSERT, Tuple.of(username, email, passwordHash)).first().toAccount()
        }
    }

    override suspend fun findCredentials(email: String): Credentials? {
        val row = client.execute(USER_BY_EMAIL, Tuple.of(email)).firstOrNull() ?: return null
        return Credentials(row.toAccount(), row.getString("password_hash"))
    }

    override suspend fun findById(id: Long): UserAccount? {
        return client.execute(USER_BY_ID, Tuple.of(id)).firstOrNull()?.toAccount()
    }

    override suspend fun update(id: Long, email: String?, username: String?, passwordHash: String?, bio: String?, image: String?): UserAccount? {
        val arguments = Tuple.tuple()
            .addString(email)
            .addString(username)
            .addString(passwordHash)
            .addString(bio)
            .addString(image)
            .addLong(id)
        return translateUniqueViolation {
            client.execute(USER_UPDATE, arguments).firstOrNull()?.toAccount()
        }
    }
}
