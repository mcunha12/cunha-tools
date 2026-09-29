#!/usr/bin/env python3
"""Fake scrcpy 4.1 server for the Pair Screen pipeline test: serves Annex-B files with the real framing over TCP."""
import argparse
import socket
import struct
import sys
import threading
import time

CODEC_IDS = {"h264": 0x68323634, "h265": 0x68323635}
FLAG_CONFIG = 1 << 62
FLAG_KEY = 1 << 61


def log(message):
    print(f"[fake-server] {message}", flush=True)


def nal_units(data):
    starts = []
    i = 0
    n = len(data)
    while i + 2 < n:
        if data[i + 2] > 1:
            i += 3
        elif data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            starts.append(i + 3)
            i += 3
        else:
            i += 1
    units = []
    for k, start in enumerate(starts):
        end = starts[k + 1] - 3 if k + 1 < len(starts) else n
        while end > start and data[end - 1] == 0:
            end -= 1
        units.append(data[start:end])
    return units


def nal_info(codec, nal):
    if codec == "h265":
        kind = (nal[0] >> 1) & 0x3F
        return kind, kind in (32, 33, 34), kind < 32, 16 <= kind <= 21, kind < 32 and nal[2] & 0x80 != 0, kind == 40
    kind = nal[0] & 0x1F
    return kind, kind in (7, 8), 1 <= kind <= 5, kind == 5, 1 <= kind <= 5 and nal[1] & 0x80 != 0, False


def split_stream(codec, data):
    """Returns (config packet, [(access unit, is_key)]) like MediaCodec would emit."""
    config = []
    frames = []
    current = []
    has_vcl = False
    is_key = False
    seen_vcl = False
    for nal in nal_units(data):
        _, is_param, is_vcl, key, first_slice, suffix = nal_info(codec, nal)
        if is_param and not seen_vcl:
            config.append(nal)
            continue
        if has_vcl and ((is_vcl and first_slice) or (not is_vcl and not suffix)):
            frames.append((current, is_key))
            current, has_vcl, is_key = [], False, False
        current.append(nal)
        if is_vcl:
            has_vcl = seen_vcl = True
            is_key = is_key or key
    if current:
        frames.append((current, is_key))
    annexb = lambda nals: b"".join(b"\x00\x00\x00\x01" + n for n in nals)
    return annexb(config), [(annexb(nals), key) for nals, key in frames]


def send_packet(sock, flags, payload):
    sock.sendall(struct.pack(">QI", flags, len(payload)) + payload)


def read_control(sock, stop):
    names = {0: "keycode", 1: "text", 2: "touch", 3: "scroll", 4: "back_or_screen_on", 8: "get_clipboard", 9: "set_clipboard", 10: "display_power", 11: "rotate", 17: "reset_video"}
    buffer = b""
    count = 0
    while not stop.is_set():
        try:
            chunk = sock.recv(65536)
        except OSError:
            break
        if not chunk:
            break
        buffer += chunk
        while buffer:
            kind = buffer[0]
            size = {0: 14, 2: 32, 3: 21, 4: 2, 8: 2, 10: 2, 11: 1, 17: 1}.get(kind)
            if kind == 1:
                size = 5 + struct.unpack(">I", buffer[1:5])[0] if len(buffer) >= 5 else None
            elif kind == 9:
                size = 14 + struct.unpack(">I", buffer[10:14])[0] if len(buffer) >= 14 else None
            if size is None or len(buffer) < size:
                break
            message, buffer = buffer[:size], buffer[size:]
            count += 1
            detail = ""
            if kind == 0:
                action, code, repeat, meta = struct.unpack(">BIII", message[1:14])
                detail = f"action={action} keycode={code} repeat={repeat} meta={meta:#x}"
            elif kind == 1:
                detail = f"text={message[5:].decode()!r}"
            elif kind == 2:
                action, pointer, x, y, w, h, pressure, action_button, buttons = struct.unpack(">BQiiHHHII", message[1:32])
                detail = f"action={action} pointer={pointer:#x} pos={x},{y} screen={w}x{h} pressure={pressure:#x} action_button={action_button} buttons={buttons}"
            elif kind == 3:
                x, y, w, h, hs, vs, buttons = struct.unpack(">iiHHhhI", message[1:21])
                detail = f"pos={x},{y} screen={w}x{h} hscroll={hs * 16 / 32768:.3f} vscroll={vs * 16 / 32768:.3f}"
            elif kind == 4:
                detail = f"action={message[1]}"
            elif kind == 9:
                sequence, paste = struct.unpack(">QB", message[1:10])
                detail = f"paste={paste} text={message[14:].decode()!r}"
            elif kind == 10:
                detail = f"on={message[1]}"
            log(f"control {names.get(kind, kind)} {detail}")
    log(f"control: {count} mensagens recebidas")


