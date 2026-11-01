using System;
using System.Buffers;
using System.Buffers.Text;
using System.Text;

/// <summary>What the routes need from a request, sliced from the bytes it arrived in.</summary>
ref struct HttpRequest
{
    public ReadOnlySpan<byte> Method, Path, Query, Authorization, Body;
    public bool HasAuthorization, Close;
}

/// <summary>The clients: accepting, reading and parsing requests, and sending responses.</summary>
sealed partial class Loop
{
    void OnListener()
    {
        int listener = (int)_listener.Handle;
        for (int k = 0; k < MaxAccepts; k++)
        {
            int fd = Native.Accept(listener);
            if (fd < 0) return;
            if (fd >= Conns.Length)
            {
                Native.close(fd);
                continue;
            }
            ref Conn c = ref Conns[fd];
            c.Busy = c.CloseAfterSend = c.PeerDone = c.Paused = false;
            c.InLength = c.OutStart = c.OutEnd = 0;
            Native.Watch(_epfd, Native.EpollCtlAdd, fd, ClientEvents, (ulong)fd);
        }
    }

    void OnClient(int fd, uint events)
    {
        ref Conn c = ref Conns[fd];
        if ((events & Native.EpollErr) != 0)
        {
            Close(fd);
            return;
        }
        if ((events & Native.EpollOut) != 0 && !SendPending(fd)) return;
        if ((events & (Native.EpollIn | Native.EpollRdHup | Native.EpollHup)) == 0) return;

        if (c.Busy || c.OutEnd > 0)
        {
            // keep what arrives until the answer before it is out; a client this far ahead waits
            if (c.InLength >= MaxRequest)
            {
                c.Paused = true;
                Arm(fd);
                return;
            }
            Hold(ref c, Math.Min(MaxRequest, c.InLength + (16 << 10)));
            int got = Native.Receive(fd, c.In!, c.InLength, Math.Min(c.In!.Length, MaxRequest) - c.InLength);
            if (got == -2) Close(fd);
            else if (got > 0) c.InLength += got;
            else if (got == 0)
            {
                // stop reading; what it asked is still answered
                c.PeerDone = true;
                Arm(fd);
            }
            return;
        }

        // the usual case: the loop's receive buffer, behind what was held back from the last read
        int held = c.InLength;
        if (held > 0) c.In.AsSpan(0, held).CopyTo(_receive);
        int n = Native.Receive(fd, _receive, held, MaxRequest - held);
        if (n == 0 || n == -2 || (n == -1 && held == MaxRequest))
        {
            Close(fd);
            return;
        }
        if (n > 0) held += n;
        Serve(fd, _receive, held);
    }

    /// <summary>Makes the connection's <see cref="Conn.In"/> hold at least <paramref name="size"/> bytes, keeping
    /// what it holds.</summary>
    static void Hold(ref Conn c, int size)
    {
        if (c.In != null && c.In.Length >= size) return;
        byte[] grown = ArrayPool<byte>.Shared.Rent(Math.Max(size, 16 << 10));
        if (c.In != null)
        {
            c.In.AsSpan(0, c.InLength).CopyTo(grown);
            ArrayPool<byte>.Shared.Return(c.In);
        }
        c.In = grown;
    }

    /// <summary>Answers the requests in <paramref name="buffer"/> until one waits or one is incomplete; what is left
    /// waits in the connection's <see cref="Conn.In"/>.</summary>
    void Serve(int fd, byte[] buffer, int length)
    {
        int at = 0;
        int gen = Conns[fd].Gen;
        while (at < length)
        {
            int used = ServeOne(fd, buffer.AsSpan(at, length - at));
            if (used == 0) break;
            if (used < 0 || Conns[fd].Gen != gen) return; // closed
            at += used;
            if (Conns[fd].Busy || Conns[fd].OutEnd > 0) break;
        }
        ref Conn c = ref Conns[fd];
        int left = length - at;
        if (left > 0)
        {
            if (buffer != c.In)
            {
                c.InLength = 0;
                Hold(ref c, left);
                buffer.AsSpan(at, left).CopyTo(c.In);
            }
            else if (at > 0) buffer.AsSpan(at, left).CopyTo(c.In);
            c.InLength = left;
        }
        else
        {
            c.InLength = 0;
            if (c.In != null)
            {
                ArrayPool<byte>.Shared.Return(c.In);
                c.In = null;
            }
        }
        if (c.PeerDone && !c.Busy && c.OutEnd == 0) Close(fd);
        else if (c.Paused && c.InLength < MaxRequest)
        {
            c.Paused = false;
            Arm(fd);
        }
    }

