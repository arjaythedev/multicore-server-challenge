package conduit.contracts.user;

import conduit.domain.User;

public interface UserRepository {
    User byId(long id);

    User byUsername(String username);

    User insert(User user);

    User save(User user);
}
