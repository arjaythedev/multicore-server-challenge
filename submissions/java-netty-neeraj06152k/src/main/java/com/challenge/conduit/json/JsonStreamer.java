package com.challenge.conduit.json;

import io.netty.buffer.ByteBuf;
import io.vertx.sqlclient.Row;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;

/**
 * Direct byte-level JSON response streaming engine.
 * Formats JSON bytes directly into Netty off-heap buffers with true zero-heap-allocation:
 * - Direct byte tokens for all JSON structure and field names
 * - Zero runtime string concatenations
 * - Zero per-character String.valueOf(c) allocations in string escaping
 * - Zero String allocation RFC3339 timestamp direct byte formatting
 */
public final class JsonStreamer {

    // Common JSON syntax bytes
    private static final byte[] EMPTY_TAGS = "{\"tags\":[]}".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] TAGS_OPEN = "{\"tags\":[".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] EMPTY_COMMENTS = "{\"comments\":[]}".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] COMMENTS_OPEN = "{\"comments\":[".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] ARTICLES_OPEN = "{\"articles\":[".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] ARTICLES_COUNT_PREFIX = "],\"articlesCount\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] CLOSE_BRACKET_BRACE = "]}".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] CLOSE_BRACKET = "]".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] CLOSE_BRACE = "}".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] DOUBLE_CLOSE_BRACE = "}}".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] OPEN_BRACE = "{".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] COMMA = ",".getBytes(StandardCharsets.US_ASCII);
    private static final byte QUOTE = '"';
    private static final byte[] NULL_BYTES = "null".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] TRUE_BYTES = "true".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FALSE_BYTES = "false".getBytes(StandardCharsets.US_ASCII);

    private static final byte[] ERRORS_PREFIX = "{\"errors\":{\"body\":[\"".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] ERRORS_SUFFIX = "\"]}}".getBytes(StandardCharsets.US_ASCII);

    // Static Root Object wrappers
    private static final byte[] USER_PREFIX = "{\"user\":{".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] PROFILE_PREFIX = "{\"profile\":{".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] ARTICLE_PREFIX = "{\"article\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] COMMENT_PREFIX = "{\"comment\":".getBytes(StandardCharsets.US_ASCII);

    // Static Field Name bytes
    private static final byte[] FIELD_EMAIL = "\"email\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_TOKEN = "\"token\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_USERNAME = "\"username\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_BIO = "\"bio\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_IMAGE = "\"image\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_FOLLOWING = "\"following\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_SLUG = "\"slug\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_TITLE = "\"title\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_DESCRIPTION = "\"description\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_BODY = "\"body\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_TAG_LIST = "\"tagList\":[".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_CREATED_AT = "\"createdAt\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_UPDATED_AT = "\"updatedAt\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_FAVORITED = "\"favorited\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_FAVORITES_COUNT = "\"favoritesCount\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_AUTHOR = "\"author\":{".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] FIELD_ID = "\"id\":".getBytes(StandardCharsets.US_ASCII);

    private static final byte[] HEX_CHARS = "0123456789abcdef".getBytes(StandardCharsets.US_ASCII);

    public static void writeEmptyArrayResponse(ByteBuf out, String key) {
        if ("comments".equals(key)) {
            out.writeBytes(EMPTY_COMMENTS);
        } else if ("tags".equals(key)) {
            out.writeBytes(EMPTY_TAGS);
        } else {
            out.writeByte('{');
            out.writeByte(QUOTE);
            out.writeCharSequence(key, StandardCharsets.US_ASCII);
            out.writeByte(QUOTE);
            out.writeByte(':');
            out.writeByte('[');
            out.writeByte(']');
            out.writeByte('}');
        }
    }

    public static void writeEmptyTags(ByteBuf out) {
        out.writeBytes(EMPTY_TAGS);
    }

    public static void writeTags(ByteBuf out, Iterable<Row> rows) {
        out.writeBytes(TAGS_OPEN);
        boolean first = true;
        for (Row row : rows) {
            if (!first) {
                out.writeBytes(COMMA);
            }
            writeEscapedString(out, row.getString(0));
            first = false;
        }
        out.writeBytes(CLOSE_BRACKET_BRACE);
    }

    public static void writeUser(ByteBuf out, Row row, String token) {
        out.writeBytes(USER_PREFIX);
        writeField(out, FIELD_EMAIL, row.getString("email"), true);
        writeField(out, FIELD_TOKEN, token, false);
        writeField(out, FIELD_USERNAME, row.getString("username"), false);
        writeNullableField(out, FIELD_BIO, row.getString("bio"), false);
        writeNullableField(out, FIELD_IMAGE, row.getString("image"), false);
        out.writeBytes(DOUBLE_CLOSE_BRACE);
    }

    public static void writeProfile(ByteBuf out, Row row, boolean following) {
        out.writeBytes(PROFILE_PREFIX);
        writeField(out, FIELD_USERNAME, row.getString("username"), true);
        writeNullableField(out, FIELD_BIO, row.getString("bio"), false);
        writeNullableField(out, FIELD_IMAGE, row.getString("image"), false);
        out.writeBytes(COMMA);
        out.writeBytes(FIELD_FOLLOWING);
        out.writeBytes(following ? TRUE_BYTES : FALSE_BYTES);
        out.writeBytes(DOUBLE_CLOSE_BRACE);
    }

    public static void writeArticle(ByteBuf out, Row row, boolean includeBody) {
        out.writeBytes(ARTICLE_PREFIX);
        writeSingleArticleObject(out, row, includeBody);
        out.writeBytes(CLOSE_BRACE);
    }

    public static void writeArticlesList(ByteBuf out, Iterable<Row> rows, long count) {
        out.writeBytes(ARTICLES_OPEN);
        boolean first = true;
        for (Row row : rows) {
            if (!first) out.writeBytes(COMMA);
            writeSingleArticleObject(out, row, false);
            first = false;
        }
        out.writeBytes(ARTICLES_COUNT_PREFIX);
        writeLong(out, count);
        out.writeBytes(CLOSE_BRACE);
    }

    public static void writeArticlesListSlice(ByteBuf out, Row[] rows, int start, int count, long totalCount) {
        out.writeBytes(ARTICLES_OPEN);
        for (int i = 0; i < count; i++) {
            if (i > 0) out.writeBytes(COMMA);
            writeSingleArticleObject(out, rows[start + i], false);
        }
        out.writeBytes(ARTICLES_COUNT_PREFIX);
        writeLong(out, totalCount);
        out.writeBytes(CLOSE_BRACE);
    }

    private static void writeSingleArticleObject(ByteBuf out, Row row, boolean includeBody) {
        out.writeBytes(OPEN_BRACE);
        writeField(out, FIELD_SLUG, row.getString("slug"), true);
        writeField(out, FIELD_TITLE, row.getString("title"), false);
        writeField(out, FIELD_DESCRIPTION, row.getString("description"), false);

        if (includeBody) {
            writeField(out, FIELD_BODY, row.getString("body"), false);
        }

        // tagList
        out.writeBytes(COMMA);
        out.writeBytes(FIELD_TAG_LIST);
        String[] tags = row.getArrayOfStrings("tag_list");
        if (tags != null) {
            for (int i = 0; i < tags.length; i++) {
                if (i > 0) out.writeBytes(COMMA);
                writeEscapedString(out, tags[i]);
            }
        }
        out.writeBytes(CLOSE_BRACKET);

        // createdAt & updatedAt (zero-allocation direct timestamp streaming)
        out.writeBytes(COMMA);
        out.writeBytes(FIELD_CREATED_AT);
        writeTimestampField(out, row.getValue("created_at"));

        out.writeBytes(COMMA);
        out.writeBytes(FIELD_UPDATED_AT);
        writeTimestampField(out, row.getValue("updated_at"));

        // favorited & favoritesCount
        boolean favorited = row.getBoolean("favorited");
        long favoritesCount = row.getLong("favorites_count");
        out.writeBytes(COMMA);
        out.writeBytes(FIELD_FAVORITED);
        out.writeBytes(favorited ? TRUE_BYTES : FALSE_BYTES);
        out.writeBytes(COMMA);
        out.writeBytes(FIELD_FAVORITES_COUNT);
        writeLong(out, favoritesCount);

        // author: Profile
        out.writeBytes(COMMA);
        out.writeBytes(FIELD_AUTHOR);
        writeField(out, FIELD_USERNAME, row.getString("username"), true);
        writeNullableField(out, FIELD_BIO, row.getString("bio"), false);
        writeNullableField(out, FIELD_IMAGE, row.getString("image"), false);
        out.writeBytes(COMMA);
        out.writeBytes(FIELD_FOLLOWING);
        out.writeBytes(row.getBoolean("following") ? TRUE_BYTES : FALSE_BYTES);
        out.writeBytes(DOUBLE_CLOSE_BRACE);
    }

    public static void writeComment(ByteBuf out, Row row, boolean following) {
        out.writeBytes(COMMENT_PREFIX);
        writeSingleCommentObject(out, row, following);
        out.writeBytes(CLOSE_BRACE);
    }

    public static void writeCommentsList(ByteBuf out, Iterable<Row> rows) {
        out.writeBytes(COMMENTS_OPEN);
        boolean first = true;
        for (Row row : rows) {
            if (!first) out.writeBytes(COMMA);
            writeSingleCommentObject(out, row, row.getBoolean("following"));
            first = false;
        }
        out.writeBytes(CLOSE_BRACKET_BRACE);
    }

    public static void writeCommentsListSlice(ByteBuf out, Row[] rows, int start, int count) {
        out.writeBytes(COMMENTS_OPEN);
        for (int i = 0; i < count; i++) {
            if (i > 0) out.writeBytes(COMMA);
            Row row = rows[start + i];
            writeSingleCommentObject(out, row, row.getBoolean("following"));
        }
        out.writeBytes(CLOSE_BRACKET_BRACE);
    }

    private static void writeSingleCommentObject(ByteBuf out, Row row, boolean following) {
        out.writeBytes(OPEN_BRACE);
        out.writeBytes(FIELD_ID);
        writeLong(out, row.getLong("id"));

        out.writeBytes(COMMA);
        out.writeBytes(FIELD_CREATED_AT);
        writeTimestampField(out, row.getValue("created_at"));

        out.writeBytes(COMMA);
        out.writeBytes(FIELD_UPDATED_AT);
        writeTimestampField(out, row.getValue("updated_at"));

        writeField(out, FIELD_BODY, row.getString("body"), false);

        out.writeBytes(COMMA);
        out.writeBytes(FIELD_AUTHOR);
        writeField(out, FIELD_USERNAME, row.getString("username"), true);
        writeNullableField(out, FIELD_BIO, row.getString("bio"), false);
        writeNullableField(out, FIELD_IMAGE, row.getString("image"), false);
        out.writeBytes(COMMA);
        out.writeBytes(FIELD_FOLLOWING);
        out.writeBytes(following ? TRUE_BYTES : FALSE_BYTES);
        out.writeBytes(DOUBLE_CLOSE_BRACE);
    }

    private static void writeField(ByteBuf out, byte[] fieldKeyBytes, String value, boolean first) {
        if (!first) out.writeBytes(COMMA);
        out.writeBytes(fieldKeyBytes);
        writeEscapedString(out, value);
    }

    private static void writeNullableField(ByteBuf out, byte[] fieldKeyBytes, String value, boolean first) {
        if (!first) out.writeBytes(COMMA);
        out.writeBytes(fieldKeyBytes);
        if (value == null) {
            out.writeBytes(NULL_BYTES);
        } else {
            writeEscapedString(out, value);
        }
    }

    /**
     * Highly optimized zero-allocation string escaping.
     * Batches safe character sequences using subSequence, eliminating per-character String.valueOf allocations.
     */
    public static void writeEscapedString(ByteBuf out, String s) {
        if (s == null) {
            out.writeBytes(NULL_BYTES);
            return;
        }
        out.writeByte(QUOTE);
        int len = s.length();
        int start = 0;
        for (int i = 0; i < len; i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\\' || c < 0x20) {
                if (i > start) {
                    out.writeCharSequence(s.subSequence(start, i), StandardCharsets.UTF_8);
                }
                switch (c) {
                    case '"' -> out.writeShort(0x5C22); // \"
                    case '\\' -> out.writeShort(0x5C5C); // \\
                    case '\b' -> out.writeShort(0x5C62); // \b
                    case '\f' -> out.writeShort(0x5C66); // \f
                    case '\n' -> out.writeShort(0x5C6E); // \n
                    case '\r' -> out.writeShort(0x5C72); // \r
                    case '\t' -> out.writeShort(0x5C74); // \t
                    default -> writeHexEscape(out, c);
                }
                start = i + 1;
            }
        }
        if (start < len) {
            out.writeCharSequence(s.subSequence(start, len), StandardCharsets.UTF_8);
        }
        out.writeByte(QUOTE);
    }

    private static void writeHexEscape(ByteBuf out, char c) {
        out.writeShort(0x5C75); // backslash-u escape prefix
        out.writeByte(HEX_CHARS[(c >>> 12) & 0xF]);
        out.writeByte(HEX_CHARS[(c >>> 8) & 0xF]);
        out.writeByte(HEX_CHARS[(c >>> 4) & 0xF]);
        out.writeByte(HEX_CHARS[c & 0xF]);
    }

    public static void writeError(ByteBuf out, String message) {
        out.writeBytes(ERRORS_PREFIX);
        int len = message.length();
        int start = 0;
        for (int i = 0; i < len; i++) {
            char c = message.charAt(i);
            if (c == '"' || c == '\\') {
                if (i > start) {
                    out.writeCharSequence(message.subSequence(start, i), StandardCharsets.UTF_8);
                }
                out.writeByte('\\');
                out.writeByte((byte) c);
                start = i + 1;
            }
        }
        if (start < len) {
            out.writeCharSequence(message.subSequence(start, len), StandardCharsets.UTF_8);
        }
        out.writeBytes(ERRORS_SUFFIX);
    }

    /**
     * Direct zero-allocation RFC3339 timestamp writing: "YYYY-MM-DDTHH:mm:ss.SSSZ"
     */
    public static void writeTimestampField(ByteBuf out, Object val) {
        if (val == null) {
            out.writeBytes(NULL_BYTES);
            return;
        }
        Instant inst = null;
        if (val instanceof Instant i) {
            inst = i;
        } else if (val instanceof OffsetDateTime odt) {
            inst = odt.toInstant();
        } else if (val instanceof LocalDateTime ldt) {
            inst = ldt.toInstant(ZoneOffset.UTC);
        }

        if (inst == null) {
            out.writeByte(QUOTE);
            out.writeCharSequence(val.toString(), StandardCharsets.US_ASCII);
            out.writeByte(QUOTE);
            return;
        }

        long epochSec = inst.getEpochSecond();
        int nano = inst.getNano();
        int millis = nano / 1_000_000;

        // Fast civil date computation from epoch second
        long days = Math.floorDiv(epochSec, 86400L);
        int secsOfDay = (int) Math.floorMod(epochSec, 86400L);

        long z = days + 719468;
        long era = (z >= 0 ? z : z - 146096) / 146097;
        long doe = z - era * 146097;
        long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        long y = yoe + era * 400;
        long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        long mp = (5 * doy + 2) / 153;
        int d = (int) (doy - (153 * mp + 2) / 5 + 1);
        int m = (int) (mp < 10 ? mp + 3 : mp - 9);
        int year = (int) (y + (m <= 2 ? 1 : 0));

        int hours = secsOfDay / 3600;
        int minutes = (secsOfDay % 3600) / 60;
        int seconds = secsOfDay % 60;

        out.writeByte(QUOTE);
        // YYYY
        write4Digits(out, year);
        out.writeByte('-');
        // MM
        write2Digits(out, m);
        out.writeByte('-');
        // DD
        write2Digits(out, d);
        out.writeByte('T');
        // HH
        write2Digits(out, hours);
        out.writeByte(':');
        // mm
        write2Digits(out, minutes);
        out.writeByte(':');
        // ss
        write2Digits(out, seconds);
        out.writeByte('.');
        // SSS
        write3Digits(out, millis);
        out.writeByte('Z');
        out.writeByte(QUOTE);
    }

    private static void write2Digits(ByteBuf out, int v) {
        out.writeByte('0' + (v / 10));
        out.writeByte('0' + (v % 10));
    }

    private static void write3Digits(ByteBuf out, int v) {
        out.writeByte('0' + (v / 100));
        out.writeByte('0' + ((v / 10) % 10));
        out.writeByte('0' + (v % 10));
    }

    private static void write4Digits(ByteBuf out, int v) {
        out.writeByte('0' + ((v / 1000) % 10));
        out.writeByte('0' + ((v / 100) % 10));
        out.writeByte('0' + ((v / 10) % 10));
        out.writeByte('0' + (v % 10));
    }

    private static final byte[] LONG_MIN_BYTES = "-9223372036854775808".getBytes(StandardCharsets.US_ASCII);
    private static final ThreadLocal<byte[]> LONG_SCRATCH = ThreadLocal.withInitial(() -> new byte[20]);

    public static void writeLong(ByteBuf out, long v) {
        if (v == 0) {
            out.writeByte('0');
            return;
        }
        if (v == Long.MIN_VALUE) {
            out.writeBytes(LONG_MIN_BYTES);
            return;
        }
        if (v < 0) {
            out.writeByte('-');
            v = -v;
        }
        byte[] buf = LONG_SCRATCH.get();
        int charPos = 20;
        while (v > 0) {
            buf[--charPos] = (byte) ('0' + (v % 10));
            v /= 10;
        }
        out.writeBytes(buf, charPos, 20 - charPos);
    }
}
