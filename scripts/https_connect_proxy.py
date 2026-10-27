#!/usr/bin/env python3
"""Forward Hugging Face HTTPS CONNECT requests without storing response data."""
from __future__ import annotations

import re
import select
import socket
import socketserver

MAX_HEADER_BYTES: int = 16 * 1024
RELAY_BUFFER_BYTES: int = 64 * 1024
CONNECT_TIMEOUT_SECONDS: int = 30
REQUEST_TIMEOUT_SECONDS: int = 30
ALLOWED_HOST_SUFFIXES: tuple[str, ...] = ("huggingface.co", "hf.co")
HOST_LABEL_PATTERN: re.Pattern[str] = re.compile(
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    r"(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*"
)


class ProxyRequestError(Exception):
    status_line: str

    def __init__(self, status_line: str) -> None:
        super().__init__(status_line)
        self.status_line = status_line


class ThreadingConnectProxyServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    block_on_close = False


class HfConnectProxyHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        client_socket: socket.socket = self.request
        client_socket.settimeout(REQUEST_TIMEOUT_SECONDS)
        try:
            header_result = read_connect_headers(client_socket)
        except OSError:
            return
        if header_result is None:
            send_response(client_socket, "400 Bad Request")
            return

        header, buffered_payload = header_result
        try:
            hostname, port = parse_connect_request(header)
        except ProxyRequestError as error:
            send_response(client_socket, error.status_line)
            return

        try:
            upstream_socket = socket.create_connection(
                (hostname, port), timeout=CONNECT_TIMEOUT_SECONDS
            )
        except OSError:
            send_response(client_socket, "502 Bad Gateway")
            return

        with upstream_socket:
            client_socket.settimeout(None)
            upstream_socket.settimeout(None)
            try:
                if not send_response(client_socket, "200 Connection Established"):
                    return
                if buffered_payload:
                    upstream_socket.sendall(buffered_payload)
                relay_bytes(client_socket, upstream_socket)
            except OSError:
                return


def read_connect_headers(
    client_socket: socket.socket,
) -> tuple[bytes, bytes] | None:
    received_bytes: bytearray = bytearray()
    while len(received_bytes) <= MAX_HEADER_BYTES:
        read_size: int = min(4096, MAX_HEADER_BYTES + 4 - len(received_bytes))
        try:
            packet: bytes = client_socket.recv(read_size)
        except OSError:
            return None
        if not packet:
            return None
        received_bytes.extend(packet)
        header_end: int = received_bytes.find(b"\r\n\r\n")
        if header_end >= 0:
            header_length: int = header_end + 4
            if header_length > MAX_HEADER_BYTES:
                return None
            return (
                bytes(received_bytes[:header_length]),
                bytes(received_bytes[header_length:]),
            )
    return None


def parse_connect_request(header: bytes) -> tuple[str, int]:
    try:
        request_line: str = header.split(b"\r\n", 1)[0].decode("ascii")
    except UnicodeDecodeError as error:
        raise ProxyRequestError("400 Bad Request") from error

    request_parts: list[str] = request_line.split()
    if len(request_parts) != 3:
        raise ProxyRequestError("400 Bad Request")
    method: str
    authority: str
    http_version: str
    method, authority, http_version = request_parts
    if method != "CONNECT":
        raise ProxyRequestError("405 Method Not Allowed")
    if http_version not in ("HTTP/1.0", "HTTP/1.1"):
        raise ProxyRequestError("400 Bad Request")
    if authority.count(":") != 1:
        raise ProxyRequestError("400 Bad Request")

    hostname, port_text = authority.rsplit(":", 1)
    if port_text != "443":
        raise ProxyRequestError("403 Forbidden")
    normalized_hostname: str = hostname.lower().rstrip(".")
    if not is_allowed_hostname(normalized_hostname):
        raise ProxyRequestError("403 Forbidden")
    return normalized_hostname, 443


def is_allowed_hostname(hostname: str) -> bool:
    if not hostname or len(hostname) > 253:
        return False
    if HOST_LABEL_PATTERN.fullmatch(hostname) is None:
        return False
    return any(
        hostname == suffix or hostname.endswith("." + suffix)
        for suffix in ALLOWED_HOST_SUFFIXES
    )


def send_response(client_socket: socket.socket, status_line: str) -> bool:
    response: bytes = (
        f"HTTP/1.1 {status_line}\r\n"
        "Connection: close\r\n"
        "Content-Length: 0\r\n\r\n"
    ).encode("ascii")
    try:
        client_socket.sendall(response)
    except OSError:
        return False
    return True


def relay_bytes(
    client_socket: socket.socket, upstream_socket: socket.socket
) -> None:
    readable_sockets: set[socket.socket] = {client_socket, upstream_socket}
    while readable_sockets:
        readable, _, exceptional = select.select(
            tuple(readable_sockets), (), tuple(readable_sockets)
        )
        if exceptional:
            return
        for source_socket in readable:
            destination_socket: socket.socket = (
                upstream_socket if source_socket is client_socket else client_socket
            )
            try:
                packet: bytes = source_socket.recv(RELAY_BUFFER_BYTES)
            except OSError:
                packet = b""
            if not packet:
                readable_sockets.discard(source_socket)
                try:
                    destination_socket.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                continue
            try:
                destination_socket.sendall(packet)
            except OSError:
                return


if __name__ == "__main__":
    with ThreadingConnectProxyServer(
        ("127.0.0.1", 0), HfConnectProxyHandler
    ) as proxy_server:
        print(proxy_server.server_address[1], flush=True)
        proxy_server.serve_forever()
