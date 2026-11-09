package conduit.usecases.commands;

import conduit.contracts.user.LoginReader;
import conduit.contracts.user.Passwords;
import conduit.contracts.user.readmodel.UserView;
import conduit.errors.InvalidInput;
import conduit.errors.Unauthenticated;
import java.util.function.LongFunction;

public final class Login {
    public record Request(
        String email,
        String password
    ) {
    }

    private final LoginReader loginReader;
    private final Passwords passwords;
    private final LongFunction<String> tokens;

    public Login(LoginReader loginReader, Passwords passwords, LongFunction<String> tokens) {
        this.loginReader = loginReader;
        this.passwords = passwords;
        this.tokens = tokens;
    }

    public UserView execute(Request request) {
        if (request.email() == null || request.email().isEmpty()) {
            throw new InvalidInput("email is required");
        }
        if (request.password() == null || request.password().isEmpty()) {
            throw new InvalidInput("password is required");
        }
        var user = loginReader.byEmail(request.email());
        if (user == null || !passwords.matches(request.password(), user.passwordHash())) {
            throw new Unauthenticated("Invalid credentials");
        }
        return new UserView(user.email(), tokens.apply(user.id()), user.username(), user.bio(),
            user.image());
    }
}
