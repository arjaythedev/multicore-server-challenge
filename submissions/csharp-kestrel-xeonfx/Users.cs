using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Npgsql;

namespace Conduit;

public static class Users
{
    static void WriteUser(JsonOut j, string email, string token, string username, string? bio, string? image)
    {
        var w = j.W;
        w.WriteStartObject();
        w.WriteStartObject(Names.User);
        w.WriteString(Names.Email, email);
        w.WriteString(Names.Token, token);
        w.WriteString(Names.Username, username);
        Http.WriteNullableString(w, Names.Bio, bio);
        Http.WriteNullableString(w, Names.Image, image);
        w.WriteEndObject();
        w.WriteEndObject();
    }

    /// <summary>The user from columns username, email, bio, image starting at <paramref name="c"/>.</summary>
    static void WriteUser(JsonOut j, NpgsqlDataReader r, int c, string token)
    {
        var w = j.W;
        w.WriteStartObject();
        w.WriteStartObject(Names.User);
        w.WriteString(Names.Email, r.GetString(c + 1));
        w.WriteString(Names.Token, token);
        w.WriteString(Names.Username, r.GetString(c));
        Http.WriteNullableString(w, Names.Bio, r, c + 2);
        Http.WriteNullableString(w, Names.Image, r, c + 3);
        w.WriteEndObject();
        w.WriteEndObject();
    }

    // POST /api/users
    public static async Task Register(HttpContext ctx)
    {
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "user", out var u)) { await Http.Unprocessable(ctx, "invalid body"); return; }
        if (!Body.TryReqString(u, "username", out string username) | !Body.TryReqString(u, "email", out string email)
            | !Body.TryReqString(u, "password", out string password))
        {
            await Http.Unprocessable(ctx, "username, email and password are required");
            return;
        }
        if (Passwords.TooLong(password)) { await Http.Unprocessable(ctx, "password is too long"); return; }
        string hash = await Passwords.HashAsync(password);

        try
        {
            await using var cmd = Db.Source.CreateCommand(Sql.Register);
            cmd.Parameters.Add(Db.P(username));
            cmd.Parameters.Add(Db.P(email));
            cmd.Parameters.Add(Db.P(hash));
            await using var r = await cmd.ExecuteReaderAsync();
            await r.ReadAsync();
            var j = JsonOut.Rent();
            WriteUser(j, r, 1, Jwt.Issue(r.GetInt64(0)));
            await Http.Send(ctx, 201, j);
        }
        catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
        {
            await Http.Unprocessable(ctx, "username or email is already taken");
        }
    }

    // POST /api/users/login
    public static async Task Login(HttpContext ctx)
    {
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "user", out var u)) { await Http.Unprocessable(ctx, "invalid body"); return; }
        if (!Body.TryReqString(u, "email", out string email) | !Body.TryReqString(u, "password", out string password))
        {
            await Http.Unprocessable(ctx, "email and password are required");
            return;
        }

        long id = 0;
        string username = "", hash = Passwords.UnknownUserHash;
        string? bio = null, image = null;
        await using (var cmd = Db.Source.CreateCommand(Sql.Login))
        {
            cmd.Parameters.Add(Db.P(email));
            await using var r = await cmd.ExecuteReaderAsync();
            if (await r.ReadAsync())
            {
                id = r.GetInt64(0);
                username = r.GetString(1);
                email = r.GetString(2);
                bio = r.IsDBNull(3) ? null : r.GetString(3);
                image = r.IsDBNull(4) ? null : r.GetString(4);
                hash = r.GetString(5);
            }
        }
        if (!await Passwords.VerifyAsync(password, hash) || id == 0) { await Http.Error(ctx, 401, "invalid email or password"); return; }
        var j = JsonOut.Rent();
        WriteUser(j, email, Jwt.Issue(id), username, bio, image);
        await Http.Send(ctx, 200, j);
    }

    // GET /api/user
    public static async Task Current(HttpContext ctx)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Http.Unauthorized(ctx); return; }
        await using var cmd = Db.Source.CreateCommand(Sql.CurrentUser);
        cmd.Parameters.Add(Db.P(viewer));
        await using var r = await cmd.ExecuteReaderAsync();
        if (!await r.ReadAsync()) { await Http.Unauthorized(ctx); return; }
        var j = JsonOut.Rent();
        WriteUser(j, r, 0, Auth.Token(ctx));
        await Http.Send(ctx, 200, j);
    }

    // PUT /api/user
    public static async Task Update(HttpContext ctx)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Http.Unauthorized(ctx); return; }
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "user", out JsonElement u)) { await Http.Unprocessable(ctx, "invalid body"); return; }
        if (!Body.TryOptString(u, "email", true, out string? email) | !Body.TryOptString(u, "username", true, out string? username)
            | !Body.TryOptString(u, "password", true, out string? password) | !Body.TryOptString(u, "bio", false, out string? bio)
            | !Body.TryOptString(u, "image", false, out string? image))
        {
            await Http.Unprocessable(ctx, "invalid user fields");
            return;
        }
        string? hash = null;
        if (password is not null)
        {
            if (Passwords.TooLong(password)) { await Http.Unprocessable(ctx, "password is too long"); return; }
            hash = await Passwords.HashAsync(password);
        }

        try
        {
            await using var cmd = Db.Source.CreateCommand(Sql.UpdateUser);
            cmd.Parameters.Add(Db.P(viewer));
            cmd.Parameters.Add(Db.Text(email));
            cmd.Parameters.Add(Db.Text(username));
            cmd.Parameters.Add(Db.Text(hash));
            cmd.Parameters.Add(Db.Text(bio));
            cmd.Parameters.Add(Db.Text(image));
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync()) { await Http.Unauthorized(ctx); return; }
            var j = JsonOut.Rent();
            WriteUser(j, r, 0, Auth.Token(ctx));
            await Http.Send(ctx, 200, j);
        }
        catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
        {
            await Http.Unprocessable(ctx, "username or email is already taken");
        }
    }
}
