package challenge.app;

import java.nio.charset.StandardCharsets;

import challenge.JsonWriter;
import challenge.pg.Query;

/**
 * JSON views written straight from Postgres DataRows into the response buffer.
 */
public final class Views {
    private Views() {}

    public static void raw(JsonWriter out, String s) {
        out.raw(s);
    }

    public static void string(JsonWriter out, String s) {
        byte[] b = s.getBytes(StandardCharsets.UTF_8);
        out.string(b, 0, b.length);
    }

    public static void column(JsonWriter out, Query q, int row,
            int col) {
        if (q.isNull(row, col)) {
            raw(out, "null");
        } else {
            out.string(q.bytes(), q.offset(row, col), q.length(row, col));
        }
    }

    /** {@code {"errors":{"body":[message]}}}. */
    public static void errors(JsonWriter out, String message) {
        raw(out, "{\"errors\":{\"body\":[");
        string(out, message);
        raw(out, "]}}");
    }

    public static void tags(JsonWriter out, Query q) {
        raw(out, "{\"tags\":[");
        for (int i = 0; i < q.rowCount(); i++) {
            if (i != 0) {
                out.put(',');
            }
            column(out, q, i, 0);
        }
        raw(out, "]}");
    }

    /** Article list; rows with a null id are the count-only row of an empty page. */
    public static void articles(JsonWriter out, Query q) {
        raw(out, "{\"articles\":[");
        for (int i = 0; i < q.rowCount(); i++) {
            if (q.isNull(i, 0)) {
                continue;
            }
            if (i > 0) {
                out.put(',');
            }
            article(out, q, i, false);
        }
        raw(out, "],\"articlesCount\":");
        out.number(q.int8At(0, 13));
        out.put('}');
    }

    public static void comments(JsonWriter out, Query q) {
        raw(out, "{\"comments\":[");
        for (int i = 0; i < q.rowCount(); i++) {
            if (q.isNull(i, 0)) {
                continue;
            }
            if (i > 0) {
                out.put(',');
            }
            comment(out, q, i, q.boolAt(i, 7));
        }
        raw(out, "]}");
    }

    public static void user(JsonWriter out, Query q, int row,
                            byte[] token, int offset, int length) {
        raw(out, "{\"email\":");
        column(out, q, row, 2);
        raw(out, ",\"token\":");
        out.string(token, offset, length);
        raw(out, ",\"username\":");
        column(out, q, row, 1);
        raw(out, ",\"bio\":");
        column(out, q, row, 3);
        raw(out, ",\"image\":");
        column(out, q, row, 4);
        out.put('}');
    }

    public static void profile(JsonWriter out, Query q, int row,
            int base, boolean following) {
        raw(out, "{\"username\":");
        column(out, q, row, base);
        raw(out, ",\"bio\":");
        column(out, q, row, base + 1);
        raw(out, ",\"image\":");
        column(out, q, row, base + 2);
        raw(out, ",\"following\":");
        raw(out, following ? "true" : "false");
        out.put('}');
    }

    public static void article(JsonWriter out, Query q, int row,
            boolean body) {
        int shift = body ? 1 : 0;
        raw(out, "{\"slug\":");
        column(out, q, row, 1);
        raw(out, ",\"title\":");
        column(out, q, row, 2);
        raw(out, ",\"description\":");
        column(out, q, row, 3);
        if (body) {
            raw(out, ",\"body\":");
            column(out, q, row, 4);
        }
        raw(out, ",\"createdAt\":");
        Formats.timestamp(out, q.int8At(row, 4 + shift));
        raw(out, ",\"updatedAt\":");
        Formats.timestamp(out, q.int8At(row, 5 + shift));
        raw(out, ",\"tagList\":[");
        int col = 6 + shift;
        for (int i = 0; i < q.arrayCount(row, col); i++) {
            if (i > 0) {
                out.put(',');
            }
            int p = q.arrayElementOffset(row, col, i);
            if (p < 0) {
                raw(out, "null");
            } else {
                out.string(q.bytes(), p, q.arrayElementLength(p));
            }
        }
        raw(out, "],\"favoritesCount\":");
        out.number(q.int8At(row, 7 + shift));
        raw(out, ",\"favorited\":");
        raw(out, q.boolAt(row, 8 + shift) ? "true" : "false");
        raw(out, ",\"author\":");
        profile(out, q, row, 9 + shift,
                q.boolAt(row, 12 + shift));
        out.put('}');
    }

    public static void comment(JsonWriter out, Query q, int row,
            boolean following) {
        raw(out, "{\"id\":");
        out.number(q.int8At(row, 0));
        raw(out, ",\"body\":");
        column(out, q, row, 1);
        raw(out, ",\"createdAt\":");
        Formats.timestamp(out, q.int8At(row, 2));
        raw(out, ",\"updatedAt\":");
        Formats.timestamp(out, q.int8At(row, 3));
        raw(out, ",\"author\":");
        profile(out, q, row, 4, following);
        out.put('}');
    }
}
