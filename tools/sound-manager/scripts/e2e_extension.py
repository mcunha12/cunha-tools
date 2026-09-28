#!/usr/bin/env python3
"""End-to-end check of the browser extension: headless Chrome, a fake app server, and real audio level measurement."""
import base64
import functools
import hashlib
import http.server
import json
import math
import os
import re
import shutil
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(ROOT))
EXTENSION = os.path.join(ROOT, "Resources", "BrowserExtension")
APP = os.path.join(REPO, "build", "Sound Manager.app")
APP_BIN = os.path.join(APP, "Contents", "MacOS", "SoundManager")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
HTTP_PORT = 8765
APP_PORT = 47899

PAGES = {
    "media.html": "<!doctype html><title>Media test</title><audio id=a src=tone.wav loop autoplay></audio>"
                  "<script>const a=document.getElementById('a');a.volume=1;a.play().catch(e=>document.title='blocked');</script>",
    "preexisting.html": "<!doctype html><title>Preexisting</title><audio id=a src=tone.wav loop></audio>",
    "webaudio.html": "<!doctype html><title>WebAudio test</title><script>"
                     "const c=new AudioContext(),o=c.createOscillator(),g=c.createGain();"
                     "g.gain.value=0.05;o.frequency.value=330;o.connect(g);g.connect(c.destination);o.start();</script>",
}


