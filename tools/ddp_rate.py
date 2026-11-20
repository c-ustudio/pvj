#!/usr/bin/env python3
"""Measure the GENERATION rate from the DDP stream.

The panel is fed at send_fps regardless of how often the simulation advances,
so most frames are duplicates. Counting DISTINCT consecutive frames over a
known wall-clock window gives generations/second directly — which is what
verifies a beat-locked clock, since at 90 BPM and 4 gens/beat the answer must
be 6.0/s and at 2/beat it must be 3.0/s.
"""
import hashlib
import socket
import sys
import time

SECS = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
FRAME_BYTES = 64 * 64 * 3

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 4048))
s.settimeout(3.0)

buf = bytearray(FRAME_BYTES)
frames = 0
changes = 0
last = None
t0 = None

while True:
    try:
        data, _ = s.recvfrom(2048)
    except socket.timeout:
        break
    if len(data) < 10 or data[3] in (250, 251):
        continue
    off = int.from_bytes(data[4:8], "big")
    ln = int.from_bytes(data[8:10], "big")
    if off + ln <= FRAME_BYTES:
        buf[off:off + ln] = data[10:10 + ln]
    if data[0] & 0x01:                       # PUSH: frame complete
        if t0 is None:
            t0 = time.monotonic()
        frames += 1
        h = hashlib.md5(bytes(buf)).digest()
        if last is not None and h != last:
            changes += 1
        last = h
        if time.monotonic() - t0 >= SECS:
            break

el = (time.monotonic() - t0) if t0 else 0.0
if el > 0:
    print(f"window   {el:.1f}s")
    print(f"frames   {frames}  ({frames/el:.1f} fps sent)")
    print(f"distinct {changes}  -> {changes/el:.2f} generations/sec")
else:
    print("no frames received")
