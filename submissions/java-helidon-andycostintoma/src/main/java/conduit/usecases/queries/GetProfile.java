package conduit.usecases.queries;

import conduit.contracts.user.UserReader;
import conduit.contracts.user.readmodel.UserProfile;
import conduit.errors.NotFound;

public final class GetProfile {
    private final UserReader reader;

    public GetProfile(UserReader reader) {
        this.reader = reader;
    }

    public UserProfile execute(String username, long viewer) {
        var profile = reader.profile(username, viewer);
        if (profile == null) {
            throw new NotFound("Profile not found");
        }
        return profile;
    }
}
