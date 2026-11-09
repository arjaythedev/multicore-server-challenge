package conduit.usecases.commands;

import conduit.contracts.UnitOfWork;
import conduit.contracts.user.Passwords;
import conduit.contracts.user.readmodel.UserView;
import conduit.domain.User;
import java.util.function.LongFunction;

public final class RegisterUser {
    public record Request(
        String username,
        String email,
        String password
    ) {
    }

    private final UnitOfWork uow;
    private final Passwords passwords;
    private final LongFunction<String> tokens;

    public RegisterUser(UnitOfWork uow, Passwords passwords, LongFunction<String> tokens) {
        this.uow = uow;
        this.passwords = passwords;
        this.tokens = tokens;
    }

    public UserView execute(Request request) {
        var registered = User.register(
            new User.Input(request.username(), request.email(), request.password()),
            passwords::hash);
        var user = uow.run(tx -> tx.users().insert(registered));
        return new UserView(user.email(), tokens.apply(user.id()), user.username(), user.bio(),
            user.image());
    }
}
