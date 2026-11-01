using System;

/// <summary>Write replies to responses, and the JSON objects every answer shares: each row's columns are written as JSON straight from the receive buffer, with
/// no string or object per row.</summary>
sealed partial class Loop
{
    /// <summary>Answers a committed write from its last statement's messages, and spares its job.</summary>
    void AnswerWrite(Job job, ReadOnlySpan<byte> messages)
    {
        if (job.Closed)
        {
            Discard(job); // its client has gone: nothing to write
            return;
        }
        Span<int> starts = stackalloc int[Row.MaxColumns];
        bool found = NextRow(ref messages, out ReadOnlySpan<byte> m);
        var r = found ? new Row(m, starts) : default;
        int at = HeadRoom;
        int status = 200;
        ReadOnlySpan<byte> error = default;
        switch (job.Kind)
        {
            case WRegister:
                if (!found) { status = 500; error = Errors.Internal; }
                else
                {
                    status = 201;
                    UserWithNewToken(ref at, r, 0);
                }
                break;
            case WUpdateUser:
                if (!found) { status = 401; error = Errors.Unauthorized; }
                else User(Room(at, 6 * m.Length + job.KeepLength + 256), ref at, r, 0, job.Keep.AsSpan(0, job.KeepLength));
                break;
            case WFollow:
            case WUnfollow:
                if (!found) { status = 404; error = Errors.ProfileNotFound; }
                else Profile(Room(at, 6 * m.Length + 256), ref at, r, 0, job.Kind == WFollow);
                break;
            case WCreateArticle:
            case WFavorite:
            case WUnfavorite:
                if (!found) { status = 404; error = Errors.ArticleNotFound; }
                else
                {
                    if (job.Kind == WCreateArticle) status = 201;
                    SingleArticle(ref at, m, starts, 0);
                }
                break;
            case WUpdateArticle:
                // author_id, then the article if the viewer wrote it
                if (!found) { status = 404; error = Errors.ArticleNotFound; }
                else if (r.IsNull(1)) { status = 403; error = Errors.NotTheAuthor; }
                else SingleArticle(ref at, m, starts, 1);
                break;
            case WDeleteArticle:
            case WDeleteComment:
                // the author of what the statement found; it deleted it only if that is the viewer
                if (!found) { status = 404; error = job.Kind == WDeleteArticle ? Errors.ArticleNotFound : Errors.CommentNotFound; }
                else if (r.Int64(0) != job.Viewer) { status = 403; error = Errors.NotTheAuthor; }
                else status = 204;
                break;
            case WCreateComment:
                if (!found) { status = 404; error = Errors.ArticleNotFound; }
                else
                {
                    status = 201;
                    byte[] b = Room(at, 6 * m.Length + 256);
                    Json.Raw(b, ref at, "{\"comment\":"u8);
                    Comment(b, ref at, r, created: true);
                    b[at++] = (byte)'}';
                }
                break;
        }
        if (!error.IsEmpty)
        {
            at = HeadRoom;
            Json.Raw(_response, ref at, error);
        }
        Answer(job, status, at);
    }

    // ---- results

    /// <summary>The next DataRow of a result.</summary>
    static bool NextRow(ref ReadOnlySpan<byte> result, out ReadOnlySpan<byte> row)
    {
        while (Pg.NextMessage(ref result, out byte type, out row))
            if (type == 'D') return true;
        row = default;
        return false;
    }

    // ---- objects

    /// <summary>{"article": ...} from the article columns at <paramref name="c"/>.</summary>
    void SingleArticle(ref int at, ReadOnlySpan<byte> m, Span<int> starts, int c)
    {
        byte[] b = Room(at, 6 * m.Length + 1024);
        Json.Raw(b, ref at, "{\"article\":"u8);
        Article(b, ref at, new Row(m, starts), c, body: true);
        b[at++] = (byte)'}';
    }

