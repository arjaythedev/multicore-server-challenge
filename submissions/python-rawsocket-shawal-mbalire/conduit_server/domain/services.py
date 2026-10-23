"""Pure business logic: validation, slug generation, list paging rules.

Zero dependencies on HTTP, sockets, or database drivers.
"""

import re
from typing import List, Tuple

_INVALID_SLUG_CHARS = re.compile(r"[^A-Za-z0-9]+")


def slugify(title: str) -> str:
    """Byte-identical to SQL: SLUGIFY(x) := trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g')))."""
    return _INVALID_SLUG_CHARS.sub("-", title).lower().strip("-")


def is_non_empty_string(value: object) -> bool:
    return isinstance(value, str) and value != ""


def require_strings(body: dict, outer: str, *fields: str) -> None:
    """Validate nested body fields exist and are non-empty strings, else raise ValueError (422 upstream)."""
    payload = body.get(outer) if isinstance(body, dict) else None
    if not isinstance(payload, dict):
        raise ValueError(f"{outer} is required")
    for field in fields:
        if not is_non_empty_string(payload.get(field)):
            raise ValueError(f"{field} is required")


def parse_limit_offset(query: "dict") -> Tuple[int, int]:
    """limit defaults to 20 and must be 1-100; offset defaults to 0 and must be >= 0.

    Strict plain decimal digits only (no '+', spaces, signs, empty strings); values fit int32.
    """
    limit_raw = query.get("limit", "20")
    offset_raw = query.get("offset", "0")
    if not re.fullmatch(r"\d+", limit_raw) or not re.fullmatch(r"\d+", offset_raw):
        raise ValueError("limit and offset must be integers")
    limit = int(limit_raw)
    offset = int(offset_raw)
    if not (1 <= limit <= 100) or offset < 0 or offset > 0x7FFFFFFF:
        raise ValueError("limit must be 1..100 and offset >= 0")
    return limit, offset


def parse_tag_list(raw: object) -> List[str]:
    """tagList is optional; when present it must be an array of non-empty strings."""
    if raw is None:
        return []
    if not isinstance(raw, list) or not all(is_non_empty_string(t) for t in raw):
        raise ValueError("tagList must be an array of non-empty strings")
    return raw
