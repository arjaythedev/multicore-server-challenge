package conduit;

import io.avaje.http.api.Controller;
import io.avaje.http.api.Delete;
import io.avaje.http.api.Get;
import io.avaje.http.api.Post;
import io.avaje.http.api.Produces;
import io.avaje.jex.http.Context;

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
    Dto.ProfileResponse get(String username, Context ctx) {
        long viewer = auth.viewer(ctx);
        UserDao.ProfileRow row = users.profile(viewer, username);
        if (row == null) {
            throw ApiException.notFound("profile");
        }
        return new Dto.ProfileResponse(new Dto.Profile(row.username(), row.bio(), row.image(), row.following()));
    }

    @Post("/api/profiles/{username}/follow")
    @Produces(statusCode = 200)
    Dto.ProfileResponse follow(String username, Context ctx) {
        return setFollow(username, ctx, true);
    }

    @Delete("/api/profiles/{username}/follow")
    @Produces(statusCode = 200)
    Dto.ProfileResponse unfollow(String username, Context ctx) {
        return setFollow(username, ctx, false);
    }

    private Dto.ProfileResponse setFollow(String username, Context ctx, boolean follow) {
        Auth.User caller = auth.user(ctx);
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
