package conduit.adapters.inbound.http.user;

import conduit.adapters.inbound.http.user.handlers.FollowUserHandler;
import conduit.adapters.inbound.http.user.handlers.GetProfileHandler;
import conduit.adapters.inbound.http.user.handlers.GetUserHandler;
import conduit.adapters.inbound.http.user.handlers.LoginHandler;
import conduit.adapters.inbound.http.user.handlers.RegisterUserHandler;
import conduit.adapters.inbound.http.user.handlers.UnfollowUserHandler;
import conduit.adapters.inbound.http.user.handlers.UpdateUserHandler;
import io.helidon.webserver.http.HttpRouting;

public final class UserRoutes {
    private final RegisterUserHandler registerUser;
    private final LoginHandler login;
    private final GetUserHandler getUser;
    private final UpdateUserHandler updateUser;
    private final GetProfileHandler getProfile;
    private final FollowUserHandler followUser;
    private final UnfollowUserHandler unfollowUser;

    public UserRoutes(RegisterUserHandler registerUser, LoginHandler login, GetUserHandler getUser,
        UpdateUserHandler updateUser, GetProfileHandler getProfile, FollowUserHandler followUser,
        UnfollowUserHandler unfollowUser) {
        this.registerUser = registerUser;
        this.login = login;
        this.getUser = getUser;
        this.updateUser = updateUser;
        this.getProfile = getProfile;
        this.followUser = followUser;
        this.unfollowUser = unfollowUser;
    }

    public void register(HttpRouting.Builder routes) {
        routes.post("/api/users", registerUser::handle).post("/api/users/login", login::handle)
            .get("/api/user", getUser::handle).put("/api/user", updateUser::handle)
            .get("/api/profiles/{username}", getProfile::handle)
            .post("/api/profiles/{username}/follow", followUser::handle)
            .delete("/api/profiles/{username}/follow", unfollowUser::handle);
    }
}
