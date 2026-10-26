using System;
using System.IO;
using System.Threading.Tasks;
using Conduit.Data;
using Conduit.Security;
using Npgsql;
using Xunit;

namespace Conduit.Tests.Endpoints;

/// <summary>
/// The repository's schema.sql in a Postgres schema of its own, in the database CONDUIT_TEST_DB names (a user that
/// may create schemas), with Db's reader and writer set up on it as Program does, with the <see cref="Db.Plan"/>
/// settings. A subclass adds its rows in <see cref="Seed"/>. Without CONDUIT_TEST_DB nothing
/// is created and the tests skip (<see cref="Require"/>). The schema is dropped on dispose.
/// </summary>
public abstract class TestSchema : IAsyncLifetime
{
    public const string Secret = "endpoint-tests";

    static readonly string? ConnectionString = Environment.GetEnvironmentVariable("CONDUIT_TEST_DB");

    public readonly string Name = "conduit_test_" + Guid.NewGuid().ToString("N");
    NpgsqlDataSource? _admin;

    /// <summary>Connections outside the server's: for setup, for holding locks, for checking what was written.</summary>
    public NpgsqlDataSource Admin => _admin!;

    public static void Require() => Assert.SkipWhen(ConnectionString is null, "CONDUIT_TEST_DB is not set");

    public async ValueTask InitializeAsync()
    {
        if (ConnectionString is null) return;
        _admin = NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder(ConnectionString) { SearchPath = Name }.ConnectionString);
        await Exec($"CREATE SCHEMA {Name}; SET search_path = {Name}; {await File.ReadAllTextAsync(SchemaFile())}");
        await Seed();
        Db.Init(new NpgsqlConnectionStringBuilder(ConnectionString) { SearchPath = Name }, readers: 4, writers: 1);
        Jwt.Init(Secret);
    }

    protected abstract Task Seed();

    /// <summary>A data source for a writer of the test's own, set up as the server's writer is.</summary>
    public NpgsqlDataSource WriterSource()
    {
        var csb = new NpgsqlConnectionStringBuilder(ConnectionString) { SearchPath = Name };
        Db.Plan(csb);
        return Db.WriterSource(csb, 1, Db.WriterLockTimeout);
    }

    public async Task Exec(string sql)
    {
        await using var cmd = Admin.CreateCommand(sql);
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task<T> Scalar<T>(string sql)
    {
        await using var cmd = Admin.CreateCommand(sql);
        return (T)(await cmd.ExecuteScalarAsync())!;
    }

    static string SchemaFile()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
        {
            string f = Path.Combine(d.FullName, "schema.sql");
            if (File.Exists(f)) return f;
        }
        throw new FileNotFoundException("schema.sql not found above " + AppContext.BaseDirectory);
    }

    public async ValueTask DisposeAsync()
    {
        if (_admin is null) return;
        Db.Writer.Complete();
        Db.Reader.Complete();
        await Exec($"DROP SCHEMA {Name} CASCADE");
        await _admin.DisposeAsync();
    }
}
