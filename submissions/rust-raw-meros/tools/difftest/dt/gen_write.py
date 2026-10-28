"""State-changing request generators for --writes.

Every writer records its expected effect in the `WriteModel` when it builds
the request and withdraws it if a side refuses. Ids that the servers assign
(user id from the token, article slug, comment id) are captured per side by
the `after` hooks, so follow-up requests use each server's own ids.
Not generated: multi-statement races between concurrent writers (the run is
sequential so both databases see the same order).
"""
from . import text
from .client import Call
from .gen import Gen, Op, UserState, q
from .gen_read import article_segment
from .jwtmint import check
from .model import ArtState, CmtState

MAX_TAGS = 5
TAG_ODDITIES = ["Ünï", "a b", "UPPER", "x" * 60, "tag/slash", "tag,comma", "日本"]


def dig(body, *path):
    """body[path[0]][path[1]]... or None if any step is missing or mistyped."""
    for step in path:
        body = body.get(step) if isinstance(body, dict) else None
    return body


def _sub(g: Gen, token):
    claims, _ = check(token, g.secret) if isinstance(token, str) else (None, "")
    return int(claims["sub"]) if claims else None


def _fresh(g: Gen) -> tuple:
    """(username, email, password) never used before in this run."""
    key = g.model.next_key("n")
    name = text.handle(g.rng, g.run_tag, int(key[1:]))
    return name, f"{name}@difftest.test", f"pw-{g.rng.randrange(10**6)}"


# --- users ---------------------------------------------------------------
def op_register(g: Gen) -> Op:
    name, email, pw = _fresh(g)
    ukey = g.model.next_key("u")
    g.model.users[ukey] = UserState(name, email, pw)

    def after(side, status, body):
        sub = _sub(g, dig(body, "user", "token"))
        if status == 201 and sub:
            side.uid[ukey] = sub
        else:
            g.model.users.pop(ukey, None)

    g.pending.append(Op("GET /api/user", Call("GET", "/api/user", auth=("user", ukey), expect_token=ukey)))
    return Op("POST /api/users", Call("POST", "/api/users", {"user": {"username": name, "email": email, "password": pw}}), after)


def _patch_fields(g: Gen) -> tuple:
    """(patch dict, applied dict): `applied` holds what the model keeps on success."""
    r, patch, applied = g.rng, {}, {}
    for field in r.sample(["bio", "image", "email", "username", "password"], r.randint(1, 3)):
        roll = r.random()
        if roll < 0.12:
            patch[field] = None
        elif roll < 0.18:
            patch[field] = ""
        elif field in ("bio", "image"):
            patch[field] = text.words(r, 2, 8) if field == "bio" else f"https://img.test/{r.randrange(10**6)}.png"
        elif roll < 0.28:
            other = g.user_m(g.user_key())          # collision: must be refused
            patch[field] = other.email if field == "email" else other.username if field == "username" else "x"
        else:
            name, email, pw = _fresh(g)
            patch[field] = {"email": email, "username": name, "password": pw}[field]
            applied[field] = patch[field]
    return patch, applied


def op_update_user(g: Gen) -> Op:
    ukey = g.user_key()
    patch, applied = _patch_fields(g)
    old = g.user_m(ukey)

    def after(side, status, body):
        if status == 200 and dig(body, "user", "username") == applied.get("username", old.username):
            g.model.set_user_state(ukey, UserState(applied.get("username", old.username),
                                                   applied.get("email", old.email), applied.get("password", old.password)))

    g.pending.append(Op("GET /api/user", Call("GET", "/api/user", auth=("user", ukey), expect_token=ukey)))
    return Op("PUT /api/user", Call("PUT", "/api/user", {"user": patch}, auth=("user", ukey), expect_token=ukey), after)


# --- articles ------------------------------------------------------------
def _tag_list(g: Gen):
    r, roll = g.rng, g.rng.random()
    if roll < 0.2:
        return r.choice([None, [], "missing"])
    tags = [g.tag() if r.random() < 0.6 else f"dt-new-{r.randrange(50)}" for _ in range(r.randint(1, MAX_TAGS))]
    if r.random() < 0.1:
        tags.append(r.choice(TAG_ODDITIES))
    if r.random() < 0.1:
        tags.append(tags[0])                       # duplicate inside one list
    return tags


