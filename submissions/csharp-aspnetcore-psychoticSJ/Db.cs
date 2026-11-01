using System.Data;
using System.Threading.Channels;
using Npgsql;
using NpgsqlTypes;

namespace ConduitChallenge;

sealed class SqlQuery(string text, params NpgsqlDbType[] types)
{
    public string Text { get; } = text;
    public NpgsqlDbType[] Types { get; } = types;
}

sealed class Db : IAsyncDisposable
{
    readonly Channel<DbSession> _reads;
    readonly Channel<DbSession> _writes;
    readonly DbSession[] _sessions;
    int _started;
    int _disposed;

    public int ReadCount { get; }

    public Db(string databaseUrl, int reads = 34, int writes = 61)
    {
        if (reads < 1 || writes < 1 || reads > 95 - writes)
            throw new ArgumentOutOfRangeException(nameof(reads), "Database connections must total 2 through 95.");
        ReadCount = reads;
        var options = new BoundedChannelOptions(reads) { SingleReader = false, SingleWriter = false };
        _reads = Channel.CreateBounded<DbSession>(options);
        _writes = Channel.CreateBounded<DbSession>(new BoundedChannelOptions(writes));
        NpgsqlConnectionStringBuilder builder;
        if (databaseUrl.StartsWith("postgres://", StringComparison.OrdinalIgnoreCase) ||
            databaseUrl.StartsWith("postgresql://", StringComparison.OrdinalIgnoreCase))
        {
            var uri = new Uri(databaseUrl);
            var credentials = uri.UserInfo.Split(':', 2);
            builder = new NpgsqlConnectionStringBuilder
            {
                Host = uri.Host,
                Port = uri.IsDefaultPort ? 5432 : uri.Port,
                Username = Uri.UnescapeDataString(credentials[0]),
                Password = credentials.Length == 2 ? Uri.UnescapeDataString(credentials[1]) : "",
                Database = Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/'))
            };
            foreach (var pair in Microsoft.AspNetCore.WebUtilities.QueryHelpers.ParseQuery(uri.Query))
                builder[pair.Key] = pair.Value.ToString();
        }
        else
            builder = new NpgsqlConnectionStringBuilder(databaseUrl);
        builder.Pooling = false;
        builder.Enlist = false;
        builder.CommandTimeout = 10;
        _sessions = new DbSession[reads + writes];
        for (var i = 0; i < _sessions.Length; i++)
        {
            var write = i >= reads;
            builder.ApplicationName = write ? "conduit-write" : "conduit-read";
            _sessions[i] = new DbSession(builder.ConnectionString, write ? _writes.Writer : _reads.Writer, write);
        }
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (Interlocked.Exchange(ref _started, 1) != 0)
            return;
        try
        {
            await Task.WhenAll(_sessions.Select(session => session.OpenAsync(cancellationToken).AsTask()));
            foreach (var session in _sessions)
                session.Return();
        }
        catch
        {
            await DisposeAsync();
            throw;
        }
    }

    public ValueTask<DbSession> ReadAsync(CancellationToken cancellationToken) => LeaseAsync(_reads.Reader, cancellationToken);
    public ValueTask<DbSession> WriteAsync(CancellationToken cancellationToken) => WriteMetrics.Enabled
        ? LeaseWriteAsync(cancellationToken) : LeaseAsync(_writes.Reader, cancellationToken);

    async ValueTask<DbSession> LeaseWriteAsync(CancellationToken cancellationToken)
    {
        var started = WriteMetrics.Stamp();
        WriteMetrics.Waiting(1);
        try { return await LeaseAsync(_writes.Reader, cancellationToken); }
        finally
        {
            WriteMetrics.RecordWait(WriteMetrics.Elapsed(started));
            WriteMetrics.Waiting(-1);
        }
    }

