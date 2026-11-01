using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;

/// <summary>Where the database is: a <c>postgres://user:password@host:port/db</c> URL.</summary>
sealed record PgSettings(string Host, int Port, string User, string Password, string Database)
{
    public static PgSettings Parse(string url)
    {
        var uri = new Uri(url);
        string[] userInfo = uri.UserInfo.Split(':', 2);
        return new PgSettings(uri.Host, uri.Port > 0 ? uri.Port : 5432, Uri.UnescapeDataString(userInfo[0]),
            userInfo.Length > 1 ? Uri.UnescapeDataString(userInfo[1]) : "", Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/')));
    }
}

/// <summary>A growable buffer of protocol messages: a statement's Bind and Execute are written here with their
/// parameters in binary.</summary>
sealed class Wire
{
    public byte[] Buf;
    public int Length;
    int _paramCountAt, _params, _arrayAt, _arrayCount;

    public Wire(int size) => Buf = new byte[size];

    static ReadOnlySpan<byte> ExecuteMessage => [(byte)'E', 0, 0, 0, 9, 0, 0, 0, 0, 0];

    /// <summary>Starts a Bind of statement <paramref name="statement"/> (see <see cref="Statement.All"/>) to the
    /// unnamed portal, every parameter binary; its parameters follow, then <see cref="Execute"/>.</summary>
    public void Bind(byte statement)
    {
        PutByte((byte)'B');
        _paramCountAt = Length; // the message's length goes here; the parameter count 6 bytes on
        PutInt32(0);
        PutByte(0);
        PutByte((byte)('A' + statement));
        PutByte(0);
        PutInt16(1); PutInt16(1);
        PutInt16(0);
        _params = 0;
    }

    public void Int8(long v)
    {
        PutInt32(8);
        PutInt64(v);
        _params++;
    }

    /// <summary>A text parameter: its binary form is its UTF-8.</summary>
    public void Text(ReadOnlySpan<byte> v)
    {
        PutInt32(v.Length);
        PutBytes(v);
        _params++;
    }

    public void Null()
    {
        PutInt32(-1);
        _params++;
    }

    /// <summary>Room for a parameter of exactly <paramref name="length"/> bytes, filled in later: where it starts.</summary>
    public int Placeholder(int length)
    {
        PutInt32(length);
        int at = Length;
        Reserve(length).Clear();
        _params++;
        return at;
    }

    /// <summary>Starts an array parameter of <paramref name="elementType"/> (text unless said; binary: one
    /// dimension, no nulls); <see cref="Element(ReadOnlySpan{byte})"/>s follow, then <see cref="EndArray"/>. An empty
    /// array is sent with its one dimension of length 0, which Postgres reads as empty.</summary>
    public void BeginArray(uint elementType = Statement.Text)
    {
        _arrayAt = Length;
        PutInt32(0); // the parameter's length
        PutInt32(1); PutInt32(0); PutInt32((int)elementType); // dimensions, has nulls, element type
        PutInt32(0); PutInt32(1); // the dimension's length, its lower bound
        _arrayCount = 0;
    }

    public void Element(ReadOnlySpan<byte> v)
    {
        PutInt32(v.Length);
        PutBytes(v);
        _arrayCount++;
    }

    public void Element(long v)
    {
        PutInt32(8);
        PutInt64(v);
        _arrayCount++;
    }

    public void EndArray()
    {
        BinaryPrimitives.WriteInt32BigEndian(Buf.AsSpan(_arrayAt), Length - _arrayAt - 4);
        BinaryPrimitives.WriteInt32BigEndian(Buf.AsSpan(_arrayAt + 16), _arrayCount);
        _params++;
    }

    /// <summary>Ends the Bind (every column binary) and adds its Execute.</summary>
    public void Execute()
    {
        PutInt16(1); PutInt16(1);
        BinaryPrimitives.WriteInt32BigEndian(Buf.AsSpan(_paramCountAt), Length - _paramCountAt);
        // the count follows the length, portal, name and the two format shorts
        BinaryPrimitives.WriteInt16BigEndian(Buf.AsSpan(_paramCountAt + 4 + 3 + 4), (short)_params);
        PutBytes(ExecuteMessage);
    }

    public Span<byte> Reserve(int n)
    {
        if (Buf.Length - Length < n) Array.Resize(ref Buf, Math.Max(Buf.Length * 2, Length + n));
        var s = Buf.AsSpan(Length, n);
        Length += n;
        return s;
    }

