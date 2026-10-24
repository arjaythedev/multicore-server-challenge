package conduit.json

import kotlin.jvm.JvmField
import conduit.pg.Row
import conduit.util.ByteBuf

/** A pre-encoded object key: the bytes of `"name":`. Create once (top-level vals), reuse forever. */
class JsonName(name: String) {
    @JvmField val bytes: ByteArray = "\"$name\":".encodeToByteArray()
}

/**
 * Streaming JSON writer straight into a [ByteBuf] (no intermediate objects, no Strings on hot paths). Handles commas
 * itself: call [name] then exactly one value inside objects; values in arrays are separated automatically.
 * String escaping: `"` `\` and control characters < 0x20 (\n \r \t as short escapes, others \u00XX); all other bytes,
 * including non-ASCII UTF-8, are copied unchanged.
 */
class JsonWriter(@JvmField val out: ByteBuf) {
    /** Clears the nesting state (call when [out] is reset). */
    fun reset(): Unit = TODO("json: reset")

    fun beginObject(): Unit = TODO("json: beginObject")
    fun endObject(): Unit = TODO("json: endObject")
    fun beginArray(): Unit = TODO("json: beginArray")
    fun endArray(): Unit = TODO("json: endArray")

    /** Writes the key (with a leading comma when needed). */
    fun name(n: JsonName): Unit = TODO("json: name")

    /** A JSON string from a Kotlin string; null writes `null`. */
    fun string(s: String?): Unit = TODO("json: string(String)")

    /** A JSON string from UTF-8 bytes (escaped as needed). */
    fun string(b: ByteArray, off: Int, len: Int): Unit = TODO("json: string(bytes)")

    /** A text column as a JSON string, or `null` when the column is NULL. */
    fun text(row: Row, col: Int): Unit = TODO("json: text(row)")

    fun number(v: Long): Unit = TODO("json: number")
    fun bool(v: Boolean): Unit = TODO("json: bool")
    fun nul(): Unit = TODO("json: nul")

    /**
     * A timestamptz as "YYYY-MM-DDTHH:MM:SS.mmmZ" (UTC, exactly 3 fractional digits, truncated not rounded).
     * [micros] is Postgres's binary value: microseconds since 2000-01-01T00:00:00Z (may be negative).
     */
    fun timestamp(micros: Long): Unit = TODO("json: timestamp")

    /** A binary text[] column as a JSON array of strings, in array order (NULL column or empty array -> `[]`). */
    fun textArray(row: Row, col: Int): Unit = TODO("json: textArray")
}

/** Parsed request-body JSON (request bodies only: writes are ~5% of traffic, allocation is fine there). */
sealed class JsonValue {
    object Null : JsonValue()
    class Bool(val value: Boolean) : JsonValue()
    /** The number's source text (validated JSON number syntax). */
    class Num(val text: String) : JsonValue()
    class Str(val value: String) : JsonValue()
    class Arr(val items: List<JsonValue>) : JsonValue()
    /** Members in source order; on duplicate keys the last one wins. */
    class Obj(val members: Map<String, JsonValue>) : JsonValue() {
        operator fun get(key: String): JsonValue? = members[key]
    }
}

object JsonReader {
    /**
     * Parses exactly one JSON value spanning b[off, off+len) (surrounding whitespace allowed; trailing garbage,
     * invalid UTF-8, bad escapes, unpaired surrogates, nesting deeper than 64 -> null). Never throws.
     */
    fun parse(b: ByteArray, off: Int = 0, len: Int = b.size): JsonValue? = TODO("json: JsonReader.parse")
}