    static async ValueTask<DbSession> LeaseAsync(ChannelReader<DbSession> pool, CancellationToken cancellationToken)
    {
        var session = await pool.ReadAsync(cancellationToken);
        session.Lease();
        try
        {
            await session.OpenAsync(cancellationToken);
            return session;
        }
        catch
        {
            session.Return();
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
            return;
        _reads.Writer.TryComplete();
        _writes.Writer.TryComplete();
        foreach (var session in _sessions)
            await session.CloseAsync();
        await WriteMetrics.StopAsync();
    }
}

sealed class DbSession(string connectionString, ChannelWriter<DbSession> pool, bool write) : IAsyncDisposable
{
    readonly Dictionary<SqlQuery, NpgsqlCommand> _commands = new();
    NpgsqlConnection _connection = new(connectionString);
    int _leased = 1;
    long _writeLeaseAt;

    public NpgsqlConnection Connection => _connection;

    internal async ValueTask OpenAsync(CancellationToken cancellationToken)
    {
        if (_connection.State == ConnectionState.Open)
            return;
        await CloseAsync();
        _connection = new NpgsqlConnection(connectionString);
        try
        {
            await _connection.OpenAsync(cancellationToken);
            await using var settings = new NpgsqlCommand("SET jit = off; SET max_parallel_workers_per_gather = 0", _connection);
            await settings.ExecuteNonQueryAsync(cancellationToken);
        }
        catch
        {
            await CloseAsync();
            _connection = new NpgsqlConnection(connectionString);
            throw;
        }
    }

    public async ValueTask<NpgsqlCommand> CommandAsync(SqlQuery query, CancellationToken cancellationToken)
    {
        if (_commands.TryGetValue(query, out var command))
            return command;
        command = new NpgsqlCommand(query.Text, _connection);
        try
        {
            foreach (var type in query.Types)
                command.Parameters.Add(Parameter(type));
            await command.PrepareAsync(cancellationToken);
            _commands.Add(query, command);
            return command;
        }
        catch
        {
            await command.DisposeAsync();
            throw;
        }
    }

    static NpgsqlParameter Parameter(NpgsqlDbType type) => type switch
    {
        NpgsqlDbType.Bigint => new NpgsqlParameter<long> { NpgsqlDbType = type },
        NpgsqlDbType.Integer => new NpgsqlParameter<int> { NpgsqlDbType = type },
        NpgsqlDbType.Text => new NpgsqlParameter<string> { NpgsqlDbType = type },
        NpgsqlDbType.Boolean => new NpgsqlParameter<bool> { NpgsqlDbType = type },
        (NpgsqlDbType.Array | NpgsqlDbType.Bigint) => new NpgsqlParameter<long[]> { NpgsqlDbType = type },
        (NpgsqlDbType.Array | NpgsqlDbType.Integer) => new NpgsqlParameter<int[]> { NpgsqlDbType = type },
        (NpgsqlDbType.Array | NpgsqlDbType.Text) => new NpgsqlParameter<string[]> { NpgsqlDbType = type },
        _ => throw new ArgumentOutOfRangeException(nameof(type), type, "Unsupported SQL parameter type.")
    };

    public static void Set<T>(NpgsqlCommand command, int index, T value)
    {
        ((NpgsqlParameter<T>)command.Parameters[index]).TypedValue = value;
    }

    internal void Lease()
    {
        Volatile.Write(ref _leased, 1);
        if (write)
        {
            _writeLeaseAt = WriteMetrics.Stamp();
            WriteMetrics.Active(1);
        }
    }

    internal void Return()
    {
        if (Interlocked.Exchange(ref _leased, 0) != 0)
        {
            var started = Interlocked.Exchange(ref _writeLeaseAt, 0);
            if (started != 0)
            {
                WriteMetrics.RecordHold(WriteMetrics.Elapsed(started));
                WriteMetrics.Active(-1);
            }
            pool.TryWrite(this);
        }
    }

    public ValueTask DisposeAsync()
    {
        Return();
        return ValueTask.CompletedTask;
    }

    internal async ValueTask CloseAsync()
    {
        foreach (var command in _commands.Values)
            await command.DisposeAsync();
        _commands.Clear();
        await _connection.DisposeAsync();
    }
}
