# Stage 1 milestone 1 runbook — PC → P8, H.264 over framing v1

The first hardware pass of the Stage 1 receive path (spec §6.6, landed
`1a077fd`): the P8 listens on TCP **4853**, WSL pushes a stamped test pattern
at it with `tools/h264_test_sender.py`, and the LINK RX row plus the burned
SEQ counter say whether MediaCodec → ExternalTexture is real. Stage 0 stays
default; everything here is reversible from the shell (§6, rollback).

Devices (confirm identity with `getprop ro.product.model`, never by guessing
from an address). ⚠️ The USB serial is IDENTITY ONLY, never the `-s` handle:
this box is wireless-adb-only (WSL has no USB bus), and a TCP-connected
device's adb serial IS its `ip:port` string — `-s <P8-serial>` can never
match anything here.

| | USB serial (identity) | IP | role here |
|---|---|---|---|
| Pixel 8 | `<P8-serial>` | <P8-ip> | receiver (the phone under test) |
| Pixel 9a | `<9a-serial>` | <9a-ip> | not needed for M1 |

Use the LINUX adb only (`/usr/bin/adb`). Starting `adb.exe` from Windows
wedges the 5037 server — recovery costs a reconnect dance.

## 1. Export the APK

Gradle builds are already on (`export_presets.cfg: use_gradle_build=true`).
Godot wants WINDOWS paths for its own args:

```bash
"$GODOT" --headless \
  --path "C:\\path\\to\\pvj-source" \
  --export-debug "Android" "C:\\path\\to\\pvj-source\\build\\PocketVJ.apk"
```

~5 min. The Windows process is invisible to WSL `ps` — do NOT `pkill -f
Godot_v4.6.3` (the pattern matches the shell running it). Wait for the
command to return, then validate the zip:

```bash
cd /mnt/c/path/to/pvj-source
python3 -c "import zipfile; z=zipfile.ZipFile('build/PocketVJ.apk'); print(len(z.namelist()), z.testzip())"
```

(~500 entries, `None`.) If `adb devices` hangs afterwards, the lingering
export process is starving the adb server: kill the exporter by exact PID,
run `adb nodaemon server` as a background task, and `adb connect` the phone
again — a fresh server forgets wireless peers.

## 2. Install on the P8

```bash
adb connect <P8-ip>:<port>        # port rotates; scan if unknown (below)
D=<P8-ip>:<port>                  # the adb serial of a TCP device IS ip:port
adb -s $D shell getprop ro.product.model   # must say "Pixel 8"
adb -s $D install -r build/PocketVJ.apk    # -r keeps app data = settings.cfg
```

Port unknown and `adb mdns services` empty (it usually is on this box):

```bash
seq 30000 65536 | xargs -P 400 -I{} sh -c 'nc -z -w1 <P8-ip> {} 2>/dev/null && echo OPEN:{}'
```

`adb connect` each OPEN port; one succeeds, `adb disconnect` the rest.
Whichever `ip:port` stuck is `$D` — `adb devices` shows it verbatim.

## 3. Seed `[link] codec="h264"` (run-as, base64)

The app rewrites `files/settings.cfg` on save, so stop it first, then edit
the pulled copy and pipe it back — `run-as` can't read `/sdcard`, so the
content goes in as base64 (the Session 21 method):

```bash
adb -s $D shell am force-stop com.pocketvj.app
adb -s $D exec-out run-as com.pocketvj.app cat files/settings.cfg > /tmp/settings.cfg

# codec= only exists in [link]; replace it, or add it right under the header.
grep -q '^codec=' /tmp/settings.cfg \
  && sed -i 's/^codec=.*/codec="h264"/' /tmp/settings.cfg \
  || sed -i '/^\[link\]/a codec="h264"' /tmp/settings.cfg
grep -A2 '^\[link\]' /tmp/settings.cfg     # eyeball it

B64=$(base64 -w0 /tmp/settings.cfg)
adb -s $D shell "run-as com.pocketvj.app sh -c 'echo $B64 | base64 -d > files/settings.cfg'"
adb -s $D shell run-as com.pocketvj.app md5sum files/settings.cfg
md5sum /tmp/settings.cfg                   # must match
```

