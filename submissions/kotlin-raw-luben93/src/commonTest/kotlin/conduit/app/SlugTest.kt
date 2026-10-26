package conduit.app

import kotlin.test.Test
import kotlin.test.assertEquals

class SlugTest {
    // Expected values computed by PostgreSQL 18 (C.UTF-8 database) with SPEC's SLUGIFY:
    // trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g')))
    private val cases = listOf(
        "Conformance: Hello, World! 2026" to "conformance-hello-world-2026",
        "  Conformance -- Renamed Title!  " to "conformance-renamed-title",
        "---" to "",
        "!!!" to "",
        "a" to "a",
        "A-B" to "a-b",
        "-Leading" to "leading",
        "Trailing-" to "trailing",
        "Ünïcödé Straße" to "n-c-d-stra-e",
        "KKelvin" to "k-elvin",
        "İstanbul" to "stanbul",
        "ﬁsh" to "sh",
        "ＡBC１" to "bc",
        "emoji 😀 end" to "emoji-end",
        "tab\u0009nl\u000Ax" to "tab-nl-x",
        "MiXeD_CaSe__123" to "mixed-case-123",
        "é" to "",
        "Ab́c" to "ab-c",
        "99 Red Balloons" to "99-red-balloons",
        "x­y" to "x-y",
        "ÀÉÎÕÜ àéîõü" to "",
        "¡Hola, señor!" to "hola-se-or",
        "Ω≈ç√∫" to "",
        "日本語のタイトル" to "",
        "abc日本def" to "abc-def",
        "__init__" to "init",
        "a.b.c" to "a-b-c",
        "Z" to "z",
        "0" to "0",
        "ZZ top-10s" to "zz-top-10s",
        "quote\"back\\slash\$dollar" to "quote-back-slash-dollar",
        "[brackets] {braces} (parens)" to "brackets-braces-parens",
        "@#%^&*" to "",
        "a\u007Fb" to "a-b",
        "" to "",
    )

    @Test
    fun matchesPostgres() {
        for ((input, want) in cases) assertEquals(want, slugify(input), "slugify(\"$input\")")
    }
}
