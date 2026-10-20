package conduit.infrastructure.web

import io.ktor.http.HttpStatusCode
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import conduit.application.UserService
import conduit.domain.user.Login
import conduit.domain.user.Registration
import conduit.domain.user.UserChanges

// Routes are declared path first, with authentication only around the method handlers: each path then exists once
// in the routing tree, so Ktor resolves it by direct lookup instead of searching every authentication branch.

fun Route.userRoutes(userService: UserService) {
    route("/api/users") {
        post {
            val input = call.receiveJson<RegisterRequest>().user
            val registration = Registration.of(input.username, input.email, input.password)
            call.respondJson(UserResponse(userService.register(registration)), HttpStatusCode.Created)
        }
    }

    route("/api/users/login") {
        post {
            val input = call.receiveJson<LoginRequest>().user
            val login = Login.of(input.email, input.password)
            call.respondJson(UserResponse(userService.login(login)))
        }
    }

    route("/api/user") {
        authenticated {
            get {
                val caller = call.user
                call.respondJson(UserResponse(userService.current(caller.id, caller.token)))
            }

            put {
                val caller = call.user
                val input = call.receiveJson<UpdateUserRequest>().user
                val changes = UserChanges.of(input.email, input.username, input.password, input.bio, input.image)
                call.respondJson(UserResponse(userService.update(caller.id, caller.token, changes)))
            }
        }
    }
}
