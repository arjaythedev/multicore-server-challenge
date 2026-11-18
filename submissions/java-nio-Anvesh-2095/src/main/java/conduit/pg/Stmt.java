package conduit.pg;

import java.util.ArrayList;
import java.util.List;

/**
 * A SQL statement that every connection prepares once (as a named statement) when it opens. Parameters are sent
 * in binary with these type OIDs, so the Java value for each must match: Long for INT8, String for TEXT, String[]
 * for TEXT_ARRAY, null for SQL NULL.
 */
public final class Stmt {
    public static final int INT8 = 20, TEXT = 25, TEXT_ARRAY = 1009;

    static final List<Stmt> ALL = new ArrayList<>();

    public final String sql;
    final int[] types;
    final byte[] name;

    private Stmt(String sql, int[] types, int index) {
        this.sql = sql;
        this.types = types;
        this.name = ("s" + index).getBytes();
    }

    /** Declares a statement. Call only during startup, before any connection opens. */
    public static synchronized Stmt of(String sql, int... types) {
        Stmt s = new Stmt(sql, types, ALL.size());
        ALL.add(s);
        return s;
    }
}
