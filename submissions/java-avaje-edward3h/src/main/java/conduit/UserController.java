package conduit;

import java.util.Map;

import at.favre.lib.crypto.bcrypt.BCrypt;
import io.avaje.http.api.Controller;
import io.avaje.http.api.Get;
import io.avaje.http.api.Post;
import io.avaje.http.api.Produces;
import io.avaje.http.api.Put;
import io.avaje.jex.http.Context;
import org.ethelred.kiwiproc.exception.UncheckedSQLException;

/** Users and auth: register, login, current user, update user. */
@Controller
class UserController {

    /** bcrypt cost 10 for every new hash; verification uses the cost stored in the hash. */
    private static final int BCRYPT_COST = 10;

    private final UserDao users;
    private final Auth auth;
    private final Jwt jwt;
    private final Body body;

    UserController(UserDao users, Auth auth, Jwt jwt, Body body) {
        this.users = users;
        this.auth = auth;
        this.jwt = jwt;
        this.body = body;
    }

    static String hash(String password) {
        return BCrypt.withDefaults().hashToString(BCRYPT_COST, Body.hashable(password).toCharArray());
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

    @Post("/api/users")
    @Produces(statusCode = 201)
    Dto.UserResponse register(Context ctx) {
        Map<String, Object> user = body.object(ctx, "user");
        String username = Body.required(user, "username");
        String email = Body.required(user, "email");
        String password = Body.required(user, "password");
        String hash = hash(password);
        UserDao.UserRow row;
        try {
            row = users.insert(username, email, hash);
        } catch (UncheckedSQLException ex) {
            throw translate(ex);
        }
        return wrap(row, jwt.sign(row.id()));
    }

    @Post("/api/users/login")
    @Produces(statusCode = 200)
    Dto.UserResponse login(Context ctx) {
        Map<String, Object> user = body.object(ctx, "user");
        String email = Body.required(user, "email");
        String password = Body.required(user, "password");
        UserDao.LoginRow row = users.findByEmail(email);
        if (row == null || !BCrypt.verifyer().verify(password.toCharArray(), row.passwordHash()).verified) {
            throw new ApiException(401, "email or password is invalid");
        }
        return wrap(new UserDao.UserRow(row.id(), row.username(), row.email(), row.bio(), row.image()),
                jwt.sign(row.id()));
    }

    @Get("/api/user")
    Dto.UserResponse current(Context ctx) {
        Auth.User caller = auth.user(ctx);
        UserDao.UserRow row = users.findById(caller.id());
        if (row == null) {
            throw ApiException.unauthorized();
        }
        return wrap(row, caller.token());
    }

    @Put("/api/user")
    Dto.UserResponse update(Context ctx) {
        Auth.User caller = auth.user(ctx);
        Map<String, Object> user = body.object(ctx, "user");
        String email = Body.optionalNonEmpty(user, "email");
        String username = Body.optionalNonEmpty(user, "username");
        String password = Body.optionalNonEmpty(user, "password");
        String bio = Body.optional(user, "bio");
        String image = Body.optional(user, "image");
        String hash = password == null ? null : hash(password);
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
