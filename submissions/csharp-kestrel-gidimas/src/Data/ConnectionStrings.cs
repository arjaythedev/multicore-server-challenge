using Npgsql;

namespace Conduit.Data;

public static class ConnectionStrings
{
    /// <summary>Turns DATABASE_URL (postgres://user:password@host:port/database) into an Npgsql connection string.</summary>
    public static string FromUrl(string databaseUrl, int maxPoolSize, bool multiplexing)
    {
        var uri = new Uri(databaseUrl);
        var userInfo = uri.UserInfo.Split(':', 2);
        return new NpgsqlConnectionStringBuilder
        {
            Host = uri.Host,
            Port = uri.Port,
            Database = Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/')),
            Username = Uri.UnescapeDataString(userInfo[0]),
            Password = userInfo.Length > 1 ? Uri.UnescapeDataString(userInfo[1]) : null,
            ApplicationName = "conduit",
            // Stay under the 95-connection budget (max_connections is 100).
            MaxPoolSize = maxPoolSize,
            // Automatic preparation (Npgsql performance guidance): statements run at least twice on a connection are
            // prepared server-side, so Postgres parses and plans them once. It also means connections returned to
            // the pool are no longer reset with DISCARD ALL, which would drop the prepared statements.
            MaxAutoPrepare = 64,
            AutoPrepareMinUsages = 2,
            // Npgsql multiplexing: commands from concurrent requests share connections and are written together.
            Multiplexing = multiplexing,
            // Short OLTP queries: JIT compilation costs more than it saves.
            Options = "-c jit=off",
        }.ConnectionString;
    }
}
