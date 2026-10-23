using System;
using System.Text.Json;
using System.Threading.Tasks;
using Conduit.Data;
using Conduit.Http;
using Conduit.Security;
using Microsoft.AspNetCore.Http;
using Npgsql;

namespace Conduit.Endpoints;

public static class Users
{
    /// <summary>{"user": ...} from columns username, email, bio, image starting at <paramref name="c"/>, with <paramref name="token"/>.</summary>
    static JsonOut User(NpgsqlDataReader r, int c, ReadOnlySpan<char> token)
    {
        var j = JsonOut.Rent();
        var w = j.W;
        w.WriteStartObject();
        w.WriteStartObject(Names.User);
        Rows.WriteText(w, Names.Email, r, c + 1);
        w.WriteString(Names.Token, token);
        Rows.WriteText(w, Names.Username, r, c);
        Rows.WriteNullableText(w, Names.Bio, r, c + 2);
        Rows.WriteNullableText(w, Names.Image, r, c + 3);
        w.WriteEndObject();
        w.WriteEndObject();
        return j;
    }

    // POST /api/users
    public static async Task Register(HttpContext ctx)
    {
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "user", out var u)) { await Responses.Unprocessable(ctx, "invalid body"); return; }
        if (!Body.TryReqString(u, "username", out string username) | !Body.TryReqString(u, "email", out string email)
            | !Body.TryReqString(u, "password", out string password))
        {
            await Responses.Unprocessable(ctx, "username, email and password are required");
            return;
        }
        if (Passwords.TooLong(password)) { await Responses.Unprocessable(ctx, "password is too long"); return; }
        string hash = await Passwords.HashAsync(password, ctx.RequestAborted);

        JsonOut j;
        try
        {
            j = await Db.Writer.Run(Db.Command(Sql.Register, Db.P(username), Db.P(email), Db.P(hash)),
                static r => User(r!, 1, Jwt.Issue(r!.GetInt64(0))), ctx.RequestAborted);
        }
        catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
        {
            await Responses.Unprocessable(ctx, "username or email is already taken");
            return;
        }
        await Responses.Send(ctx, 201, j);
    }

    // POST /api/users/login
    public static async Task Login(HttpContext ctx)
    {
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "user", out var u)) { await Responses.Unprocessable(ctx, "invalid body"); return; }
        if (!Body.TryReqString(u, "email", out string email) | !Body.TryReqString(u, "password", out string password))
        {
            await Responses.Unprocessable(ctx, "email and password are required");
            return;
        }

        // The response is built while the row is at hand and sent only if the password matches.
        JsonOut? j = null;
        try
        {
            string hash;
            (hash, j) = await Db.Reader.Run(Db.Command(Sql.Login, Db.P(email)), ReadLogin, ctx.RequestAborted);
            if (!await Passwords.VerifyAsync(password, hash, ctx.RequestAborted) || j is null) { await Responses.Error(ctx, 401, "invalid email or password"); return; }
            var ok = j;
            j = null;
            await Responses.Send(ctx, 200, ok);
        }
        finally
        {
            j?.Dispose(); // a wrong password, or a failure on the way
        }
    }

    /// <summary>The stored hash and the response for its user; an unknown email checks against a hash of nothing.</summary>
    static readonly Func<NpgsqlDataReader, ValueTask<(string Hash, JsonOut? User)>> ReadLogin = static async r =>
        await r.ReadAsync() ? (r.GetString(5), User(r, 1, Jwt.Issue(r.GetInt64(0)))) : (Passwords.UnknownUserHash, null);

    // GET /api/user
    public static async Task Current(HttpContext ctx)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Responses.Unauthorized(ctx); return; }
        var j = await Db.Reader.Run(Db.Command(Sql.CurrentUser, Db.P(viewer)), ReadCurrent, ctx, ctx.RequestAborted);
        if (j is null) await Responses.Unauthorized(ctx);
        else await Responses.Send(ctx, 200, j);
    }

    /// <summary>The user and the token the request presented. It runs on a reader loop while the request waits, so it
    /// may read the request's header.</summary>
    static readonly Func<NpgsqlDataReader, object?, ValueTask<JsonOut?>> ReadCurrent = static async (r, ctx) =>
        await r.ReadAsync() ? User(r, 0, Auth.Token((HttpContext)ctx!)) : null;

    static readonly Func<NpgsqlDataReader?, object?, JsonOut?> Updated = static (r, token) => r is null ? null : User(r, 0, (string)token!);

    // PUT /api/user
    public static async Task Update(HttpContext ctx)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Responses.Unauthorized(ctx); return; }
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "user", out JsonElement u)) { await Responses.Unprocessable(ctx, "invalid body"); return; }
        if (!Body.TryOptString(u, "email", true, out string? email) | !Body.TryOptString(u, "username", true, out string? username)
            | !Body.TryOptString(u, "password", true, out string? password) | !Body.TryOptString(u, "bio", false, out string? bio)
            | !Body.TryOptString(u, "image", false, out string? image))
        {
            await Responses.Unprocessable(ctx, "invalid user fields");
            return;
        }
        string? hash = null;
        if (password is not null)
        {
            if (Passwords.TooLong(password)) { await Responses.Unprocessable(ctx, "password is too long"); return; }
            hash = await Passwords.HashAsync(password, ctx.RequestAborted);
        }

        JsonOut? j;
        try
        {
            string token = Auth.Token(ctx).ToString();
            j = await Db.Writer.Run(
                Db.Command(Sql.UpdateUser, Db.P(viewer), Db.Text(email), Db.Text(username), Db.Text(hash), Db.Text(bio), Db.Text(image)),
                Updated, token, ctx.RequestAborted);
        }
        catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
        {
            await Responses.Unprocessable(ctx, "username or email is already taken");
            return;
        }
        if (j is not null) await Responses.Send(ctx, 200, j);
        else await Responses.Unauthorized(ctx);
    }
}
