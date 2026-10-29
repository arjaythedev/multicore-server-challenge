using System.Buffers;

namespace Conduit.Http;

/// <summary>
/// One client connection. <see cref="Send"/> may be called from any thread. All other state
/// changes happen on the owning loop thread, under the connection's lock where another thread can
/// also see them. The owning loop closes the descriptor, on its thread or from its Dispose.
/// </summary>
public sealed unsafe class Connection {
    /// <summary>Largest amount of unparsed input kept for one connection.</summary>
    internal const int MaxPendingBytes = HttpParser.MaxHeadBytes + HttpParser.MaxBodyBytes + 65536;

    /// <summary>The loop that owns this connection.</summary>
    private readonly HttpLoop _loop;

    /// <summary>The socket descriptor.</summary>
    private readonly int _fd;

    /// <summary>Guards every field below it, which the loop thread and a responding thread both touch.</summary>
    private readonly object _sync = new();

    /// <summary>Set once the descriptor is closed and the buffers are released.</summary>
    private volatile bool _closed;

    /// <summary>A request is with the handler and has no response yet.</summary>
    private bool _busy;

    /// <summary>A send failed; the loop will close the connection.</summary>
    private bool _failed;

    /// <summary>Close once the current response is written: the client asked for it or the request was malformed.</summary>
    private bool _closeAfterResponse;

    /// <summary>Pooled buffer of received bytes not yet handed to the parser.</summary>
    private byte[]? _pending;

    /// <summary>Number of valid bytes in <see cref="_pending"/>.</summary>
    private int _pendingLen;

    /// <summary>Pooled buffer of response bytes the socket did not accept yet.</summary>
    private byte[]? _out;

    /// <summary>Start and length of the unsent bytes in <see cref="_out"/>.</summary>
    private int _outOff, _outLen;

    /// <summary>Wraps an accepted, non-blocking descriptor that <paramref name="loop"/> owns.</summary>
    internal Connection(HttpLoop loop, int fd) {
        _loop = loop;
        _fd = fd;
    }

    /// <summary>True once the client is gone and the connection state has been released.</summary>
    public bool IsClosed => _closed;

    /// <summary>The socket descriptor.</summary>
    internal int Fd => _fd;

    /// <summary>Unparsed bytes that arrived while a request was outstanding or only partly received.</summary>
    internal ReadOnlySpan<byte> PendingSpan => new(_pending, 0, _pendingLen);

    /// <summary>Number of unparsed bytes held for this connection.</summary>
    internal int PendingLength => _pendingLen;

    /// <summary>
    /// Sends the response for the outstanding request, then lets the next pipelined request run.
    /// Whatever the socket does not take at once is queued and written when the socket is writable.
    /// A closed or failed connection drops the bytes. Safe to call from any thread.
    /// </summary>
    public void Send(ReadOnlySpan<byte> response) {
        bool resume;
        lock (_sync) {
            if (_closed || _failed) {
                return;
            }

            _busy = false;
            if (_outLen == 0) {
                int sent = SendLocked(response);
                if (sent < 0) {
                    FailLocked();
                    return;
                }
                if (sent < response.Length) {
                    Stash(response[sent..]);
                }
            } else {
                Stash(response);
            }

            if (_outLen == 0 && _closeAfterResponse) {
                Libc.shutdown(_fd, Libc.SHUT_RDWR);
            }

            resume = _pendingLen > 0 && _outLen == 0 && !_closeAfterResponse;
        }
        if (resume) {
            _loop.Post(this);
        }
    }

    /// <summary>Claims the connection for the next request. False while one is outstanding, output is queued, or the client asked to close.</summary>
    internal bool TryBegin() {
        lock (_sync) {
            if (_closed || _failed || _busy || _outLen > 0 || _closeAfterResponse) {
                return false;
            }

            _busy = true;
            return true;
        }
    }

    /// <summary>Gives the claim back when no whole request was available.</summary>
    internal void CancelBegin() {
        lock (_sync) {
            _busy = false;
        }
    }

    /// <summary>Records whether the connection stays open after the response to the request just parsed.</summary>
    internal void SetKeepAlive(bool keepAlive) {
        if (keepAlive) {
            return;
        }

        lock (_sync) {
            _closeAfterResponse = true;
        }
    }

    /// <summary>Answers a malformed request with a response and closes after it is written, dropping any unparsed input.</summary>
    internal void SendAndClose(ReadOnlySpan<byte> response) {
        lock (_sync) {
            _closeAfterResponse = true;
            ReleasePendingLocked();
        }
        Send(response);
    }

