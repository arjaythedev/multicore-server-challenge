package conduit;


import io.avaje.http.api.Controller;
import io.avaje.http.api.Get;
import io.avaje.http.api.Post;
import io.avaje.http.api.Produces;
import io.avaje.http.api.Put;
import io.helidon.webserver.http.ServerRequest;
import org.ethelred.kiwiproc.exception.UncheckedSQLException;

/** Users and auth: register, login, current user, update user. */
@Controller
class UserController implements ApiController {

    private final UserDao users;
    private final Auth auth;
    private final Jwt jwt;
    private final Passwords passwords;

    UserController(UserDao users, Auth auth, Jwt jwt, Passwords passwords) {
        this.users = users;
        this.auth = auth;
        this.jwt = jwt;
        this.passwords = passwords;
    }

    private static Dto.UserResponse wrap(UserDao.UserRow r, String token) {
        return new Dto.UserResponse(new Dto.User(r.email(), token, r.username(), r.bio(), r.image()));
    }

    /** A unique violation (SQLSTATE 23505) is a 422; anything else is unexpected. */
    static RuntimeException translate(UncheckedSQLException ex) {
        if (ex.getCause() instanceof java.sql.SQLException sql && "23505".equals(sql.getSQLState())) {
            return ApiException.invalid("username or email has already been taken");
        }
        return ex;
    }

    @Access(Access.Level.NONE)
    @Post("/api/users")
    @Produces(statusCode = 201)
    Dto.UserResponse register(Requests.Register request) {
        Requests.Register.Registration user = Body.inner(request, Requests.Register::user, "user");
        String username = Body.required(user.username(), "username");
        String email = Body.required(user.email(), "email");
        String password = Body.required(user.password(), "password");
        String hash = passwords.hash(password);
        UserDao.UserRow row;
        try {
            row = users.insert(username, email, hash);
        } catch (UncheckedSQLException ex) {
            throw translate(ex);
        }
        return wrap(row, jwt.sign(row.id()));
    }

    @Access(Access.Level.NONE)
    @Post("/api/users/login")
    @Produces(statusCode = 200)
    Dto.UserResponse login(Requests.Login request) {
        Requests.Login.Credentials user = Body.inner(request, Requests.Login::user, "user");
        String email = Body.required(user.email(), "email");
        String password = Body.required(user.password(), "password");
        UserDao.LoginRow row = users.findByEmail(email);
        if (row == null || !passwords.verify(password, row.passwordHash())) {
            throw new ApiException(401, "email or password is invalid");
        }
        return wrap(new UserDao.UserRow(row.id(), row.username(), row.email(), row.bio(), row.image()),
                jwt.sign(row.id()));
    }

    @Get("/api/user")
    Dto.UserResponse current(ServerRequest req) {
        Auth.User caller = auth.user(req);
        UserDao.UserRow row = users.findById(caller.id());
        if (row == null) {
            throw ApiException.unauthorized();
        }
        return wrap(row, caller.token());
    }

    @Put("/api/user")
    Dto.UserResponse update(ServerRequest req, Requests.UpdateUser request) {
        Auth.User caller = auth.user(req);
        Requests.UpdateUser.Changes user = Body.inner(request, Requests.UpdateUser::user, "user");
        String email = Body.optionalNonEmpty(user.email(), "email");
        String username = Body.optionalNonEmpty(user.username(), "username");
        String password = Body.optionalNonEmpty(user.password(), "password");
        String bio = user.bio();
        String image = user.image();
        String hash = password == null ? null : passwords.hash(password);
        UserDao.UserRow row;
        try {
            row = users.update(caller.id(), email, username, hash, bio, image);
        } catch (UncheckedSQLException ex) {
            throw translate(ex);
        }
        if (row == null) {
            throw ApiException.unauthorized();
        }
        return wrap(row, caller.token());
    }
}
