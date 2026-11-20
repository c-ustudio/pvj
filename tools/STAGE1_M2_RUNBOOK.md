# Stage 1 milestone 2 runbook — P8 → PC, the phone's first H.264 send

The mirror of M1: there the PC pushed framing v1 at a listening phone; here
the PHONE is the sender (spec §6.6 send side, landed `dd08e86`/`fb1acd6`) and
WSL is the far end, listening with `tools/h264_test_receiver.py`. A start
verb over TCP 4850 with `codec:"h264"` and the empty-ip rule (§6.4) makes
the P8 aim its stream 0 — the composited output, through MediaCodec — back
at whoever asked. Everything is reversible from the shell (§7, rollback).

Same rig facts as M1 (STAGE1_M1_RUNBOOK.md has the long versions): Linux adb
only, wireless only, the adb serial of a TCP device IS its `ip:port`, and
identity comes from `getprop ro.product.model`, never from an address.

| | USB serial (identity) | IP | role here |
|---|---|---|---|
| Pixel 8 | `<P8-serial>` | <P8-ip> | SENDER (the phone under test) |
| Pixel 9a | `<9a-serial>` | <9a-ip> | not needed for this smoke |
| this box | — | <PC-ip> | receiver (WSL, mirrored networking) |

## 1. Export and install

Identical to M1 — follow STAGE1_M1_RUNBOOK.md §1–2 verbatim (export with the
Windows-path invocation, validate the zip, `adb install -r`, and the
`adb nodaemon server` recovery if `adb devices` hangs after the export).
The APK must postdate `dd08e86` — that commit is the send half of the
plugin; an M1-era APK carries the singleton but refuses `start_send` (§5
below shows exactly how that refusal looks, on screen and in logcat).

```bash
adb connect <P8-ip>:<port>
D=<P8-ip>:<port>
adb -s $D shell getprop ro.product.model   # must say "Pixel 8"
adb -s $D install -r build/PocketVJ.apk    # -r keeps app data = settings.cfg
```

## 2. Seed `[link] codec="h264"` on the P8

Honesty first: the SEND codec does not come from this setting — it rides
the start verb, per-destination (§6.4), so the send smoke would run with
the phone still on jpeg. The seed is here because (a) the beacon then
advertises the *effective* codec, which is the cheapest pre-flight proof
the APK carries the plugin at all — check it before blaming the network —
and (b) it puts the phone in full Stage 1 posture (receive door on 4853
too), the exact configuration the §9-M7 mirror rematch runs in.

Same base64 run-as dance as M1 §3 (the app rewrites `files/settings.cfg`
on save, so force-stop first; `run-as` can't read `/sdcard`, so the edited
copy goes back in as base64):

```bash
adb -s $D shell am force-stop com.pocketvj.app
adb -s $D exec-out run-as com.pocketvj.app cat files/settings.cfg > /tmp/settings.cfg

grep -q '^codec=' /tmp/settings.cfg \
  && sed -i 's/^codec=.*/codec="h264"/' /tmp/settings.cfg \
  || sed -i '/^\[link\]/a codec="h264"' /tmp/settings.cfg
grep -A2 '^\[link\]' /tmp/settings.cfg     # eyeball it

B64=$(base64 -w0 /tmp/settings.cfg)
adb -s $D shell "run-as com.pocketvj.app sh -c 'echo $B64 | base64 -d > files/settings.cfg'"
adb -s $D shell run-as com.pocketvj.app md5sum files/settings.cfg
md5sum /tmp/settings.cfg                   # must match
```

