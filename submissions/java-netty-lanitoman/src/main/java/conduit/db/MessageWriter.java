package conduit.db;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufUtil;
import java.nio.charset.StandardCharsets;

/**
 * Writes frontend messages of the Postgres protocol (version 3.0) into a buffer. A query is
 * {@code bind(statement)}, its parameters, {@code execute()}, repeated for every statement of the query, then one
 * {@code sync()}. All parameters and results use the binary format.
 *
 * <p>Every message is a type byte and an Int32 length (counting itself, not the type byte), then the body.
 */
public final class MessageWriter {
    private final ByteBuf out;
    private int bindStart;
    private int arrayStart;
    private int arraySizePosition;
    private int arrayCount;

    public MessageWriter(ByteBuf out) {
        this.out = out;
    }

    // ---------- the extended query protocol ----------

    /** Bind: the unnamed portal to a prepared statement, parameters in binary. Parameters follow, then execute(). */
    public MessageWriter bind(Statement statement) {
        bindStart = out.writerIndex();
        out.writeByte('B');
        out.writeInt(0);                        // length, patched in execute()
        out.writeByte(0);                       // portal name "" (unnamed)
        out.writeBytes(statement.name).writeByte(0);
        out.writeShort(1).writeShort(1);        // one format code for all parameters: binary
        out.writeShort(statement.parameterTypes.length);
        return this;
    }

    /** Ends the Bind message (results in binary) and adds Execute: run the portal, return all rows. */
    public MessageWriter execute() {
        out.writeShort(1).writeShort(1);        // one format code for all result columns: binary
        out.setInt(bindStart + 1, out.writerIndex() - bindStart - 1);
        out.writeByte('E').writeInt(9).writeByte(0).writeInt(0);
        return this;
    }

    /** Sync: ends the query. Postgres commits (or rolls back after an error) and answers ReadyForQuery. */
    public void sync() {
        out.writeByte('S').writeInt(4);
    }

    // ---------- parameters ----------

    public MessageWriter nullValue() {
        out.writeInt(-1);
        return this;
    }

    public MessageWriter int8(long value) {
        out.writeInt(8).writeLong(value);
        return this;
    }

    public MessageWriter int4(int value) {
        out.writeInt(4).writeInt(value);
        return this;
    }

    /** A text parameter, UTF-8 encoded; null becomes SQL NULL. */
    public MessageWriter text(String value) {
        if (value == null) return nullValue();
        int lengthPosition = out.writerIndex();
        out.writeInt(0);
        int written = ByteBufUtil.writeUtf8(out, value);
        out.setInt(lengthPosition, written);
        return this;
    }

    /** A text[] parameter (one dimension, no NULL elements). */
    public MessageWriter textArray(Iterable<String> values) {
        beginArray(Statement.TEXT);
        for (String value : values) arrayText(value);
        return endArray();
    }

    /**
     * Starts a one-dimensional array parameter. Binary layout: Int32 dimensions (1), Int32 has-nulls flag, Int32
     * element type, Int32 size, Int32 lower bound (1), then each element as Int32 length and bytes.
     */
    public MessageWriter beginArray(int elementType) {
        arrayStart = out.writerIndex();
        out.writeInt(0);                        // parameter length, patched in endArray()
        out.writeInt(1);                        // dimensions
        out.writeInt(1);                        // may contain NULLs (Postgres accepts 1 even when none are)
        out.writeInt(elementType);
        arraySizePosition = out.writerIndex();
        out.writeInt(0);                        // size, patched in endArray()
        out.writeInt(1);                        // lower bound
        arrayCount = 0;
        return this;
    }

    public MessageWriter arrayInt4(int value) {
        arrayCount++;
        return int4(value);
    }

    public MessageWriter arrayInt8(long value) {
        arrayCount++;
        return int8(value);
    }

    /** A text element; null becomes a NULL element. */
    public MessageWriter arrayText(String value) {
        arrayCount++;
        return text(value);
    }

    public MessageWriter endArray() {
        out.setInt(arraySizePosition, arrayCount);
        out.setInt(arrayStart, out.writerIndex() - arrayStart - 4);
        return this;
    }

    // ---------- connection startup ----------

    /** StartupMessage: no type byte; Int32 length, Int32 protocol version 3.0, then name/value pairs, then a NUL. */
    void startup(String user, String database, String options) {
        int start = out.writerIndex();
        out.writeInt(0);
        out.writeInt(196608);
        cString("user").cString(user);
        cString("database").cString(database);
        cString("client_encoding").cString("UTF8");
        cString("application_name").cString("conduit");
        if (options != null && !options.isEmpty()) cString("options").cString(options);
        out.writeByte(0);
        out.setInt(start, out.writerIndex() - start);
    }

    /** PasswordMessage / SASLInitialResponse / SASLResponse: all are 'p' messages with an opaque body. */
    void password(byte[] body) {
        out.writeByte('p').writeInt(4 + body.length).writeBytes(body);
    }

    /** Parse: prepares a named statement with declared parameter types. */
    void parse(Statement statement) {
        int start = out.writerIndex();
        out.writeByte('P');
        out.writeInt(0);
        out.writeBytes(statement.name).writeByte(0);
        cString(statement.sql);
        out.writeShort(statement.parameterTypes.length);
        for (int type : statement.parameterTypes) out.writeInt(type);
        out.setInt(start + 1, out.writerIndex() - start - 1);
    }

    private MessageWriter cString(String value) {
        out.writeBytes(value.getBytes(StandardCharsets.UTF_8)).writeByte(0);
        return this;
    }
}
