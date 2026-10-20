package conduit.application

import conduit.domain.profile.Profile
import conduit.domain.profile.ProfileRepository
import conduit.domain.shared.orNotFound

class ProfileService(private val profileRepository: ProfileRepository) {

    suspend fun get(viewerId: Long, username: String): Profile {
        return profileRepository.find(viewerId, username).orNotFound("profile")
    }

    suspend fun follow(userId: Long, username: String): Profile {
        return profileRepository.follow(userId, username).orNotFound("profile")
    }

    suspend fun unfollow(userId: Long, username: String): Profile {
        return profileRepository.unfollow(userId, username).orNotFound("profile")
    }
}
