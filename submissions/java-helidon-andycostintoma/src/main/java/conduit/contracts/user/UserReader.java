package conduit.contracts.user;

import conduit.contracts.user.readmodel.UserDetails;
import conduit.contracts.user.readmodel.UserProfile;

public interface UserReader {
    UserDetails byId(long id);

    UserProfile profile(String username, long viewer);
}
