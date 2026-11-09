package conduit.usecases.queries;

import conduit.contracts.user.UserReader;
import conduit.contracts.user.readmodel.UserView;
import conduit.errors.Unauthenticated;

public final class GetUser {
    private final UserReader reader;

    public GetUser(UserReader reader) {
        this.reader = reader;
    }

    public UserView execute(long userId, String token) {
        var user = reader.byId(userId);
        if (user == null) {
            throw new Unauthenticated("User not found");
        }
        return new UserView(user.email(), token, user.username(), user.bio(), user.image());
    }
}
