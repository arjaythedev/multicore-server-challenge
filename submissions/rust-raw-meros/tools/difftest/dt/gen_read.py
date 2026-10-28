"""Read-only request generators, weighted like WORKLOAD.md plus edge cases.

Everything here is safe to run against an unchanged database: GETs, logins
and registrations that must fail validation or uniqueness.
Not generated: HEAD/OPTIONS, request bodies on GET, HTTP/1.0.
"""
from .client import Call
from .gen import Gen, Op, q, query

LIMIT_OK = [1, 2, 5, 10, 10, 10, 20, 20, 50, 99, 100]
LIMIT_EDGE = ["0", "101", "-1", "abc", "", "1.5", "+5", "05", " 5", "1e2", "100000000000000000000",
              "٣", "0x10", "1_0", "5 ", "٥", "NaN", "null"]
OFFSET_EDGE = ["-1", "abc", "", "1.5", "+0", "007", "2147483647", "2147483648", "9223372036854775807",
               "9223372036854775808", " 3", "1e1"]
ODD_SEGMENTS = ["%FF", "%00", "%2e%2e", "a%2Fb", "%C3%A5%C3%A4%C3%B6", "%E6%97%A5%E6%9C%AC", "x" * 3000, "%20",
                "%27%20OR%201%3D1--", "+", "%25", "..", ".", "%0A", "feed", "tags"]


def _page_pairs(g: Gen) -> list:
    """limit/offset pairs: usually valid, often boundary, sometimes invalid."""
    r, pairs = g.rng, []
    roll = r.random()
    if roll < 0.2:
        pass
    elif roll < 0.65:
        pairs.append(("limit", r.choice(LIMIT_OK)))
    else:
        pairs.append(("limit", r.choice(LIMIT_EDGE)))
    roll = r.random()
    if roll < 0.3:
        pass
    elif roll < 0.8:
        pairs.append(("offset", r.choice([0, 0, 0, 10, 20, 30, 40, 50, 100, 990, 1000, 9990,
                                          r.randrange(0, g.world.n_articles * 2 + 1)])))
    else:
        pairs.append(("offset", r.choice(OFFSET_EDGE)))
    if r.random() < 0.03:
        pairs.append(r.choice(pairs) if pairs else ("limit", 3))  # repeated parameter
    return pairs


def _tag_value(g: Gen) -> str:
    roll = g.rng.random()
    if roll < 0.78:
        return g.tag()
    return g.rng.choice(["nosuchtag", "", g.tag().upper(), "with space", "ü", g.tag() + " ", "%"])


def _name_value(g: Gen) -> str:
    roll = g.rng.random()
    if roll < 0.8:
        return g.any_username()
    return g.rng.choice(["nosuchuser", "", g.any_username().upper(), "ü", "a b"])


def _filter_pairs(g: Gen) -> list:
    """Zero, one or several of tag/author/favorited (only the first by priority applies)."""
    roll = g.rng.random()
    makers = {"tag": _tag_value, "author": _name_value, "favorited": _name_value}
    if roll < 0.3:
        return []
    if roll < 0.85:
        key = g.rng.choice(list(makers))
        return [(key, makers[key](g))]
    keys = g.rng.sample(list(makers), g.rng.choice([2, 3]))
    return [(k, makers[k](g)) for k in keys]


def op_list(g: Gen) -> Op:
    pairs = _filter_pairs(g) + _page_pairs(g)
    g.rng.shuffle(pairs)
    return Op("GET /api/articles", Call("GET", "/api/articles" + query(pairs), auth=g.viewer()))


def op_feed(g: Gen) -> Op:
    auth = ("user", g.feed_user_key()) if g.rng.random() > 0.03 else None
    return Op("GET /api/articles/feed", Call("GET", "/api/articles/feed" + query(_page_pairs(g)), auth=auth))


def article_segment(g: Gen) -> str:
    """Path segment naming an article: normally a key placeholder, sometimes odd on purpose."""
    roll = g.rng.random()
    if roll < 0.86:
        return "{slug:%s}" % g.art_key()
    base = g.seed_art().slug
    if roll < 0.92:
        return q(base + "-nope")
    if roll < 0.95:
        return "missing-" + str(g.rng.randrange(10**9))
    variants = [q(base.upper()), q(q(base)), q(base[:-1]), q(base) + "%20", q(base) + "/", g.rng.choice(ODD_SEGMENTS)]
    return g.rng.choice(variants)


def op_article(g: Gen) -> Op:
    return Op("GET /api/articles/:slug", Call("GET", "/api/articles/" + article_segment(g), auth=g.viewer()))


def op_comments(g: Gen) -> Op:
    path = "/api/articles/" + article_segment(g) + "/comments"
    return Op("GET /api/articles/:slug/comments", Call("GET", path, auth=g.viewer()))


def profile_segment(g: Gen) -> str:
    roll = g.rng.random()
    if roll < 0.85:
        return q(g.any_username())
    return g.rng.choice([q("nosuchuser"), q(g.any_username().upper()), g.rng.choice(ODD_SEGMENTS), "%C3%BC"])


def op_profile(g: Gen) -> Op:
    return Op("GET /api/profiles/:username", Call("GET", "/api/profiles/" + profile_segment(g), auth=g.viewer()))


def op_tags(g: Gen) -> Op:
    return Op("GET /api/tags", Call("GET", "/api/tags" + g.rng.choice(["", "", "", "?limit=3", "?x=1"])))


