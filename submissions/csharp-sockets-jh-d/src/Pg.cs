using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Conduit;

// A minimal PostgreSQL client (protocol 3.0, extended query protocol, binary results), written for this server:
// a few long-lived connections, every statement prepared once per connection at startup, and many queries
// pipelined on each connection. A query writes Bind/Execute.../Sync into the connection's send buffer; the
// connection's reader thread parses the replies and hands rows straight to the query (no row objects, no strings).

static class Oid
{
    public const uint Bool = 16, Int8 = 20, Int4 = 23, Text = 25, Int4Array = 1007, TextArray = 1009, Int8Array = 1016;
}

// A statement prepared on every connection (as "s<Id>").
sealed class Stmt
{
    static readonly List<Stmt> All = new();
    public readonly int Id;
    public readonly string Sql;
    public readonly uint[] ParamOids;
    public readonly byte[] Name;

    Stmt(int id, string sql, uint[] oids)
    {
        Id = id;
        Sql = sql;
        ParamOids = oids;
        Name = Encoding.ASCII.GetBytes("s" + id);
    }

    public static Stmt Define(string sql, params uint[] oids)
    {
        lock (All)
        {
            var s = new Stmt(All.Count, sql, oids);
            All.Add(s);
            return s;
        }
    }

    public static IReadOnlyList<Stmt> List => All;
}

sealed class PgError
{
    public readonly string SqlState, Message;
    public PgError(string state, string message) { SqlState = state; Message = message; }
    public override string ToString() => SqlState + ": " + Message;
}

// One query = one Sync group: its Bind/Execute pairs and a Sync. Rows and command completions are numbered by
// statement (result) within the group; Done comes once, after ReadyForQuery, with the first error if any.
abstract class PgQuery
{
    public abstract void Write(PgWriter w);
    public virtual void Row(int result, ref PgRow row) { }
    public virtual void Complete(int result, ReadOnlySpan<byte> tag) { }
    public abstract void Done(PgError error);
}

// A row of a DataRow message: column values as spans of the connection's receive buffer (valid during the callback).
ref struct PgRow
{
    readonly ReadOnlySpan<byte> _p;
    readonly int[] _off, _len;
    public readonly int Count;

    public PgRow(ReadOnlySpan<byte> payload, int[] off, int[] len)
    {
        _p = payload;
        _off = off;
        _len = len;
        int n = BinaryPrimitives.ReadInt16BigEndian(payload);
        int pos = 2;
        for (int i = 0; i < n; i++)
        {
            int l = BinaryPrimitives.ReadInt32BigEndian(payload[pos..]);
            pos += 4;
            off[i] = pos;
            len[i] = l;
            if (l > 0) pos += l;
        }
        Count = n;
    }

    public bool IsNull(int i) => _len[i] < 0;
    public ReadOnlySpan<byte> Bytes(int i) => _len[i] < 0 ? default : _p.Slice(_off[i], _len[i]);
    public long Int8(int i) => BinaryPrimitives.ReadInt64BigEndian(_p[_off[i]..]);
    public int Int4(int i) => BinaryPrimitives.ReadInt32BigEndian(_p[_off[i]..]);
    public bool Bool(int i) => _p[_off[i]] != 0;
    // timestamptz: microseconds since 2000-01-01 00:00:00 UTC
    public long Micros(int i) => BinaryPrimitives.ReadInt64BigEndian(_p[_off[i]..]);
}

// Builds frontend messages in a growable buffer.
sealed class PgWriter
{
    byte[] _b = new byte[64 * 1024];
    int _n;
    int _bindStart, _paramStart, _arrayStart, _arrayCount;

    public int Length => _n;
    public byte[] Buffer => _b;
    public void Reset() => _n = 0;

    void Ensure(int more)
    {
        if (_n + more <= _b.Length) return;
        Array.Resize(ref _b, Math.Max(_b.Length * 2, _n + more));
    }

