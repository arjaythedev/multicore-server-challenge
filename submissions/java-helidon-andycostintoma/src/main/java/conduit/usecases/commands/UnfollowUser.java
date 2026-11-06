package conduit.usecases.commands;

import conduit.contracts.UnitOfWork;
import conduit.contracts.user.readmodel.UserProfile;
import conduit.errors.NotFound;

public final class UnfollowUser {
    private final UnitOfWork uow;

    public UnfollowUser(UnitOfWork uow) {
        this.uow = uow;
    }

    public UserProfile execute(String username, long viewer) {
        return uow.run(tx -> {
            var user = tx.users().byUsername(username);
            if (user == null) {
                throw new NotFound("Profile not found");
            }
            tx.follows().remove(viewer, user.id());
            return new UserProfile(user.username(), user.bio(), user.image(), false);
        });
    }
}
