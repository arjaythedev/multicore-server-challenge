using System.Buffers;
using System.Buffers.Text;
using System.Collections.Concurrent;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Conduit;

enum Route : byte
{
    None, Tags, ListAll, ListTag, ListAuthor, ListFavorited, Feed, Article, Comments, Profile, User,
    CreateArticle, UpdateArticle, DeleteArticle, Favorite, Unfavorite, CreateComment, DeleteComment,
    Follow, Unfollow, Register, Login, UpdateUser,
}

// One request: what was asked (route, viewer, parameters as UTF-8), the response being built, and the state of
// multi-step requests (logins, writes). Pooled; nothing in it is allocated per request on the read paths.
sealed class Ctx
{
    static readonly ConcurrentQueue<Ctx> Pool = new();
    static readonly JsonWriterOptions WriterOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        SkipValidation = true,
    };

    public HttpConn Conn;
    public bool CloseAfter;
    public Route Route;
    public long Viewer;
    public int Status;
    public int Step;          // multi-step requests: which statement is running
    public int Rows;          // rows seen by the running statement
    public long Count;        // list: articlesCount; delete: rows deleted
    public bool Found;
    public long Queued;       // when a batched read was queued (Stopwatch ticks)

    // parameters: Key = slug, username or list filter (UTF-8, URL-decoded); Tok = the token (GET/PUT /api/user)
    public byte[] P = new byte[512];
    public int KeyOff, KeyLen, TokOff, TokLen;
    public int Limit;
    public long Offset;
    public long Id;           // comment id

    // write requests (rare): the decoded body
    public string S1, S2, S3, S4, S5, S6;
    public string[] Tags;
    public BCrypt.Job Job;
    public byte[] Salt, Expected;

    public readonly Buf Out = new();
    public readonly Utf8JsonWriter W;
    public readonly SingleQuery Single;

    Ctx()
    {
        W = new Utf8JsonWriter(Out, WriterOptions);
        Single = new SingleQuery(this);
    }

    public ReadOnlySpan<byte> Key => P.AsSpan(KeyOff, KeyLen);
    public ReadOnlySpan<byte> Token => P.AsSpan(TokOff, TokLen);

    public static Ctx Rent(HttpConn conn)
    {
        if (!Pool.TryDequeue(out var c)) c = new Ctx();
        c.Conn = conn;
        c.Status = 200;
        return c;
    }

    public static void Return(Ctx c)
    {
        c.Conn = null;
        c.CloseAfter = false;
        c.Route = Route.None;
        c.Viewer = 0;
        c.Status = 200;
        c.Step = c.Rows = 0;
        c.Count = 0;
        c.Found = false;
        c.KeyOff = c.KeyLen = c.TokOff = c.TokLen = c.PLen = 0;
        c.Limit = 0;
        c.Offset = c.Id = 0;
        c.S1 = c.S2 = c.S3 = c.S4 = c.S5 = c.S6 = null;
        c.Tags = null;
        c.Job = null;
        c.Salt = c.Expected = null;
        c.Out.Reset();
        c.W.Reset(c.Out);
        if (c.Out.Capacity > 256 * 1024 || c.P.Length > 4096 || Pool.Count > 8192) return; // drop outsized ones
        Pool.Enqueue(c);
    }

    // appends bytes to the parameter buffer, returning their offset
    public int Put(ReadOnlySpan<byte> s)
    {
        int at = PLen;
        if (at + s.Length > P.Length) Array.Resize(ref P, Math.Max(P.Length * 2, at + s.Length));
        s.CopyTo(P.AsSpan(at));
        PLen = at + s.Length;
        return at;
    }

    public int PLen;

    // ---------- responses ----------

    public void Error(int status, string message)
    {
        Out.Reset();
        W.Reset(Out);
        Status = status;
        W.WriteStartObject();
        W.WritePropertyName(N.errors);
        W.WriteStartObject();
        W.WritePropertyName(N.body);
        W.WriteStartArray();
        W.WriteStringValue(message);
        W.WriteEndArray();
        W.WriteEndObject();
        W.WriteEndObject();
    }

    public void NoContent()
    {
        Out.Reset();
        W.Reset(Out);
        Status = 204;
    }

    // Completes the request: the response goes out on this thread.
    public void Finish()
    {
        W.Flush();
        Out.WriteHead(Status, CloseAfter);
        Conn.Send(this);
    }

    public void GetResponse(out byte[] buf, out int off, out int len) => Out.Response(out buf, out off, out len);
}

// The response: headers are written last, right in front of the JSON body, into space reserved at the start.
sealed class Buf : IBufferWriter<byte>
{
    const int Reserve = 192;
    byte[] _a = new byte[8 * 1024];
    int _n = Reserve;
    int _head = Reserve;

    public int Capacity => _a.Length;
    public int BodyLength => _n - Reserve;

    public void Reset()
    {
        _n = Reserve;
        _head = Reserve;
    }

    public void Advance(int count) => _n += count;

    public Memory<byte> GetMemory(int sizeHint = 0)
    {
        Ensure(sizeHint);
        return _a.AsMemory(_n);
    }

    public Span<byte> GetSpan(int sizeHint = 0)
    {
        Ensure(sizeHint);
        return _a.AsSpan(_n);
    }

    void Ensure(int hint)
    {
        if (hint < 256) hint = 256;
        if (_a.Length - _n >= hint) return;
        Array.Resize(ref _a, Math.Max(_a.Length * 2, _n + hint));
    }

    public void WriteHead(int status, bool close)
    {
        Span<byte> h = stackalloc byte[Reserve];
        int n = 0;
        Add(h, ref n, status switch
        {
            200 => "HTTP/1.1 200 OK\r\n"u8,
            201 => "HTTP/1.1 201 Created\r\n"u8,
            204 => "HTTP/1.1 204 No Content\r\n"u8,
            400 => "HTTP/1.1 400 Bad Request\r\n"u8,
            401 => "HTTP/1.1 401 Unauthorized\r\n"u8,
            403 => "HTTP/1.1 403 Forbidden\r\n"u8,
            404 => "HTTP/1.1 404 Not Found\r\n"u8,
            411 => "HTTP/1.1 411 Length Required\r\n"u8,
            413 => "HTTP/1.1 413 Content Too Large\r\n"u8,
            422 => "HTTP/1.1 422 Unprocessable Entity\r\n"u8,
            431 => "HTTP/1.1 431 Request Header Fields Too Large\r\n"u8,
            _ => "HTTP/1.1 500 Internal Server Error\r\n"u8,
        });
        if (status != 204)
        {
            Add(h, ref n, "Content-Type: application/json\r\nContent-Length: "u8);
            Utf8Formatter.TryFormat(BodyLength, h[n..], out int w);
            n += w;
            Add(h, ref n, "\r\n"u8);
        }
        else _n = Reserve;
        if (close) Add(h, ref n, "Connection: close\r\n"u8);
        Add(h, ref n, HttpDate.Line);
        Add(h, ref n, "\r\n"u8);
        _head = Reserve - n;
        h[..n].CopyTo(_a.AsSpan(_head));
    }

    static void Add(Span<byte> h, ref int n, ReadOnlySpan<byte> s)
    {
        s.CopyTo(h[n..]);
        n += s.Length;
    }

    public void Response(out byte[] buf, out int off, out int len)
    {
        buf = _a;
        off = _head;
        len = _n - _head;
    }
}
