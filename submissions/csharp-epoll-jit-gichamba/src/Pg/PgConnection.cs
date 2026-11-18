using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace Conduit.Pg;

/// <summary>
/// One Postgres connection using the extended protocol with binary results. Requests are pipelined:
/// <see cref="Send"/> writes and returns, and a reader thread delivers results through the request's callbacks.
/// </summary>
public sealed class PgConnection : IDisposable {
    /// <summary>The byte pipe to the server.</summary>
    private readonly IPgTransport _transport;
    /// <summary>Splits the server's bytes into messages. Used by one thread at a time: login, Prepare, then the reader thread.</summary>
    private readonly PgMessageReader _reader;
    /// <summary>Builds outgoing messages. Used under <see cref="_writeLock"/>, or alone during login.</summary>
    private readonly PgWriter _writer = new();
    /// <summary>Serializes writes to the transport and the choice to start the reader thread.</summary>
    private readonly object _writeLock = new();
    /// <summary>Guards the queue of sent requests and the broken flag.</summary>
    private readonly object _queueLock = new();
    /// <summary>Requests sent and not yet done, oldest first. The server answers in this order.</summary>
    private readonly Queue<PgRequest> _queue = new();
    /// <summary>The application name, used to name the reader thread.</summary>
    private readonly string _name;
    /// <summary>Column offsets and lengths reused for every DataRow; only the reader thread touches it.</summary>
    private int[] _scratch = new int[32];
    /// <summary>Set once, when the connection fails.</summary>
    private volatile bool _broken;
    /// <summary>Set by Dispose, so the failure it causes does not raise <see cref="Broken"/>.</summary>
    private volatile bool _closing;
    /// <summary>The reader thread, started by the first Send, or null.</summary>
    private Thread? _thread;

    /// <summary>Raised once, on the thread that noticed the failure, with every request sent and not yet done. Not raised after Dispose.</summary>
    public event Action<PgConnection, IReadOnlyList<PgRequest>, Exception>? Broken;

    /// <summary>Creates a connection over <paramref name="transport"/>. Login happens in <see cref="Open"/>.</summary>
    private PgConnection(IPgTransport transport, string name) {
        _transport = transport;
        _name = name;
        _reader = new PgMessageReader(transport);
    }

    /// <summary>Opens a TCP connection, logs in and applies the session settings, which go in the startup packet.</summary>
    public static PgConnection Connect(PgConnectionString cs, string applicationName,
        IReadOnlyList<KeyValuePair<string, string>> sessionSettings) {
        SocketTransport t = SocketTransport.Connect(cs.Host, cs.Port);
        try {
            return Open(t, cs, applicationName, sessionSettings, null);
        } catch {
            t.Close();
            throw;
        }
    }

    /// <summary>Logs in over an existing transport. <paramref name="clientNonce"/> is for tests; null picks a random one.</summary>
    internal static PgConnection Open(IPgTransport transport, PgConnectionString cs, string applicationName,
        IReadOnlyList<KeyValuePair<string, string>> sessionSettings, string? clientNonce) {
        PgConnection c = new(transport, applicationName);
        c._writer.Clear();
        PgEncoder.Startup(c._writer, cs.User, cs.Database, applicationName, sessionSettings);
        transport.Write(c._writer.Written);

        PgScram? scram = null;
        while (true) {
            byte type = c._reader.Next(out ReadOnlySpan<byte> body);
            switch ((char)type) {
                case 'R':
                    scram = c.HandleAuth(body, cs, scram, clientNonce);
                    break;
                case 'E':
                    throw new PgException(PgMessages.ParseError(body));
                case 'Z':
                    return c;
                default:
                    // ParameterStatus, BackendKeyData and notices: nothing here needs them.
                    break;
            }
        }
    }

    /// <summary>Replies to one Authentication message and returns the SCRAM state to keep. Only SCRAM-SHA-256 and trust are accepted.</summary>
    private PgScram? HandleAuth(ReadOnlySpan<byte> body, PgConnectionString cs, PgScram? scram, string? clientNonce) {
        int code = BinaryPrimitives.ReadInt32BigEndian(body);
        switch (code) {
            case 0:
                return scram;
            case 10:
                if (!SaslMechanisms(body[4..]).Contains("SCRAM-SHA-256")) {
                    throw new PgException("server offers no SCRAM-SHA-256");
                }

                scram = new PgScram(cs.User, cs.Password, clientNonce ?? NewNonce());
                _writer.Clear();
                PgEncoder.SaslInitialResponse(_writer, "SCRAM-SHA-256", Encoding.UTF8.GetBytes(scram.ClientFirst));
                _transport.Write(_writer.Written);
                return scram;
            case 11:
                if (scram is null) {
                    throw new PgException("unexpected SASLContinue");
                }

                _writer.Clear();
                PgEncoder.SaslResponse(_writer, Encoding.UTF8.GetBytes(scram.ClientFinal(Encoding.UTF8.GetString(body[4..]))));
                _transport.Write(_writer.Written);
                return scram;
            case 12:
                if (scram is null) {
                    throw new PgException("unexpected SASLFinal");
                }

                scram.VerifyServerFinal(Encoding.UTF8.GetString(body[4..]));
                return scram;
            default:
                throw new PgException("unsupported authentication method " + code);
        }
    }

    /// <summary>Reads the NUL-terminated mechanism names of an AuthenticationSASL message.</summary>
    private static List<string> SaslMechanisms(ReadOnlySpan<byte> list) {
        List<string> result = [];
        while (!list.IsEmpty && list[0] != 0) {
            int end = list.IndexOf((byte)0);
            result.Add(Encoding.ASCII.GetString(list[..end]));
            list = list[(end + 1)..];
        }
        return result;
    }