    void U8(byte v) { Ensure(1); _b[_n++] = v; }
    void I16(int v) { Ensure(2); BinaryPrimitives.WriteInt16BigEndian(_b.AsSpan(_n), (short)v); _n += 2; }
    void I32(int v) { Ensure(4); BinaryPrimitives.WriteInt32BigEndian(_b.AsSpan(_n), v); _n += 4; }
    void Raw(ReadOnlySpan<byte> s) { Ensure(s.Length); s.CopyTo(_b.AsSpan(_n)); _n += s.Length; }
    void CStr(ReadOnlySpan<byte> s) { Raw(s); U8(0); }
    void Patch(int at, int v) => BinaryPrimitives.WriteInt32BigEndian(_b.AsSpan(at), v);

    // Bind (unnamed portal, all parameters and results binary). Parameters follow, then EndBind.
    public void Bind(Stmt s)
    {
        _bindStart = _n;
        U8((byte)'B');
        I32(0);
        U8(0); // portal ""
        CStr(s.Name);
        I16(1); I16(1); // all parameters binary
        I16(s.ParamOids.Length);
    }

    public void EndBind()
    {
        I16(1); I16(1); // all results binary
        Patch(_bindStart + 1, _n - _bindStart - 1);
        // Execute (unnamed portal, all rows)
        U8((byte)'E'); I32(9); U8(0); I32(0);
    }

    public void Sync() { U8((byte)'S'); I32(4); }

    public void Null() => I32(-1);
    public void Int8(long v) { I32(8); Ensure(8); BinaryPrimitives.WriteInt64BigEndian(_b.AsSpan(_n), v); _n += 8; }
    public void Int4(int v) { I32(4); I32(v); }
    public void Bool(bool v) { I32(1); U8(v ? (byte)1 : (byte)0); }
    public void Text(ReadOnlySpan<byte> utf8) { I32(utf8.Length); Raw(utf8); }

    public void Text(string s)
    {
        if (s == null) { Null(); return; }
        int max = Encoding.UTF8.GetMaxByteCount(s.Length);
        Ensure(4 + max);
        int len = Encoding.UTF8.GetBytes(s, _b.AsSpan(_n + 4));
        BinaryPrimitives.WriteInt32BigEndian(_b.AsSpan(_n), len);
        _n += 4 + len;
    }

    public void TextArray(string[] values)
    {
        BeginArray(Oid.Text);
        foreach (var v in values) Text(v);
        EndArray(values.Length);
    }

    // a one-dimensional array parameter without NULLs: BeginArray, elements (Int8/Int4/Text), EndArray(count)
    public void BeginArray(uint elementOid)
    {
        _paramStart = _n;
        I32(0);  // parameter length
        I32(1);  // ndim
        I32(0);  // no NULLs
        I32((int)elementOid);
        _arrayCount = _n;
        I32(0);  // dimension size
        I32(1);  // lower bound
        _arrayStart = _n;
    }

    public void EndArray(int count)
    {
        Patch(_arrayCount, count);
        Patch(_paramStart, _n - _paramStart - 4);
    }

    public void Raw(byte[] src, int len) => Raw(src.AsSpan(0, len));

    // ---------- startup ----------

    public void Startup(string user, string database, string options)
    {
        int start = _n;
        I32(0);
        I32(196608); // protocol 3.0
        foreach (var (k, v) in new[] { ("user", user), ("database", database), ("options", options),
                     ("client_encoding", "UTF8"), ("application_name", "conduit") })
        {
            if (string.IsNullOrEmpty(v)) continue;
            CStr(Encoding.UTF8.GetBytes(k));
            CStr(Encoding.UTF8.GetBytes(v));
        }
        U8(0);
        Patch(start, _n - start);
    }

    public void Password(ReadOnlySpan<byte> body)
    {
        U8((byte)'p');
        I32(4 + body.Length);
        Raw(body);
    }

    public void Parse(Stmt s)
    {
        int start = _n;
        U8((byte)'P');
        I32(0);
        CStr(s.Name);
        CStr(Encoding.UTF8.GetBytes(s.Sql));
        I16(s.ParamOids.Length);
        foreach (var o in s.ParamOids) I32((int)o);
        Patch(start + 1, _n - start - 1);
    }
}

