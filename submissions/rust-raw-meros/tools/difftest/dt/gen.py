"""Shared generator state and helpers for building random requests.

A generated `Op` is side-independent: it names users, articles and comments
by key, and each `Side` resolves keys to the ids its own server issued.
"""
import random
import time
from dataclasses import dataclass
from urllib.parse import quote

from . import jwtmint
from .client import Call
from .world import World

ANON_SHARE = 0.45         # optional-auth requests sent without a token
GHOST_SHARE = 0.03        # valid token for a user id that does not exist
GHOST_ID = 987654321
SEED_PASSWORD = "password123"


@dataclass(slots=True)
class UserState:
    """What the run believes a user's credentials are right now."""
    username: str
    email: str
    password: str


@dataclass(slots=True)
class Op:
    """A labelled call plus an optional hook that records what a side answered."""
    label: str
    call: Call
    after: object = None   # callable(side, status, parsed json or None)
    variant: str = ""      # sub-case shown in mismatch classes, not in the endpoint table


class Gen:
    """Random choices over a `World` (and, with --writes, a `WriteModel`)."""

    def __init__(self, rng: random.Random, world: World, secret: str, run_tag: str, model=None, evil: bool = False):
        self.rng, self.world, self.secret, self.model = rng, world, secret, model
        self.run_tag, self.evil = run_tag, evil
        self.by_id = {u.id: u for u in world.users}
        self.pending: list = []   # follow-up ops queued by writers, served first
        self.heavy = [u for u in world.users if u.feed_count >= 1000]
        self.empty = [u for u in world.users if u.feed_count == 0]
        self.middle = [u for u in world.users if 0 < u.feed_count < 1000]

    # --- users -----------------------------------------------------------
    def seeded_user(self):
        return self.rng.choice(self.world.users)

    def user_key(self):
        """A user key: seeded id, or (writes) a user created in this run."""
        if self.model and self.model.users and self.rng.random() < 0.4:
            return self.rng.choice(list(self.model.users))
        return self.seeded_user().id

    def feed_user_key(self):
        """Users that follow many, some, or nobody (bucket chosen at random)."""
        buckets = [b for b in (self.heavy, self.middle, self.empty) if b]
        roll = self.rng.random()
        if self.model and self.model.users and roll < 0.25:
            return self.rng.choice(list(self.model.users))
        return self.rng.choice(self.rng.choice(buckets)).id if buckets else self.seeded_user().id

    def user_m(self, ukey):
        """Current (username, email, password) of a user; changes made in this run included."""
        if self.model:
            known = self.model.user_state(ukey)
            if known:
                return known
        u = self.by_id[ukey]
        return UserState(u.username, u.email, SEED_PASSWORD)

    def username(self, ukey) -> str:
        return self.user_m(ukey).username

    def any_username(self) -> str:
        return self.username(self.user_key())

    def viewer(self):
        """Auth for an auth-optional endpoint: anonymous, a real user, or a ghost id."""
        roll = self.rng.random()
        if roll < ANON_SHARE:
            return None
        if roll > 1 - GHOST_SHARE:
            return ("user", GHOST_ID)
        return ("user", self.user_key())

    # --- articles --------------------------------------------------------
    def art_key(self) -> str:
        """Article key: in writes mode half the time one created/changed in this run."""
        if self.model and self.model.arts and self.rng.random() < 0.5:
            return self.rng.choice(list(self.model.arts))
        return self.rng.choice(self.world.arts).key

    def seed_art(self):
        return self.rng.choice(self.world.arts)

    def tag(self) -> str:
        return self.rng.choice(self.world.tags)

    # --- misc ------------------------------------------------------------
    def now(self) -> int:
        return int(time.time())

    def bad_token(self, odd: bool):
        """(label, token) from the must-reject set, or the spec-open set if `odd`."""
        uid = self.seeded_user().id
        pool = (jwtmint.odd_tokens if odd else jwtmint.rejected_tokens)(self.secret, uid, self.now())
        return self.rng.choice(pool)


def q(value) -> str:
    """Percent-encode one URL component completely."""
    return quote(str(value), safe="")


def query(pairs) -> str:
    """'?k=v&...' from (key, value) pairs, '' when there are none."""
    return "?" + "&".join(f"{q(k)}={q(v)}" for k, v in pairs) if pairs else ""
