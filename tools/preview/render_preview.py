#!/usr/bin/env python3
"""Render preview.png from a real gpvpnd and the fake openconnect."""

import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DAEMON = REPO / "bin" / "gpvpnd"
FAKE = REPO / "tests" / "fixtures" / "fake-openconnect"
GLYPHS = {
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["01110", "10001", "00001", "00110", "00001", "10001", "01110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
}


def chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def write_png(path: Path, width: int, height: int, rgba: bytearray) -> None:
    raw = b"".join(b"\x00" + bytes(rgba[y * width * 4:(y + 1) * width * 4]) for y in range(height))
    blob = b"\x89PNG\r\n\x1a\n"
    blob += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    blob += chunk(b"IDAT", zlib.compress(raw, 9))
    blob += chunk(b"IEND", b"")
    path.write_bytes(blob)


def put(rgba: bytearray, width: int, height: int, x: int, y: int, color: tuple[int, int, int, int]) -> None:
    if 0 <= x < width and 0 <= y < height:
        index = (y * width + x) * 4
        rgba[index:index + 4] = bytes(color)


def paint(ip: str) -> tuple[int, int, bytearray]:
    scale = 4
    pad = 16
    width = pad * 2 + (5 * scale + scale) * len(ip)
    height = 72
    rgba = bytearray(width * height * 4)
    background = (18, 24, 28, 255)
    green = (64, 168, 96, 255)
    ink = (236, 240, 236, 255)
    for y in range(height):
        for x in range(width):
            put(rgba, width, height, x, y, background)
    for y in range(18, 54):
        for x in range(8, 14):
            put(rgba, width, height, x, y, green)
    cursor = 22
    for char in ip:
        glyph = GLYPHS.get(char, GLYPHS["."])
        for row, bits in enumerate(glyph):
            for col, bit in enumerate(bits):
                if bit != "1":
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        put(rgba, width, height, cursor + col * scale + dx, 18 + row * scale + dy, ink)
        cursor += 6 * scale
    return width, height, rgba


def wait_status(sock: str) -> dict:
    last = {}
    for _ in range(40):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.settimeout(1)
            client.connect(sock)
            client.sendall(b'{"cmd":"status"}\n')
            data = b""
            while b"\n" not in data:
                chunk = client.recv(65536)
                if not chunk:
                    break
                data += chunk
        except OSError:
            time.sleep(0.1)
            continue
        finally:
            client.close()
        if not data:
            time.sleep(0.1)
            continue
        last = json.loads(data.split(b"\n", 1)[0].decode())
        if last.get("state") == "connected" and last.get("ip"):
            return last
        time.sleep(0.1)
    raise SystemExit(f"daemon did not connect: {last}")


def main() -> int:
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "preview.png"
    work = tempfile.mkdtemp(prefix="omaglobal-preview-")
    sock = os.path.join(work, "ctrl.sock")
    env = os.environ.copy()
    env["FAKE_OC_DIR"] = os.path.join(work, "oc")
    env["FAKE_OC_MODE"] = "ok"
    env["FAKE_OC_SLEEP"] = "20"
    daemon = subprocess.Popen(
        [sys.executable, str(DAEMON), "--socket", sock, "--openconnect", str(FAKE), "--state-file", os.path.join(work, "state.json")],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(50):
            if os.path.exists(sock):
                break
            time.sleep(0.05)
        else:
            raise SystemExit("preview daemon did not listen")
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(sock)
        payload = {
            "cmd": "connect",
            "cookie": "fixture",
            "user": "user@example.com",
            "server": "vpn.example.com",
            "usergroup": "gateway:prelogin-cookie",
            "gateway": "",
        }
        client.sendall((json.dumps(payload) + "\n").encode())
        client.close()
        status = wait_status(sock)
        ip = str(status["ip"])
        width, height, rgba = paint(ip)
        target.parent.mkdir(parents=True, exist_ok=True)
        write_png(target, width, height, rgba)
        print(f"PREVIEW_IP {ip}")
        print(f"PREVIEW_BYTES {target.stat().st_size}")
        return 0
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=2)
        except subprocess.TimeoutExpired:
            daemon.kill()


if __name__ == "__main__":
    raise SystemExit(main())