def _article_body(g: Gen) -> dict:
    r = g.rng
    body = {"title": text.title(r, g.evil), "description": text.words(r, 3, 12), "body": text.paragraph(r)}
    tags = _tag_list(g)
    if tags != "missing":
        body["tagList"] = tags
    return body


def _invalid_article(g: Gen):
    base = _article_body(g)
    breaks = [lambda b: b.pop("title"), lambda b: b.update(title=""), lambda b: b.update(description=""),
              lambda b: b.update(body=""), lambda b: b.update(body=5), lambda b: b.update(tagList="x"),
              lambda b: b.update(tagList=[""]), lambda b: b.update(tagList=[5]), lambda b: b.update(title=None),
              lambda b: b.update(tagList={"a": 1})]
    g.rng.choice(breaks)(base)
    return g.rng.choice([{"article": base}, {"article": base}, {}, {"article": []}, b"{oops", {"user": base}])


def op_create_article(g: Gen) -> Op:
    ukey = g.user_key()
    valid = g.rng.random() > 0.15
    akey = g.model.next_key("a")
    body = {"article": _article_body(g)} if valid else _invalid_article(g)
    listed = body["article"].get("tagList") if valid else None
    tags = sorted({t for t in listed if isinstance(t, str)}) if isinstance(listed, list) else []
    if valid:
        g.model.arts[akey] = ArtState(ukey, tags)

    def after(side, status, resp):
        slug = dig(resp, "article", "slug")
        if status == 201 and isinstance(slug, str):
            side.slug[akey] = slug
        else:
            g.model.arts.pop(akey, None)

    if valid:
        g.pending.append(Op("GET /api/articles/:slug", Call("GET", "/api/articles/{slug:%s}" % akey, auth=g.viewer())))
        g.pending.append(Op("GET /api/tags", Call("GET", "/api/tags")))
    return Op("POST /api/articles", Call("POST", "/api/articles", body, auth=("user", ukey)), after)


def _owner(g: Gen, akey: str):
    """User key that owns `akey`, or None when the owner was not sampled."""
    if akey in g.model.arts:
        return g.model.arts[akey].author
    art = next((a for a in g.world.arts if a.key == akey), None)
    return g.world.author_id(art.author) if art else None


def _article_target(g: Gen) -> tuple:
    """(article key, acting user key) for an owner-only operation; usually the owner."""
    r = g.rng
    if g.model.arts and r.random() < 0.6:
        akey = r.choice(list(g.model.arts))
    else:
        akey = r.choice(g.world.arts).key
    owner = _owner(g, akey)
    return (akey, owner) if owner is not None and r.random() < 0.85 else (akey, g.user_key())


def op_update_article(g: Gen) -> Op:
    akey, actor = _article_target(g)
    r, patch = g.rng, {}
    for field, make in (("title", lambda x: text.title(x, g.evil)), ("description", lambda x: text.words(x, 3, 9)), ("body", text.paragraph)):
        roll = r.random()
        if roll < 0.45:
            patch[field] = make(r)
        elif roll < 0.55:
            patch[field] = None
        elif roll < 0.58:
            patch[field] = ""
    if not patch or r.random() < 0.03:
        patch = r.choice([{}, {"title": 5}, {"tagList": ["x"]}])

    def after(side, status, resp):
        slug = dig(resp, "article", "slug")
        if status == 200 and isinstance(slug, str):
            side.slug[akey] = slug

    g.pending.append(Op("GET /api/articles/:slug", Call("GET", "/api/articles/{slug:%s}" % akey, auth=g.viewer())))
    return Op("PUT /api/articles/:slug", Call("PUT", "/api/articles/{slug:%s}" % akey, {"article": patch}, auth=("user", actor)), after)


def op_delete_article(g: Gen) -> Op:
    akey, actor = _article_target(g)

    def after(side, status, resp):
        if status == 204:
            g.model.drop_article(akey)

    g.pending.append(Op("GET /api/articles/:slug", Call("GET", "/api/articles/{slug:%s}" % akey, auth=g.viewer())))
    return Op("DELETE /api/articles/:slug", Call("DELETE", "/api/articles/{slug:%s}" % akey, auth=("user", actor)), after)


def op_favorite(g: Gen) -> Op:
    method = g.rng.choice(["POST", "DELETE"])
    seg = article_segment(g)
    return Op(f"{method} /api/articles/:slug/favorite", Call(method, f"/api/articles/{seg}/favorite", auth=("user", g.user_key())))