`enabled=true` must be in `[link]` (it has been since the Session 26 mesh);
`debug_counter=true` too if you want the burned SEQ/clock stamp — it lives
in the capture SubViewport, upstream of the readback, so it rides h264
exactly as it rode jpeg (that's the M7-rematch measuring stick).

Relaunch:

```bash
adb -s $D shell am start --display 0 -n com.pocketvj.app/com.godot.game.GodotAppLauncher
```

Beacon pre-flight (M1 §4's listener one-liner) — wanted:
`PVJ1|<name>|main|h264|4853|4850`. A `jpeg|4851` line means the plugin is
missing from the APK; stop here and fix the export. Note the beacon proves
the singleton (its receive half binds 4853) — an M1-era APK passes this
check and still refuses the send, which is what §5's refusal flash is for.

## 3. Start the PC receiver — FIRST

The phone's plugin redials every 2 s while started, so a late receiver
heals — but receiver-first keeps the smoke deterministic and the phone's
logcat quiet. In WSL:

```bash
python3 tools/h264_test_receiver.py            # listens 0.0.0.0:4853
# add --dump m2.h264 to keep the Annex-B for ffplay/ffprobe afterwards
```

**Networking**: <PC-ip> is this box's LAN ip, and this WSL runs
mirrored networking (verified: `wslinfo --networking-mode` → `mirrored`,
and <PC-ip> sits on eth1 *inside* WSL) — so the 0.0.0.0 bind is
reachable at <PC-ip>:4853 from the LAN with no forwarding. What can
still eat the connection is the WINDOWS side: the Hyper-V firewall that
fronts mirrored WSL, plus the ordinary inbound firewall. If the phone's
logcat loops `connect to <PC-ip>:4853 failed ... retrying every 2 s`
while the receiver sits silent, that's the firewall — admin PowerShell:

```powershell
New-NetFirewallRule -DisplayName "PVJ h264 rx" -Direction Inbound -Protocol TCP -LocalPort 4853 -Action Allow
# mirrored-mode WSL traffic is additionally gated by the Hyper-V firewall:
Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow
```

(That GUID is WSL's fixed VMCreatorId.) Fallback if this box ever leaves
mirrored mode (NAT): the WSL address stops being LAN-visible entirely —
bridge it by hand and keep the firewall rule:

```powershell
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=4853 connectaddress=$(wsl hostname -I) connectport=4853
```

## 4. Trigger the phone's stream 0

A start verb over the control channel, TCP 4850 — newline-delimited JSON,
`ip` EMPTY per the §6.4 empty-ip rule: the phone substitutes the TCP
connection's far end, which from this WSL presents as <PC-ip>, so
the phone streams back at exactly the box that asked. From WSL:

```bash
python3 - <<'EOF'
import json, socket
s = socket.create_connection(("<P8-ip>", 4850), timeout=5)
s.sendall((json.dumps({"t": "start", "stream": 0, "ip": "", "port": 4853,
                       "fps": 24.0, "quality": 0.75,
                       "codec": "h264"}) + "\n").encode())
s.close()
EOF
```

(`quality` rides the verb but only the jpeg body reads it — the h264 body
encodes CBR at the fixed 4 Mbps of `NetSender.H264_BITRATE_BPS`. And no
port confusion: the P8 listens on ITS 4853 as a receiver while the plugin
connects OUT to ours from an ephemeral port — two sockets, no collision.)

## 5. Expected output

Receiver side, within ~2 s:

```
sender connected from <P8-ip>:<eph> (connection 1 — fresh decoder)
rx 24fps  4.1Mb  nal=28 idr=1 sps=1  total 25 frames 0.5 MB
```

— steady ~24 fps, ~4 Mb; `idr`/`sps` climb together, +1 per second (1 s
GOP, SPS+PPS glued ahead of every IDR per §6.6). ffmpeg's `frame=` counter
climbing on the same tty IS the decode validation; a decode warning spray
means the phone's framing or parameter-set discipline broke. With
`--dump`, eyeball the stream after the fact — the burned SEQ/clock stamp
must be in the picture if `debug_counter` was on:

```bash
ffprobe -f h264 -count_frames -show_streams m2.h264 | grep -E "nb_read_frames|width|height"
ffplay -f h264 m2.h264
```

Phone side:

- Status flash: `LINK SEND: STREAM 0 -> <PC-ip> (H264)`.
- Bottom bar: `LINK TX 24fps 4.1Mb rb<X> en<Y>` — `rb` is the 1280x720
  readback (the §9-M3 cost v1 accepts), `en` is the plugin's
  queueInput→output time. First hardware pass: record both numbers here.
- Logcat (both tags, as ever — `-s godot` alone silences the plugin):

```bash
adb -s $D logcat -d -s godot PocketVJVideoLink | grep -i "send\|encoder\|connect"
```

  wants `sending to TCP <PC-ip>:4853 (1280x720 @24.0, 4000000 bps)`,
  `encoder up: <codec>`, `connected to <PC-ip>:4853 — streaming`.

The two honest failure shapes:

- Flash `LINK SEND: H264 REFUSED (NO SEND PLUGIN?)` + logcat "plugin
  predates the send path" — an M1-era APK (it passed the §2 beacon check;
  only `start_send` is missing). Re-export.
- No flash refusal, receiver silent, logcat looping `connect ... failed`
  — the stream is nominally ACTIVE (a dead peer is a LOST layer that
  heals, never a failed start) and the phone is paying readback + encode
  into the redial. Fix the firewall (§3); it heals within 2 s, no re-ask
  needed.

## 6. Stop

Ctrl-C on the receiver is NOT a stop: the phone treats a dropped receiver
as an outage and redials every 2 s, paying 24 fps of readback + encode
while it does — on a phone that cannot charge. The real stop is the verb:

```bash
python3 - <<'EOF'
import json, socket
s = socket.create_connection(("<P8-ip>", 4850), timeout=5)
s.sendall((json.dumps({"t": "stop", "stream": 0}) + "\n").encode())
s.close()
EOF
```

The stop is scoped by the asker's address (same socket-truth as the
empty-ip rule), which matches the destination we registered — the phone
flashes `LINK SEND: STOPPED` and the TX row leaves the bottom bar. Then
Ctrl-C the receiver; its totals line is the session's tally.

## 7. Rollback — codec back to jpeg

Same §2 dance with `codec="jpeg"` (force-stop, sed, base64, md5sum,
relaunch). Confirm the beacon says `jpeg|4851` again and a 9a jpeg PULL
behaves exactly as before. Note the send smoke never depended on the seed
(the codec rode the verb), so this rollback is about the phone's
ADVERTISED receive posture, not about undoing the send path — a jpeg start
verb works before, during, and after.

## Known traps, collected

- Everything in M1's list still applies: battery vs wireless adb, `run-as
  ... ls | wc -l` lying, the lingering exporter starving the adb server.
- A second sender's connect() into the receiver "succeeds" and waits
  unseen in the kernel backlog (serial accept — the tool mirrors the
  phone's rule). If the rx line sits at 0 while a sender claims connected,
  ask who ELSE is streaming.
- The receiver's per-second line and ffmpeg's `frame=` progress share the
  tty; the rx line is the framing truth, `frame=` is the decode truth —
  they should agree to within a second's worth of frames.
- `wslinfo --networking-mode` before blaming the firewall: a Windows
  update has flipped networking modes before, and NAT mode makes
  <PC-ip>:4853 dead air without the §3 portproxy.
