using Npgsql;

namespace Conduit.Data;

public static class PostgresErrors
{
    /// <summary>True when a statement failed on a unique constraint (SQLSTATE 23505).</summary>
    public static bool IsUniqueViolation(this PostgresException e) => e.SqlState == PostgresErrorCodes.UniqueViolation;
}
