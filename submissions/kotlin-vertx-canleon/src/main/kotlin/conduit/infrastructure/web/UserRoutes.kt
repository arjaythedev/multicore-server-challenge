package conduit.infrastructure.web

import io.netty.handler.codec.http.HttpResponseStatus
import io.vertx.ext.web.Router
import io.vertx.kotlin.coroutines.CoroutineRouterSupport
import conduit.application.UserService
import conduit.domain.user.Login
import conduit.domain.user.Registration
import conduit.domain.user.UserChanges

// Each route: the body (POST and PUT; Vert.x Web wants it first), then authentication (if any), then the handler as a
// coroutine on the event loop.

fun CoroutineRouterSupport.userRoutes(router: Router, authentication: TokenAuthentication, userService: UserService) {
    router.post("/api/users").handler(bodyHandler).coHandler { context ->
        val input = context.receiveJson<RegisterRequest>().user
        val registration = Registration.of(input.username, input.email, input.password)
        context.respondJson(UserResponse(userService.register(registration)), HttpResponseStatus.CREATED)
    }

    router.post("/api/users/login").handler(bodyHandler).coHandler { context ->
        val input = context.receiveJson<LoginRequest>().user
        val login = Login.of(input.email, input.password)
        context.respondJson(UserResponse(userService.login(login)))
    }

    router.get("/api/user").handler(authentication.required).coHandler { context ->
        val caller = context.user
        context.respondJson(UserResponse(userService.current(caller.id, caller.token)))
    }

    router.put("/api/user").handler(bodyHandler).handler(authentication.required).coHandler { context ->
        val caller = context.user
        val input = context.receiveJson<UpdateUserRequest>().user
        val changes = UserChanges.of(input.email, input.username, input.password, input.bio, input.image)
        context.respondJson(UserResponse(userService.update(caller.id, caller.token, changes)))
    }
}
