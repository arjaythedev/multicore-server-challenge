package conduit.app

import conduit.json.JsonValue

internal class RegisterBody(val username: String, val email: String, val password: String)
internal class LoginBody(val email: String, val password: String)
/** null = unchanged. */
internal class UserUpdateBody(
    val email: String?, val username: String?, val password: String?, val bio: String?, val image: String?,
)
internal class ArticleBody(val title: String, val description: String, val body: String, val tags: List<String>)
/** null = unchanged. */
internal class ArticleUpdateBody(val title: String?, val description: String?, val body: String?)

/**
 * Request-body validation with the Go reference's rules (examples/go/util.go readWrapper/optString/reqString): the
 * body must be a JSON object whose [wrapper] member is an object; unknown members are ignored; a field that is absent
 * or null is "not given"; any other non-string type is invalid. Every failure is 422 (null result).
 * Strings containing NUL are invalid too: Postgres text can't hold them (the write would fail with a 500).
 */
internal object Bodies {
    /** bcrypt's limit: longer passwords are rejected, never silently truncated. */
    const val MAX_PASSWORD_BYTES = 72

    fun register(v: JsonValue?): RegisterBody? {
        val f = Fields.of(v, "user") ?: return null
        val username = f.req("username")
        val email = f.req("email")
        val password = f.req("password")
        if (f.bad || username == null || email == null || password == null) return null
        if (utf8Length(password) > MAX_PASSWORD_BYTES) return null
        return RegisterBody(username, email, password)
    }

    /** NUL is allowed here: nothing is stored, and an email with NUL just matches no user (401, see Handlers). */
    fun login(v: JsonValue?): LoginBody? {
        val f = Fields.of(v, "user", nulOk = true) ?: return null
        val email = f.req("email")
        val password = f.req("password")
        if (f.bad || email == null || password == null) return null
        return LoginBody(email, password)
    }

    fun updateUser(v: JsonValue?): UserUpdateBody? {
        val f = Fields.of(v, "user") ?: return null
        val email = f.opt("email", nonEmpty = true)
        val username = f.opt("username", nonEmpty = true)
        val password = f.opt("password", nonEmpty = true)
        val bio = f.opt("bio", nonEmpty = false)
        val image = f.opt("image", nonEmpty = false)
        if (f.bad) return null
        if (password != null && utf8Length(password) > MAX_PASSWORD_BYTES) return null
        return UserUpdateBody(email, username, password, bio, image)
    }

    /** tagList: absent or null = none; else an array of non-empty strings (no nulls). Duplicates are fine (SQL). */
    fun article(v: JsonValue?): ArticleBody? {
        val f = Fields.of(v, "article") ?: return null
        val title = f.req("title")
        val description = f.req("description")
        val body = f.req("body")
        if (f.bad || title == null || description == null || body == null) return null
        val tags: List<String> = when (val t = f.obj["tagList"]) {
            null, JsonValue.Null -> emptyList()
            is JsonValue.Arr -> {
                val out = ArrayList<String>(t.items.size)
                for (item in t.items) {
                    if (item !is JsonValue.Str || item.value.isEmpty() || hasNul(item.value)) return null
                    out.add(item.value)
                }
                out
            }
            else -> return null
        }
        return ArticleBody(title, description, body, tags)
    }

    fun articleUpdate(v: JsonValue?): ArticleUpdateBody? {
        val f = Fields.of(v, "article") ?: return null
        val title = f.opt("title", nonEmpty = true)
        val description = f.opt("description", nonEmpty = true)
        val body = f.opt("body", nonEmpty = true)
        if (f.bad) return null
        return ArticleUpdateBody(title, description, body)
    }

    fun comment(v: JsonValue?): String? {
        val f = Fields.of(v, "comment") ?: return null
        val body = f.req("body")
        return if (f.bad) null else body
    }

    private class Fields(val obj: JsonValue.Obj, val nulOk: Boolean) {
        var bad = false

        /** Absent or null -> null; a string -> it (empty is invalid with [nonEmpty]); any other type is invalid. */
        fun opt(key: String, nonEmpty: Boolean): String? = when (val x = obj[key]) {
            null, JsonValue.Null -> null
            is JsonValue.Str -> {
                if ((nonEmpty && x.value.isEmpty()) || (!nulOk && hasNul(x.value))) bad = true
                x.value
            }
            else -> { bad = true; null }
        }

        /** Must be a non-empty string. */
        fun req(key: String): String? = opt(key, nonEmpty = true).also { if (it == null) bad = true }

        companion object {
            fun of(v: JsonValue?, wrapper: String, nulOk: Boolean = false): Fields? {
                if (v !is JsonValue.Obj) return null
                val inner = v[wrapper] as? JsonValue.Obj ?: return null
                return Fields(inner, nulOk)
            }
        }
    }

    fun hasNul(s: String): Boolean = s.indexOf('\u0000') >= 0

    /** UTF-8 length of [s] (lone surrogates count 3, as ByteBuf.putUtf8 writes U+FFFD). */
    fun utf8Length(s: String): Int {
        var n = 0
        var i = 0
        while (i < s.length) {
            val c = s[i].code
            n += when {
                c < 0x80 -> 1
                c < 0x800 -> 2
                c in 0xD800..0xDBFF && i + 1 < s.length && s[i + 1].code in 0xDC00..0xDFFF -> { i++; 4 }
                else -> 3
            }
            i++
        }
        return n
    }
}
