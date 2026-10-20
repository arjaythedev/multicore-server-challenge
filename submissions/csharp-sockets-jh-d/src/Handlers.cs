using System.Buffers.Text;
using System.Text;
using System.Text.Json;

namespace Conduit;

// The endpoints. A request is routed and authenticated on the receiving thread, then either queued for its batched
// read (Batch.cs) or sent as its own statement(s) (SingleQuery); rows are written as JSON as they arrive, and the
// response goes out when the statement completes.
static class Handlers
{
    const int Get = 1, Post = 2, Put = 3, Delete = 4;

    public static void Start(Ctx c, ReadOnlySpan<byte> method, ReadOnlySpan<byte> path, ReadOnlySpan<byte> query,
        bool hasAuth, ReadOnlySpan<byte> auth, ReadOnlySpan<byte> body)
    {
        try
        {
            Route(c, method, path, query, hasAuth, auth, body);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(e);
            c.Error(500, "internal error");
            c.Finish();
        }
    }

    static void Route(Ctx c, ReadOnlySpan<byte> method, ReadOnlySpan<byte> path, ReadOnlySpan<byte> query,
        bool hasAuth, ReadOnlySpan<byte> auth, ReadOnlySpan<byte> body)
    {
        int m = method.SequenceEqual("GET"u8) ? Get : method.SequenceEqual("POST"u8) ? Post :
            method.SequenceEqual("PUT"u8) ? Put : method.SequenceEqual("DELETE"u8) ? Delete : 0;
        if (!path.StartsWith("/api/"u8)) { NotFound(c); return; }
        var rest = path[5..];
        if (rest.Length > 0 && rest[^1] == '/') rest = rest[..^1];
        Span<Range> seg = stackalloc Range[5];
        int n = SplitPath(rest, seg);
        if (n > 4) { NotFound(c); return; }
        var s0 = rest[seg[0]];

        // authentication: 1 = valid token, 0 = none, -1 = present but invalid
        int a = 0;
        if (hasAuth)
        {
            a = -1;
            if (auth.StartsWith("Token "u8))
            {
                long id = Jwt.Verify(auth[6..]);
                if (id > 0)
                {
                    a = 1;
                    c.Viewer = id;
                    c.TokOff = c.Put(auth[6..]);
                    c.TokLen = auth.Length - 6;
                }
            }
        }

        if (s0.SequenceEqual("articles"u8))
        {
            if (n == 1)
            {
                if (m == Get) { if (Optional(c, a)) List(c, query); }
                else if (m == Post) { if (Required(c, a)) CreateArticle(c, body); }
                else NotFound(c);
                return;
            }
            var s1 = rest[seg[1]];
            if (n == 2)
            {
                if (m == Get && s1.SequenceEqual("feed"u8)) { if (Required(c, a)) Feed(c, query); }
                else if (m == Get) { if (Optional(c, a)) Read(c, Conduit.Route.Article, Sql.Article, s1); }
                else if (m == Put) { if (Required(c, a)) UpdateArticle(c, s1, body); }
                else if (m == Delete) { if (Required(c, a)) Single(c, Conduit.Route.DeleteArticle, s1); }
                else NotFound(c);
                return;
            }
            var s2 = rest[seg[2]];
            if (s2.SequenceEqual("comments"u8))
            {
                if (n == 3 && m == Get) { if (Optional(c, a)) Read(c, Conduit.Route.Comments, Sql.Comments, s1); }
                else if (n == 3 && m == Post) { if (Required(c, a)) CreateComment(c, s1, body); }
                else if (n == 4 && m == Delete)
                {
                    if (!Required(c, a)) return;
                    if (!Digits(rest[seg[3]], out long id)) { c.Error(404, "comment not found"); c.Finish(); return; }
                    c.Id = id;
                    Single(c, Conduit.Route.DeleteComment, s1);
                }
                else NotFound(c);
                return;
            }
            if (n == 3 && s2.SequenceEqual("favorite"u8) && (m == Post || m == Delete))
            {
                if (Required(c, a)) Single(c, m == Post ? Conduit.Route.Favorite : Conduit.Route.Unfavorite, s1);
                return;
            }
            NotFound(c);
            return;
        }
        if (s0.SequenceEqual("tags"u8) && n == 1 && m == Get)
        {
            c.Route = Conduit.Route.Tags;
            Sql.Tags.Enqueue(c);
            return;
        }
        if (s0.SequenceEqual("profiles"u8) && n >= 2)
        {
            var name = rest[seg[1]];
            if (n == 2 && m == Get) { if (Optional(c, a)) Read(c, Conduit.Route.Profile, Sql.Profile, name); }
            else if (n == 3 && rest[seg[2]].SequenceEqual("follow"u8) && (m == Post || m == Delete))
            {
                if (Required(c, a)) Single(c, m == Post ? Conduit.Route.Follow : Conduit.Route.Unfollow, name);
            }
            else NotFound(c);
            return;
        }
        if (s0.SequenceEqual("user"u8) && n == 1)
        {
            if (m == Get)
            {
                if (!Required(c, a)) return;
                c.Route = Conduit.Route.User;
                Sql.User.Enqueue(c);
            }
            else if (m == Put) { if (Required(c, a)) UpdateUser(c, body); }
            else NotFound(c);
            return;
        }
        if (s0.SequenceEqual("users"u8) && m == Post)
        {
            if (n == 1) { Register(c, body); return; }
            if (n == 2 && rest[seg[1]].SequenceEqual("login"u8)) { Login(c, body); return; }
        }
        NotFound(c);
    }

