package conduit

import java.io.{PrintWriter, StringWriter}
import java.time.Instant

/** The server's log: one JSON object per line on stderr, which a log collector reads without patterns. Each line has
  * `time` (UTC), `level`, `msg` (what happened, in fixed words) and the event's own fields:
  *
  * {{{
  * {"time":"2026-10-18T09:12:03.512Z","level":"error","msg":"group commit failed","requests":12,"error":"…","stack":"…"}
  * }}}
  *
  * The server logs at startup and when something goes wrong, never for a request that succeeds, so none of this is on
  * the hot path.
  */
object Log:
  def info(msg: String, fields: (String, Any)*): Unit = write("info", msg, fields)

  def warn(msg: String, fields: (String, Any)*): Unit = write("warn", msg, fields)

  /** Adds the exception (`error`) and its stack trace (`stack`) to the fields. */
  def error(msg: String, e: Throwable, fields: (String, Any)*): Unit =
    val stack = StringWriter()
    e.printStackTrace(PrintWriter(stack))
    write("error", msg, fields :+ ("error" -> e.toString) :+ ("stack" -> stack.toString))

  private def write(level: String, msg: String, fields: Seq[(String, Any)]): Unit =
    System.err.println(line(level, msg, fields))

  /** The event as one line of JSON. */
  private[conduit] def line(level: String, msg: String, fields: Seq[(String, Any)]): String =
    val line = java.lang.StringBuilder(160)
    line.append("{\"time\":\"").append(Instant.now()).append("\",\"level\":\"").append(level).append("\",\"msg\":")
    string(line, msg)
    for (key, value) <- fields do
      line.append(',')
      string(line, key)
      line.append(':')
      value match
        case n: Int => line.append(n)
        case n: Long => line.append(n)
        case b: Boolean => line.append(b)
        case d: Double if java.lang.Double.isFinite(d) => line.append(d)
        case other => string(line, String.valueOf(other))
    line.append('}').toString

  private val Hex = "0123456789abcdef"

  /** `s` as a JSON string. */
  private def string(line: java.lang.StringBuilder, s: String): Unit =
    line.append('"')
    var i = 0
    while i < s.length do
      s.charAt(i) match
        case '"' => line.append("\\\"")
        case '\\' => line.append("\\\\")
        case '\n' => line.append("\\n")
        case '\r' => line.append("\\r")
        case '\t' => line.append("\\t")
        case c if c < ' ' => line.append("\\u00").append(Hex.charAt(c >> 4)).append(Hex.charAt(c & 0xf))
        case c => line.append(c)
      i += 1
    line.append('"')
