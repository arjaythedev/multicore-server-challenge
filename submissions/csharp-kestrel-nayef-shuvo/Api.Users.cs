using Npgsql;

namespace Conduit;

internal sealed partial class Api
{
    private static Task WriteUser(HttpContext ctx, int status, string username, string email, string? bio, string? image, string token) =>
        Http.Json(ctx, status, w =>
        {
            w.WriteStartObject();
            w.WriteStartObject("user");
            w.WriteString("email", email);
            w.WriteString("token", token);
            w.WriteString("username", username);
            NullableString(w, "bio", bio);
            NullableString(w, "image", image);
            w.WriteEndObject();
            w.WriteEndObject();
        });

    // POST /api/users
    private async Task Register(HttpContext ctx)
    {
        var body = await Http.ReadWrapper(ctx, "user");
        if (body is null)
        {
            await Http.Error(ctx, 422, "invalid body");
            return;
        }
        var u = body.Value;
        var okUsername = Http.ReqString(u, "username", out var username);
        var okEmail = Http.ReqString(u, "email", out var email);
        var okPassword = Http.ReqString(u, "password", out var password);
        if (!okUsername || !okEmail || !okPassword)
        {
            await Http.Error(ctx, 422, "username, email and password are required");
            return;
        }
        if (!Auth.TryHash(password, out var hash))
        {
            await Http.Error(ctx, 422, "password is too long");
            return;
        }

        long id;
        string? bio, image;
        try
        {
            await using var cmd = db.CreateCommand(@"INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
RETURNING id, username, email, bio, image");
            cmd.AddText(username);
            cmd.AddText(email);
            cmd.AddText(hash);
            await using var r = await cmd.ExecuteReaderAsync();
            await r.ReadAsync();
            id = r.GetInt64(0);
            username = r.GetString(1);
            email = r.GetString(2);
            bio = r.GetNullableString(3);
            image = r.GetNullableString(4);
        }
        catch (PostgresException e) when (e.IsUniqueViolation())
        {
            await Http.Error(ctx, 422, "username or email is already taken");
            return;
        }
        await WriteUser(ctx, 201, username, email, bio, image, auth.IssueToken(id));
    }

    // POST /api/users/login
    private async Task Login(HttpContext ctx)
    {
        var body = await Http.ReadWrapper(ctx, "user");
        if (body is null)
        {
            await Http.Error(ctx, 422, "invalid body");
            return;
        }
        var okEmail = Http.ReqString(body.Value, "email", out var email);
        var okPassword = Http.ReqString(body.Value, "password", out var password);
        if (!okEmail || !okPassword)
        {
            await Http.Error(ctx, 422, "email and password are required");
            return;
        }

        long id;
        string username, hash;
        string? bio, image;
        await using (var cmd = db.CreateCommand("SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"))
        {
            cmd.AddText(email);
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync())
            {
                await Http.Error(ctx, 401, "invalid email or password");
                return;
            }
            id = r.GetInt64(0);
            username = r.GetString(1);
            email = r.GetString(2);
            bio = r.GetNullableString(3);
            image = r.GetNullableString(4);
            hash = r.GetString(5);
        }
        if (!Auth.Verify(password, hash))
        {
            await Http.Error(ctx, 401, "invalid email or password");
            return;
        }
        await WriteUser(ctx, 200, username, email, bio, image, auth.IssueToken(id));
    }

    // GET /api/user
    private async Task CurrentUser(HttpContext ctx, long viewer, string token)
    {
        await using var cmd = db.CreateCommand("SELECT id, username, email, bio, image FROM users WHERE id = $1");
        cmd.AddInt8(viewer);
        await using var r = await cmd.ExecuteReaderAsync();
        if (!await r.ReadAsync())
        {
            await Http.Error(ctx, 401, "unauthorized");
            return;
        }
        await WriteUser(ctx, 200, r.GetString(1), r.GetString(2), r.GetNullableString(3), r.GetNullableString(4), token);
    }

    // PUT /api/user
    private async Task UpdateUser(HttpContext ctx, long viewer, string token)
    {
        var body = await Http.ReadWrapper(ctx, "user");
        if (body is null)
        {
            await Http.Error(ctx, 422, "invalid body");
            return;
        }
        var u = body.Value;
        var ok = Http.OptString(u, "email", true, out var email)
               & Http.OptString(u, "username", true, out var username)
               & Http.OptString(u, "password", true, out var password)
               & Http.OptString(u, "bio", false, out var bio)
               & Http.OptString(u, "image", false, out var image);
        if (!ok)
        {
            await Http.Error(ctx, 422, "invalid user fields");
            return;
        }
        string? hash = null;
        if (password != null && !Auth.TryHash(password, out hash))
        {
            await Http.Error(ctx, 422, "password is too long");
            return;
        }

        try
        {
            await using var cmd = db.CreateCommand(@"UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image");
            cmd.AddInt8(viewer);
            cmd.AddText(email);
            cmd.AddText(username);
            cmd.AddText(hash);
            cmd.AddText(bio);
            cmd.AddText(image);
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync())
            {
                await Http.Error(ctx, 401, "unauthorized");
                return;
            }
            await WriteUser(ctx, 200, r.GetString(1), r.GetString(2), r.GetNullableString(3), r.GetNullableString(4), token);
        }
        catch (PostgresException e) when (e.IsUniqueViolation())
        {
            await Http.Error(ctx, 422, "username or email is already taken");
        }
    }

    // GET /api/profiles/{username}
    private async Task GetProfile(HttpContext ctx, long viewer, string username)
    {
        await using var cmd = db.CreateCommand(@"SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = $2");
        cmd.AddInt8(viewer);
        cmd.AddText(username);
        await using var r = await cmd.ExecuteReaderAsync();
        if (!await r.ReadAsync())
        {
            await Http.Error(ctx, 404, "profile not found");
            return;
        }
        await WriteProfile(ctx, r.GetString(1), r.GetNullableString(2), r.GetNullableString(3), r.GetBoolean(4));
    }

    // POST and DELETE /api/profiles/{username}/follow
    private async Task Follow(HttpContext ctx, long viewer, string username, bool follow)
    {
        long id;
        string name;
        string? bio, image;
        await using (var cmd = db.CreateCommand("SELECT id, username, bio, image FROM users WHERE username = $1"))
        {
            cmd.AddText(username);
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync())
            {
                await Http.Error(ctx, 404, "profile not found");
                return;
            }
            id = r.GetInt64(0);
            name = r.GetString(1);
            bio = r.GetNullableString(2);
            image = r.GetNullableString(3);
        }
        await using (var cmd = db.CreateCommand(follow
            ? "INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"
            : "DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2"))
        {
            cmd.AddInt8(viewer);
            cmd.AddInt8(id);
            await cmd.ExecuteNonQueryAsync();
        }
        await WriteProfile(ctx, name, bio, image, follow);
    }

    // GET /api/tags
    private async Task Tags(HttpContext ctx)
    {
        var names = new List<string>();
        await using (var cmd = db.CreateCommand("SELECT name FROM tags ORDER BY name"))
        {
            await using var r = await cmd.ExecuteReaderAsync();
            while (await r.ReadAsync()) names.Add(r.GetString(0));
        }
        await Http.Json(ctx, 200, w =>
        {
            w.WriteStartObject();
            w.WriteStartArray("tags");
            foreach (var n in names) w.WriteStringValue(n);
            w.WriteEndArray();
            w.WriteEndObject();
        });
    }
}