    // up to 5 segments separated by '/' (5 = too many)
    static int SplitPath(ReadOnlySpan<byte> s, Span<Range> seg)
    {
        int n = 0, start = 0;
        for (int i = 0; i <= s.Length; i++)
        {
            if (i < s.Length && s[i] != '/') continue;
            if (n == seg.Length) return n;
            seg[n++] = new Range(start, i);
            start = i + 1;
        }
        return n;
    }

    static void NotFound(Ctx c)
    {
        c.Error(404, "not found");
        c.Finish();
    }

    static bool Optional(Ctx c, int a)
    {
        if (a >= 0) return true;
        c.Error(401, "unauthorized");
        c.Finish();
        return false;
    }

    static bool Required(Ctx c, int a)
    {
        if (a == 1) return true;
        c.Error(401, "unauthorized");
        c.Finish();
        return false;
    }

    // a path segment, URL-decoded, as the request's key
    static void SetKey(Ctx c, ReadOnlySpan<byte> raw)
    {
        if (raw.IndexOf((byte)'%') < 0)
        {
            c.KeyOff = c.Put(raw);
            c.KeyLen = raw.Length;
            return;
        }
        Span<byte> tmp = raw.Length <= 512 ? stackalloc byte[raw.Length] : new byte[raw.Length];
        int len = Unescape(raw, tmp, plusIsSpace: false);
        c.KeyOff = c.Put(tmp[..len]);
        c.KeyLen = len;
    }

    static void Read(Ctx c, Route r, Kind k, ReadOnlySpan<byte> key)
    {
        c.Route = r;
        SetKey(c, key);
        k.Enqueue(c);
    }

    static void Single(Ctx c, Route r, ReadOnlySpan<byte> key)
    {
        c.Route = r;
        SetKey(c, key);
        Pg.Write(c.Single);
    }

    // ---------- lists ----------

    static void List(Ctx c, ReadOnlySpan<byte> query)
    {
        if (!ParseList(c, query, out int filter)) { InvalidList(c); return; }
        switch (filter)
        {
            case 1: c.Route = Conduit.Route.ListTag; Sql.ListTag.Enqueue(c); break;
            case 2: c.Route = Conduit.Route.ListAuthor; Sql.ListAuthor.Enqueue(c); break;
            case 3: c.Route = Conduit.Route.ListFavorited; Sql.ListFavorited.Enqueue(c); break;
            default: c.Route = Conduit.Route.ListAll; Sql.ListAll.Enqueue(c); break;
        }
    }

