#!/usr/bin/env python3
"""Query the LED panel's DDP status channel (device 251) and print the JSON.

Replicates ddp_output.gd:build_control_header(DDP_ID_STATUS, 0, query=true):
  flags = 0x40 (ver1) | 0x02 (query) = 0x42, sequence 0, data type 0 (JSON,
  not pixels), device id 251, offset 0, length 0. 10 bytes, no payload.
"""
import json
import socket
import sys

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.50"
PORT = 4048
REPEATS = int(sys.argv[2]) if len(sys.argv) > 2 else 1

QUERY = bytes([0x42, 0, 0, 251, 0, 0, 0, 0, 0, 0])

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("", 0))          # must bind to receive, same trap the spec flags
s.settimeout(2.0)

for i in range(REPEATS):
    s.sendto(QUERY, (HOST, PORT))
    try:
        data, addr = s.recvfrom(2048)
    except socket.timeout:
        print(f"[{i}] TIMEOUT — no reply from {HOST}:{PORT}")
        continue
    if len(data) < 10:
        print(f"[{i}] short packet ({len(data)} bytes) from {addr}")
        continue
    flags, seq, dtype, dev = data[0], data[1], data[2], data[3]
    body = data[10:]
    try:
        parsed = json.loads(body.decode("utf-8", "replace"))
        pretty = json.dumps(parsed, sort_keys=True)
    except Exception:
        pretty = repr(body[:200])
    print(f"[{i}] from {addr[0]} flags=0x{flags:02x} dev={dev} len={len(body)}")
    print(f"     {pretty}")
