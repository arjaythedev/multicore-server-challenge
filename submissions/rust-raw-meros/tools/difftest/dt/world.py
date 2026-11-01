"""What the databases hold, learned from side A before the run starts.

The tester has no database access; it samples users through the API
(GET /api/user with a minted token), then each sampled user's feed size and
authored articles, plus random pages of the global list and the comments of
a few articles. Both servers get the same requests, so a wrong guess shows
up as a 404 on both, not as a mismatch.
"""
import json
import random
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from urllib.parse import quote

from .client import Call
from .side import Side

PAGE = 100                 # articles per discovery page
COMMENT_ARTICLES = 60      # articles whose comments are sampled
HEAVY_FEED = 1000          # articlesCount is capped at 1000, so this means "follows a lot"
WORKERS = 16


@dataclass(slots=True)
class User:
    id: int
    username: str
    email: str
    feed_count: int = 0


@dataclass(slots=True)
class Art:
    key: str                  # side-independent key, resolved by Side.slug
    slug: str
    author: str               # username at discovery time
    tags: list


@dataclass(slots=True)
class Cmt:
    key: str
    art_key: str
    id: int
    author: str


@dataclass
class World:
    tags: list = field(default_factory=list)
    users: list = field(default_factory=list)
    arts: list = field(default_factory=list)
    cmts: list = field(default_factory=list)
    n_articles: int = 0
    n_users: int = 0

    def author_id(self, username: str):
        """Numeric id of a sampled user by username, or None."""
        for u in self.users:
            if u.username == username:
                return u.id
        return None

    def seed_maps(self):
        """(slug map, comment-id map) to preload into each Side."""
        return ({a.key: a.slug for a in self.arts}, {c.key: c.id for c in self.cmts})


def _get(side: Side, path: str, auth=None):
    resp = side.run(Call("GET", path, auth=auth)).resp
    if resp.status != 200:
        raise SystemExit(f"discovery: GET {path} answered {resp.status} {resp.error or resp.body[:200]!r}")
    return json.loads(resp.body)


def _learn_user(side: Side, uid: int):
    """User record for `uid` (None if the id does not exist) plus its authored articles."""
    resp = side.run(Call("GET", "/api/user", auth=("user", uid))).resp
    if resp.status != 200:
        return None, []
    u = json.loads(resp.body)["user"]
    feed = _get(side, "/api/articles/feed?limit=1", ("user", uid))["articlesCount"]
    mine = _get(side, f"/api/articles?author={quote(u['username'], safe='')}&limit={PAGE}")["articles"]
    return User(uid, u["username"], u["email"], feed), mine


def discover(side: Side, rng: random.Random, n_articles: int, n_users: int, sample: int) -> World:
    """Build a `World` by sampling `sample` user ids out of 1..n_users."""
    world = World(n_articles=n_articles, n_users=n_users)
    world.tags = _get(side, "/api/tags")["tags"]
    ids = rng.sample(range(1, n_users + 1), min(sample, n_users))
    offsets = [rng.randrange(0, max(1, n_articles)) for _ in range(max(10, sample // 10))]
    seen: dict = {}
    with ThreadPoolExecutor(WORKERS) as pool:
        learned = list(pool.map(lambda uid: _learn_user(side, uid), ids))
        pages = list(pool.map(lambda o: _get(side, f"/api/articles?limit={PAGE}&offset={o}")["articles"], offsets))
    for user, mine in learned:
        if user:
            world.users.append(user)
        for art in mine:
            seen.setdefault(art["slug"], art)
    for page in pages:
        for art in page:
            seen.setdefault(art["slug"], art)
    for i, art in enumerate(seen.values()):
        world.arts.append(Art(f"s{i}", art["slug"], art["author"]["username"], art["tagList"]))
    _learn_comments(side, world, rng)
    return world


def _learn_comments(side: Side, world: World, rng: random.Random):
    """Sample comments of some articles so DELETE targets real seeded ids."""
    for art in rng.sample(world.arts, min(COMMENT_ARTICLES, len(world.arts))):
        body = _get(side, f"/api/articles/{quote(art.slug, safe='')}/comments")
        for c in body["comments"]:
            world.cmts.append(Cmt(f"c{len(world.cmts)}", art.key, c["id"], c["author"]["username"]))
