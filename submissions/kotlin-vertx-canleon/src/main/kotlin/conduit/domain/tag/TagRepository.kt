package conduit.domain.tag

interface TagRepository {
    /** Every tag, sorted by name. */
    suspend fun all(): List<String>
}
