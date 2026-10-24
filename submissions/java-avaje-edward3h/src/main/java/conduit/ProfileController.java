package conduit;

import io.avaje.http.api.Controller;
import io.avaje.http.api.Delete;
import io.avaje.http.api.Get;
import io.avaje.http.api.Post;
import io.avaje.http.api.Produces;
import io.helidon.webserver.http.ServerRequest;

/** Profiles and follows. */
@Controller
class ProfileController {

    private final UserDao users;
    private final Auth auth;

    ProfileController(UserDao users, Auth auth) {
        this.users = users;
        this.auth = auth;
    }

    @Get("/api/profiles/{username}")
    Dto.ProfileResponse get(String username, ServerRequest req) {
        long viewer = auth.viewer(req);
        UserDao.ProfileRow row = users.profile(viewer, username);
        if (row == null) {
            throw ApiException.notFound("profile");
        }
        return new Dto.ProfileResponse(new Dto.Profile(row.username(), row.bio(), row.image(), row.following()));
    }

    @Post("/api/profiles/{username}/follow")
    @Produces(statusCode = 200)
    Dto.ProfileResponse follow(String username, ServerRequest req) {
        return setFollow(username, req, true);
    }

    @Delete("/api/profiles/{username}/follow")
    @Produces(statusCode = 200)
    Dto.ProfileResponse unfollow(String username, ServerRequest req) {
        return setFollow(username, req, false);
    }

    private Dto.ProfileResponse setFollow(String username, ServerRequest req, boolean follow) {
        Auth.User caller = auth.user(req);
        UserDao.FolloweeRow row = users.findByUsername(username);
        if (row == null) {
            throw ApiException.notFound("profile");
        }
        if (follow) {
            users.follow(caller.id(), row.id());
        } else {
            users.unfollow(caller.id(), row.id());
        }
        return new Dto.ProfileResponse(new Dto.Profile(row.username(), row.bio(), row.image(), follow));
    }
}