class FakeApp:
    def __init__(self):
        self.sessions = {}
        self.origin = None
        self.lock = threading.Lock()

    def serve(self):
        server = socket.socket()
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", APP_PORT))
        server.listen()
        while True:
            conn, _ = server.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        request = b""
        while b"\r\n\r\n" not in request:
            request += conn.recv(4096)
        headers = {}
        for line in request.decode().split("\r\n")[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                headers[name.strip().lower()] = value.strip()
        accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + WS_GUID).encode()).digest()).decode()
        conn.sendall(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n".encode())
        origin = headers.get("origin")
        with self.lock:
            self.sessions[origin] = {"conn": conn, "hello": None, "tabs": []}
        while True:
            frame = self.read_frame(conn)
            if frame is None:
                return
            opcode, payload = frame
            if opcode == 8:
                return
            if opcode == 1:
                message = json.loads(payload)
                with self.lock:
                    if message.get("type") == "hello":
                        self.sessions[origin]["hello"] = message
                    elif message.get("type") == "tabs":
                        self.sessions[origin]["tabs"] = message["tabs"]

    @staticmethod
    def read_frame(conn):
        def recv_exact(count):
            data = b""
            while len(data) < count:
                chunk = conn.recv(count - len(data))
                if not chunk:
                    raise ConnectionError
                data += chunk
            return data
        try:
            head = recv_exact(2)
            length = head[1] & 0x7F
            if length == 126:
                length = struct.unpack(">H", recv_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", recv_exact(8))[0]
            mask = recv_exact(4) if head[1] & 0x80 else b"\0\0\0\0"
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(recv_exact(length)))
            return head[0] & 0x0F, payload
        except (ConnectionError, OSError):
            return None

    def send(self, message):
        payload = json.dumps(message).encode()
        header = bytes([0x81, len(payload)]) if len(payload) < 126 else bytes([0x81, 126]) + struct.pack(">H", len(payload))
        self.sessions[self.origin]["conn"].sendall(header + payload)

    def hello(self):
        with self.lock:
            return (self.sessions.get(self.origin) or {}).get("hello")

    def tab(self, url_part):
        with self.lock:
            tabs = (self.sessions.get(self.origin) or {}).get("tabs", [])
            return next((tab for tab in tabs if url_part in tab["url"]), None)


class Chrome:
    def __init__(self):
        self.profile = tempfile.mkdtemp(prefix="soundmanager-e2e-")
        chrome_reads, self.writer = os.pipe()
        self.reader, chrome_writes = os.pipe()
        os.dup2(chrome_reads, 100)
        os.dup2(chrome_writes, 101)
        args = [
            "--headless=new", f"--user-data-dir={self.profile}", "--remote-debugging-pipe",
            "--enable-unsafe-extension-debugging", "--autoplay-policy=no-user-gesture-required",
            "--no-first-run", "--no-default-browser-check", "about:blank",
        ]
        self.process = subprocess.Popen(
            ["/bin/sh", "-c", 'exec "$0" "$@" 3<&100 4>&101 100<&- 101>&-', CHROME, *args],
            pass_fds=(100, 101), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        os.close(100)
        os.close(101)
        self.next_id = 0
        self.buffer = b""

    def call(self, method, session=None, **params):
        self.next_id += 1
        message = {"id": self.next_id, "method": method, "params": params}
        if session:
            message["sessionId"] = session
        os.write(self.writer, json.dumps(message).encode() + b"\0")
        while True:
            while b"\0" not in self.buffer:
                self.buffer += os.read(self.reader, 65536)
            raw, self.buffer = self.buffer.split(b"\0", 1)
            message = json.loads(raw)
            if message.get("id") == self.next_id:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message["result"]

    def close(self):
        self.process.terminate()
        self.process.wait(timeout=10)
        shutil.rmtree(self.profile, ignore_errors=True)


def write_site(directory):
    for name, html in PAGES.items():
        with open(os.path.join(directory, name), "w") as file:
            file.write(html)
    with wave.open(os.path.join(directory, "tone.wav"), "wb") as tone:
        tone.setnchannels(2)
        tone.setsampwidth(2)
        tone.setframerate(48000)
        frames = bytearray()
        for i in range(48000 * 2):
            value = int(0.05 * 32767 * math.sin(2 * math.pi * 440 * i / 48000))
            frames += struct.pack("<hh", value, value)
        tone.writeframes(bytes(frames))


def serve_site(directory):
    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    handler = functools.partial(QuietHandler, directory=directory)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def wait_for(predicate, timeout, label):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    raise TimeoutError(label)


def playing_helper(chrome_pid):
    output = subprocess.run([APP_BIN, "--list-audio"], capture_output=True, text=True).stdout
    for line in output.splitlines():
        pid, parent, _responsible, _bundle, state = line.split()
        if int(parent) == chrome_pid and state == "playing":
            return int(pid)
    return None


def has_sound(tab):
    return bool(tab) and (tab["audible"] or ((tab["muted"] or tab["volume"] < 1) and tab.get("playing") is True))


def measure(helper_pid, phases, log_path, snapshot):
    subprocess.run(["open", "-n", APP, "--stderr", log_path, "--args", "--selftest", str(helper_pid), "0", "--seconds", str(len(phases) * 3 + 2)])
    wait_for(lambda: os.path.exists(log_path) and "raw=" in open(log_path).read(), 15, "selftest start")
    marks = []
    states = {}
    for label, action in phases:
        action()
        marks.append((label, time.time()))
        time.sleep(3)
        states[label] = snapshot()
    marks.append(("end", time.time()))
    time.sleep(1.5)
    samples = []
    for line in open(log_path):
        match = re.match(r"selftest (\d+\.\d): raw=(\d+\.\d+)", line)
        if match:
            samples.append((float(match.group(1)), float(match.group(2))))
    results = {}
    for (label, start), (_, end) in zip(marks, marks[1:]):
        window = [raw for stamp, raw in samples if start + 1 <= stamp <= end]
        results[label] = (statistics.median(window) if window else None, states[label])
    return results


def visibility_scenario(chrome, app, site):
    page = "media.html"
    target = chrome.call("Target.createTarget", url=f"http://127.0.0.1:{HTTP_PORT}/{page}?visibility")["targetId"]
    session = chrome.call("Target.attachToTarget", targetId=target, flatten=True)["sessionId"]
    tab = wait_for(lambda: (t := app.tab("visibility")) and t["audible"] and t, 15, "visibility tab audible")
    helper = wait_for(lambda: playing_helper(chrome.process.pid), 10, "audio helper")
    evaluate = lambda expression: chrome.call("Runtime.evaluate", session=session, expression=expression)
    send = lambda message: app.send({**message, "tabId": tab["id"]})
    print(f"\n[Visibilidade] tab {tab['id']}")
    phases = [
        ("volume 100%", lambda: None),
        ("volume 0%", lambda: send({"type": "setVolume", "volume": 0})),
        ("volume 30%", lambda: send({"type": "setVolume", "volume": 0.3})),
        ("pausado", lambda: evaluate("document.getElementById('a').pause()")),
        ("play de novo", lambda: evaluate("document.getElementById('a').play()")),
    ]
    results = measure(helper, phases, os.path.join(site, "visibility.log"), lambda: app.tab("visibility"))
    for label, (level, state) in results.items():
        print(f"  {label:13} raw={level} audible={state['audible']} playing={state.get('playing')} volume={state['volume']} -> aparece={has_sound(state)}")
    failures = []
    base = results["volume 100%"][0] or 0
    expected = {"volume 100%": True, "volume 0%": True, "volume 30%": True, "pausado": False, "play de novo": True}
    for label, visible in expected.items():
        if has_sound(results[label][1]) != visible:
            failures.append(f"visibility: '{label}' should {'show' if visible else 'hide'}")
    if not base or results["volume 0%"][0] > base * 0.01:
        failures.append("visibility: 0% phase not silent")
    if base and abs(results["play de novo"][0] / base - 0.3) > 0.05:
        failures.append(f"visibility: resumed ratio {results['play de novo'][0] / base:.2f}, expected 0.30")
    chrome.call("Target.closeTarget", targetId=target)
    return failures


def extension_copy(directory):
    copy = os.path.join(directory, "extension")
    shutil.copytree(EXTENSION, copy)
    background = os.path.join(copy, "background.js")
    source = open(background).read()
    assert "ws://127.0.0.1:47821" in source
    open(background, "w").write(source.replace("ws://127.0.0.1:47821", f"ws://127.0.0.1:{APP_PORT}"))
    return copy


def preexisting_scenario(chrome, app, site, target, extension):
    session = chrome.call("Target.attachToTarget", targetId=target, flatten=True)["sessionId"]
    chrome.call("Runtime.evaluate", session=session, expression="document.getElementById('a').play()")
    tab = wait_for(lambda: (t := app.tab("preexisting")) and t["audible"] and t.get("playing") is True and t, 15, "preexisting tab playing")
    helper = wait_for(lambda: playing_helper(chrome.process.pid), 10, "audio helper")
    send = lambda message: app.send({**message, "tabId": tab["id"]})
    print(f"\n[Aba aberta antes da extensão] tab {tab['id']} playing={tab['playing']}")
    phases = [
        ("volume 100%", lambda: None),
        ("volume 0%", lambda: send({"type": "setVolume", "volume": 0})),
        ("extensão recarregada", lambda: chrome.call("Extensions.loadUnpacked", path=extension)),
    ]
    results = measure(helper, phases, os.path.join(site, "preexisting.log"), lambda: app.tab("preexisting"))
    for label, (level, state) in results.items():
        print(f"  {label:21} raw={level} audible={state['audible']} playing={state.get('playing')} volume={state['volume']} -> aparece={has_sound(state)}")
    failures = []
    base = results["volume 100%"][0] or 0
    if not has_sound(results["volume 0%"][1]):
        failures.append("preexisting: tab at 0% should stay visible")
    if not base or results["volume 0%"][0] > base * 0.01:
        failures.append("preexisting: 0% phase not silent")
    reloaded_level, reloaded_state = results["extensão recarregada"]
    if not base or abs(reloaded_level / base - 1) > 0.05 or reloaded_state["volume"] != 1 or not has_sound(reloaded_state):
        failures.append("preexisting: extension reload should restore the tab to 100% and keep it visible")
    return failures


def main():
    site = tempfile.mkdtemp(prefix="soundmanager-site-")
    write_site(site)
    extension = extension_copy(site)
    serve_site(site)
    app = FakeApp()
    threading.Thread(target=app.serve, daemon=True).start()
    chrome = Chrome()
    failures = []
    try:
        preexisting = chrome.call("Target.createTarget", url=f"http://127.0.0.1:{HTTP_PORT}/preexisting.html")["targetId"]
        time.sleep(1)
        extension_id = chrome.call("Extensions.loadUnpacked", path=extension)["id"]
        print("extension loaded:", extension_id)
        app.origin = f"chrome-extension://{extension_id}"
        hello = wait_for(app.hello, 15, "hello from extension")
        print("origin:", app.origin, "| brands:", hello.get("brands"))

        for page, check in (("media.html", "HTMLMediaElement"), ("webaudio.html", "Web Audio")):
            target = chrome.call("Target.createTarget", url=f"http://127.0.0.1:{HTTP_PORT}/{page}")["targetId"]
            tab = wait_for(lambda: (t := app.tab(page)) and t["audible"] and t, 15, f"{page} audible")
            helper = wait_for(lambda: playing_helper(chrome.process.pid), 10, "audio helper")
            print(f"\n[{check}] tab {tab['id']} audible, audio helper pid {helper}")
            send = lambda *messages: [app.send({**message, "tabId": tab["id"]}) for message in messages]
            phases = [
                ("volume 100%", lambda: None),
                ("volume 30%", lambda: send({"type": "setVolume", "volume": 0.3})),
                ("muted", lambda: send({"type": "setMuted", "muted": True})),
                ("restored", lambda: send({"type": "setMuted", "muted": False}, {"type": "setVolume", "volume": 1})),
            ]
            results = measure(helper, phases, os.path.join(site, f"{page}.log"), lambda: app.tab(page))
            levels = {label: level for label, (level, _) in results.items()}
            for label, level in levels.items():
                print(f"  {label:12} raw peak = {level}")
            base = levels["volume 100%"] or 0
            if not base:
                failures.append(f"{check}: no baseline audio")
            else:
                if abs(levels["volume 30%"] / base - 0.3) > 0.05:
                    failures.append(f"{check}: 30% phase ratio {levels['volume 30%'] / base:.2f}")
                if levels["muted"] > base * 0.01:
                    failures.append(f"{check}: muted phase not silent")
                if abs(levels["restored"] / base - 1) > 0.05:
                    failures.append(f"{check}: restore ratio {levels['restored'] / base:.2f}")
            chrome.call("Target.closeTarget", targetId=target)
            time.sleep(1)

        failures += visibility_scenario(chrome, app, site)
        failures += preexisting_scenario(chrome, app, site, preexisting, extension)
    finally:
        chrome.close()
        shutil.rmtree(site, ignore_errors=True)
    print("\nFAIL:\n- " + "\n- ".join(failures) if failures else "\nPASS")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
