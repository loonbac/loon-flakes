#!/usr/bin/env python3
"""Serve the current Wayland clipboard image over a private Unix socket."""

from __future__ import annotations

import argparse
import http.server
import os
import signal
import socketserver
import stat
import subprocess
import threading
from pathlib import Path


SUPPORTED_TYPES = ("image/png", "image/jpeg", "image/webp", "image/gif")
MAX_IMAGE_BYTES = 50 * 1024 * 1024


def _run_wl_paste(args: list[str], timeout: float) -> bytes | None:
    try:
        result = subprocess.run(
            ["@wl_paste@", *args],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout


def available_image_types() -> list[str]:
    raw = _run_wl_paste(["--list-types"], timeout=1.0)
    if raw is None:
        return []

    advertised: dict[str, str] = {}
    for line in raw.decode("utf-8", errors="replace").splitlines():
        value = line.strip()
        base = value.split(";", 1)[0].strip().lower()
        if base in SUPPORTED_TYPES and base not in advertised:
            advertised[base] = value
    return [mime for mime in SUPPORTED_TYPES if mime in advertised]


def has_valid_signature(mime_type: str, data: bytes) -> bool:
    if mime_type == "image/png":
        return data.startswith(b"\x89PNG\r\n\x1a\n")
    if mime_type == "image/jpeg":
        return data.startswith(b"\xff\xd8\xff")
    if mime_type == "image/webp":
        return len(data) >= 12 and data.startswith(b"RIFF") and data[8:12] == b"WEBP"
    if mime_type == "image/gif":
        return data.startswith((b"GIF87a", b"GIF89a"))
    return False


def read_image(mime_type: str) -> bytes | None:
    if mime_type not in SUPPORTED_TYPES or mime_type not in available_image_types():
        return None
    data = _run_wl_paste(["--type", mime_type, "--no-newline"], timeout=3.0)
    if not data or len(data) > MAX_IMAGE_BYTES or not has_valid_signature(mime_type, data):
        return None
    return data


class ClipboardHandler(http.server.BaseHTTPRequestHandler):
    server_version = "PiSshClipboard/1"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/v1/types":
            body = ("\n".join(available_image_types()) + "\n").encode()
            self._reply(200, "text/plain; charset=utf-8", body)
            return

        prefix = "/v1/image/"
        if self.path.startswith(prefix):
            mime_type = self.path[len(prefix) :]
            data = read_image(mime_type)
            if data is None:
                self._reply(404, "text/plain; charset=utf-8", b"image unavailable\n")
                return
            self._reply(200, mime_type, data)
            return

        self._reply(404, "text/plain; charset=utf-8", b"not found\n")

    def _reply(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


class ClipboardServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    socket_path: Path = args.socket
    socket_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.path.lexists(socket_path):
        mode = socket_path.lstat().st_mode
        if not stat.S_ISSOCK(mode):
            raise SystemExit(f"refusing to replace non-socket path: {socket_path}")
        socket_path.unlink()

    server = ClipboardServer(str(socket_path), ClipboardHandler)
    os.chmod(socket_path, 0o600)
    bound_inode = socket_path.stat().st_ino

    def stop(_signum: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        try:
            if socket_path.stat().st_ino == bound_inode:
                socket_path.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
