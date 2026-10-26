package conduit.db;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * A SQL statement that is prepared once on every connection at startup (as "s0", "s1", ...). Queries then only send
 * Bind/Execute messages that name it, so Postgres never parses or plans the SQL again.
 */
public final class Statement {
    /** Parameter and column type OIDs used by this server (pg_type.oid). */
    public static final int BOOL = 16, INT8 = 20, INT4 = 23, TEXT = 25;
    public static final int INT4_ARRAY = 1007, TEXT_ARRAY = 1009, INT8_ARRAY = 1016;

    private static final List<Statement> ALL = new ArrayList<>();

    public final String sql;
    final byte[] name;
    final int[] parameterTypes;

    private Statement(int index, String sql, int[] parameterTypes) {
        this.sql = sql;
        this.name = ("s" + index).getBytes(StandardCharsets.US_ASCII);
        this.parameterTypes = parameterTypes;
    }

    /** Defines a statement. Call before the connections are opened: they prepare every statement defined so far. */
    public static synchronized Statement define(String sql, int... parameterTypes) {
        Statement statement = new Statement(ALL.size(), sql, parameterTypes);
        ALL.add(statement);
        return statement;
    }

    static synchronized List<Statement> all() {
        return Collections.unmodifiableList(new ArrayList<>(ALL));
    }

    /** Every statement as "name<TAB>sql", for reviewing the SQL (java -jar conduit.jar --print-sql). */
    public static synchronized List<String> describeAll() {
        List<String> lines = new ArrayList<>();
        for (Statement statement : ALL) {
            lines.add(new String(statement.name, StandardCharsets.US_ASCII) + "\t" + statement.sql.replaceAll("\\s+", " "));
        }
        return lines;
    }
}
