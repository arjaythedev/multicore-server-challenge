package conduit.domain.profile

interface ProfileRepository {
    suspend fun find(viewerId: Long, username: String): Profile?

    /** Follows the user (idempotent) and returns their profile as the follower now sees it; null if there's no such user. */
    suspend fun follow(followerId: Long, username: String): Profile?

    /** Unfollows the user (idempotent) and returns their profile as the follower now sees it; null if there's no such user. */
    suspend fun unfollow(followerId: Long, username: String): Profile?
}
