import selectors
import socket

from typing import Callable, Dict


class RawSocketHttpServer:
    """Non-blocking epoll(7)-backed raw HTTP/1.1 keep-alive server."""

    MAX_HEAD = 16 * 1024

    def __init__(self, host: str, port: int, router: "Callable"):
        self.selector = selectors.DefaultSelector()
        self.router = router  # router.dispatch handler: HttpRequest -> bytes
        self.buffers: Dict[int, bytearray] = {}
        self.server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server_sock.bind((host, port))
        self.server_sock.listen(1024)
        self.server_sock.setblocking(False)

    def start(self):
        self.selector.register(self.server_sock, selectors.EVENT_READ, self._accept)
        print(
            f"Raw socket server running on port {self.server_sock.getsockname()[1]}...",
            flush=True,
        )

        while True:
            events = self.selector.select(timeout=None)
            for key, mask in events:
                callback = key.data
                callback(key.fileobj)

    def _accept(self, sock):
        try:
            conn, _ = sock.accept()
        except BlockingIOError:
            return
        conn.setblocking(False)
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buffers[conn.fileno()] = bytearray()
        self.selector.register(conn, selectors.EVENT_READ, self._read)

    def _read(self, conn):
        try:
            data = conn.recv(65536)
        except InterruptedError:
            return
        except OSError:
            self._close(conn)
            return

        if not data:
            self._close(conn)
            return

        buf = self.buffers.setdefault(conn.fileno(), bytearray())
        buf += data
        if len(buf) > self.MAX_HEAD and b"\r\n\r\n" not in buf:
            self._close(conn)
            return

        end = buf.find(b"\r\n\r\n")
        if end == -1:
            return  # wait for the rest of the headers

        head = buf[: end + 4]
        content_length = 0
        for line in head.decode("latin1", errors="replace").split("\r\n")[1:]:
            if ":" in line:
                k, _, v = line.partition(":")
                if k.strip().lower() == "content-length":
                    try:
                        content_length = max(0, int(v.strip()))
                    except ValueError:
                        content_length = 0
        total = end + 4 + content_length
        if len(buf) < total:
            return  # body not fully received yet

        raw = bytes(buf[:total])
        keep_close = b"connection: close" in bytes(head).lower()
        del buf[:total]

        from conduit_server.adapters.inbound.router import parse_request

        try:
            request = parse_request(raw)
            response = self.router(request)
        except Exception:
            response = (
                b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n"
                b"Content-Length: 34\r\nConnection: keep-alive\r\n\r\n"
                b'{"errors": {"body": ["Bad request"]}}'
            )
        if keep_close:
            response = response.replace(b"keep-alive", b"close", 1)

        self._send(conn, response)
        if keep_close:
            self._close(conn)

    def _send(self, conn, payload: bytes):
        """Best-effort write: temporarily flip the socket to blocking (hot path mostly succeeds immediately)."""
        conn.setblocking(True)
        try:
            conn.sendall(payload)
        except OSError:
            self.selector.unregister(conn)
            try:
                conn.close()
            except OSError:
                pass
        finally:
            conn.setblocking(False)

    def _close(self, conn):
        self.buffers.pop(conn.fileno(), None)
        try:
            self.selector.unregister(conn)
        except KeyError:
            pass
        try:
            conn.close()
        except OSError:
            pass
