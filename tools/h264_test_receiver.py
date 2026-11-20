#!/usr/bin/env python3
"""Stage 1 test receiver — the far end of the phone's h264 send (spec §6.6).

Mirror of h264_test_sender.py: that script plays the milestone-2 SENDER at a
listening phone; this one plays the RECEIVING phone at a milestone-2 sender.
It LISTENS (TCP 4853), the phone connects and pushes framing v1
    u32 big-endian length ++ Annex-B payload (start code(s) included),
and the shim strips the prefixes, walks the start codes for per-NAL stats,
and feeds the raw Annex-B to ffmpeg (`-f h264` → null sink) so a climbing
`frame=` counter — and the absence of decode warnings — is the validation.

Guards are the SPEC's guards, verbatim (§6.6 failure discipline), because
this tool's job includes proving the phone never trips them:
  - length outside (0, 2 MiB]: the framing itself is lost and a
    length-prefixed stream cannot resync — drop the CONNECTION, keep the
    listener.
  - a payload that scans to more than 64 NAL units: lost framing wearing a
    valid length — drop the connection.
  - a payload with no start code: skipped (throttled log), connection lives.
  - 4 s of silence: sender presumed dead — connection closed, re-accept.
Senders are served SERIALLY, one at a time (the phone's own listener rule):
a second connect() succeeds into the kernel backlog and simply waits.
Every accepted connection gets a FRESH ffmpeg — the receiving phone starts a
fresh decoder per connection, and the sender's contract (SPS/PPS first, IDR
before P-frames) is only proven if the decoder here is equally amnesiac.

Needs ffmpeg on PATH for decode validation (same probe as the sender:
`ffmpeg` then `ffmpeg.exe`); without it — or with --no-decode — the framing
parse and stats still run, which already proves the wire format.

Usage:
    python3 tools/h264_test_receiver.py [--port 4853] [--bind 0.0.0.0]
        [--no-decode] [--dump out.h264]

--dump appends the stripped Annex-B to a file; `ffplay -f h264 out.h264`
afterwards is how you eyeball the burned SEQ/wallclock stamp at leisure.
"""
import argparse
import shutil
import socket
import struct
import subprocess
import sys
import time

# Line-buffer stdout even when redirected: a per-second stats line that only
# shows up at exit is useless for watching a live smoke test through tee.
sys.stdout.reconfigure(line_buffering=True)

MAX_PAYLOAD = 2 * 1024 * 1024   # spec §6.6: beyond this the framing is lost
MAX_NALS_PER_PAYLOAD = 64       # §6.6: wall-to-wall start codes = lost framing
IDLE_TIMEOUT = 4.0              # §6.6: this much silence = sender presumed dead

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--port", type=int, default=4853)
parser.add_argument("--bind", default="0.0.0.0",
                    help="listen address (default every interface — WSL "
                         "mirrored networking needs 0.0.0.0 to be reachable "
                         "on the host's LAN ip)")
parser.add_argument("--no-decode", action="store_true",
                    help="framing parse + stats only, no ffmpeg")
parser.add_argument("--dump", default=None, metavar="FILE",
                    help="append the stripped Annex-B here (ffplay later)")
args = parser.parse_args()

ffmpeg = None
if not args.no_decode:
    ffmpeg = shutil.which("ffmpeg") or shutil.which("ffmpeg.exe")
    if not ffmpeg:
        print("no ffmpeg on PATH — running parse-only (framing still proven)")

# Totals survive across connections: the phone's 2 s redial makes reconnects
# normal traffic, and the final line should tell the whole session's story.
rx_bytes = 0        # wire bytes incl. the 4-byte prefixes, matching the sender
rx_payloads = 0
rx_nals = 0
rx_frames = 0       # VCL NALs (types 1/5) — one per frame while the phone's
                    # encoder emits one slice per frame (MediaCodec's habit;
                    # the sender counts the same way, so tx and rx lines match)
rx_idr = 0
rx_sps = 0
rx_conns = 0
no_start_code = 0   # skipped payloads (throttled log)
win_start = time.monotonic()
win_bytes = 0
win_frames = 0

dump = open(args.dump, "ab") if args.dump else None


def nal_types(payload: bytes) -> list:
    # Walk Annex-B start codes and return each NAL's type. The sender glues
    # SPS+PPS ahead of every IDR in ONE payload (§6.6 tolerates whole access
    # units), so a payload is 1..n NALs — the walk, not the payload count, is
    # what the per-NAL stats trust.
    out = []
    i = 0
    n = len(payload)
    while i < n - 3:
        if payload[i] == 0 and payload[i + 1] == 0:
            if payload[i + 2] == 1:
                j = i + 3
            elif payload[i + 2] == 0 and i < n - 4 and payload[i + 3] == 1:
                j = i + 4
            else:
                i += 1
                continue
            if j < n:
                out.append(payload[j] & 0x1F)
            i = j
        else:
            i += 1
    return out


