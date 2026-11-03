#!/usr/bin/env python3
"""Push bar states into the real store. This is not the product daemon."""

import json
import os
import socket
import sys
import threading

path = sys.argv[1]
if os.path.exists(path):
    os.unlink(path)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(8)
state = {
    "state": "idle",
    "ip": "",
    "gateway": "",
    "user": "",
    "expires": "",
    "since": 0,
    "message": "",
    "gateways": [],
    "server": "",
}
clients = []
lock = threading.Lock()


def send(conn, message):
    try:
        conn.sendall((json.dumps(message) + "\n").encode())
    except OSError:
        return


def broadcast(message):
    data = (json.dumps(message) + "\n").encode()
    with lock:
        current = list(clients)
    for conn in current:
        try:
            conn.sendall(data)
        except OSError:
            pass


def handle(conn):
    with lock:
        clients.append(conn)
    buf = b""
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                if not raw.strip():
                    continue
                req = json.loads(raw.decode())
                cmd = req.get("cmd")
                if cmd == "status":
                    send(conn, {"type": "state", **state})
                elif cmd == "disconnect":
                    state.update(state="idle", ip="", expires="", message="", server="")
                    broadcast({"type": "state", **state})
                    send(conn, {"type": "accepted", **state})
                elif cmd == "push":
                    for key in ("state", "ip", "gateway", "user", "expires", "message", "server"):
                        if key in req:
                            state[key] = req[key]
                    broadcast({"type": "state", **state})
                elif cmd == "connect":
                    send(conn, {"type": "error", "message": "Already connecting or connected"})
                else:
                    send(conn, {"type": "error", "message": "Unknown command"})
    finally:
        with lock:
            if conn in clients:
                clients.remove(conn)
        conn.close()


while True:
    try:
        conn, _addr = server.accept()
    except OSError:
        break
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