def op_follow(g: Gen) -> Op:
    method, ukey = g.rng.choice(["POST", "DELETE"]), g.user_key()
    target = g.any_username() if g.rng.random() < 0.9 else "nosuchuser"
    g.pending.append(Op("GET /api/profiles/:username", Call("GET", "/api/profiles/" + q(target), auth=("user", ukey))))
    g.pending.append(Op("GET /api/articles/feed", Call("GET", "/api/articles/feed?limit=20", auth=("user", ukey))))
    return Op(f"{method} /api/profiles/:username/follow", Call(method, f"/api/profiles/{q(target)}/follow", auth=("user", ukey)))


# --- comments ------------------------------------------------------------
def op_comment_add(g: Gen) -> Op:
    r, ukey, akey = g.rng, g.user_key(), g.art_key()
    ckey = g.model.next_key("k")
    roll = r.random()
    body = ({"comment": {"body": text.words(r, 3, 20)}} if roll < 0.88
            else r.choice([{"comment": {"body": ""}}, {"comment": {}}, {"comment": {"body": 5}}, {}, b"{x"]))
    if roll < 0.88:
        g.model.cmts[ckey] = CmtState(akey, ukey)

    def after(side, status, resp):
        cid = dig(resp, "comment", "id")
        if status == 201 and isinstance(cid, int):
            side.cid[ckey] = cid
        else:
            g.model.cmts.pop(ckey, None)

    g.pending.append(Op("GET /api/articles/:slug/comments", Call("GET", "/api/articles/{slug:%s}/comments" % akey, auth=g.viewer())))
    return Op("POST /api/articles/:slug/comments", Call("POST", "/api/articles/{slug:%s}/comments" % akey, body, auth=("user", ukey)), after)


def op_comment_delete(g: Gen) -> Op:
    r = g.rng
    if g.model.cmts and r.random() < 0.7:
        ckey = r.choice(list(g.model.cmts))
        akey, owner = g.model.cmts[ckey].art, g.model.cmts[ckey].author
    elif g.world.cmts:
        c = r.choice(g.world.cmts)
        ckey, akey, owner = c.key, c.art_key, g.world.author_id(c.author)
    else:
        return op_favorite(g)
    actor = owner if owner is not None and r.random() < 0.85 else g.user_key()
    path = "/api/articles/{slug:%s}/comments/{cid:%s}" % (akey, ckey)
    roll = r.random()
    if roll < 0.04:
        path = "/api/articles/{slug:%s}/comments/%s" % (akey, r.choice(["abc", "1.5", "-1", "0", "99999999999999999999", "%20"]))
    elif roll < 0.08:
        path = "/api/articles/{slug:%s}/comments/{cid:%s}" % (g.art_key(), ckey)   # comment of another article

    def after(side, status, resp):
        if status == 204:
            g.model.cmts.pop(ckey, None)

    g.pending.append(Op("GET /api/articles/:slug/comments", Call("GET", "/api/articles/{slug:%s}/comments" % akey, auth=g.viewer())))
    return Op("DELETE /api/articles/:slug/comments/:id", Call("DELETE", path, auth=("user", actor)), after)


def op_rejected_write(g: Gen) -> Op:
    """A write endpoint with a token that must be refused: nothing may change."""
    label, token = g.bad_token(odd=False)
    method, path, body = g.rng.choice([
        ("POST", "/api/articles", {"article": {"title": "t", "description": "d", "body": "b"}}),
        ("PUT", "/api/user", {"user": {"bio": "hijack"}}),
        ("POST", "/api/profiles/" + q(g.any_username()) + "/follow", None),
        ("POST", "/api/articles/" + article_segment(g) + "/favorite", None),
        ("DELETE", "/api/articles/" + article_segment(g), None),
        ("POST", "/api/articles/" + article_segment(g) + "/comments", {"comment": {"body": "x"}}),
    ])
    return Op(f"{method} with rejected token", Call(method, path, body, auth=("raw", "Token " + token)))


# (weight, generator)
WRITE_OPS = [(6, op_register), (5, op_update_user), (12, op_create_article), (8, op_update_article),
             (5, op_delete_article), (14, op_favorite), (8, op_follow), (12, op_comment_add),
             (8, op_comment_delete), (3, op_rejected_write)]