    static void Feed(Ctx c, ReadOnlySpan<byte> query)
    {
        if (!ParseList(c, query, out _)) { InvalidList(c); return; }
        c.Route = Conduit.Route.Feed;
        Sql.ListFeed.Enqueue(c);
    }

    static void InvalidList(Ctx c)
    {
        c.Error(422, "limit must be 1-100 and offset >= 0");
        c.Finish();
    }

    // limit (1-100, default 20), offset (>= 0, default 0) and one filter (tag, author or favorited; the first
    // occurrence of each parameter wins, empty filters are ignored, tag before author before favorited)
    static bool ParseList(Ctx c, ReadOnlySpan<byte> s, out int filter)
    {
        filter = 0;
        c.Limit = 20;
        c.Offset = 0;
        bool haveLimit = false, haveOffset = false;
        int tagOff = -1, tagLen = 0, authorOff = -1, authorLen = 0, favOff = -1, favLen = 0;
        Span<byte> tmp = stackalloc byte[256];
        Span<byte> keyBuf = stackalloc byte[64];
        while (s.Length > 0)
        {
            int amp = s.IndexOf((byte)'&');
            var pair = amp < 0 ? s : s[..amp];
            s = amp < 0 ? default : s[(amp + 1)..];
            if (pair.Length == 0) continue;
            int eq = pair.IndexOf((byte)'=');
            scoped ReadOnlySpan<byte> key = eq < 0 ? pair : pair[..eq];
            var raw = eq < 0 ? default : pair[(eq + 1)..];
            if (key.IndexOfAny((byte)'%', (byte)'+') >= 0)
            {
                if (key.Length > keyBuf.Length) continue; // not a parameter we know
                int kl = Unescape(key, keyBuf, plusIsSpace: true);
                key = keyBuf[..kl];
            }
            Span<byte> val = raw.Length <= tmp.Length ? tmp : new byte[raw.Length];
            int vl = Unescape(raw, val, plusIsSpace: true);
            var v = val[..vl];
            if (key.SequenceEqual("limit"u8))
            {
                if (haveLimit) continue;
                haveLimit = true;
                if (!Digits(v, out long x) || x < 1 || x > 100) return false;
                c.Limit = (int)x;
            }
            else if (key.SequenceEqual("offset"u8))
            {
                if (haveOffset) continue;
                haveOffset = true;
                if (!Digits(v, out long x)) return false;
                c.Offset = Math.Min(x, long.MaxValue / 2); // beyond any page; keeps limit + offset in range
            }
            else if (key.SequenceEqual("tag"u8)) { if (tagOff < 0 && vl > 0) { tagOff = c.Put(v); tagLen = vl; } }
            else if (key.SequenceEqual("author"u8)) { if (authorOff < 0 && vl > 0) { authorOff = c.Put(v); authorLen = vl; } }
            else if (key.SequenceEqual("favorited"u8)) { if (favOff < 0 && vl > 0) { favOff = c.Put(v); favLen = vl; } }
        }
        if (tagOff >= 0) { filter = 1; c.KeyOff = tagOff; c.KeyLen = tagLen; }
        else if (authorOff >= 0) { filter = 2; c.KeyOff = authorOff; c.KeyLen = authorLen; }
        else if (favOff >= 0) { filter = 3; c.KeyOff = favOff; c.KeyLen = favLen; }
        return true;
    }

    // %XX escapes (and '+' as space in query strings); a malformed escape is kept as is
    static int Unescape(ReadOnlySpan<byte> src, Span<byte> dst, bool plusIsSpace)
    {
        int n = 0;
        for (int i = 0; i < src.Length; i++)
        {
            byte b = src[i];
            if (b == '%' && i + 2 < src.Length && Hex(src[i + 1]) >= 0 && Hex(src[i + 2]) >= 0)
            {
                dst[n++] = (byte)(Hex(src[i + 1]) << 4 | Hex(src[i + 2]));
                i += 2;
            }
            else dst[n++] = plusIsSpace && b == '+' ? (byte)' ' : b;
        }
        return n;
    }

