package conduit.usecases.commands;

import conduit.contracts.UnitOfWork;
import conduit.contracts.user.Passwords;
import conduit.contracts.user.readmodel.UserView;
import conduit.domain.User;
import conduit.errors.Unauthenticated;

public final class UpdateUser {
    public record Request(
        String email,
        String username,
        String password,
        String bio,
        String image
    ) {
    }

    private final UnitOfWork uow;
    private final Passwords passwords;

    public UpdateUser(UnitOfWork uow, Passwords passwords) {
        this.uow = uow;
        this.passwords = passwords;
    }

    public UserView execute(long userId, String token, Request request) {
        var changes = new User.UpdateInput(request.username(), request.email(), request.password(),
            request.bio(), request.image());
        var hash = changes.password() == null ? null : passwords.hash(changes.password());
        var user = uow.run(tx -> {
            var users = tx.users();
            var current = users.byId(userId);
            if (current == null) {
                throw new Unauthenticated("User not found");
            }
            return users.save(current.update(changes, hash));
        });
        return new UserView(user.email(), token, user.username(), user.bio(), user.image());
    }
}
