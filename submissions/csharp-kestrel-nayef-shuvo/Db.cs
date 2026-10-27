using System.Data.Common;
using Npgsql;
using NpgsqlTypes;

namespace Conduit;

internal static class Db
{
    /// <summary>Builds the pool from a postgres://user:password@host:port/database URL.</summary>
    internal static NpgsqlDataSource Create(string url, int poolSize, ILoggerFactory loggerFactory)
    {
        var u = new Uri(url);
        var userInfo = u.UserInfo.Split(':', 2);
        var b = new NpgsqlConnectionStringBuilder
        {
            Host = u.Host,
            Port = u.Port > 0 ? u.Port : 5432,
            Username = Uri.UnescapeDataString(userInfo[0]),
            Password = userInfo.Length > 1 ? Uri.UnescapeDataString(userInfo[1]) : null,
            Database = u.AbsolutePath.TrimStart('/'),
            MaxPoolSize = poolSize,
            SslMode = SslMode.Disable,
        };
        var dataSource = new NpgsqlDataSourceBuilder(b.ConnectionString);
#if DEBUG
        dataSource.UseLoggerFactory(loggerFactory); // Npgsql's own logs: connection problems, and the SQL with LOG_SQL=1
#endif
        return dataSource.Build();
    }

    // Positional parameters ($1, $2, ...): add them in order, each with an explicit type.
    internal static void AddInt8(this NpgsqlCommand cmd, long v) =>
        cmd.Parameters.Add(new NpgsqlParameter<long> { TypedValue = v });

    internal static void AddText(this NpgsqlCommand cmd, string? v) =>
        cmd.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Text, Value = (object?)v ?? DBNull.Value });

    internal static void AddTextArray(this NpgsqlCommand cmd, string[] v) =>
        cmd.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Array | NpgsqlDbType.Text, Value = v });

    internal static string? GetNullableString(this DbDataReader r, int i) => r.IsDBNull(i) ? null : r.GetString(i);

    internal static bool IsUniqueViolation(this PostgresException e) => e.SqlState == PostgresErrorCodes.UniqueViolation;
}