    static int Hex(byte b) => b switch
    {
        >= (byte)'0' and <= (byte)'9' => b - '0',
        >= (byte)'a' and <= (byte)'f' => b - 'a' + 10,
        >= (byte)'A' and <= (byte)'F' => b - 'A' + 10,
        _ => -1,
    };

    // decimal digits only (leading zeros allowed), no sign, no spaces, no overflow
    static bool Digits(ReadOnlySpan<byte> s, out long v)
    {
        v = 0;
        if (s.Length == 0) return false;
        foreach (byte ch in s)
        {
            if (ch < '0' || ch > '9') return false;
            int d = ch - '0';
            if (v > (long.MaxValue - d) / 10) return false;
            v = v * 10 + d;
        }
        return true;
    }

    // ---------- batched reads: rows and completion ----------

    public static void BatchRow(Ctx c, ref PgRow r)
    {
        var w = c.W;
        switch (c.Route)
        {
            case Conduit.Route.Tags:
                w.WriteStartObject();
                w.WritePropertyName(N.tags);
                Json.TextArray(w, r.Bytes(1));
                w.WriteEndObject();
                break;
            case Conduit.Route.Article:
                if (c.Found) return;
                w.WriteStartObject();
                w.WritePropertyName(N.article);
                Json.Article(w, ref r, 1, true);
                w.WriteEndObject();
                break;
            case Conduit.Route.Comments:
                if (!c.Found)
                {
                    w.WriteStartObject();
                    w.WritePropertyName(N.comments);
                    w.WriteStartArray();
                }
                if (!r.IsNull(2))
                {
                    w.WriteStartObject();
                    w.WriteNumber(N.id, r.Int8(2));
                    Json.Time(w, N.createdAt, r.Micros(4));
                    Json.Time(w, N.updatedAt, r.Micros(5));
                    Json.Text(w, N.body, ref r, 3);
                    w.WritePropertyName(N.author);
                    Json.Profile(w, ref r, 6);
                    w.WriteEndObject();
                }
                break;
            case Conduit.Route.Profile:
                if (c.Found) return;
                w.WriteStartObject();
                w.WritePropertyName(N.profile);
                Json.Profile(w, ref r, 1);
                w.WriteEndObject();
                break;
            case Conduit.Route.User:
                if (c.Found) return;
                Json.User(w, ref r, 1, c.Token);
                break;
            default: // lists: (i, count, article columns or NULLs for an empty page)
                if (!c.Found)
                {
                    c.Count = r.Int8(1);
                    w.WriteStartObject();
                    w.WritePropertyName(N.articles);
                    w.WriteStartArray();
                }
                if (!r.IsNull(2)) Json.Article(w, ref r, 2, false);
                break;
        }
        c.Found = true;
    }

    public static void BatchDone(Ctx c, PgError err)
    {
        if (err != null)
        {
            Console.Error.WriteLine("batched " + c.Route + ": " + err);
            c.Error(500, "internal error");
            c.Finish();
            return;
        }
        var w = c.W;
        switch (c.Route)
        {
            case Conduit.Route.Tags:
                if (!c.Found) c.Error(500, "no tags row");
                break;
            case Conduit.Route.Article:
                if (!c.Found) c.Error(404, "article not found");
                break;
            case Conduit.Route.Comments:
                if (!c.Found) c.Error(404, "article not found");
                else
                {
                    w.WriteEndArray();
                    w.WriteEndObject();
                }
                break;
            case Conduit.Route.Profile:
                if (!c.Found) c.Error(404, "profile not found");
                break;
            case Conduit.Route.User:
                if (!c.Found) c.Error(401, "unauthorized");
                break;
            default:
                if (!c.Found)
                {
                    w.WriteStartObject();
                    w.WritePropertyName(N.articles);
                    w.WriteStartArray();
                }
                w.WriteEndArray();
                w.WriteNumber(N.articlesCount, c.Count);
                w.WriteEndObject();
                break;
        }
        c.Finish();
    }