def op_user(g: Gen) -> Op:
    ukey = g.user_key()
    return Op("GET /api/user", Call("GET", "/api/user", auth=("user", ukey), expect_token=ukey))


def _raw_headers(valid: str) -> list:
    """(label, Authorization header value) pairs with a valid token in the wrong frame."""
    return [("scheme Bearer", "Bearer " + valid), ("scheme lowercase token", "token " + valid),
            ("scheme TOKEN", "TOKEN " + valid), ("two spaces", "Token  " + valid),
            ("trailing space", "Token " + valid + " "), ("scheme only", "Token"), ("scheme+space only", "Token "),
            ("empty header", ""), ("bare token", valid), ("Basic", "Basic dXNlcjpwYXNz"),
            ("trailing comma", "Token " + valid + ",x")]


def _bad_auth_targets(g: Gen) -> list:
    return ["/api/user", "/api/articles/feed", "/api/articles", "/api/articles/" + article_segment(g),
            "/api/articles/" + article_segment(g) + "/comments", "/api/profiles/" + q(g.any_username()), "/api/tags"]


def op_bad_auth(g: Gen) -> Op:
    """A GET with a broken or unusual Authorization header; the label names the variant."""
    path = g.rng.choice(_bad_auth_targets(g))
    roll = g.rng.random()
    if roll < 0.8:
        label, token = g.bad_token(odd=roll >= 0.6)
        header = "Token " + token
    else:
        label, header = g.rng.choice(_raw_headers(g.bad_token(odd=True)[1]))
    where = "tags" if path == "/api/tags" else "optional/required"
    return Op(f"GET with unusual auth ({where})", Call("GET", path, auth=("raw", header)), variant=label)


def op_login(g: Gen) -> Op:
    return Op("POST /api/users/login", Call("POST", "/api/users/login", _login_body(g)))


def login_credentials(g: Gen):
    """(email, password) of a user that exists, as the run currently knows them."""
    state = g.user_m(g.user_key())
    return state.email, state.password


def _login_body(g: Gen):
    email, password = login_credentials(g)
    roll = g.rng.random()
    if roll < 0.55:
        return {"user": {"email": email, "password": password}}
    variants = [
        {"user": {"email": email, "password": password + "x"}},
        {"user": {"email": "nobody-" + email, "password": password}},
        {"user": {"email": email.upper(), "password": password}},
        {"user": {"email": "", "password": password}},
        {"user": {"email": email, "password": ""}},
        {"user": {"email": email}},
        {"user": {"password": password}},
        {"user": {"email": 5, "password": password}},
        {"user": {"email": email, "password": 12345}},
        {"user": {"email": None, "password": None}},
        {"user": {"email": email, "password": password, "extra": 1}},
        {"user": []}, {"user": "x"}, {"email": email, "password": password}, {}, [], "str", None,
        b"{not json", b"", b'{"user":{"email":"' + email.encode() + b'","password":"' + password.encode() + b'"}} trailing',
    ]
    return g.rng.choice(variants)


def op_bad_register(g: Gen) -> Op:
    """Registrations that must be refused, so the database stays unchanged."""
    u = g.seeded_user()
    fresh = f"nobody{g.rng.randrange(10**9)}"
    variants = [
        {"user": {"username": u.username, "email": fresh + "@x.test", "password": "pw"}},
        {"user": {"username": fresh, "email": u.email, "password": "pw"}},
        {"user": {"username": "", "email": fresh + "@x.test", "password": "pw"}},
        {"user": {"username": fresh, "email": "", "password": "pw"}},
        {"user": {"username": fresh, "email": fresh + "@x.test", "password": ""}},
        {"user": {"username": fresh, "email": fresh + "@x.test"}},
        {"user": {"username": 7, "email": fresh + "@x.test", "password": "pw"}},
        {"user": {"username": fresh, "email": fresh + "@x.test", "password": ["pw"]}},
        {"user": {}}, {"user": None}, {"user": 1}, {}, [], b"{bad", b"",
    ]
    return Op("POST /api/users (refused)", Call("POST", "/api/users", g.rng.choice(variants)))


MISC = [("GET", "/"), ("GET", "/api"), ("GET", "/api/nothing"), ("GET", "/api/articles/"), ("GET", "/api/tags/"),
        ("GET", "/api/users"), ("GET", "/api/profiles"), ("GET", "/api/profiles/"), ("POST", "/api/tags"),
        ("DELETE", "/api/tags"), ("POST", "/api/user"), ("DELETE", "/api/user"), ("PATCH", "/api/user"),
        ("PUT", "/api/articles"), ("GET", "/api/articles/feed/"), ("GET", "/api//tags"), ("GET", "/API/tags"),
        ("PUT", "/api/articles/feed"), ("POST", "/api/articles/feed"), ("GET", "/api/users/login"),
        ("GET", "/api/articles/x/favorite"), ("GET", "/api/articles/x/comments/1"), ("GET", "/api/profiles/x/follow")]


def op_misc(g: Gen) -> Op:
    method, path = g.rng.choice(MISC)
    return Op(f"{method} unrouted", Call(method, path, auth=g.viewer()))


# (weight, generator): list/feed/article weights follow WORKLOAD.md page mix
READ_OPS = [(5, op_tags), (28, op_list), (11, op_feed), (13, op_article), (11, op_comments), (8, op_profile),
            (5, op_user), (5, op_bad_auth), (4, op_login), (2, op_bad_register), (1, op_misc)]