def recv_exact(conn: socket.socket, n: int) -> bytes:
    # Returns exactly n bytes or raises; a clean FIN mid-read is ConnectionError
    # (the caller treats every exit the same way: drop connection, re-accept).
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(min(65536, n - len(buf)))
        if not chunk:
            raise ConnectionError("sender closed the connection")
        buf += chunk
    return bytes(buf)


def start_decoder():
    # Fresh ffmpeg per connection (see module docstring). -stats keeps the
    # climbing frame= line visible at -loglevel warning; decode errors land
    # on the same inherited stderr. Writes into its stdin can in principle
    # block, but null-sink 720p decode runs far faster than realtime — this
    # is a test rig, not the phone's drop-never-buffer path.
    return subprocess.Popen(
        [ffmpeg, "-hide_banner", "-loglevel", "warning", "-stats",
         "-fflags", "nobuffer", "-flags", "low_delay",
         "-f", "h264", "-i", "-", "-f", "null", "-"],
        stdin=subprocess.PIPE)


def stop_decoder(proc) -> None:
    if proc is None:
        return
    # Close stdin FIRST: EOF is what lets ffmpeg drain and print its final
    # frame count; terminate is only the impatient fallback.
    try:
        proc.stdin.close()
    except OSError:
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def tick_stats() -> None:
    global win_start, win_bytes, win_frames
    now = time.monotonic()
    el = now - win_start
    if el >= 1.0:
        print("rx %2.0ffps %4.1fMb  nal=%d idr=%d sps=%d  total %d frames %.1f MB"
              % (win_frames / el, win_bytes * 8.0 / el / 1e6,
                 rx_nals, rx_idr, rx_sps, rx_frames, rx_bytes / 1e6))
        win_start = now
        win_bytes = 0
        win_frames = 0


def serve(conn: socket.socket, peer: str) -> None:
    global rx_bytes, rx_payloads, rx_nals, rx_frames, rx_idr, rx_sps
    global win_bytes, win_frames, no_start_code
    proc = start_decoder() if ffmpeg else None
    try:
        while True:
            try:
                prefix = recv_exact(conn, 4)
                length = struct.unpack(">I", prefix)[0]
                if not (0 < length <= MAX_PAYLOAD):
                    print("%s: length %d outside (0, 2 MiB] — framing lost, "
                          "dropping connection" % (peer, length))
                    return
                payload = recv_exact(conn, length)
            except socket.timeout:
                print("%s: silent for %.0f s — presumed dead, re-accepting"
                      % (peer, IDLE_TIMEOUT))
                return
            except ConnectionError as e:
                print("%s: %s" % (peer, e))
                return

            types = nal_types(payload)
            if len(types) > MAX_NALS_PER_PAYLOAD:
                print("%s: %d NALs in one payload — lost framing wearing a "
                      "valid length, dropping connection" % (peer, len(types)))
                return
            if not types:
                no_start_code += 1
                if no_start_code == 1 or no_start_code % 100 == 0:
                    print("%s: payload without start code, skipped (%d so far)"
                          % (peer, no_start_code))
                continue

            rx_payloads += 1
            rx_bytes += length + 4
            win_bytes += length + 4
            rx_nals += len(types)
            for t in types:
                if t in (1, 5):
                    rx_frames += 1
                    win_frames += 1
                    if t == 5:
                        rx_idr += 1
                elif t == 7:
                    rx_sps += 1

            if dump is not None:
                dump.write(payload)
            if proc is not None:
                try:
                    proc.stdin.write(payload)
                except (BrokenPipeError, OSError):
                    # ffmpeg died (its stderr already said why) — keep the
                    # framing stats running; the parse is evidence on its own.
                    stop_decoder(proc)
                    proc = None

            tick_stats()
    finally:
        stop_decoder(proc)
        conn.close()


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((args.bind, args.port))
srv.listen(1)   # serial accept — extras wait in the backlog, the phone's rule
print("listening on %s:%d — start the phone's stream now (Ctrl-C to stop)"
      % (args.bind, args.port))

try:
    while True:
        conn, addr = srv.accept()
        conn.settimeout(IDLE_TIMEOUT)
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        rx_conns += 1
        print("sender connected from %s:%d (connection %d%s)"
              % (addr[0], addr[1], rx_conns,
                 " — fresh decoder" if ffmpeg else ", parse-only"))
        serve(conn, "%s:%d" % addr)
except KeyboardInterrupt:
    pass
finally:
    srv.close()
    if dump is not None:
        dump.close()
    print("received %d frames (%d IDR), %d NALs, %d payloads, %.1f MB, "
          "%d connection(s)"
          % (rx_frames, rx_idr, rx_nals, rx_payloads, rx_bytes / 1e6, rx_conns))