    // ---------- writes and logins ----------

    static bool ParseBody(Ctx c, ReadOnlySpan<byte> body, string wrapper, out Body b)
    {
        b = Body.Parse(body.Length == 0 ? null : body.ToArray(), wrapper);
        return b != null;
    }

    static void Unprocessable(Ctx c, string message)
    {
        c.Error(422, message);
        c.Finish();
    }

    static void CreateArticle(Ctx c, ReadOnlySpan<byte> body)
    {
        string title, description, text;
        string[] tags;
        if (!ParseBody(c, body, "article", out var b)) { Unprocessable(c, "title, description and body are required; tagList must be strings"); return; }
        using (b)
        {
            if (!b.Required("title", out title) || !b.Required("description", out description) ||
                !b.Required("body", out text) || !b.Tags(out tags))
            {
                Unprocessable(c, "title, description and body are required; tagList must be strings");
                return;
            }
        }
        c.Route = Conduit.Route.CreateArticle;
        c.S1 = title;
        c.S2 = description;
        c.S3 = text;
        c.S4 = Slug.Make(title) + "-";
        c.Tags = tags;
        Pg.Write(c.Single);
    }

    static void UpdateArticle(Ctx c, ReadOnlySpan<byte> slug, ReadOnlySpan<byte> body)
    {
        string title, description, text;
        if (!ParseBody(c, body, "article", out var b)) { Unprocessable(c, "invalid article"); return; }
        using (b)
        {
            if (!b.Optional("title", false, out title) || !b.Optional("description", false, out description) ||
                !b.Optional("body", false, out text))
            {
                Unprocessable(c, "invalid article");
                return;
            }
        }
        c.S1 = title;
        c.S2 = description;
        c.S3 = text;
        c.S4 = title == null ? null : Slug.Make(title) + "-";
        Single(c, Conduit.Route.UpdateArticle, slug);
    }

    static void CreateComment(Ctx c, ReadOnlySpan<byte> slug, ReadOnlySpan<byte> body)
    {
        string text;
        if (!ParseBody(c, body, "comment", out var b)) { Unprocessable(c, "body is required"); return; }
        using (b)
        {
            if (!b.Required("body", out text)) { Unprocessable(c, "body is required"); return; }
        }
        c.S1 = text;
        Single(c, Conduit.Route.CreateComment, slug);
    }

    static void Register(Ctx c, ReadOnlySpan<byte> body)
    {
        string username, email, password;
        if (!ParseBody(c, body, "user", out var b)) { Unprocessable(c, "username, email and password are required"); return; }
        using (b)
        {
            if (!b.Required("username", out username) || !b.Required("email", out email) || !b.Required("password", out password))
            {
                Unprocessable(c, "username, email and password are required");
                return;
            }
        }
        if (Encoding.UTF8.GetByteCount(password) > 72) { Unprocessable(c, "password is longer than 72 bytes"); return; }
        c.Route = Conduit.Route.Register;
        c.S1 = username;
        c.S2 = email;
        c.Job = BCrypt.HashJob(password, out c.Salt);
        CpuWork.Run(c);
    }

    static void Login(Ctx c, ReadOnlySpan<byte> body)
    {
        string email, password;
        if (!ParseBody(c, body, "user", out var b)) { Unprocessable(c, "email and password are required"); return; }
        using (b)
        {
            if (!b.Required("email", out email) || !b.Required("password", out password))
            {
                Unprocessable(c, "email and password are required");
                return;
            }
        }
        c.Route = Conduit.Route.Login;
        c.S1 = email;
        c.S6 = password;
        Pg.Read(c.Single); // a read: not behind commits
    }