    public void PutByte(byte b) => Reserve(1)[0] = b;
    public void PutBytes(ReadOnlySpan<byte> b) => b.CopyTo(Reserve(b.Length));
    public void PutInt16(short v) => BinaryPrimitives.WriteInt16BigEndian(Reserve(2), v);
    public void PutInt32(int v) => BinaryPrimitives.WriteInt32BigEndian(Reserve(4), v);
    public void PutInt64(long v) => BinaryPrimitives.WriteInt64BigEndian(Reserve(8), v);
}

/// <summary>A row of a binary result: its columns located once, then read by number.</summary>
ref struct Row
{
    public const int MaxColumns = 24;
    readonly ReadOnlySpan<byte> _data;
    readonly Span<int> _start;
    public readonly int Count;

    /// <param name="starts">Room for <see cref="MaxColumns"/> offsets.</param>
    public Row(ReadOnlySpan<byte> dataRow, Span<int> starts)
    {
        _data = dataRow;
        _start = starts;
        Count = Math.Min((int)BinaryPrimitives.ReadInt16BigEndian(dataRow), MaxColumns);
        int at = 2;
        for (int i = 0; i < Count; i++)
        {
            _start[i] = at;
            int length = BinaryPrimitives.ReadInt32BigEndian(dataRow[at..]);
            at += 4 + Math.Max(length, 0);
        }
    }

    public int Length(int c) => BinaryPrimitives.ReadInt32BigEndian(_data[_start[c]..]);
    public bool IsNull(int c) => Length(c) < 0;
    public ReadOnlySpan<byte> Bytes(int c) => IsNull(c) ? default : _data.Slice(_start[c] + 4, Length(c));
    public long Int64(int c) => BinaryPrimitives.ReadInt64BigEndian(_data[(_start[c] + 4)..]);
    public bool Bool(int c) => !IsNull(c) && _data[_start[c] + 4] != 0;
}

/// <summary>
/// One Postgres connection, owned by one loop: every statement prepared once as it opens, then one exchange at a time:
/// a reader's batch phase or a writer's group, as Binds and Executes under one Sync, answered up to its ReadyForQuery.
/// Parameters and rows are binary.
/// </summary>
sealed class Pg
{
    const int LoginTimeoutMs = 2_000, ReconnectDelayMs = 1000;

    static ReadOnlySpan<byte> SyncMessage => [(byte)'S', 0, 0, 0, 4];

    readonly PgSettings _settings;
    readonly bool _writer;
    public int Fd = -1;
    public bool Broken = true;
    /// <summary>Between <see cref="BeginOpen"/> and <see cref="FinishOpen"/>; still <see cref="Broken"/>.</summary>
    public bool Connecting;
    public long ConnectDeadline, RetryAt;
    IPAddress? _address;

    /// <summary>[_outSent, _sealed) goes with the next flush; [_sealed, Length) is being written (no Sync yet).</summary>
    readonly Wire _out = new(64 << 10);
    int _outSent, _sealed;
    byte[] _in = new byte[256 << 10];
    int _inStart, _inEnd;
    /// <summary>The writes of the group in flight, in the order they were sent.</summary>
    public readonly List<Job> Group = [];
    /// <summary>A reader's batch (null on a writer).</summary>
    public readonly Batch? Batch;

    public Pg(PgSettings settings, bool writer)
    {
        _settings = settings;
        _writer = writer;
        if (!writer) Batch = new Batch();
    }

    public bool IsWriter => _writer;
    public bool WantsWrite => _outSent < _sealed;
    /// <summary>Connected, and no exchange out: a reader's batch is idle, a writer has no group.</summary>
    public bool Idle => !Broken && (_writer ? Group.Count == 0 : Batch!.Phase == BatchPhase.Idle);
    /// <summary>The sealed bytes not sent yet.</summary>
    internal ReadOnlySpan<byte> Unsent => _out.Buf.AsSpan(_outSent, _sealed - _outSent);

    /// <summary>Starts connecting without blocking: the loop watches <see cref="Fd"/> for writable and then calls
    /// <see cref="FinishOpen"/>, or gives up at <see cref="ConnectDeadline"/>.</summary>
    public void BeginOpen()
    {
        if (_address == null)
        {
            IPAddress[] all = Dns.GetHostAddresses(_settings.Host);
            _address = Array.Find(all, a => a.AddressFamily == AddressFamily.InterNetwork) ?? all[0];
        }
        int fd = Native.Connect(_address, _settings.Port);
        if (fd < 0)
        {
            _address = null;
            throw new SocketException(-fd);
        }
        Fd = fd;
        Connecting = true;
        ConnectDeadline = Environment.TickCount64 + LoginTimeoutMs;
    }

