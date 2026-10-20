package conduit.infrastructure.postgres

import conduit.domain.profile.Profile
import conduit.domain.profile.ProfileRepository
import io.vertx.sqlclient.SqlClient
import io.vertx.sqlclient.Tuple

class PostgresProfileRepository(private val client: SqlClient) : ProfileRepository {

    override suspend fun find(viewerId: Long, username: String): Profile? {
        return client.execute(PROFILE, Tuple.of(viewerId, username)).firstOrNull()?.toProfile()
    }

    override suspend fun follow(followerId: Long, username: String): Profile? {
        return client.execute(FOLLOW_BY_USERNAME, Tuple.of(username, followerId)).firstOrNull()?.toProfile()
    }

    override suspend fun unfollow(followerId: Long, username: String): Profile? {
        return client.execute(UNFOLLOW_BY_USERNAME, Tuple.of(username, followerId)).firstOrNull()?.toProfile()
    }
}