    /// <summary>A random client nonce for SCRAM, from 18 random bytes in base64.</summary>
    private static string NewNonce() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(18));

    /// <summary>
    /// Prepares a named statement and waits for the server. Call it at setup, before the first <see cref="Send"/>.
    /// </summary>
    /// <exception cref="PgException">The server rejected the statement.</exception>
    public void Prepare(string statementName, string sql, ReadOnlySpan<uint> paramOids) {
        lock (_writeLock) {
            if (_thread is not null) {
                throw new InvalidOperationException("Prepare must run before the first Send");
            }

            _writer.Clear();
            PgEncoder.Parse(_writer, statementName, sql, paramOids);
            PgEncoder.Sync(_writer);
            _transport.Write(_writer.Written);
            PgError? error = null;
            while (true) {
                byte type = _reader.Next(out ReadOnlySpan<byte> body);
                if (type == 'Z') {
                    if (error is { } e) {
                        throw new PgException(e);
                    }

                    return;
                }
                if (type == 'E') {
                    error = PgMessages.ParseError(body);
                }
            }
        }
    }

    /// <summary>
    /// Writes Bind and Execute for each statement of <paramref name="request"/> and one Sync, without waiting.
    /// A write failure breaks the connection and the request is reported through <see cref="Broken"/>.
    /// </summary>
    /// <exception cref="InvalidOperationException">The connection is already broken.</exception>
    public void Send(PgRequest request) {
        Exception? failure = null;
        lock (_writeLock) {
            if (_broken) {
                throw new InvalidOperationException("connection is broken");
            }

            _thread ??= StartReader();
            _writer.Clear();
            for (int i = 0; i < request.StatementCount; i++) {
                PgEncoder.Bind(_writer, request.StatementName(i), request.StatementParams(i));
                PgEncoder.Execute(_writer);
            }
            PgEncoder.Sync(_writer);
            lock (_queueLock) {
                if (_broken) {
                    throw new InvalidOperationException("connection is broken");
                }

                _queue.Enqueue(request);
            }
            try {
                _transport.Write(_writer.Written);
            } catch (Exception ex) {
                failure = ex;
            }
        }
        if (failure is not null) {
            Fail(failure);
        }
    }

    /// <summary>Starts the background thread that runs <see cref="ReadLoop"/>.</summary>
    private Thread StartReader() {
        Thread t = new(ReadLoop) { IsBackground = true, Name = "pg-reader-" + _name };
        t.Start();
        return t;
    }

    /// <summary>The oldest request in flight, which owns the messages now arriving. Throws when none is in flight.</summary>
    private PgRequest Head() {
        lock (_queueLock) {
            if (_queue.Count == 0) {
                throw new PgException("server sent results with no request in flight");
            }

            return _queue.Peek();
        }
    }

    /// <summary>The reader thread: delivers backend messages to the request at the head of the queue until the connection fails.</summary>
    private void ReadLoop() {
        try {
            PgRequest? current = null;
            int statement = 0;
            bool failed = false;
            while (true) {
                byte type = _reader.Next(out ReadOnlySpan<byte> body);
                switch ((char)type) {
                    case 'D':
                        current ??= Head();
                        current.OnRow(statement, PgRow.Parse(body, ref _scratch));
                        break;
                    case 'C':
                        current ??= Head();
                        current.OnCommandComplete(statement++, PgMessages.ParseTag(body));
                        break;
                    case 'I': // EmptyQueryResponse counts as a finished statement
                        current ??= Head();
                        statement++;
                        break;
                    case 'E':
                        current ??= Head();
                        if (!failed) {
                            failed = true;
                            current.OnError(PgMessages.ParseError(body));
                        }
                        break;
                    case 'Z':
                        current ??= Head();
                        lock (_queueLock) {
                            _queue.Dequeue();
                        }

                        current.OnDone();
                        current = null;
                        statement = 0;
                        failed = false;
                        break;
                    case 'R':
                        throw new PgException("unexpected authentication message");
                    default:
                        // BindComplete, NoData, notices and parameter changes carry nothing a request needs.
                        break;
                }
            }
        } catch (Exception ex) {
            Fail(ex);
        }
    }

    /// <summary>Marks the connection broken once, closes the transport and reports the lost requests.</summary>
    private void Fail(Exception ex) {
        PgRequest[] pending;
        lock (_queueLock) {
            if (_broken) {
                return;
            }

            _broken = true;
            pending = [.. _queue];
            _queue.Clear();
        }
        try {
            _transport.Close();
        } catch (Exception) {
            // Already closed.
        }
        if (!_closing) {
            Broken?.Invoke(this, pending, ex);
        }
    }

    /// <summary>
    /// Breaks the connection with <paramref name="reason"/> and raises <see cref="Broken"/> with the requests in flight.
    /// Does nothing when it is already broken.
    /// </summary>
    public void Abort(Exception reason) => Fail(reason);

    /// <summary>Sends Terminate and closes the transport. No <see cref="Broken"/> event is raised.</summary>
    public void Dispose() {
        _closing = true;
        lock (_writeLock) {
            if (!_broken) {
                try {
                    _writer.Clear();
                    PgEncoder.Terminate(_writer);
                    _transport.Write(_writer.Written);
                } catch (Exception) {
                    // Closing anyway.
                }
            }
        }
        Fail(new ObjectDisposedException(nameof(PgConnection)));
    }
}
