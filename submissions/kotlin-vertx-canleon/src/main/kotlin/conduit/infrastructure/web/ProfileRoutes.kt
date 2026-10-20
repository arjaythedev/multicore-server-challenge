package conduit.infrastructure.web

import io.vertx.ext.web.Router
import io.vertx.kotlin.coroutines.CoroutineRouterSupport
import conduit.application.ProfileService

fun CoroutineRouterSupport.profileRoutes(router: Router, authentication: TokenAuthentication, profileService: ProfileService) {
    router.get("/api/profiles/:username").handler(authentication.optional).coHandler { context ->
        val viewerId = context.viewerId
        val username = context.pathParameter("username")
        context.respondJson(ProfileResponse(profileService.get(viewerId, username)))
    }

    router.post("/api/profiles/:username/follow").handler(authentication.required).coHandler { context ->
        val userId = context.user.id
        val username = context.pathParameter("username")
        context.respondJson(ProfileResponse(profileService.follow(userId, username)))
    }

    router.delete("/api/profiles/:username/follow").handler(authentication.required).coHandler { context ->
        val userId = context.user.id
        val username = context.pathParameter("username")
        context.respondJson(ProfileResponse(profileService.unfollow(userId, username)))
    }
}
