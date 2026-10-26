from typing import Protocol

from conduit_server.adapters.inbound.router import HttpRequest


class InboundServer(Protocol):
    """Contract for any inbound HTTP transport."""

    def start(self) -> None: ...


class RequestParser(Protocol):
    """Contract for turning raw socket bytes into an HttpRequest."""

    def parse(self, raw: bytes) -> HttpRequest: ...
