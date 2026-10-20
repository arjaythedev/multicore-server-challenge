package conduit.infrastructure.postgres

import conduit.domain.tag.TagRepository
import io.vertx.sqlclient.SqlClient
import io.vertx.sqlclient.Tuple

class PostgresTagRepository(private val client: SqlClient) : TagRepository {

    override suspend fun all(): List<String> {
        val rows = client.execute(TAGS, Tuple.tuple())
        val tags = ArrayList<String>(rows.size())
        for (row in rows) {
            tags.add(row.getString("name"))
        }
        return tags
    }
}
