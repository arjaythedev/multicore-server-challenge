namespace Conduit.Pg;

/// <summary>
/// One pipelined unit of work: a list of prepared statements run back to back and one Sync.
/// Callbacks run on the connection's reader thread and must not block.
/// </summary>
public abstract class PgRequest {
    /// <summary>Prepared statement name of each statement added.</summary>
    private string[] _names = new string[4];
    /// <summary>Parameter list of each statement. The objects are kept and reused.</summary>
    private PgParams?[] _parameters = new PgParams?[4];
    /// <summary>Number of statements added.</summary>
    private int _count;

    /// <summary>Number of statements added.</summary>
    public int StatementCount => _count;

    /// <summary>Removes all statements so the object can be reused.</summary>
    protected void ResetStatements() => _count = 0;

    /// <summary>Adds a prepared statement and returns its (cleared) parameter list to fill.</summary>
    protected PgParams AddStatement(string preparedName) {
        if (_count == _names.Length) {
            Array.Resize(ref _names, _count * 2);
            Array.Resize(ref _parameters, _count * 2);
        }
        PgParams p = _parameters[_count] ??= new PgParams();
        p.Clear();
        _names[_count] = preparedName;
        _count++;
        return p;
    }

    /// <summary>The prepared name of statement <paramref name="i"/>.</summary>
    internal string StatementName(int i) => _names[i];

    /// <summary>The parameters of statement <paramref name="i"/>.</summary>
    internal PgParams StatementParams(int i) => _parameters[i]!;

    /// <summary>A result row of statement <paramref name="statementIndex"/>.</summary>
    public abstract void OnRow(int statementIndex, in PgRow row);

    /// <summary>Statement <paramref name="statementIndex"/> finished; <paramref name="tag"/> is the command tag such as "SELECT 3".</summary>
    public abstract void OnCommandComplete(int statementIndex, ReadOnlySpan<byte> tag);

    /// <summary>The server reported an error. The remaining statements are skipped. <see cref="OnDone"/> follows.</summary>
    public abstract void OnError(PgError error);

    /// <summary>ReadyForQuery arrived: the request is finished, with or without an error.</summary>
    public abstract void OnDone();
}
