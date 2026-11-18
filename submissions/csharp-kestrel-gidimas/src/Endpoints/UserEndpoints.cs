using System.Security.Claims;
using Conduit.Auth;
using Conduit.Data;
using Conduit.Json;
using Dapper;
using Npgsql;

namespace Conduit.Endpoints;

/// <summary>Registration, login and the current user.</summary>
public static class UserEndpoints
{
    public static void MapUserEndpoints(this RouteGroupBuilder api)
    {
        api.MapPost("/users", Register).RequireRateLimiting(RateLimits.PasswordHashing);
        api.MapPost("/users/login", Login).RequireRateLimiting(RateLimits.PasswordHashing);
        api.MapGet("/user", GetCurrent).RequireAuthorization();
        api.MapPut("/user", Update).RequireAuthorization();
    }

    private static async Task<IResult> Register(RegisterRequest request, NpgsqlDataSource db, TokenService tokens)
    {
        var input = request.User;
        if (input is null || string.IsNullOrEmpty(input.Username) || string.IsNullOrEmpty(input.Email) || string.IsNullOrEmpty(input.Password))
        {
            return ApiErrors.Unprocessable("username, email and password are required");
        }

        if (Passwords.TooLong(input.Password))
        {
            return ApiErrors.Unprocessable("password must be at most 72 bytes");
        }

        var passwordHash = Passwords.Hash(input.Password);
        UserRow user;
        try
        {
            await using var conn = await db.OpenConnectionAsync();
            user = await conn.QuerySingleAsync<UserRow>(Sql.InsertUser, new { input.Username, input.Email, passwordHash });
        }
        catch (PostgresException e) when (e.IsUniqueViolation())
        {
            return ApiErrors.Unprocessable("username or email already taken");
        }

        return Results.Json(new UserResponse(user.ToDto(tokens.Issue(user.Id))), statusCode: StatusCodes.Status201Created);
    }

    private static async Task<IResult> Login(LoginRequest request, NpgsqlDataSource db, TokenService tokens)
    {
        var input = request.User;
        if (input is null || string.IsNullOrEmpty(input.Email) || string.IsNullOrEmpty(input.Password))
        {
            return ApiErrors.Unprocessable("email and password are required");
        }

        // A password over 72 bytes can never be the one that was stored (registration rejects them).
        if (Passwords.TooLong(input.Password))
        {
            return ApiErrors.Unauthorized();
        }

        UserRow? user;
        await using (var conn = await db.OpenConnectionAsync())
        {
            user = await conn.QuerySingleOrDefaultAsync<UserRow>(Sql.UserByEmail, new { input.Email });
        }

        // The connection goes back to the pool before the (slow) bcrypt check.
        if (user is null || !Passwords.Verify(input.Password, user.PasswordHash))
        {
            return ApiErrors.Unauthorized();
        }

        return TypedResults.Ok(new UserResponse(user.ToDto(tokens.Issue(user.Id))));
    }

    private static async Task<IResult> GetCurrent(ClaimsPrincipal principal, HttpRequest request, NpgsqlDataSource db)
    {
        await using var conn = await db.OpenConnectionAsync();
        var user = await conn.QuerySingleOrDefaultAsync<UserRow>(Sql.UserById, new { viewer = principal.Id() });
        return user is null ? ApiErrors.Unauthorized() : TypedResults.Ok(new UserResponse(user.ToDto(request.PresentedToken())));
    }

    private static async Task<IResult> Update(UpdateUserRequest request, ClaimsPrincipal principal, HttpRequest httpRequest, NpgsqlDataSource db)
    {
        var input = request.User;
        if (input is null)
        {
            return ApiErrors.Unprocessable("user object required");
        }

        // Absent or null fields keep their value (COALESCE in the statement); an empty email, username or password is invalid.
        if (input.Email == "" || input.Username == "" || input.Password == "")
        {
            return ApiErrors.Unprocessable("email, username and password cannot be empty");
        }

        if (input.Password is not null && Passwords.TooLong(input.Password))
        {
            return ApiErrors.Unprocessable("password must be at most 72 bytes");
        }

        var passwordHash = input.Password is null ? null : Passwords.Hash(input.Password);
        UserRow? user;
        try
        {
            await using var conn = await db.OpenConnectionAsync();
            user = await conn.QuerySingleOrDefaultAsync<UserRow>(Sql.UpdateUser, new
            {
                viewer = principal.Id(),
                input.Email,
                input.Username,
                passwordHash,
                input.Bio,
                input.Image,
            });
        }
        catch (PostgresException e) when (e.IsUniqueViolation())
        {
            return ApiErrors.Unprocessable("username or email already taken");
        }

        return user is null ? ApiErrors.Unauthorized() : TypedResults.Ok(new UserResponse(user.ToDto(httpRequest.PresentedToken())));
    }
}