    /// <summary>Handles the request at the start of <paramref name="bytes"/>: the bytes it took, 0 when it isn't all
    /// here yet, -1 when the connection closed.</summary>
    int ServeOne(int fd, ReadOnlySpan<byte> bytes)
    {
        int gen = Conns[fd].Gen;
        int total = Parse(bytes, out HttpRequest request);
        if (total == 0) return bytes.Length >= MaxRequest ? Refuse(fd, 413) : 0;
        if (total == -2) return Refuse(fd, 413);
        if (total < 0) return Refuse(fd, 400);
        if (request.Close) Conns[fd].CloseAfterSend = true;
        Dispatch(fd, request);
        return Conns[fd].Gen == gen ? total : -1;
    }

    /// <summary>Reads the request at the start of <paramref name="bytes"/>: the bytes it takes, 0 when it isn't all
    /// here yet, -1 when it is malformed, -2 when it is larger than <see cref="MaxRequest"/>.</summary>
    public static int Parse(ReadOnlySpan<byte> bytes, out HttpRequest request)
    {
        request = default;
        int headEnd = bytes.IndexOf("\r\n\r\n"u8);
        if (headEnd < 0) return 0;
        ReadOnlySpan<byte> head = bytes[..headEnd];

        int lineEnd = head.IndexOf("\r\n"u8);
        ReadOnlySpan<byte> line = lineEnd < 0 ? head : head[..lineEnd];
        int firstSpace = line.IndexOf((byte)' ');
        int lastSpace = line.LastIndexOf((byte)' ');
        if (firstSpace <= 0 || lastSpace <= firstSpace) return -1;
        ReadOnlySpan<byte> target = line[(firstSpace + 1)..lastSpace];
        ReadOnlySpan<byte> version = line[(lastSpace + 1)..];
        if (!version.StartsWith("HTTP/1."u8) || target.IsEmpty) return -1;
        request.Method = line[..firstSpace];
        request.Close = !version.SequenceEqual("HTTP/1.1"u8); // HTTP/1.0 closes unless asked not to

        long contentLength = 0;
        bool hasLength = false;
        ReadOnlySpan<byte> headers = lineEnd < 0 ? default : head[(lineEnd + 2)..];
        while (!headers.IsEmpty)
        {
            int end = headers.IndexOf("\r\n"u8);
            ReadOnlySpan<byte> header = end < 0 ? headers : headers[..end];
            headers = end < 0 ? default : headers[(end + 2)..];
            int colon = header.IndexOf((byte)':');
            if (colon <= 0) return -1;
            ReadOnlySpan<byte> name = header[..colon], value = header[(colon + 1)..].Trim(" \t"u8);
            if (Ascii.EqualsIgnoreCase(name, "authorization"u8))
            {
                // the first one counts
                if (!request.HasAuthorization)
                {
                    request.Authorization = value;
                    request.HasAuthorization = true;
                }
            }
            else if (Ascii.EqualsIgnoreCase(name, "content-length"u8))
            {
                // a second, different length could smuggle a request: refused
                if (!Utf8Parser.TryParse(value, out long length, out int used) || used != value.Length || length < 0) return -1;
                if (hasLength && length != contentLength) return -1;
                contentLength = length;
                hasLength = true;
            }
            else if (Ascii.EqualsIgnoreCase(name, "connection"u8))
            {
                if (Ascii.EqualsIgnoreCase(value, "close"u8)) request.Close = true;
                else if (Ascii.EqualsIgnoreCase(value, "keep-alive"u8)) request.Close = false;
            }
            // a chunked body isn't read: the request counts as malformed
            else if (Ascii.EqualsIgnoreCase(name, "transfer-encoding"u8)) return -1;
        }
        long total = headEnd + 4 + contentLength;
        if (total > MaxRequest) return -2;
        if (bytes.Length < total) return 0;
        request.Body = bytes.Slice(headEnd + 4, (int)contentLength);

        int query = target.IndexOf((byte)'?');
        request.Path = query >= 0 ? target[..query] : target;
        request.Query = query >= 0 ? target[(query + 1)..] : default;
        return (int)total;
    }