    /// <summary>An article from the columns Sql.Columns selects, starting at <paramref name="c"/>: slug, title,
    /// description, body (when <paramref name="body"/>), created_at, updated_at, the tag list as JSON, the favorites
    /// count, favorited, then the author's username, bio, image and following.</summary>
    static void Article(byte[] b, ref int at, in Row r, int c, bool body)
    {
        Json.Raw(b, ref at, "{\"slug\":"u8);
        Json.String(b, ref at, r.Bytes(c++));
        Json.Raw(b, ref at, ",\"title\":"u8);
        Json.String(b, ref at, r.Bytes(c++));
        Json.Raw(b, ref at, ",\"description\":"u8);
        Json.String(b, ref at, r.Bytes(c++));
        if (body)
        {
            Json.Raw(b, ref at, ",\"body\":"u8);
            Json.String(b, ref at, r.Bytes(c++));
        }
        Json.Raw(b, ref at, ",\"createdAt\":"u8);
        Json.Timestamp(b, ref at, r.Int64(c++));
        Json.Raw(b, ref at, ",\"updatedAt\":"u8);
        Json.Timestamp(b, ref at, r.Int64(c++));
        Json.Raw(b, ref at, ",\"tagList\":"u8);
        Json.Raw(b, ref at, r.Bytes(c++));
        Json.Raw(b, ref at, ",\"favoritesCount\":"u8);
        Json.Long(b, ref at, r.Int64(c++));
        Json.Raw(b, ref at, r.Bool(c++) ? ",\"favorited\":true,\"author\":"u8 : ",\"favorited\":false,\"author\":"u8);
        Person(b, ref at, r, c, r.Bool(c + 3));
        b[at++] = (byte)'}';
    }

    /// <summary>A comment from id, created_at, updated_at, body, username, bio, image and (when listed) following.</summary>
    static void Comment(byte[] b, ref int at, in Row r, bool created)
    {
        Json.Raw(b, ref at, "{\"id\":"u8);
        Json.Long(b, ref at, r.Int64(0));
        Json.Raw(b, ref at, ",\"createdAt\":"u8);
        Json.Timestamp(b, ref at, r.Int64(1));
        Json.Raw(b, ref at, ",\"updatedAt\":"u8);
        Json.Timestamp(b, ref at, r.Int64(2));
        Json.Raw(b, ref at, ",\"body\":"u8);
        Json.String(b, ref at, r.Bytes(3));
        Json.Raw(b, ref at, ",\"author\":"u8);
        Person(b, ref at, r, 4, !created && r.Bool(7));
        b[at++] = (byte)'}';
    }

    /// <summary>{"profile": ...} from username, bio and image at <paramref name="c"/>.</summary>
    static void Profile(byte[] b, ref int at, in Row r, int c, bool following)
    {
        Json.Raw(b, ref at, "{\"profile\":"u8);
        Person(b, ref at, r, c, following);
        b[at++] = (byte)'}';
    }

    /// <summary>A profile object from username, bio and image at <paramref name="c"/>.</summary>
    static void Person(byte[] b, ref int at, in Row r, int c, bool following)
    {
        Json.Raw(b, ref at, "{\"username\":"u8);
        Json.String(b, ref at, r.Bytes(c));
        Json.Raw(b, ref at, ",\"bio\":"u8);
        NullableString(b, ref at, r, c + 1);
        Json.Raw(b, ref at, ",\"image\":"u8);
        NullableString(b, ref at, r, c + 2);
        Json.Raw(b, ref at, following ? ",\"following\":true}"u8 : ",\"following\":false}"u8);
    }

    static void NullableString(byte[] b, ref int at, in Row r, int c)
    {
        if (r.IsNull(c)) Json.Raw(b, ref at, "null"u8);
        else Json.String(b, ref at, r.Bytes(c));
    }

    /// <summary>{"user": ...} from username, email, bio and image at <paramref name="c"/>, with <paramref name="token"/>.</summary>
    static void User(byte[] b, ref int at, in Row r, int c, ReadOnlySpan<byte> token)
    {
        Json.Raw(b, ref at, "{\"user\":{\"email\":"u8);
        Json.String(b, ref at, r.Bytes(c + 1));
        Json.Raw(b, ref at, ",\"token\":"u8);
        Json.String(b, ref at, token);
        Json.Raw(b, ref at, ",\"username\":"u8);
        Json.String(b, ref at, r.Bytes(c));
        Json.Raw(b, ref at, ",\"bio\":"u8);
        NullableString(b, ref at, r, c + 2);
        Json.Raw(b, ref at, ",\"image\":"u8);
        NullableString(b, ref at, r, c + 3);
        Json.Raw(b, ref at, "}}"u8);
    }

    /// <summary>The user whose id is column <paramref name="c"/> (username, email, bio, image after it) with a new
    /// token for it.</summary>
    void UserWithNewToken(ref int at, in Row r, int c)
    {
        Span<byte> token = stackalloc byte[Jwt.MaxIssuedBytes];
        int n = Jwt.Issue(r.Int64(c), token);
        User(Room(at, 6 * 1024 + 6 * RowBytes(r) + n), ref at, r, c + 1, token[..n]);
    }

    /// <summary>A bound on a row's text, for <see cref="Room"/>.</summary>
    static int RowBytes(in Row r)
    {
        int n = 0;
        for (int i = 0; i < r.Count; i++) n += Math.Max(r.Length(i), 0);
        return n;
    }
}