No `[link]` section at all means the app has never saved settings on this
install — launch it once, quit, re-pull. `enabled=true` should already be
there from tonight's mesh; if not, the settings panel's VIDEO LINK toggle
sets it at runtime.

## 4. Launch and confirm the phone opened the h264 door

```bash
adb -s $D shell am start --display 0 -n com.pocketvj.app/com.godot.game.GodotAppLauncher
```

(`monkey` launches onto whichever display has focus; `am start --display 0`
does not.) Two checks BEFORE sending:

**Beacon** — the phone advertises the *effective* codec. From WSL:

```bash
python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 4849)); s.settimeout(6)
print(s.recvfrom(256))"
```

Wanted: `PVJ1|<name>|<role>|h264|4853|4850`. Two other honest outcomes:

- `jpeg|4851` — the plugin fell back to Stage 0 (missing from the APK).
- `h264|0|4850` — the plugin is THERE but `listen()` failed: the effective
  codec is still h264, `recv_port` stayed 0. Port 4853 held by something
  else, or the ExternalTexture had no GL name — the log says which.

Either way, check the log with BOTH tags (GDScript prints under `godot`,
the Kotlin plugin under `PocketVJVideoLink` — `-s godot` alone silences
every plugin line, including the one that explains a refused port):

```bash
adb -s $D logcat -d -s godot PocketVJVideoLink \
  | grep -i "NetSource\|VideoLink\|SHADER ERROR\|bind\|decoder"
```

"plugin is missing — staying on jpeg" here means the APK didn't carry the
Kotlin plugin; "cannot bind TCP 4853" is the port squatter; a `SHADER
ERROR` means the OES layer shader died and the layer is silently a no-op
(freeze-not-black rules still make it LOOK alive).

## 5. Send

```bash
python3 tools/h264_test_sender.py --host <P8-ip>
```

Sender side, within ~2 s, once per second (first line ramps, then steady):

```
tx 24fps  3.1Mb  nal=42 idr=1  total 39 frames 0.6 MB
```

`connection refused` = the phone isn't listening on 4853: link disabled,
codec still jpeg, or app not in front. The sender exits on disconnect —
rerun it; the phone's listener re-accepts (new connection = fresh SPS/PPS,
which the sender always leads with).

Phone side:

- **Bottom bar:** `LINK RX 24fps 3.1Mb de<X> LIVE`, dim text (red = not
  LIVE). `de` is now MediaCodec's queueInput→output time — the first P8
  pass (2026-08-06) read 14.0–15.4 ms, top of Stage 0's de2.4–14.1 band,
  not the low single digits hoped for. Not a blocker; the M7 latency
  rematch judges glass-to-glass, and this number is on its list.
- **The layer:** testsrc2 color bars with `SEQ <n>` and a wallclock burned
  top-left, counting at 24/s. Alpha slider in the settings panel VIDEO LINK
  section if the layer isn't visible.
- **PULL is supposed to refuse** in h264 mode (all phone/TD senders still
  speak MJPEG until milestone 2) and auto-pull stands down silently. The PC
  sender pushes unbidden — no pull needed.

Capture for the notes: `adb -s $D exec-out screencap -p > m1.png` (add
`-d <id>` from `dumpsys display` if a cable is attached — multi-display
screencap without `-d` injects a warning line into the PNG).

Stop: Ctrl-C the sender. The phone's layer must FREEZE on the last frame
(not black), freshness LIVE → STALE → LOST over 2 s in the LINK row.

## 6. Rollback — codec back to jpeg

Same §3 dance with `codec="jpeg"` (force-stop, sed, base64, md5sum,
relaunch). Confirm the beacon says `jpeg|4851` again and a 9a PULL behaves
exactly like tonight — that IS the acceptance test for "a broken Stage 1
degrades to the Stage 0 that ran".

## Known traps, collected

- P8 battery: long sessions at load lose ~17%/hour and low battery silently
  drops wireless debugging (looks like a rotated port; isn't). Check the
  percentage before blaming the network.
- `run-as ... ls | wc -l` lies on these Pixels; `ls -la` or md5sum is truth.
- The sender's wallclock stamp is THIS machine's clock — cross-device skew
  means the M7 latency rematch still uses the mirror method (9a camera at
  the P8, both numbers from one clock), not this stamp against the phone's.
