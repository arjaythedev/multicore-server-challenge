package conduit.db;

/** An ErrorResponse from Postgres (or a lost connection), reduced to what the handlers look at. */
public final class PgError {
    public static final String UNIQUE_VIOLATION = "23505";
    public static final String FOREIGN_KEY_VIOLATION = "23503";
    public static final String CONNECTION_FAILURE = "08006";

    public final String sqlState;
    public final String message;

    public PgError(String sqlState, String message) {
        this.sqlState = sqlState;
        this.message = message;
    }

    public static PgError connectionLost() {
        return new PgError(CONNECTION_FAILURE, "connection to Postgres lost");
    }

    public boolean isUniqueViolation() {
        return UNIQUE_VIOLATION.equals(sqlState);
    }

    @Override
    public String toString() {
        return sqlState + ": " + message;
    }
}