sealed partial class PgConn
{
    readonly Socket _sock;
    readonly nint _fd;
    readonly object _lock = new();
    readonly Queue<PgQuery> _inflight = new();
    PgWriter _pending = new(), _sending = new();
    bool _flushing;
    readonly AutoResetEvent _flushSignal = new(false);
    int _leftOffset;          // bytes of _sending already sent when the flusher thread takes over
    public int Inflight;      // queries sent and not yet completed (approximate, for picking a connection)

    byte[] _r = new byte[256 * 1024];
    int _rs, _re;
    readonly int[] _off = new int[1664], _len = new int[1664]; // a DataRow has at most 1664 columns
    PgQuery _cur;
    int _result;
    PgError _error;
    public volatile bool Broken;

    PgConn(Socket s)
    {
        _sock = s;
        _fd = s.SafeHandle.DangerousGetHandle();
    }

    // Connects, authenticates (SCRAM-SHA-256, MD5 or cleartext), prepares every statement, starts the threads.
    public static PgConn Open(string host, int port, string user, string password, string database, string options, int index)
    {
        var addr = IPAddress.TryParse(host, out var ip) ? ip : Dns.GetHostAddresses(host)[0];
        var s = new Socket(addr.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        s.Connect(new IPEndPoint(addr, port));
        var c = new PgConn(s);
        c.Handshake(user, password, database, options);
        c.PrepareAll();
        new Thread(c.ReadLoop) { IsBackground = true, Name = "pg-read-" + index }.Start();
        new Thread(c.FlushLoop) { IsBackground = true, Name = "pg-flush-" + index }.Start();
        return c;
    }

    public void Close() => Fail(new PgError("08006", "closed"));

    // ---------- sending ----------

    // Writes the query into the send buffer; the first submitter to find no flush in progress sends.
    public void Submit(PgQuery q) => Submit(q, reserved: false);

    // reserved: the dispatcher already counted this query in Inflight when it picked the connection
    public void Submit(PgQuery q, bool reserved)
    {
        bool flush = false, rejected = false;
        lock (_lock)
        {
            if (Broken)
            {
                rejected = true;
                if (reserved) Inflight--;
            }
            else
            {
                q.Write(_pending);
                _inflight.Enqueue(q);
                if (!reserved) Inflight++;
                flush = !_flushing;
                if (flush) _flushing = true;
            }
        }
        // a query that was queued is completed by the reader (or by Fail), never here: exactly once
        if (rejected)
        {
            q.Done(new PgError("08006", "connection lost"));
            return;
        }
        if (flush) Flush();
    }

    // the dispatcher's claim on one in-flight slot of this connection (see Dispatch)
    public void Reserve() { lock (_lock) Inflight++; }

    // called after each completed query (read connections: lets the dispatcher send the next batch)
    public Action Freed;

    // Sends without ever blocking the calling thread (which may be this connection's reader: a blocking send there
    // could deadlock against Postgres blocking on its own output). Whatever the socket won't take now goes to the
    // flusher thread.
    void Flush()
    {
        while (true)
        {
            PgWriter w;
            lock (_lock)
            {
                if (_pending.Length == 0)
                {
                    _flushing = false;
                    return;
                }
                w = _pending;
                _pending = _sending;
                _sending = w;
            }
            int sent = SendNonBlocking(w.Buffer, 0, w.Length);
            if (sent < 0) { Fail(new PgError("08006", "send failed")); return; }
            if (sent < w.Length)
            {
                _leftOffset = sent;
                _flushSignal.Set(); // the flusher thread finishes this buffer (and keeps _flushing set until then)
                return;
            }
            w.Reset();
        }
    }

    void FlushLoop()
    {
        while (true)
        {
            _flushSignal.WaitOne();
            var w = _sending;
            try
            {
                int off = _leftOffset;
                while (off < w.Length) off += _sock.Send(w.Buffer, off, w.Length - off, SocketFlags.None);
            }
            catch (Exception)
            {
                Fail(new PgError("08006", "send failed"));
                return;
            }
            w.Reset();
            Flush();
        }
    }

    const int MSG_DONTWAIT = 0x40, MSG_NOSIGNAL = 0x4000, EAGAIN = 11, EINTR = 4;

    [LibraryImport("libc", SetLastError = true)]
    private static unsafe partial nint send(nint fd, byte* buf, nint len, int flags);

    unsafe int SendNonBlocking(byte[] buf, int off, int len)
    {
        int total = 0;
        fixed (byte* p = buf)
        {
            while (total < len)
            {
                nint n = send(_fd, p + off + total, len - total, MSG_DONTWAIT | MSG_NOSIGNAL);
                if (n > 0) { total += (int)n; continue; }
                int err = Marshal.GetLastPInvokeError();
                if (n < 0 && err == EINTR) continue;
                if (n < 0 && err == EAGAIN) return total;
                return -1;
            }
        }
        return total;
    }

    // ---------- receiving ----------

    void ReadLoop()
    {
        try
        {
            while (true)
            {
                if (_re == _r.Length)
                {
                    if (_rs > 0)
                    {
                        Buffer.BlockCopy(_r, _rs, _r, 0, _re - _rs);
                        _re -= _rs;
                        _rs = 0;
                    }
                    else Array.Resize(ref _r, _r.Length * 2);
                }
                int n = _sock.Receive(_r, _re, _r.Length - _re, SocketFlags.None);
                if (n <= 0) throw new IOException("connection closed by the server");
                _re += n;
                while (_re - _rs >= 5)
                {
                    int len = BinaryPrimitives.ReadInt32BigEndian(_r.AsSpan(_rs + 1));
                    if (_re - _rs < 1 + len)
                    {
                        if (1 + len > _r.Length)
                        {
                            var bigger = new byte[Math.Max(_r.Length * 2, 1 + len)];
                            Buffer.BlockCopy(_r, _rs, bigger, 0, _re - _rs);
                            _re -= _rs;
                            _rs = 0;
                            _r = bigger;
                        }
                        break;
                    }
                    byte type = _r[_rs];
                    var body = new ReadOnlySpan<byte>(_r, _rs + 5, len - 4);
                    _rs += 1 + len;
                    Handle(type, body);
                }
                if (_rs == _re) _rs = _re = 0;
            }
        }
        catch (Exception e)
        {
            if (Broken) return; // closed on purpose
            Console.Error.WriteLine("postgres connection failed: " + e.Message);
            Fail(new PgError("08006", "connection lost"));
        }
    }

    PgQuery Current()
    {
        if (_cur == null)
            lock (_lock)
                _cur = _inflight.Peek();
        return _cur;
    }

    void Handle(byte type, ReadOnlySpan<byte> body)
    {
        switch (type)
        {
            case (byte)'D':
            {
                var row = new PgRow(body, _off, _len);
                if (_error == null) Current().Row(_result, ref row);
                break;
            }
            case (byte)'C':
                if (_error == null) Current().Complete(_result, body.Length > 0 ? body[..^1] : body);
                _result++;
                break;
            case (byte)'E':
                _error ??= ParseError(body);
                break;
            case (byte)'Z':
            {
                PgQuery q;
                lock (_lock)
                {
                    q = _inflight.Dequeue();
                    Inflight--;
                }
                _cur = null;
                var err = _error;
                _error = null;
                _result = 0;
                try { q.Done(err); }
                catch (Exception e) { Console.Error.WriteLine(e); }
                Freed?.Invoke();
                break;
            }
            // BindComplete, ParseComplete, NoData, EmptyQuery, PortalSuspended, notices, parameter status: nothing
        }
    }

    static PgError ParseError(ReadOnlySpan<byte> body)
    {
        string state = "XX000", msg = "";
        while (body.Length > 1 && body[0] != 0)
        {
            byte f = body[0];
            int end = body[1..].IndexOf((byte)0);
            if (end < 0) break;
            var v = Encoding.UTF8.GetString(body.Slice(1, end));
            if (f == 'C') state = v;
            else if (f == 'M') msg = v;
            body = body[(end + 2)..];
        }
        return new PgError(state, msg);
    }

    void Fail(PgError err)
    {
        List<PgQuery> lost;
        lock (_lock)
        {
            if (Broken) return;
            Broken = true;
            lost = new List<PgQuery>(_inflight);
            _inflight.Clear();
        }
        try { _sock.Close(); } catch (Exception) { }
        foreach (var q in lost)
        {
            try { q.Done(err); } catch (Exception e) { Console.Error.WriteLine(e); }
        }
    }

    // ---------- startup (blocking, before any traffic) ----------

    byte ReadMessage(out byte[] body)
    {
        Span<byte> head = stackalloc byte[5];
        ReadExactly(head);
        int len = BinaryPrimitives.ReadInt32BigEndian(head[1..]);
        body = new byte[len - 4];
        ReadExactly(body);
        return head[0];
    }

    void ReadExactly(Span<byte> dst)
    {
        while (dst.Length > 0)
        {
            int n = _sock.Receive(dst);
            if (n <= 0) throw new IOException("connection closed during startup");
            dst = dst[n..];
        }
    }

    void SendNow(PgWriter w)
    {
        int off = 0;
        while (off < w.Length) off += _sock.Send(w.Buffer, off, w.Length - off, SocketFlags.None);
        w.Reset();
    }

    void Handshake(string user, string password, string database, string options)
    {
        var w = new PgWriter();
        w.Startup(user, database, options);
        SendNow(w);
        string clientFirstBare = null, nonce = null;
        byte[] serverSignature = null;
        while (true)
        {
            byte t = ReadMessage(out var body);
            if (t == 'E') throw new InvalidOperationException("postgres: " + ParseError(body));
            if (t == 'Z') return;
            if (t != 'R') continue;
            int code = BinaryPrimitives.ReadInt32BigEndian(body);
            switch (code)
            {
                case 0: break; // AuthenticationOk
                case 3: // cleartext
                    w.Password(Encoding.UTF8.GetBytes(password + "\0"));
                    SendNow(w);
                    break;
                case 5: // MD5: "md5" + md5(md5(password + user) + salt)
                {
                    string inner = Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(password + user)));
                    var withSalt = Encoding.ASCII.GetBytes(inner).Concat(body.AsSpan(4, 4).ToArray()).ToArray();
                    w.Password(Encoding.ASCII.GetBytes("md5" + Convert.ToHexStringLower(MD5.HashData(withSalt)) + "\0"));
                    SendNow(w);
                    break;
                }
                case 10: // SASL: SCRAM-SHA-256
                {
                    nonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(18));
                    clientFirstBare = "n=*,r=" + nonce;
                    var first = Encoding.ASCII.GetBytes("n,," + clientFirstBare);
                    var msg = new List<byte>();
                    msg.AddRange(Encoding.ASCII.GetBytes("SCRAM-SHA-256\0"));
                    var lenBytes = new byte[4];
                    BinaryPrimitives.WriteInt32BigEndian(lenBytes, first.Length);
                    msg.AddRange(lenBytes);
                    msg.AddRange(first);
                    w.Password(msg.ToArray());
                    SendNow(w);
                    break;
                }
                case 11: // SASLContinue: server-first-message
                {
                    string serverFirst = Encoding.ASCII.GetString(body, 4, body.Length - 4);
                    string r = null, salt = null;
                    int iter = 0;
                    foreach (var part in serverFirst.Split(','))
                    {
                        if (part.StartsWith("r=")) r = part[2..];
                        else if (part.StartsWith("s=")) salt = part[2..];
                        else if (part.StartsWith("i=")) iter = int.Parse(part[2..]);
                    }
                    if (r == null || !r.StartsWith(nonce) || salt == null || iter <= 0)
                        throw new InvalidOperationException("postgres: bad SCRAM server-first message");
                    string withoutProof = "c=biws,r=" + r;
                    byte[] salted = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), Convert.FromBase64String(salt),
                        iter, HashAlgorithmName.SHA256, 32);
                    byte[] clientKey = HMACSHA256.HashData(salted, "Client Key"u8);
                    byte[] storedKey = SHA256.HashData(clientKey);
                    byte[] authMessage = Encoding.ASCII.GetBytes(clientFirstBare + "," + serverFirst + "," + withoutProof);
                    byte[] clientSig = HMACSHA256.HashData(storedKey, authMessage);
                    var proof = new byte[32];
                    for (int i = 0; i < 32; i++) proof[i] = (byte)(clientKey[i] ^ clientSig[i]);
                    byte[] serverKey = HMACSHA256.HashData(salted, "Server Key"u8);
                    serverSignature = HMACSHA256.HashData(serverKey, authMessage);
                    w.Password(Encoding.ASCII.GetBytes(withoutProof + ",p=" + Convert.ToBase64String(proof)));
                    SendNow(w);
                    break;
                }
                case 12: // SASLFinal: verify the server's signature
                {
                    string final = Encoding.ASCII.GetString(body, 4, body.Length - 4);
                    if (!final.StartsWith("v=") || serverSignature == null ||
                        !CryptographicOperations.FixedTimeEquals(Convert.FromBase64String(final[2..]), serverSignature))
                        throw new InvalidOperationException("postgres: SCRAM server signature mismatch");
                    break;
                }
                default:
                    throw new InvalidOperationException("postgres: unsupported authentication method " + code);
            }
        }
    }

    void PrepareAll()
    {
        var w = new PgWriter();
        foreach (var s in Stmt.List) w.Parse(s);
        w.Sync();
        SendNow(w);
        PgError err = null;
        while (true)
        {
            byte t = ReadMessage(out var body);
            if (t == 'E') err ??= ParseError(body);
            if (t == 'Z') break;
        }
        if (err != null) throw new InvalidOperationException("postgres: preparing statements failed: " + err);
    }
}

