"""Temporary loopback relay for proxies unreachable from rootless containers."""

from __future__ import annotations

import contextlib
import select
import socket
import socketserver
import threading
from collections.abc import Iterator
from urllib.parse import urlsplit, urlunsplit


class _RelayServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    address_family = socket.AF_INET6
    daemon_threads = True
    upstream: tuple[str, int]


class _RelayHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        upstream = socket.create_connection(self.server.upstream)  # type: ignore[attr-defined]
        with upstream:
            peers = (self.request, upstream)
            while True:
                readable, _, _ = select.select(peers, (), (), 30.0)
                if not readable:
                    continue
                for source in readable:
                    data = source.recv(64 * 1024)
                    if not data:
                        return
                    destination = upstream if source is self.request else self.request
                    destination.sendall(data)


def _needs_bridge(host: str, port: int) -> bool:
    addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    has_ipv4 = any(family == socket.AF_INET for family, *_ in addresses)
    has_ipv6 = any(family == socket.AF_INET6 for family, *_ in addresses)
    return has_ipv6 and not has_ipv4


@contextlib.contextmanager
def bridged_proxy(proxy_url: str | None) -> Iterator[str | None]:
    """Yield a container-reachable URL, relaying IPv6-only proxies if needed."""

    if not proxy_url:
        yield None
        return
    parsed = urlsplit(proxy_url)
    if not parsed.hostname:
        raise ValueError(f"proxy URL has no host: {proxy_url}")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    if not _needs_bridge(parsed.hostname, port):
        yield proxy_url
        return

    server = _RelayServer(("::1", 0), _RelayHandler)
    server.upstream = (parsed.hostname, port)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        local_port = int(server.server_address[1])
        yield urlunsplit((parsed.scheme, f"[::1]:{local_port}", "", "", ""))
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5.0)