    static void UpdateUser(Ctx c, ReadOnlySpan<byte> body)
    {
        string email, username, password, bio, image;
        if (!ParseBody(c, body, "user", out var b)) { Unprocessable(c, "invalid user"); return; }
        using (b)
        {
            if (!b.Optional("email", false, out email) || !b.Optional("username", false, out username) ||
                !b.Optional("password", false, out password) || !b.Optional("bio", true, out bio) ||
                !b.Optional("image", true, out image))
            {
                Unprocessable(c, "invalid user");
                return;
            }
        }
        if (password != null && Encoding.UTF8.GetByteCount(password) > 72) { Unprocessable(c, "password is longer than 72 bytes"); return; }
        c.Route = Conduit.Route.UpdateUser;
        c.S1 = email;
        c.S2 = username;
        c.S4 = bio;
        c.S5 = image;
        if (password == null) Pg.Write(c.Single);
        else
        {
            c.Job = BCrypt.HashJob(password, out c.Salt);
            CpuWork.Run(c);
        }
    }

    // on a bcrypt thread, with c.Job computed
    public static void AfterBcrypt(Ctx c)
    {
        switch (c.Route)
        {
            case Conduit.Route.Register:
            case Conduit.Route.UpdateUser:
                c.S3 = BCrypt.FormatHash(c.Salt, c.Job);
                Pg.Write(c.Single);
                break;
            case Conduit.Route.Login:
                if (!BCrypt.Matches(c.Job, c.Expected)) c.Error(401, "invalid email or password");
                else
                {
                    var w = c.W;
                    w.WriteStartObject();
                    w.WritePropertyName(N.user);
                    w.WriteStartObject();
                    w.WriteString(N.email, c.S3);
                    w.WriteString(N.token, Jwt.Issue(c.Id));
                    w.WriteString(N.username, c.S2);
                    if (c.S4 == null) w.WriteNull(N.bio); else w.WriteString(N.bio, c.S4);
                    if (c.S5 == null) w.WriteNull(N.image); else w.WriteString(N.image, c.S5);
                    w.WriteEndObject();
                    w.WriteEndObject();
                }
                c.Finish();
                break;
        }
    }

    public static void WriteSingle(Ctx c, PgWriter w)
    {
        switch (c.Route)
        {
            case Conduit.Route.CreateArticle:
                w.Bind(Sql.ArticleInsert);
                w.Int8(c.Viewer); w.Text(c.S4); w.Text(c.S1); w.Text(c.S2); w.Text(c.S3);
                w.EndBind();
                if (c.Tags.Length > 0)
                {
                    w.Bind(Sql.TagsInsert); w.TextArray(c.Tags); w.EndBind();
                    w.Bind(Sql.ArticleTagsInsert); w.TextArray(c.Tags); w.EndBind();
                }
                w.Bind(Sql.ArticleByCurrval); w.Int8(c.Viewer); w.EndBind();
                break;
            case Conduit.Route.UpdateArticle:
                if (c.Step == 0)
                {
                    w.Bind(Sql.ArticleUpdate);
                    w.Int8(c.Viewer); w.Text(c.Key); w.Text(c.S1); w.Text(c.S2); w.Text(c.S3); w.Text(c.S4);
                    w.EndBind();
                }
                else { w.Bind(Sql.ArticleAuthorBySlug); w.Text(c.Key); w.EndBind(); }
                break;
            case Conduit.Route.DeleteArticle:
                if (c.Step == 0) { w.Bind(Sql.ArticleDelete); w.Text(c.Key); w.Int8(c.Viewer); w.EndBind(); }
                else { w.Bind(Sql.ArticleAuthorBySlug); w.Text(c.Key); w.EndBind(); }
                break;
            case Conduit.Route.Favorite:
            case Conduit.Route.Unfavorite:
                w.Bind(c.Route == Conduit.Route.Favorite ? Sql.FavoriteInsert : Sql.FavoriteDelete);
                w.Int8(c.Viewer); w.Text(c.Key);
                w.EndBind();
                w.Bind(Sql.ArticleBySlug); w.Int8(c.Viewer); w.Text(c.Key); w.EndBind();
                break;
            case Conduit.Route.CreateComment:
                w.Bind(Sql.CommentInsert); w.Int8(c.Viewer); w.Text(c.Key); w.Text(c.S1); w.EndBind();
                break;
            case Conduit.Route.DeleteComment:
                if (c.Step == 0) { w.Bind(Sql.CommentDelete); w.Int8(c.Id); w.Text(c.Key); w.Int8(c.Viewer); w.EndBind(); }
                else { w.Bind(Sql.CommentAuthor); w.Int8(c.Id); w.Text(c.Key); w.EndBind(); }
                break;
            case Conduit.Route.Follow:
            case Conduit.Route.Unfollow:
                w.Bind(c.Route == Conduit.Route.Follow ? Sql.Follow : Sql.Unfollow);
                w.Int8(c.Viewer); w.Text(c.Key);
                w.EndBind();
                break;
            case Conduit.Route.Register:
                w.Bind(Sql.UserInsert); w.Text(c.S1); w.Text(c.S2); w.Text(c.S3); w.EndBind();
                break;
            case Conduit.Route.Login:
                w.Bind(Sql.UserByEmail); w.Text(c.S1); w.EndBind();
                break;
            case Conduit.Route.UpdateUser:
                w.Bind(Sql.UserUpdate);
                w.Int8(c.Viewer); w.Text(c.S1); w.Text(c.S2); w.Text(c.S3); w.Text(c.S4); w.Text(c.S5);
                w.EndBind();
                break;
        }
        w.Sync();
    }

