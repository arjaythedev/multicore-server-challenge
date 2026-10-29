namespace Conduit.Pg;

/// <summary>Parsed <c>postgres://user:pass@host:port/db</c> URL.</summary>
public sealed class PgConnectionString {
    /// <summary>Server host name or address.</summary>
    public string Host { get; }

    /// <summary>TCP port, 5432 when absent.</summary>
    public int Port { get; }

    /// <summary>Login user.</summary>
    public string User { get; }

    /// <summary>Password, empty when absent.</summary>
    public string Password { get; }

    /// <summary>Database name, the user name when absent.</summary>
    public string Database { get; }

    /// <summary>Creates the parsed value. <see cref="Parse"/> is the way in.</summary>
    private PgConnectionString(string host, int port, string user, string password, string database) {
        Host = host;
        Port = port;
        User = user;
        Password = password;
        Database = database;
    }

    /// <summary>Parses a postgres:// or postgresql:// URL. User, password and database are percent-decoded. A query string is ignored.</summary>
    /// <exception cref="FormatException">The URL is not usable.</exception>
    public static PgConnectionString Parse(string url) {
        string rest;
        if (url.StartsWith("postgres://", StringComparison.Ordinal)) {
            rest = url["postgres://".Length..];
        } else if (url.StartsWith("postgresql://", StringComparison.Ordinal)) {
            rest = url["postgresql://".Length..];
        } else {
            throw new FormatException("connection string must start with postgres://");
        }

        int q = rest.IndexOf('?');
        if (q >= 0) {
            rest = rest[..q];
        }

        int slash = rest.IndexOf('/');
        string authority = slash < 0 ? rest : rest[..slash];
        string db = slash < 0 ? "" : Uri.UnescapeDataString(rest[(slash + 1)..]);

        int at = authority.LastIndexOf('@');
        if (at < 0) {
            throw new FormatException("connection string has no user");
        }

        string userInfo = authority[..at];
        string hostPort = authority[(at + 1)..];

        int colon = userInfo.IndexOf(':');
        string user = Uri.UnescapeDataString(colon < 0 ? userInfo : userInfo[..colon]);
        string password = colon < 0 ? "" : Uri.UnescapeDataString(userInfo[(colon + 1)..]);
        if (user.Length == 0) {
            throw new FormatException("connection string has no user");
        }

        string host = hostPort;
        int port = 5432;
        int portColon = hostPort.LastIndexOf(':');
        if (portColon >= 0 && !hostPort.EndsWith(']')) {
            host = hostPort[..portColon];
            if (!int.TryParse(hostPort[(portColon + 1)..], out port) || port is < 1 or > 65535) {
                throw new FormatException("connection string has a bad port");
            }
        }
        host = host.Trim('[', ']');
        if (host.Length == 0) {
            host = "localhost";
        }

        return new PgConnectionString(host, port, user, password, db.Length == 0 ? user : db);
    }
}