// The connections, and which one gets the next query. Two pools: reads, and the requests' own write statements.
// A write's commit waits for the WAL flush (milliseconds on a cloud disk); on a shared, pipelined connection every
// read queued behind it would wait too.
sealed class PgPool
{
    readonly PgConn[] _conns;
    int _rr;

    public PgPool(PgConn[] conns) => _conns = conns;

    public PgConn[] Conns => _conns;

    // the least loaded connection with fewer than `depth` queries in flight, or null
    public PgConn PickBelow(int depth)
    {
        var cs = _conns;
        int start = (int)((uint)Interlocked.Increment(ref _rr) % (uint)cs.Length);
        PgConn best = null;
        int bestN = depth;
        for (int k = 0; k < cs.Length; k++)
        {
            var c = cs[(start + k) % cs.Length];
            if (c.Broken) continue;
            int n = c.Inflight;
            if (n < bestN) { best = c; bestN = n; if (n == 0) break; }
        }
        return best;
    }

    // the connection with the fewest queries in flight (ties: round robin)
    public PgConn Pick()
    {
        var cs = _conns;
        int start = (int)((uint)Interlocked.Increment(ref _rr) % (uint)cs.Length);
        PgConn best = null;
        int bestN = int.MaxValue;
        for (int k = 0; k < cs.Length; k++)
        {
            var c = cs[(start + k) % cs.Length];
            if (c.Broken) continue;
            int n = c.Inflight;
            if (n < bestN) { best = c; bestN = n; if (n == 0) break; }
        }
        return best ?? cs[start];
    }
}

static class Pg
{
    public static PgPool Reads, Writes;

    public static void Open(string url, int reads, int writes, string options)
    {
        Reads = new PgPool(OpenMany(url, reads, options, 0));
        Writes = new PgPool(OpenMany(url, writes, options, reads));
    }

    static PgConn[] OpenMany(string url, int count, string options, int firstIndex)
    {
        var cs = new PgConn[count];
        for (int i = 0; i < count; i++) cs[i] = OpenOne(url, options, firstIndex + i);
        return cs;
    }

    public static PgConn OpenOne(string url, string options, int index = 99)
    {
        var u = new Uri(url);
        var userInfo = u.UserInfo.Split(':', 2);
        return PgConn.Open(u.Host, u.Port > 0 ? u.Port : 5432, Uri.UnescapeDataString(userInfo[0]),
            userInfo.Length > 1 ? Uri.UnescapeDataString(userInfo[1]) : "", Uri.UnescapeDataString(u.AbsolutePath.TrimStart('/')),
            options, index);
    }

    public static void Read(PgQuery q) => Reads.Pick().Submit(q);
    public static void Write(PgQuery q) => Writes.Pick().Submit(q);
}