    public static void SingleRow(Ctx c, int result, ref PgRow r)
    {
        var w = c.W;
        switch (c.Route)
        {
            case Conduit.Route.CreateArticle:
                if (result != (c.Tags.Length > 0 ? 3 : 1) || c.Found) return;
                c.Status = 201;
                WriteArticle(w, ref r);
                break;
            case Conduit.Route.UpdateArticle:
                if (c.Step == 0) WriteArticle(w, ref r);
                break;
            case Conduit.Route.Favorite:
            case Conduit.Route.Unfavorite:
                if (result != 1 || c.Found) return;
                WriteArticle(w, ref r);
                break;
            case Conduit.Route.CreateComment:
                if (c.Found) return;
                c.Status = 201;
                w.WriteStartObject();
                w.WritePropertyName(N.comment);
                w.WriteStartObject();
                w.WriteNumber(N.id, r.Int8(0));
                Json.Time(w, N.createdAt, r.Micros(2));
                Json.Time(w, N.updatedAt, r.Micros(3));
                Json.Text(w, N.body, ref r, 1);
                w.WritePropertyName(N.author);
                Json.Profile(w, ref r, 4, 0);
                w.WriteEndObject();
                w.WriteEndObject();
                break;
            case Conduit.Route.Follow:
            case Conduit.Route.Unfollow:
                if (c.Found) return;
                w.WriteStartObject();
                w.WritePropertyName(N.profile);
                Json.Profile(w, ref r, 0, c.Route == Conduit.Route.Follow ? 1 : 0);
                w.WriteEndObject();
                break;
            case Conduit.Route.Register:
                if (c.Found) return;
                c.Status = 201;
                Json.User(w, ref r, 0, Encoding.ASCII.GetBytes(Jwt.Issue(r.Int8(0))));
                break;
            case Conduit.Route.UpdateUser:
                if (c.Found) return;
                Json.User(w, ref r, 0, c.Token);
                break;
            case Conduit.Route.Login:
                if (c.Found) return;
                c.Id = r.Int8(0);
                c.S2 = Encoding.UTF8.GetString(r.Bytes(1));
                c.S3 = Encoding.UTF8.GetString(r.Bytes(2));
                c.S4 = r.IsNull(3) ? null : Encoding.UTF8.GetString(r.Bytes(3));
                c.S5 = r.IsNull(4) ? null : Encoding.UTF8.GetString(r.Bytes(4));
                c.Job = BCrypt.VerifyJob(c.S6, Encoding.UTF8.GetString(r.Bytes(5)), out c.Expected);
                break;
        }
        c.Found = true;
    }