    /// <summary>Decodes %XX escapes in a path as Kestrel does: an escaped '/' stays escaped (it can't split a
    /// segment), and a malformed escape stays as it is. Returns the decoded length.</summary>
    internal static int DecodePath(ReadOnlySpan<byte> path, Span<byte> dest)
    {
        int n = 0;
        for (int i = 0; i < path.Length; i++)
        {
            byte c = path[i];
            if (c == '%' && i + 2 < path.Length && HexValue(path[i + 1]) >= 0 && HexValue(path[i + 2]) >= 0)
            {
                byte d = (byte)(HexValue(path[i + 1]) << 4 | HexValue(path[i + 2]));
                if (d != '/')
                {
                    c = d;
                    i += 2;
                }
            }
            dest[n++] = c;
        }
        return n;
    }

    static int HexValue(byte c) => c switch
    {
        >= (byte)'0' and <= (byte)'9' => c - '0',
        >= (byte)'a' and <= (byte)'f' => c - 'a' + 10,
        >= (byte)'A' and <= (byte)'F' => c - 'A' + 10,
        _ => -1,
    };

    /// <summary>Answers 400 or 413 and closes after it; -1, as <see cref="ServeOne"/> returns for a closed connection.</summary>
    int Refuse(int fd, int status)
    {
        Conns[fd].CloseAfterSend = true;
        Error(fd, status, status == 413 ? Errors.BodyTooLarge : Errors.BadRequest);
        return -1;
    }

    /// <summary>Watches a client for what it can do now: read unless paused or done, write while output waits.</summary>
    void Arm(int fd)
    {
        ref Conn c = ref Conns[fd];
        uint events = (c.PeerDone || c.Paused ? 0 : ClientEvents) | (c.OutEnd > 0 ? Native.EpollOut : 0);
        Native.Watch(_epfd, Native.EpollCtlMod, fd, events, (ulong)fd);
    }

    /// <summary>After an answer to a request that waited, serves what the client sent meanwhile.</summary>
    void Resume(int fd, int gen)
    {
        ref Conn c = ref Conns[fd];
        if (c.Gen != gen || c.Busy || c.OutEnd > 0) return;
        if (c.InLength > 0) Serve(fd, c.In!, c.InLength);
        else if (c.PeerDone) Close(fd);
    }

    /// <summary>A whole body, such as one of <see cref="Errors"/>.</summary>
    void Error(int fd, int status, ReadOnlySpan<byte> body)
    {
        int at = HeadRoom;
        Json.Raw(Room(at, body.Length), ref at, body);
        Respond(fd, status, at);
    }

    /// <summary>Sends the body at [HeadRoom, end) of the response buffer with its head; what the socket won't take
    /// waits in the connection's Out. 204 sends no body.</summary>
    void Respond(int fd, int status, int end) => Respond(fd, status, _response, end);

