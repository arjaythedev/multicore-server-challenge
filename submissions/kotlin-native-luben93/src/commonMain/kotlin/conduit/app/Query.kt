package conduit.app

import kotlin.jvm.JvmField

/** The list filter in effect: only one applies, precedence tag > author > favorited. */
internal object Filter {
    const val NONE = 0
    const val TAG = 1
    const val AUTHOR = 2
    const val FAVORITED = 3
}

/** Parsed `?limit=&offset=&tag=&author=&favorited=`. [key] is the filter value ("" for [Filter.NONE]). */
internal class ListQuery(
    @JvmField val limit: Int,
    @JvmField val offset: Long,
    @JvmField val filter: Int,
    @JvmField val key: String,
) {
    companion object {
        /** Offsets are clamped here so the feed's `r.l + r.o` can't overflow int8 (any such page is empty anyway). */
        const val MAX_OFFSET = Long.MAX_VALUE / 2
        private val DEFAULT = ListQuery(20, 0, Filter.NONE, "")

        /**
         * Parses a raw query string like Go's url.ParseQuery + the reference handlers: '&'-separated pairs, a pair
         * with ';' or a malformed escape is skipped, a key without '=' has an empty value, `+` and `%XX` are decoded,
         * the first occurrence of a key wins. `limit` (1..100, default 20) and `offset` (>= 0, default 0) must be
         * ASCII digits fitting in int64 when present, even empty; else null (422). Empty filter values count as
         * absent. A filter value that decodes to bytes Postgres text can't hold (NUL, invalid UTF-8) is [Url.INVALID]:
         * it still takes precedence, and matches nothing (the handler answers the empty list without SQL).
         * [filters] = false (the feed) ignores tag/author/favorited.
         */
        fun parse(q: String?, filters: Boolean): ListQuery? {
            if (q.isNullOrEmpty()) return DEFAULT
            var limit: String? = null
            var offset: String? = null
            var tag: String? = null
            var author: String? = null
            var favorited: String? = null
            var p = 0
            val n = q.length
            while (p <= n) {
                var e = q.indexOf('&', p)
                if (e < 0) e = n
                if (e > p && !has(q, p, e, ';')) {
                    var eq = q.indexOf('=', p)
                    if (eq < 0 || eq > e) eq = e
                    val k = Url.decode(q, p, eq, plus = true, invalid = Url.INVALID)
                    val v = if (k == null) null else Url.decode(q, minOf(eq + 1, e), e, plus = true, invalid = Url.INVALID)
                    if (k != null && v != null) {
                        when (k) {
                            "limit" -> if (limit == null) limit = v
                            "offset" -> if (offset == null) offset = v
                            "tag" -> if (tag == null) tag = v
                            "author" -> if (author == null) author = v
                            "favorited" -> if (favorited == null) favorited = v
                        }
                    }
                }
                p = e + 1
            }
            var l = 20
            if (limit != null) {
                val x = digits(limit)
                if (x < 1 || x > 100) return null
                l = x.toInt()
            }
            var o = 0L
            if (offset != null) {
                o = digits(offset)
                if (o < 0) return null
                if (o > MAX_OFFSET) o = MAX_OFFSET
            }
            if (!filters) return if (l == 20 && o == 0L) DEFAULT else ListQuery(l, o, Filter.NONE, "")
            return when {
                !tag.isNullOrEmpty() -> ListQuery(l, o, Filter.TAG, tag)
                !author.isNullOrEmpty() -> ListQuery(l, o, Filter.AUTHOR, author)
                !favorited.isNullOrEmpty() -> ListQuery(l, o, Filter.FAVORITED, favorited)
                l == 20 && o == 0L -> DEFAULT
                else -> ListQuery(l, o, Filter.NONE, "")
            }
        }

        private fun has(s: String, from: Int, to: Int, c: Char): Boolean {
            for (i in from until to) if (s[i] == c) return true
            return false
        }

        /** Non-empty ASCII digits fitting in int64 (leading zeros allowed) -> value; else -1. */
        fun digits(s: String): Long {
            if (s.isEmpty()) return -1
            var v = 0L
            for (c in s) {
                if (c < '0' || c > '9') return -1
                val d = c - '0'
                if (v > (Long.MAX_VALUE - d) / 10) return -1
                v = v * 10 + d
            }
            return v
        }
    }
}
