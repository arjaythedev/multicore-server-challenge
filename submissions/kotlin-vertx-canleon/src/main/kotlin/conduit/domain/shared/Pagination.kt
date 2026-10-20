package conduit.domain.shared

/** Rules for every paged list: limit 1..100 (default 20), offset >= 0 (default 0). */
object Pagination {
    const val DEFAULT_LIMIT = 20
    const val DEFAULT_OFFSET = 0
    private const val MAX_LIMIT = 100

    fun assertRange(limit: Int, offset: Int) {
        if (limit !in 1..MAX_LIMIT || offset < 0) {
            throw ValidationException("limit must be 1-$MAX_LIMIT and offset >= 0")
        }
    }
}