    static void WriteArticle(Utf8JsonWriter w, ref PgRow r)
    {
        w.WriteStartObject();
        w.WritePropertyName(N.article);
        Json.Article(w, ref r, 0, true);
        w.WriteEndObject();
    }

    // "DELETE n": rows deleted
    public static void SingleComplete(Ctx c, int result, ReadOnlySpan<byte> tag)
    {
        if (c.Route is not (Conduit.Route.DeleteArticle or Conduit.Route.DeleteComment) || c.Step != 0) return;
        int sp = tag.LastIndexOf((byte)' ');
        if (sp >= 0 && Utf8Parser.TryParse(tag[(sp + 1)..], out long n, out _)) c.Count = n;
    }

    public static void SingleDone(Ctx c, PgError err)
    {
        if (err != null)
        {
            if (err.SqlState == "23505") c.Error(422, "already taken");
            else if (err.SqlState == "23503") c.Error(404, "not found");
            else
            {
                Console.Error.WriteLine(c.Route + ": " + err);
                c.Error(500, "internal error");
            }
            c.Finish();
            return;
        }
        switch (c.Route)
        {
            case Conduit.Route.CreateArticle:
                if (!c.Found) c.Error(500, "article not read back");
                break;
            case Conduit.Route.UpdateArticle:
            case Conduit.Route.DeleteArticle:
            case Conduit.Route.DeleteComment:
                if (c.Step == 0)
                {
                    bool done = c.Route == Conduit.Route.UpdateArticle ? c.Found : c.Count > 0;
                    if (!done)
                    {
                        // nothing matched: 404 if there is no such article/comment, else 403
                        c.Step = 1;
                        c.Found = false;
                        Pg.Write(c.Single);
                        return;
                    }
                    if (c.Route != Conduit.Route.UpdateArticle) c.NoContent();
                }
                else
                {
                    bool comment = c.Route == Conduit.Route.DeleteComment;
                    if (!c.Found) c.Error(404, comment ? "comment not found" : "article not found");
                    else c.Error(403, "not the author");
                }
                break;
            case Conduit.Route.Favorite:
            case Conduit.Route.Unfavorite:
            case Conduit.Route.CreateComment:
                if (!c.Found) c.Error(404, "article not found");
                break;
            case Conduit.Route.Follow:
            case Conduit.Route.Unfollow:
                if (!c.Found) c.Error(404, "profile not found");
                break;
            case Conduit.Route.Register:
                if (!c.Found) c.Error(500, "user not read back");
                break;
            case Conduit.Route.UpdateUser:
                if (!c.Found) c.Error(401, "unauthorized");
                break;
            case Conduit.Route.Login:
                if (!c.Found || c.Job == null) c.Error(401, "invalid email or password");
                else
                {
                    CpuWork.Run(c); // the response comes from AfterBcrypt
                    return;
                }
                break;
        }
        c.Finish();
    }
}

static class Slug
{
    // trim(both '-' from lower(regexp_replace(title, '[^A-Za-z0-9]+', '-', 'g')))
    public static string Make(string title)
    {
        var sb = new StringBuilder(title.Length);
        bool dash = false;
        foreach (char ch in title)
        {
            if (ch is >= 'a' and <= 'z' or >= '0' and <= '9') { Flush(); sb.Append(ch); }
            else if (ch is >= 'A' and <= 'Z') { Flush(); sb.Append((char)(ch + 32)); }
            else dash = true;
        }
        return sb.ToString();

        void Flush()
        {
            if (dash && sb.Length > 0) sb.Append('-');
            dash = false;
        }
    }
}
