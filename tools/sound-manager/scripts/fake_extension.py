#!/usr/bin/env python3
"""Pretends to be the browser extension: sends a tab list to the app and prints the commands it receives."""
import base64
import json
import os
import socket
import struct
import sys
import time

HOST, PORT = "127.0.0.1", int(os.environ.get("SOUNDMANAGER_PORT", "47821"))


def connect(origin):
    sock = socket.create_connection((HOST, PORT), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        f"GET / HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
        + (f"Origin: {origin}\r\n" if origin else "")
        + "\r\n"
    )
    sock.sendall(request.encode())
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(1024)
        if not chunk:
            break
        response += chunk
    status = response.split(b"\r\n", 1)[0].decode(errors="replace")
    return sock, status


def send_text(sock, text):
    payload = text.encode()
    header = bytearray([0x81])
    mask = os.urandom(4)
    if len(payload) < 126:
        header.append(0x80 | len(payload))
    elif len(payload) < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", len(payload))
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", len(payload))
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(header) + mask + masked)


def read_frame(sock):
    head = sock.recv(2)
    if len(head) < 2:
        return None
    length = head[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", sock.recv(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", sock.recv(8))[0]
    data = b""
    while len(data) < length:
        data += sock.recv(length - len(data))
    return head[0] & 0x0F, data


TABS = [
    {"id": 11, "windowId": 1, "title": "Lo-fi beats – YouTube", "url": "https://www.youtube.com/watch?v=abc", "favIconUrl": None, "audible": True, "muted": False, "volume": 0.4, "playing": True, "volumeSupported": True},
    {"id": 12, "windowId": 1, "title": "Spotify – Web Player", "url": "https://open.spotify.com/", "favIconUrl": None, "audible": False, "muted": True, "volume": 1, "playing": True, "volumeSupported": True},
    {"id": 13, "windowId": 1, "title": "Notion – Docs", "url": "https://www.notion.so/", "favIconUrl": None, "audible": False, "muted": False, "volume": 1, "playing": False, "volumeSupported": True},
    {"id": 14, "windowId": 2, "title": "Extensões", "url": "chrome://extensions/", "favIconUrl": None, "audible": False, "muted": False, "volume": 1, "volumeSupported": False},
]


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "session"
    if mode == "reject":
        for origin in (None, "https://evil.example"):
            _, status = connect(origin)
            print(f"origin={origin!r} -> {status}")
        return
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 6
    sock, status = connect("chrome-extension://abcdefghijklmnopabcdefghijklmnop")
    print("handshake:", status)
    send_text(sock, json.dumps({"type": "hello", "brands": ["Chromium", "Google Chrome", "Not=A?Brand"]}))
    send_text(sock, json.dumps({"type": "tabs", "tabs": TABS}))
    sock.settimeout(0.5)
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            frame = read_frame(sock)
        except socket.timeout:
            continue
        if frame is None:
            break
        opcode, data = frame
        if opcode == 1:
            print("command:", data.decode())
    sock.close()


if __name__ == "__main__":
    main()