    /// <summary>Once connected: logs in and prepares the statements, waiting two seconds at most for each answer.</summary>
    public void FinishOpen()
    {
        Connecting = false;
        int error = Native.SocketError(Fd);
        if (error != 0)
        {
            _address = null;
            throw new SocketException(error);
        }
        Startup(Fd);
        _out.Length = _outSent = 0;
        for (int i = 0; i < Statement.All.Length; i++)
        {
            var (sql, types) = Statement.All[i];
            _out.PutByte((byte)'P');
            int start = _out.Length;
            _out.PutInt32(0);
            _out.PutByte((byte)('A' + i));
            _out.PutByte(0);
            _out.PutBytes(Encoding.UTF8.GetBytes(sql));
            _out.PutByte(0);
            _out.PutInt16((short)types.Length);
            foreach (uint t in types) _out.PutInt32((int)t);
            BinaryPrimitives.WriteInt32BigEndian(_out.Buf.AsSpan(start), _out.Length - start);
        }
        _out.PutBytes(SyncMessage);
        SendAll(Fd, _out.Buf, _out.Length);
        _out.Length = _sealed = 0;
        while (true)
        {
            byte type = ReadBlocking(Fd, out byte[] body);
            if (type == 'E') throw new InvalidOperationException("Postgres: " + ErrorText(body));
            if (type == 'Z') break;
        }
        _inStart = _inEnd = 0;
        Broken = false;
    }

    void Startup(int fd)
    {
        var m = new List<byte>();
        void Text(string v)
        {
            m.AddRange(Encoding.UTF8.GetBytes(v));
            m.Add(0);
        }
        m.AddRange([0, 0, 0, 0, 0, 3, 0, 0]); // length, then protocol 3.0
        Text("user"); Text(_settings.User);
        Text("database"); Text(_settings.Database);
        Text("client_encoding"); Text("UTF8");
        // The statements are written so the generic plan is the right one: planned once per connection, not on every
        // execution as custom plans are. JIT and parallel workers never pay off for statements this short.
        Text("plan_cache_mode"); Text("force_generic_plan");
        Text("jit"); Text("off");
        Text("max_parallel_workers_per_gather"); Text("0");
        Text("statement_timeout"); Text("30s");
        // A write blocked on a lock held by something other than another loop's group fails after 2 s, not 30
        if (_writer) { Text("lock_timeout"); Text("2s"); }
        m.Add(0);
        byte[] startup = [.. m];
        BinaryPrimitives.WriteInt32BigEndian(startup, startup.Length);
        SendAll(fd, startup, startup.Length);
        Scram? scram = null;
        while (true)
        {
            byte type = ReadBlocking(fd, out byte[] body);
            switch (type)
            {
                case (byte)'E':
                    throw new InvalidOperationException("Postgres: " + ErrorText(body));
                case (byte)'Z':
                    return;
                case (byte)'R':
                    int code = BinaryPrimitives.ReadInt32BigEndian(body);
                    switch (code)
                    {
                        case 0: break; // AuthenticationOk
                        case 3: // cleartext password
                            SendBlocking(fd, (byte)'p', [.. Encoding.UTF8.GetBytes(_settings.Password), 0]);
                            break;
                        case 10: // SASL: SCRAM-SHA-256
                            scram = new Scram(_settings.Password);
                            byte[] first = scram.ClientFirst();
                            byte[] initial = [.. "SCRAM-SHA-256"u8, 0, 0, 0, 0, 0, .. first];
                            BinaryPrimitives.WriteInt32BigEndian(initial.AsSpan(14), first.Length);
                            SendBlocking(fd, (byte)'p', initial);
                            break;
                        case 11: // SASLContinue
                            SendBlocking(fd, (byte)'p', scram!.ClientFinal(body.AsSpan(4)));
                            break;
                        case 12: // SASLFinal
                            scram!.VerifyServerFinal(body.AsSpan(4));
                            break;
                        default:
                            throw new InvalidOperationException($"Postgres asks for authentication method {code}, which this client doesn't speak");
                    }
                    break;
            }
        }
    }

    static void SendBlocking(int fd, byte type, byte[] body)
    {
        byte[] m = new byte[5 + body.Length];
        m[0] = type;
        BinaryPrimitives.WriteInt32BigEndian(m.AsSpan(1), 4 + body.Length);
        body.CopyTo(m, 5);
        SendAll(fd, m, m.Length);
    }

    static void SendAll(int fd, byte[] bytes, int count)
    {
        for (int at = 0; at < count;)
        {
            int n = Native.Send(fd, bytes, at, count - at);
            if (n < 0) throw new InvalidOperationException("Postgres: the connection failed");
            if (n == 0 && !Native.Wait(fd, write: true, LoginTimeoutMs)) throw new TimeoutException("Postgres didn't take the login in time");
            at += n;
        }
    }

    static byte ReadBlocking(int fd, out byte[] body)
    {
        byte[] head = new byte[5];
        Fill(fd, head);
        body = new byte[BinaryPrimitives.ReadInt32BigEndian(head.AsSpan(1)) - 4];
        Fill(fd, body);
        return head[0];
    }