def serve_round(server, args, streams, round_index):
    video, _ = server.accept()
    video.sendall(b"\x00")
    control, _ = server.accept()
    control.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    log(f"rodada {round_index}: cliente conectado")
    video.sendall(args.name.encode().ljust(64, b"\x00")[:64])
    if args.fail_first and round_index == 1:
        log("rodada 1: simulando encoder indisponível (fecha antes do codec id)")
        for s in (video, control):
            s.close()
        return
    video.sendall(struct.pack(">I", CODEC_IDS[args.codec]))
    stop = threading.Event()
    reader = threading.Thread(target=read_control, args=(control, stop), daemon=True)
    reader.start()

    start = time.monotonic()
    clipboard_sent = False
    sent = 0
    interval = 1 / args.fps
    try:
        for config, frames, width, height in streams:
            video.sendall(struct.pack(">III", 0x80000000, width, height))
            send_packet(video, FLAG_CONFIG, config)
            session_start = time.monotonic()
            for index, (payload, key) in enumerate(frames):
                pts = int(index * 1_000_000 / args.fps)
                send_packet(video, pts | (FLAG_KEY if key else 0), payload)
                sent += 1
                if args.clipboard and not clipboard_sent and time.monotonic() - start > args.clipboard_at:
                    text = args.clipboard.encode()
                    control.sendall(b"\x00" + struct.pack(">I", len(text)) + text)
                    clipboard_sent = True
                    log("clipboard do celular enviado")
                delay = session_start + (index + 1) * interval - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
            log(f"rodada {round_index}: sessão {width}x{height} enviada ({len(frames)} frames)")
        log(f"rodada {round_index}: FRAMES_ENVIADOS={sent}")
        if round_index < args.rounds:
            time.sleep(0.3)
        else:
            video.settimeout(args.linger)
            try:
                while video.recv(1):
                    pass
            except OSError:
                pass
    except (BrokenPipeError, ConnectionResetError):
        log(f"rodada {round_index}: cliente desconectou após {sent} frames")
    stop.set()
    for s in (video, control):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        s.close()
    reader.join(timeout=1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--codec", choices=CODEC_IDS, default="h265")
    parser.add_argument("--stream", action="append", required=True, help="file.h26x:WIDTHxHEIGHT, in order")
    parser.add_argument("--fps", type=float, default=60)
    parser.add_argument("--name", default="Fake Galaxy S25 Ultra")
    parser.add_argument("--clipboard")
    parser.add_argument("--clipboard-at", type=float, default=2.5)
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--linger", type=float, default=15)
    parser.add_argument("--fail-first", action="store_true", help="round 1 closes before the codec id, like a missing encoder")
    args = parser.parse_args()

    streams = []
    for item in args.stream:
        path, size = item.rsplit(":", 1)
        width, height = (int(v) for v in size.split("x"))
        config, frames = split_stream(args.codec, open(path, "rb").read())
        keys = sum(1 for _, key in frames if key)
        log(f"{path}: config {len(config)} bytes, {len(frames)} frames, {keys} key frames")
        streams.append((config, frames, width, height))

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.port))
    server.listen(2)
    log(f"ouvindo em 127.0.0.1:{args.port}")
    for round_index in range(1, args.rounds + 1):
        serve_round(server, args, streams, round_index)
    server.close()
    log("fim")


if __name__ == "__main__":
    sys.exit(main())