    /// <summary>As <see cref="Respond(int, int, int)"/>, from <paramref name="buf"/>: its body at [HeadRoom, end), with
    /// HeadRoom free before it for the head.</summary>
    void Respond(int fd, int status, byte[] buf, int end)
    {
        ref Conn c = ref Conns[fd];
        int start = Head(buf, status, end - HeadRoom, c.CloseAfterSend);
        if (status == 204) end = HeadRoom;
        int sent = Native.Send(fd, buf, start, end - start);
        if (sent < 0)
        {
            Close(fd);
            return;
        }
        if (sent == end - start)
        {
            if (c.CloseAfterSend) Close(fd);
            return;
        }
        // the socket is full: keep the rest and wait until it drains
        int rest = end - start - sent;
        c.Out = ArrayPool<byte>.Shared.Rent(rest);
        buf.AsSpan(start + sent, rest).CopyTo(c.Out);
        c.OutStart = 0;
        c.OutEnd = rest;
        Arm(fd);
    }

    /// <summary>Writes the head of a response whose body of <paramref name="length"/> bytes starts at HeadRoom right in
    /// front of it, back to front; returns where it starts. A 204 has no body and no body headers.</summary>
    internal static int Head(byte[] b, int status, int length, bool close)
    {
        ReadOnlySpan<byte> tail = close ? "\r\nConnection: close\r\n\r\n"u8 : "\r\n\r\n"u8;
        int start = HeadRoom - tail.Length;
        tail.CopyTo(b.AsSpan(start));
        if (status == 204)
        {
            ReadOnlySpan<byte> noContent = "HTTP/1.1 204 No Content"u8;
            start -= noContent.Length;
            noContent.CopyTo(b.AsSpan(start));
            return start;
        }
        do
        {
            b[--start] = (byte)('0' + length % 10);
            length /= 10;
        } while (length > 0);
        ReadOnlySpan<byte> type = "Content-Type: application/json\r\nContent-Length: "u8;
        start -= type.Length;
        type.CopyTo(b.AsSpan(start));
        ReadOnlySpan<byte> line = status switch
        {
            200 => "HTTP/1.1 200 OK\r\n"u8,
            201 => "HTTP/1.1 201 Created\r\n"u8,
            400 => "HTTP/1.1 400 Bad Request\r\n"u8,
            401 => "HTTP/1.1 401 Unauthorized\r\n"u8,
            403 => "HTTP/1.1 403 Forbidden\r\n"u8,
            404 => "HTTP/1.1 404 Not Found\r\n"u8,
            413 => "HTTP/1.1 413 Payload Too Large\r\n"u8,
            422 => "HTTP/1.1 422 Unprocessable Entity\r\n"u8,
            503 => "HTTP/1.1 503 Service Unavailable\r\n"u8,
            _ => "HTTP/1.1 500 Internal Server Error\r\n"u8,
        };
        start -= line.Length;
        line.CopyTo(b.AsSpan(start));
        return start;
    }

    /// <summary>Sends what waits in Out. False when the connection closed.</summary>
    bool SendPending(int fd)
    {
        ref Conn c = ref Conns[fd];
        if (c.OutEnd == 0) return true;
        int sent = Native.Send(fd, c.Out!, c.OutStart, c.OutEnd - c.OutStart);
        if (sent < 0)
        {
            Close(fd);
            return false;
        }
        c.OutStart += sent;
        if (c.OutStart < c.OutEnd) return true;
        ArrayPool<byte>.Shared.Return(c.Out!);
        c.Out = null;
        c.OutStart = c.OutEnd = 0;
        if (c.CloseAfterSend)
        {
            Close(fd);
            return false;
        }
        Arm(fd);
        int gen = c.Gen;
        Resume(fd, gen);
        return Conns[fd].Gen == gen;
    }

    void Close(int fd)
    {
        ref Conn c = ref Conns[fd];
        c.Gen++;
        c.Busy = c.CloseAfterSend = c.PeerDone = c.Paused = false;
        if (c.In != null) ArrayPool<byte>.Shared.Return(c.In);
        if (c.Out != null) ArrayPool<byte>.Shared.Return(c.Out);
        c.In = c.Out = null;
        c.InLength = c.OutStart = c.OutEnd = 0;
        Native.close(fd); // leaves the epoll set with it
    }
}
