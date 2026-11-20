#!/usr/bin/env python3
"""Receive DDP frames and write them out as PNGs — a stand-in for the panel.

Point PocketVJ's target_ip at this host and we see exactly the pixels the
LED panel would light, which is the one thing adb and the board's status
channel cannot show.

Reassembly mirrors the firmware: payload bytes land at their big-endian offset,
and the PUSH flag (0x01) on the last packet is what completes a frame.
"""
import socket
import sys
from PIL import Image

W = H = 64
FRAME_BYTES = W * H * 3
WANT = int(sys.argv[1]) if len(sys.argv) > 1 else 6
OUT = sys.argv[2] if len(sys.argv) > 2 else "panel"
SCALE = 8

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 4048))
s.settimeout(20.0)

buf = bytearray(FRAME_BYTES)
saved = 0
seen_from = set()
pkts = 0

while saved < WANT:
    try:
        data, addr = s.recvfrom(2048)
    except socket.timeout:
        print(f"TIMEOUT after {pkts} packets, {saved} frames")
        break
    if len(data) < 10:
        continue
    flags = data[0]
    dev = data[3]
    if dev in (250, 251):          # control channel, not pixels
        continue
    off = int.from_bytes(data[4:8], "big")
    ln = int.from_bytes(data[8:10], "big")
    payload = data[10:10 + ln]
    pkts += 1
    seen_from.add(addr[0])
    if off + len(payload) <= FRAME_BYTES:
        buf[off:off + len(payload)] = payload
    if flags & 0x01:               # PUSH — frame complete
        img = Image.frombytes("RGB", (W, H), bytes(buf))
        img.resize((W * SCALE, H * SCALE), Image.NEAREST).save(f"{OUT}_{saved}.png")
        lit = sum(1 for i in range(0, FRAME_BYTES, 3)
                  if buf[i] + buf[i + 1] + buf[i + 2] > 30)
        print(f"frame {saved}: from {addr[0]}  lit_px={lit}/{W*H}")
        saved += 1

print(f"done: {pkts} packets from {sorted(seen_from)}, {saved} frames written")
