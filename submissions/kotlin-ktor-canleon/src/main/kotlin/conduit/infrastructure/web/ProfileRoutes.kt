package conduit.infrastructure.web

import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import conduit.application.ProfileService

fun Route.profileRoutes(profileService: ProfileService) {
    route("/api/profiles/{username}") {
        optionalAuth {
            get {
                val viewerId = call.viewerId
                val username = call.pathParameter("username")
                call.respondJson(ProfileResponse(profileService.get(viewerId, username)))
            }
        }
    }

    route("/api/profiles/{username}/follow") {
        authenticated {
            post {
                val userId = call.user.id
                val username = call.pathParameter("username")
                call.respondJson(ProfileResponse(profileService.follow(userId, username)))
            }

            delete {
                val userId = call.user.id
                val username = call.pathParameter("username")
                call.respondJson(ProfileResponse(profileService.unfollow(userId, username)))
            }
        }
    }
}
