"""What the run believes it has created or changed (side-independent).

Optimistic: a writer records its effect when it generates the request and
withdraws it if any side answered with a failure status. The model only
steers request choice (who owns what); it never decides pass or fail.
"""
from dataclasses import dataclass, field

from .gen import UserState


@dataclass(slots=True)
class ArtState:
    author: object          # user key of the creator
    tags: list


@dataclass(slots=True)
class CmtState:
    art: str                # article key
    author: object          # user key


@dataclass
class WriteModel:
    users: dict = field(default_factory=dict)    # created-user key -> UserState
    seeded: dict = field(default_factory=dict)   # seeded id -> UserState after a change
    arts: dict = field(default_factory=dict)     # created-article key -> ArtState
    cmts: dict = field(default_factory=dict)     # created-comment key -> CmtState
    serial: int = 0

    def next_key(self, prefix: str) -> str:
        self.serial += 1
        return f"{prefix}{self.serial}"

    def user_state(self, ukey):
        return self.seeded.get(ukey) if isinstance(ukey, int) else self.users.get(ukey)

    def set_user_state(self, ukey, state: UserState):
        (self.seeded if isinstance(ukey, int) else self.users)[ukey] = state

    def drop_article(self, akey: str):
        """Forget an article and the comments that went with it."""
        self.arts.pop(akey, None)
        for ckey in [k for k, c in self.cmts.items() if c.art == akey]:
            del self.cmts[ckey]
