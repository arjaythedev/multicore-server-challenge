package conduit.app

/**
 * SPEC's SLUGIFY computed in the app (regexp_replace costs Postgres CPU, the scarce resource):
 * `trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g')))`. ASCII letters are lowercased, digits
 * kept, every run of anything else (any other character, including non-ASCII and '-') becomes one '-', and leading
 * and trailing '-' are dropped. The article id is appended as "-<id>" in SQL.
 */
internal fun slugify(title: String): String {
    val sb = StringBuilder(title.length)
    var dash = false
    for (ch in title) {
        val c = if (ch in 'A'..'Z') ch + 32 else ch
        if (c in 'a'..'z' || c in '0'..'9') {
            if (dash && sb.isNotEmpty()) sb.append('-')
            dash = false
            sb.append(c)
        } else {
            dash = true
        }
    }
    return sb.toString()
}
