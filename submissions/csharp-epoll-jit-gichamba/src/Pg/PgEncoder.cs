namespace Conduit.Pg;

/// <summary>Encoders for the frontend messages the client sends.</summary>
internal static class PgEncoder {
    /// <summary>StartupMessage (protocol 3.0). Session settings travel as extra startup parameters.</summary>
    public static void Startup(PgWriter w, string user, string database, string applicationName,
        IReadOnlyList<KeyValuePair<string, string>> settings) {
        int at = w.BeginUntyped();
        w.Int32(196608);
        w.CString("user");
        w.CString(user);
        w.CString("database");
        w.CString(database);
        w.CString("application_name");
        w.CString(applicationName);
        w.CString("client_encoding");
        w.CString("UTF8");
        foreach (KeyValuePair<string, string> kv in settings) {
            w.CString(kv.Key);
            w.CString(kv.Value);
        }
        w.Byte(0);
        w.EndMessage(at);
    }

    /// <summary>SASLInitialResponse: chosen mechanism and the client-first-message.</summary>
    public static void SaslInitialResponse(PgWriter w, string mechanism, ReadOnlySpan<byte> clientFirst) {
        int at = w.BeginMessage((byte)'p');
        w.CString(mechanism);
        w.Int32(clientFirst.Length);
        w.Bytes(clientFirst);
        w.EndMessage(at);
    }

    /// <summary>SASLResponse: the client-final-message.</summary>
    public static void SaslResponse(PgWriter w, ReadOnlySpan<byte> data) {
        int at = w.BeginMessage((byte)'p');
        w.Bytes(data);
        w.EndMessage(at);
    }

    /// <summary>Parse: creates a named prepared statement with the given parameter type OIDs.</summary>
    public static void Parse(PgWriter w, string name, string sql, ReadOnlySpan<uint> paramOids) {
        int at = w.BeginMessage((byte)'P');
        w.CString(name);
        w.CString(sql);
        w.Int16((short)paramOids.Length);
        foreach (uint oid in paramOids) {
            w.Int32((int)oid);
        }

        w.EndMessage(at);
    }

    /// <summary>Bind to the unnamed portal: all parameters binary, all result columns binary.</summary>
    public static void Bind(PgWriter w, string statement, PgParams parameters) {
        int at = w.BeginMessage((byte)'B');
        w.Byte(0); // unnamed portal
        w.CString(statement);
        w.Int16(1); // one parameter format code, applies to all
        w.Int16(1); // binary
        w.Int16((short)parameters.Count);
        w.Bytes(parameters.Values);
        w.Int16(1); // one result format code, applies to all columns
        w.Int16(1); // binary
        w.EndMessage(at);
    }

    /// <summary>Execute the unnamed portal with no row limit.</summary>
    public static void Execute(PgWriter w) {
        int at = w.BeginMessage((byte)'E');
        w.Byte(0);
        w.Int32(0);
        w.EndMessage(at);
    }

    /// <summary>Sync: ends the pipelined batch and asks for ReadyForQuery.</summary>
    public static void Sync(PgWriter w) => w.EndMessage(w.BeginMessage((byte)'S'));

    /// <summary>Terminate: polite close.</summary>
    public static void Terminate(PgWriter w) => w.EndMessage(w.BeginMessage((byte)'X'));
}
