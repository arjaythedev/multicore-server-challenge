"""Random human-ish text for titles, bodies, bios and usernames.

`tricky_title` covers what slugification and JSON/UTF-8 handling must get
right: punctuation-only titles, mixed case, non-ASCII letters, quotes,
escapes and very long text. NUL and lone surrogates are deliberately
rare: they are legal JSON that Postgres text columns cannot store.
"""
import random

WORDS = ("alpha bravo delta echo golf hotel india juliet kilo lima mike nova oscar papa quebec romeo sierra "
         "tango uniform victor whiskey xray yankee zulu rust conduit server memory arena buffer socket "
         "epoll thread kernel signal pipe cache index query plan vector slice borrow lifetime trait").split()

TRICKY_TITLES = [
    "!!!", "---", "   ", "-a-", "A  B   C", "C++ & Rust: a love/hate story?", "Ünïcödé Tïtle ÅÄÖ åäö",
    "日本語のタイトル", "emoji \U0001F680 launch", 'He said "hello" \\ and left', "tab\tand\nnewline",
    "<script>alert(1)</script>", "'; DROP TABLE articles; --", "100% sure %s %d {x}", "MiXeD CaSe 123 456",
    "x" * 300, "a-b_c.d,e;f:g", "---leading and trailing---", "ß straße İstanbul", " nbsp ",
]
RARE_EVIL = ["nul \u0000 byte", "lone surrogate \ud800 here"]


def words(rng: random.Random, low: int, high: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(rng.randint(low, high)))


def title(rng: random.Random, evil: bool = False) -> str:
    """A title: mostly plain words, sometimes tricky; unstorable ones only if `evil`."""
    roll = rng.random()
    if evil and roll < 0.03:
        return rng.choice(RARE_EVIL)
    if roll < 0.25:
        return rng.choice(TRICKY_TITLES)
    return words(rng, 2, 7).capitalize()


def paragraph(rng: random.Random) -> str:
    """Multi-line body text, sometimes with non-ASCII characters."""
    text = "\n\n".join(words(rng, 8, 40) + "." for _ in range(rng.randint(1, 3)))
    return text + (" åäö \U0001F600" if rng.random() < 0.2 else "")


def handle(rng: random.Random, run_tag: str, serial: int) -> str:
    """A fresh unique-looking username: run tag + serial + random suffix."""
    return f"dt{run_tag}u{serial}{rng.choice(WORDS)[:4]}"