    /// <summary>Adds received bytes to the pending buffer. False when the connection holds too much unparsed input.</summary>
    internal bool Append(ReadOnlySpan<byte> data) {
        lock (_sync) {
            if (_closed) {
                return false;
            }

            if (_pendingLen + data.Length > MaxPendingBytes) {
                return false;
            }

            int needed = _pendingLen + data.Length;
            if (_pending is null || _pending.Length < needed) {
                byte[] bigger = ArrayPool<byte>.Shared.Rent(Math.Max(needed, 4096));
                if (_pending is not null) {
                    _pending.AsSpan(0, _pendingLen).CopyTo(bigger);
                    ArrayPool<byte>.Shared.Return(_pending);
                }
                _pending = bigger;
            }
            data.CopyTo(_pending.AsSpan(_pendingLen));
            _pendingLen = needed;
            return true;
        }
    }

    /// <summary>
    /// Keeps <paramref name="rest"/> (which may live in the old pending buffer) as the new pending input.
    /// Returns true when the caller should try to parse again, because nothing is outstanding and
    /// whole requests may be waiting; this closes the race with a <see cref="Send"/> from another thread.
    /// </summary>
    internal bool StoreLeftover(ReadOnlySpan<byte> rest, bool needMore) {
        lock (_sync) {
            if (_closed) {
                return false;
            }

            if (rest.IsEmpty) {
                ReleasePendingLocked();
                return false;
            }
            byte[] fresh = ArrayPool<byte>.Shared.Rent(Math.Max(rest.Length, 1024));
            rest.CopyTo(fresh);
            if (_pending is not null) {
                ArrayPool<byte>.Shared.Return(_pending);
            }

            _pending = fresh;
            _pendingLen = rest.Length;
            return !needMore && !_busy && _outLen == 0 && !_closeAfterResponse && !_failed;
        }
    }

    /// <summary>
    /// Writes queued output now that the socket is writable. Returns true when nothing is queued,
    /// no request is outstanding and unparsed input is waiting, so the loop should parse it.
    /// </summary>
    internal bool FlushOutput() {
        lock (_sync) {
            if (_closed || _failed) {
                return false;
            }

            if (_outLen > 0) {
                int n = SendLocked(new ReadOnlySpan<byte>(_out, _outOff, _outLen));
                if (n < 0) {
                    FailLocked();
                    return false;
                }
                _outOff += n;
                _outLen -= n;
                if (_outLen == 0) {
                    ArrayPool<byte>.Shared.Return(_out!);
                    _out = null;
                    _outOff = 0;
                }
            }
            if (_outLen > 0) {
                return false;
            }

            if (_closeAfterResponse) {
                Libc.shutdown(_fd, Libc.SHUT_RDWR);
                return false;
            }
            return !_busy && _pendingLen > 0;
        }
    }

    /// <summary>Closes the descriptor and frees the buffers. Called by the owning loop only. Later sends are dropped.</summary>
    internal void Release() {
        lock (_sync) {
            if (_closed) {
                return;
            }

            _closed = true;
            Libc.close(_fd);
            ReleasePendingLocked();
            if (_out is not null) {
                ArrayPool<byte>.Shared.Return(_out);
                _out = null;
            }
            _outOff = _outLen = 0;
        }
    }

    /// <summary>Returns the pending buffer to the pool and empties it. Caller holds the lock.</summary>
    private void ReleasePendingLocked() {
        if (_pending is not null) {
            ArrayPool<byte>.Shared.Return(_pending);
            _pending = null;
        }
        _pendingLen = 0;
    }

    /// <summary>A failed send: stop using the socket and let the loop notice the hang-up and close it. Caller holds the lock.</summary>
    private void FailLocked() {
        _failed = true;
        Libc.shutdown(_fd, Libc.SHUT_RDWR);
    }

    /// <summary>Sends until everything is written or the socket is full. Returns bytes written, or -1 on a fatal error. Caller holds the lock.</summary>
    private int SendLocked(ReadOnlySpan<byte> data) {
        int done = 0;
        fixed (byte* p = data) {
            while (done < data.Length) {
                nint n = Libc.send(_fd, p + done, (nuint)(data.Length - done), Libc.MSG_NOSIGNAL);
                if (n >= 0) {
                    done += (int)n;
                    continue;
                }

                int err = Libc.Errno;
                if (err == Libc.EINTR) {
                    continue;
                }

                if (err == Libc.EAGAIN) {
                    break;
                }

                return -1;
            }
        }
        return done;
    }

    /// <summary>Queues bytes the socket did not accept; <see cref="FlushOutput"/> writes them later. Caller holds the lock.</summary>
    private void Stash(ReadOnlySpan<byte> data) {
        int needed = _outLen + data.Length;
        if (_out is null) {
            _out = ArrayPool<byte>.Shared.Rent(Math.Max(needed, 4096));
            _outOff = 0;
        } else if (_outOff + needed > _out.Length) {
            byte[] bigger = ArrayPool<byte>.Shared.Rent(needed);
            _out.AsSpan(_outOff, _outLen).CopyTo(bigger);
            ArrayPool<byte>.Shared.Return(_out);
            _out = bigger;
            _outOff = 0;
        }
        data.CopyTo(_out.AsSpan(_outOff + _outLen));
        _outLen += data.Length;
    }
}
