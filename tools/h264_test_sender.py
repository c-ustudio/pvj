#!/usr/bin/env python3
"""Stage 1 test sender — speaks FRAMING v1 (VIDEO_LINK_SPEC.md §6.6) at a phone.

The phone LISTENS (TCP 4853); this script connects and pushes, exactly like the
milestone-2 senders will. ffmpeg does the encoding — testsrc2 moving pattern
with a burned frame counter + wallclock, low-latency H.264 (zerolatency, no
B-frames, SPS/PPS repeated on every IDR) as raw Annex-B on stdout — and the
shim here walks the start codes and puts each NAL unit on the wire as
    u32 big-endian length ++ one Annex-B NAL (start code included).

Needs ffmpeg on PATH (Linux `ffmpeg` or Windows `ffmpeg.exe`, checked in that
order). On this box: /usr/bin/ffmpeg 6.1.1. If absent: `sudo apt install
ffmpeg` (needs libx264 + drawtext, which the Ubuntu build has).

Latency shape, so the M7 rematch isn't measuring the test rig: a NAL's end is
only knowable when the NEXT start code arrives, and the next access unit is a
full frame interval away — so the tail NAL of every burst is flushed on a read
GAP (--gap-ms, default 8) instead. That is the shim's whole latency cost:
~8 ms, not ~42. The gamble is that ffmpeg writes each access unit in one
burst (it does, with zerolatency); a host-load stall mid-write would ship a
truncated NAL, which the receiver skips — one glitched frame, self-heals.

Usage:
    python3 tools/h264_test_sender.py --host <P8-ip> [--port 4853]
        [--fps 24] [--size 1280x720] [--bitrate-kbps 4000]
"""
import argparse
import os
import select
import shutil
import socket
import struct
import subprocess
import sys
import time

MAX_PAYLOAD = 2 * 1024 * 1024   # spec §6.6: beyond this the receiver drops us

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--host", required=True, help="the LISTENING phone's LAN IP")
parser.add_argument("--port", type=int, default=4853)
parser.add_argument("--fps", type=int, default=24)
parser.add_argument("--size", default="1280x720")
parser.add_argument("--bitrate-kbps", type=int, default=4000)
parser.add_argument("--gop", type=int, default=0, help="keyframe interval, 0 = 2*fps")
parser.add_argument("--gap-ms", type=float, default=8.0,
                    help="read gap that flushes a burst's tail NAL")
args = parser.parse_args()
gop = args.gop or args.fps * 2

ffmpeg = shutil.which("ffmpeg") or shutil.which("ffmpeg.exe")
if not ffmpeg:
    sys.exit("no ffmpeg on PATH (tried ffmpeg, ffmpeg.exe) — sudo apt install ffmpeg")

# Burned counter mirrors the Session 27 debug_counter recipe: big, outlined,
# survives compression. SEQ is the encoder's frame index; the wallclock line is
# THIS machine's clock (cross-device skew is why measurements use the mirror
# method, not this number directly).
vf = ("drawtext=text='SEQ %{n}':x=48:y=48:fontsize=96:"
      "fontcolor=white:borderw=6:bordercolor=black,"
      "drawtext=text='%{localtime}':x=48:y=168:fontsize=64:"
      "fontcolor=white:borderw=5:bordercolor=black")

# sliced-threads=0: zerolatency's default slicing splits each frame across N
# slice NALs (one per core) — legal on the wire, but one-slice-per-frame keeps
# the tx frame count honest and gives the decoder whole frames per NAL.
# repeat-headers=1: SPS/PPS ride along with every IDR (§6.6 "ideally per IDR").
# scenecut=0: testsrc2's hard pattern changes must not spray surprise IDRs
# through the bitrate budget. VBV = 2 frames, so a burst can't queue behind
# the socket.
cmd = [
    ffmpeg, "-hide_banner", "-loglevel", "error",
    # -re: lavfi is not a realtime source — without it ultrafast 720p encodes
    # at several hundred fps and this becomes a throughput test, not a latency
    # rig (and the burned wallclock detaches from the wall).
    "-re", "-f", "lavfi", "-i", "testsrc2=size=%s:rate=%d" % (args.size, args.fps),
    "-vf", vf,
    "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
    "-bf", "0", "-g", str(gop),
    "-x264-params", "sliced-threads=0:scenecut=0:repeat-headers=1",
    "-b:v", "%dk" % args.bitrate_kbps,
    "-maxrate", "%dk" % args.bitrate_kbps,
    "-bufsize", "%dk" % max(1, args.bitrate_kbps * 2 // args.fps),
    "-pix_fmt", "yuv420p", "-an",
    "-f", "h264", "-",
]

sock = socket.create_connection((args.host, args.port), timeout=5.0)
sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)  # frames, not batches
sock.settimeout(None)
print("connected to %s:%d — starting ffmpeg" % (args.host, args.port))

proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)   # stderr inherits the tty
fd = proc.stdout.fileno()

buf = bytearray()
tx_bytes = 0        # wire bytes incl. the 4-byte prefixes, same as RX kbps counts
tx_nals = 0
tx_frames = 0       # VCL NALs (types 1/5) — one per frame, per sliced-threads=0
tx_idr = 0
win_start = time.monotonic()
win_bytes = 0
win_frames = 0


def send_nal(nal: bytes) -> None:
    global tx_bytes, tx_nals, tx_frames, tx_idr, win_bytes, win_frames
    if not (0 < len(nal) <= MAX_PAYLOAD):
        return
    off = 4 if nal[:4] == b"\x00\x00\x00\x01" else 3
    if len(nal) <= off:
        return   # bare start code, no NAL header — nothing to say
    ntype = nal[off] & 0x1F
    sock.sendall(struct.pack(">I", len(nal)) + nal)
    tx_bytes += len(nal) + 4
    win_bytes += len(nal) + 4
    tx_nals += 1
    if ntype in (1, 5):
        tx_frames += 1
        win_frames += 1
        if ntype == 5:
            tx_idr += 1


def start_positions(b: bytearray) -> list:
    # Annex-B start codes; a 3-byte hit preceded by 0x00 is really a 4-byte
    # code, and the extra zero belongs to the NAL in front of it — back up one.
    out = []
    i = 0
    while True:
        j = b.find(b"\x00\x00\x01", i)
        if j < 0:
            return out
        out.append(j - 1 if j > 0 and b[j - 1] == 0 else j)
        i = j + 3


try:
    while True:
        ready, _, _ = select.select([fd], [], [], args.gap_ms / 1000.0)
        if ready:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break   # encoder exited; its stderr already said why
            buf += chunk
            starts = start_positions(buf)
            if starts and starts[0] > 0:
                del buf[:starts[0]]     # pre-start-code junk: impossible, but cheap
                starts = [s - starts[0] for s in starts]
            # Everything up to the LAST start code is complete NALs; the tail
            # NAL stays buffered until its terminator or the gap flush.
            for a, b in zip(starts, starts[1:]):
                send_nal(bytes(buf[a:b]))
            if len(starts) > 1:
                del buf[:starts[-1]]
        elif buf and (buf[:3] == b"\x00\x00\x01" or buf[:4] == b"\x00\x00\x00\x01"):
            # Read gap: the encoder finished its per-frame burst, so what's
            # buffered is one whole NAL — the frame's slice. Flush it now
            # rather than waiting ~42 ms for the next access unit.
            send_nal(bytes(buf))
            buf.clear()

        now = time.monotonic()
        el = now - win_start
        if el >= 1.0:
            print("tx %2.0ffps %4.1fMb  nal=%d idr=%d  total %d frames %.1f MB"
                  % (win_frames / el, win_bytes * 8.0 / el / 1e6,
                     tx_nals, tx_idr, tx_frames, tx_bytes / 1e6))
            win_start = now
            win_bytes = 0
            win_frames = 0
except (BrokenPipeError, ConnectionResetError):
    print("receiver closed the connection (codec back on jpeg? app gone?)")
except KeyboardInterrupt:
    pass
finally:
    # Close the pipe FIRST: an ffmpeg blocked in write() never services a
    # signal, and EPIPE is what actually unwedges it.
    proc.stdout.close()
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    sock.close()
    print("sent %d frames, %d NALs, %.1f MB" % (tx_frames, tx_nals, tx_bytes / 1e6))
