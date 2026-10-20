using System.Buffers.Text;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Conduit;

// A small HTTP/1.1 server on raw sockets: keep-alive, Content-Length bodies, one request at a time per connection
// (pipelined requests are served in order). Socket completions run inline on the epoll threads
// (DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=1), so a request is parsed and handed to Postgres on the thread
// that received it, and its response is sent from the Postgres reader thread that completed it. Per connection:
// one receive buffer and two reusable SocketAsyncEventArgs; per request: a pooled Ctx. No allocations per request.
sealed class HttpServer
{
    readonly Socket _listen;
    readonly SocketAsyncEventArgs _accept = new();

    public HttpServer(IPAddress ip, int port)
    {
        _listen = new Socket(ip.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
        if (ip.AddressFamily == AddressFamily.InterNetworkV6) _listen.DualMode = true;
        _listen.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _listen.Bind(new IPEndPoint(ip, port));
        _listen.Listen(65535);
        _accept.Completed += (_, e) => { if (Accepted(e)) Accept(); };
    }

    public void Start() => Accept();

    void Accept()
    {
        while (true)
        {
            _accept.AcceptSocket = null;
            bool pending;
            try { pending = _listen.AcceptAsync(_accept); }
            catch (ObjectDisposedException) { return; }
            if (pending) return;
            if (!Accepted(_accept)) return;
        }
    }

    static bool Accepted(SocketAsyncEventArgs e)
    {
        if (e.SocketError == SocketError.Success && e.AcceptSocket is { } s)
        {
            s.NoDelay = true;
            new HttpConn(s).Start();
        }
        return e.SocketError != SocketError.OperationAborted;
    }
}

sealed class HttpConn
{
    const int MaxRequest = (1 << 20) + 64 * 1024; // 1 MB body + headers
    readonly Socket _s;
    readonly SocketAsyncEventArgs _rx = new(), _tx = new();
    byte[] _buf = new byte[2048];
    int _len;        // bytes received
    int _reqLen;     // bytes of the request being served
    bool _closeAfter;
    Ctx _sending;
    volatile bool _closed;

    public bool Closed => _closed;

    public HttpConn(Socket s)
    {
        _s = s;
        _rx.Completed += (_, _) => { if (Received()) Receive(); };
        _tx.Completed += (_, _) => Sent();
    }

    public void Start() => Receive();

    void Receive()
    {
        while (true)
        {
            if (_len == _buf.Length)
            {
                if (_buf.Length >= MaxRequest) { Close(); return; }
                Array.Resize(ref _buf, Math.Min(_buf.Length * 2, MaxRequest));
            }
            _rx.SetBuffer(_buf, _len, _buf.Length - _len);
            bool pending;
            try { pending = _s.ReceiveAsync(_rx); }
            catch (Exception) { Close(); return; }
            if (pending) return;
            if (!Received()) return;
        }
    }

    // true: keep receiving (the request is incomplete)
    bool Received()
    {
        if (_rx.SocketError != SocketError.Success || _rx.BytesTransferred == 0)
        {
            Close();
            return false;
        }
        _len += _rx.BytesTransferred;
        return !TryServe();
    }