    static void Fill(int fd, byte[] into)
    {
        for (int at = 0; at < into.Length;)
        {
            int n = Native.Receive(fd, into, at, into.Length - at);
            if (n == 0) throw new InvalidOperationException("Postgres closed the connection");
            if (n == -2) throw new InvalidOperationException("Postgres: the connection failed");
            if (n == -1)
            {
                if (!Native.Wait(fd, write: false, LoginTimeoutMs)) throw new TimeoutException("Postgres didn't answer the login in time");
                continue;
            }
            at += n;
        }
    }

    /// <summary>The M (message) field of an ErrorResponse.</summary>
    public static string ErrorText(ReadOnlySpan<byte> body) => Encoding.UTF8.GetString(ErrorField(body, (byte)'M'));

    /// <summary>One field of an ErrorResponse (C is the SQLSTATE, M the message); empty when it has none.</summary>
    public static ReadOnlySpan<byte> ErrorField(ReadOnlySpan<byte> body, byte field)
    {
        while (body.Length > 1 && body[0] != 0)
        {
            int end = body[1..].IndexOf((byte)0) + 1;
            if (end <= 0) break;
            if (body[0] == field) return body[1..end];
            body = body[(end + 1)..];
        }
        return default;
    }

    /// <summary>Closes the socket; the replies it owed are the caller's to fail first (<see cref="Group"/>, <see cref="Batch"/>).</summary>
    public void Close()
    {
        Broken = true;
        Connecting = false;
        RetryAt = Environment.TickCount64 + ReconnectDelayMs;
        if (Fd >= 0) Native.close(Fd);
        Fd = -1;
        _out.Length = _outSent = _sealed = _inStart = _inEnd = 0;
    }

    // ---- sending

    /// <summary>Where the next exchange's Binds and Executes are written; <see cref="Sync"/> ends it.</summary>
    public Wire Out => _out;

    /// <summary>Ends what was written since the last Sync with one: it goes with the next flush.</summary>
    public void Sync()
    {
        _out.PutBytes(SyncMessage);
        _sealed = _out.Length;
    }

    /// <summary>Sends <see cref="Group"/> as one transaction: each write's Binds and Executes, then one Sync.</summary>
    public void SendGroup()
    {
        foreach (Job job in Group) _out.PutBytes(job.Bind.Buf.AsSpan(0, job.Bind.Length));
        Sync();
    }

    // ---- the socket

    /// <summary>Sends what is queued. False on an error; <see cref="WantsWrite"/> says whether some is left.</summary>
    public bool Flush()
    {
        while (_outSent < _sealed)
        {
            int n = Native.Send(Fd, _out.Buf, _outSent, _sealed - _outSent);
            if (n < 0) return false;
            if (n == 0) return true;
            _outSent += n;
        }
        if (_outSent == _out.Length) _out.Length = _outSent = _sealed = 0;
        else if (_outSent > 0)
        {
            // keep what is being written at the start
            _out.Buf.AsSpan(_outSent, _out.Length - _outSent).CopyTo(_out.Buf);
            _out.Length -= _outSent;
            _sealed -= _outSent;
            _outSent = 0;
        }
        return true;
    }

    /// <summary>Reads what arrived. False when the connection is gone.</summary>
    public bool Receive()
    {
        if (_inEnd == _in.Length)
        {
            if (_inStart > 0)
            {
                _in.AsSpan(_inStart, _inEnd - _inStart).CopyTo(_in);
                _inEnd -= _inStart;
                _inStart = 0;
            }
            else Array.Resize(ref _in, _in.Length * 2);
        }
        int n = Native.Receive(Fd, _in, _inEnd, _in.Length - _inEnd);
        if (n == -1) return true;
        if (n <= 0) return false;
        _inEnd += n;
        return true;
    }

    /// <summary>The next whole reply: its messages up to and with the ReadyForQuery that ends it.</summary>
    public bool NextReply(out ReadOnlySpan<byte> reply)
    {
        int at = _inStart;
        while (_inEnd - at >= 5)
        {
            int length = BinaryPrimitives.ReadInt32BigEndian(_in.AsSpan(at + 1));
            if (_inEnd - at < 1 + length) break;
            byte type = _in[at];
            at += 1 + length;
            if (type == 'Z')
            {
                reply = _in.AsSpan(_inStart, at - _inStart);
                _inStart = at;
                if (_inStart == _inEnd) _inStart = _inEnd = 0;
                return true;
            }
        }
        reply = default;
        return false;
    }

    /// <summary>The next message of a reply.</summary>
    public static bool NextMessage(scoped ref ReadOnlySpan<byte> reply, out byte type, out ReadOnlySpan<byte> body)
    {
        if (reply.Length < 5)
        {
            type = 0;
            body = default;
            return false;
        }
        type = reply[0];
        int length = BinaryPrimitives.ReadInt32BigEndian(reply[1..]);
        body = reply.Slice(5, length - 4);
        reply = reply[(1 + length)..];
        return true;
    }
}