    // Parses one request from the buffer and hands it to the handlers. false: more bytes are needed.
    bool TryServe()
    {
        var data = new ReadOnlySpan<byte>(_buf, 0, _len);
        int headEnd = data.IndexOf("\r\n\r\n"u8);
        if (headEnd < 0)
        {
            if (_len >= 64 * 1024) { Reject(431); return true; }
            return false;
        }
        var head = data[..headEnd];
        int lineEnd = head.IndexOf("\r\n"u8);
        var line = lineEnd < 0 ? head : head[..lineEnd];
        int sp1 = line.IndexOf((byte)' ');
        int sp2 = sp1 < 0 ? -1 : line[(sp1 + 1)..].IndexOf((byte)' ');
        if (sp1 <= 0 || sp2 <= 0) { Reject(400); return true; }
        var method = line[..sp1];
        var target = line.Slice(sp1 + 1, sp2);
        var version = line[(sp1 + 2 + sp2)..];
        bool http10 = version.SequenceEqual("HTTP/1.0"u8);

        long contentLength = 0;
        bool closeReq = http10, keepAlive = false, chunked = false;
        ReadOnlySpan<byte> auth = default;
        bool hasAuth = false;
        var rest = lineEnd < 0 ? default : head[(lineEnd + 2)..];
        while (rest.Length > 0)
        {
            int e = rest.IndexOf("\r\n"u8);
            var h = e < 0 ? rest : rest[..e];
            rest = e < 0 ? default : rest[(e + 2)..];
            int colon = h.IndexOf((byte)':');
            if (colon <= 0) continue;
            var name = h[..colon];
            var value = h[(colon + 1)..].Trim((byte)' ').Trim((byte)'\t');
            if (Is(name, "content-length"u8))
            {
                if (!Utf8Parser.TryParse(value, out contentLength, out int used) || used != value.Length || contentLength < 0)
                {
                    Reject(400);
                    return true;
                }
            }
            else if (Is(name, "authorization"u8)) { auth = value; hasAuth = true; }
            else if (Is(name, "connection"u8))
            {
                if (Contains(value, "close"u8)) closeReq = true;
                else if (Contains(value, "keep-alive"u8)) keepAlive = true;
            }
            else if (Is(name, "transfer-encoding"u8)) chunked = true;
        }
        if (chunked) { Reject(411); return true; }
        if (contentLength > (1 << 20)) { Reject(413); return true; }
        int total = headEnd + 4 + (int)contentLength;
        if (_len < total)
        {
            if (total > _buf.Length) Array.Resize(ref _buf, total);
            return false;
        }
        _reqLen = total;
        _closeAfter = closeReq && !(http10 && keepAlive);

        int q = target.IndexOf((byte)'?');
        var path = q < 0 ? target : target[..q];
        var query = q < 0 ? default : target[(q + 1)..];
        var c = Ctx.Rent(this);
        c.CloseAfter = _closeAfter;
        Handlers.Start(c, method, path, query, hasAuth, auth, data.Slice(headEnd + 4, (int)contentLength));
        return true;
    }

    static bool Is(ReadOnlySpan<byte> name, ReadOnlySpan<byte> lower)
    {
        if (name.Length != lower.Length) return false;
        for (int i = 0; i < name.Length; i++)
        {
            byte b = name[i];
            if (b >= 'A' && b <= 'Z') b += 32;
            if (b != lower[i]) return false;
        }
        return true;
    }

    static bool Contains(ReadOnlySpan<byte> value, ReadOnlySpan<byte> lower)
    {
        for (int i = 0; i + lower.Length <= value.Length; i++)
            if (Is(value.Slice(i, lower.Length), lower)) return true;
        return false;
    }

    void Reject(int status)
    {
        _closeAfter = true;
        _reqLen = _len;
        var c = Ctx.Rent(this);
        c.CloseAfter = true;
        c.Error(status, status == 413 ? "body too large" : "bad request");
        c.Finish();
    }

    // Sends a finished response (called exactly once per request, from any thread).
    public void Send(Ctx c)
    {
        if (_closed)
        {
            Ctx.Return(c);
            return;
        }
        _sending = c;
        c.GetResponse(out var buf, out int off, out int len);
        _tx.SetBuffer(buf, off, len);
        bool pending;
        try { pending = _s.SendAsync(_tx); }
        catch (Exception)
        {
            _sending = null;
            Ctx.Return(c);
            Close();
            return;
        }
        if (!pending) Sent();
    }

    void Sent()
    {
        // a send that took only part of the buffer continues with the rest before the request is done
        while (_tx.SocketError == SocketError.Success && _tx.BytesTransferred < _tx.Count)
        {
            _tx.SetBuffer(_tx.Offset + _tx.BytesTransferred, _tx.Count - _tx.BytesTransferred);
            bool pending;
            try { pending = _s.SendAsync(_tx); }
            catch (Exception) { break; }
            if (pending) return;
        }
        var c = _sending;
        _sending = null;
        bool ok = _tx.SocketError == SocketError.Success && _tx.BytesTransferred == _tx.Count;
        Ctx.Return(c);
        if (!ok || _closeAfter)
        {
            Close();
            return;
        }
        int rest = _len - _reqLen;
        if (rest > 0) Buffer.BlockCopy(_buf, _reqLen, _buf, 0, rest);
        _len = rest;
        _reqLen = 0;
        if (_buf.Length > 2048 && _len <= 2048) _buf = new byte[2048]; // drop a large body's buffer
        if (_len > 0 && TryServe()) return;
        Receive();
    }

    void Close()
    {
        if (_closed) return;
        _closed = true;
        try { _s.Shutdown(SocketShutdown.Both); } catch (Exception) { }
        _s.Close();
    }
}

// "Date: <IMF-fixdate>\r\n", refreshed every second
static class HttpDate
{
    static byte[] _line = Make();
    static readonly Timer Tick = new(_ => _line = Make(), null, 1000, 1000);

    static byte[] Make() => Encoding.ASCII.GetBytes("Date: " + DateTime.UtcNow.ToString("r") + "\r\n");

    public static ReadOnlySpan<byte> Line => _line;
}
