# VIDEO LINK — interconnect spec (phones ↔ phones ↔ TouchDesigner)

**Status: DESIGN — no code yet.** Written 2026-08-05 from a three-way research pass
(NDI/Android, Godot/Android video I/O, TouchDesigner stream I/O). Every load-bearing
claim below carries its source; things we have NOT verified on our own hardware are
in §9 as measurements that gate implementation.

This is the interconnectivity layer that precedes Sequencer 2.0: any device's video
output must be mixable into any other device, live.

---

## 1. What it must do

The three scenarios that define the feature (from the brief):

- **S1 — TD graphics into the main phone.** TouchDesigner renders a graphics layer;
  the main phone (Pixel 8, PocketVJ) receives it as a live texture and mixes it over
  its decks like any other layer.
- **S2 — camera phone into the main phone.** The second phone (Pixel 9a) runs
  PocketVJ in a camera-source mode; its feed arrives on the main phone as a live
  texture, mixable with decks/graphics.
- **S3 — phone into TD.** Either phone's output lands in TouchDesigner as a TOP,
  so TD can process/mix it and (optionally) send the result back — the full loop.

Generalized: **N sources, any-to-any, both directions.** Each PocketVJ instance can
be a sender, a receiver, or both; TD is a peer like any other.

### Requirements

| # | Requirement | Target |
|---|---|---|
| R1 | Glass-to-glass latency | ≤ 150 ms feels layered-live; ≤ 80 ms feels tight. Phone↔phone matters most (beat-synced mixing); TD→phone next; phone→TD is most tolerant (TD is usually the "big screen" end). |
| R2 | Bandwidth | Must fit real venue WiFi with **3 simultaneous streams** plus DDP plus control traffic. Assume ~50 Mbps usable until measured (§9-M1). |
| R3 | Setup friction | Phone side: zero-config — devices find each other on join, like the DDP board. TD side: drop in one .tox, no per-gig editing. |
| R4 | Coexistence | Phones keep doing their day job while streaming: decks decoding, effects, HDMI out, DDP out, audio analysis. The link cannot eat the frame budget. |
| R5 | Degrade gracefully | WiFi hiccup = stale frame or brief freeze on the *received layer only*. Never a hitch in the local deck pipeline. |

---

## 2. Topology and known facts

```
┌─────────────────┐   WiFi LAN 192.168.1.0/24  ┌──────────────────┐
│ TouchDesigner PC │◄──────────────────────────►│ Pixel 8 (main)   │──HDMI──► projector
│ <laptop-ip>      │                            │ PocketVJ decks    │
│ Windows          │◄──────────┐                └──────┬───────────┘
└─────────────────┘           │                        │ WiFi
                              │                 ┌──────▼───────────┐      ┌────────────┐
                              └────────────────►│ Pixel 9a (cam)   │      │ LED board  │
                                                │ PocketVJ camera   │      │ .50 (DDP)  │
                                                └──────────────────┘      └────────────┘
```

Facts already established in this project:

- Phone IPs move between sessions (the 8 has been .89, the 9a .228) — anything
  that hardcodes an IP fails R3. The DDP board taught us this.
- The AP is consumer-grade; wireless adb measured 2.4–2.7 MB/s (that is adb's
  ceiling, not the WiFi's — but it warns us not to assume hundreds of Mbps).
- One USB-C port per phone, occupied by HDMI at showtime → **no USB fallback
  during a show**; the link must be WiFi.
- PocketVJ already has a working "tap the output and ship it" architecture:
  `DdpOutput.set_source(output_world)` + the two-stage GPU downsample. The video
  link generalizes that tap, it does not invent a new one.
- Godot 4.6, renderer GL Compatibility / Vulkan (both must work).
- TD on the .197 machine — **verified 2026-08-05 via the tdmcp bridge**: build
  **2025.33070** (past the 2022.32230 SRT decoder fixes) on an **RTX 5080** →
  NVENC out and NVDEC in both available. The NVENC-only gate on Video Stream Out
  is cleared.
- TD is scriptable from this machine: the `tdmcp_bridge` component serves HTTP on
  port 9980 (bearer token, `TDMCP_BRIDGE_TOKEN`), so the .tox in §7 can be built
  and wired programmatically.

---

## 3. Transport survey — every way to do this, and the verdict on each

Ordered from "sounds obvious" to "actually right." Full sources in §10.

### 3.1 Full NDI — the obvious guess; wrong for the phones

- TD: native NDI In/Out TOPs, free, mature. Desktop Godot: `godot-ndi` GDExtension,
  actively maintained (releases through 2026-03), send *and* receive.
- **But:** full NDI at 1080p60 is ~150 Mbps *per stream* (official white paper).
  Two phone streams ≈ 300 Mbps through one consumer AP — does not fit (R2), and
  NDI "degrades ungracefully" on jittery links per Derivative's own docs (R5).
- **And:** `godot-ndi` ships **no Android binaries** — verified from its
  `.gdextension` and CI matrix. An Android port means building the NDI SDK into a
  Godot Android plugin *plus* mandatory `NsdManager` discovery glue that the NDI
  docs require the app to own; Unity's equivalent plugin reports Android 12+
  discovery as chronically unstable.
- **Verdict: NO for phone links. OPTIONAL for TD↔desktop later** (if a laptop
  Godot instance ever joins, godot-ndi works there today).

### 3.2 NDI|HX — right bitrate, wrong license

- HX (hardware H.264/HEVC inside NDI framing) is 2–40 Mbps — the bitrate we want.
- **But** on Android, HX encode *and* HX pass-through decode are **NDI Advanced
  SDK** features: commercial license, unpublished volume pricing, plus our own
  H.264 patent-licensing responsibility. That's why the official "NDI HX Camera"
  Android app is a paid Vizrt product.
- **Verdict: NO.** The same hardware codec is reachable without the toll booth (§3.4).

### 3.3 WebRTC — TD is ready, Godot fundamentally is not

- TD: first-class (WebRTC DAT + Stream In/Out TOPs), works LAN-only with the
  bundled signaling components. Lowest-latency option on the TD side.
- **But Godot's WebRTC is data-channels only.** It wraps libdatachannel, exposes
  no media tracks; the media-track request has been open since 2020 with no
  implementation. Real WebRTC video in Godot = writing a libwebrtc GDExtension
  ourselves — the largest possible build item.
- **Verdict: NO for video. YES as a pattern reference** — its "hardware codec +
  RTP + tiny jitter buffer" is exactly what we build by hand in §3.4.

### 3.4 Hardware H.264 (MediaCodec) over SRT / raw stream — **the winner**

This is the scrcpy architecture, which ships today at **35–70 ms** glass-to-glass:
capture → MediaCodec hardware encode → bytes over a socket → hardware decode →
display with zero buffering. Every piece exists for us:

- **Phone encode:** MediaCodec H.264 hardware encoder, fed from a Surface.
  Proven Android libraries we can wrap or crib from: RootEncoder, StreamPack
  (both take a Surface in, push RTMP/RTSP/**SRT** out).
- **Phone decode → Godot texture, zero-copy:** MediaCodec decoder → output
  `SurfaceTexture` → `getHardwareBuffer()` → **Godot `ExternalTexture`** (in core
  since 4.4, Android-only, works on *both* GL Compatibility and Vulkan). No CPU
  touch on the receive path at all.
- **TD ingest:** Video Stream In TOP speaks SRT with H.264 + NVDEC hardware
  decode; buffer parameters are tunable (community-proven settings in §10).
- **TD egress:** Video Stream Out TOP as **SRT listener** (phones call in — no
  phone-IP config on the TD side), NVENC H.264, low-latency preset.
- **Phone↔phone:** no SRT needed — raw length-prefixed H.264 NAL stream over TCP,
  decoded with zero buffering, exactly scrcpy's framing. Simplest and fastest link
  in the whole mesh.
- Bitrate: 4–8 Mbps per 1080p30 stream → three streams ≈ 12–24 Mbps. Fits R2
  with a wide margin, coexists with DDP (~6 Mbps).

Two honest costs, called out plainly:

1. **It's our first Kotlin/Godot Android plugin.** Decode side is assembly of
   proven parts. Encode side has one genuinely hard piece: getting Godot's
   rendered frame into the encoder's input Surface **without** a full-res
   `get_image()` readback (the one thing that failed in the only prior art,
   Williangalvani's RTSP GDExtension). Mitigation: v1 encodes at 720p from the
   existing two-stage GPU downsample tap (readback of a 1280×720 image, measured
   first, §9-M3), v2 does the GPU→GPU blit into the encoder Surface.
2. **H.264 latency depends on encoder config**, not the protocol: all-intra or
   intra-refresh, no B-frames, CBR, 1-frame VBV. scrcpy's numbers prove the
   ceiling; sloppy GOP settings would give us RTSP-camera numbers instead (2–3 s).

**Verdict: YES — this is the production transport for all three link types.**

### 3.5 MJPEG over UDP/TCP — the zero-native-code prototype tier

Pure GDScript both directions: `Image.save_jpg_to_buffer()` on the sender,
`Image.load_jpg_from_buffer()` + `ImageTexture.update()` on the receiver. No
plugin, no codec licensing, intra-only so latency is one frame + network.

- At 640×360 q≈0.75: ~30–60 KB/frame → 8–15 Mbps at 30 fps. Fits R2 for the
  prototype phase (barely, with three streams — run two).
- TD **cannot** ingest MJPEG via Video Stream In (confirmed unsupported). TD-side
  stand-in: Script TOP + bundled OpenCV (`cv2.imdecode` → `copyNumpyArray`) —
  mechanism confirmed, 30 fps feasibility unbenchmarked.
- Costs: readback + JPEG encode on the phone CPU every frame (unmeasured, §9-M2/M3),
  visibly softer image, no motion compression.
- **Verdict: PROTOTYPE ONLY.** Worth building *first* anyway — see §5 Stage 0 —
  because it proves discovery, the NetSource mixing UX, and the TD patch with
  zero native code, and every one of those survives the transport swap.

### 3.6 RTSP — no

TD ingests it but defaults to 2–3 s of buffering (community-measured), tunable
down only with fragile settings. Nothing RTSP gives us that SRT/raw doesn't do
better. **Verdict: NO.**

### 3.7 Touch In/Out TOP — no

TD-to-TD only, proprietary framing, Hap/uncompressed (WiFi-hostile). **Verdict: NO.**

### 3.8 Hardware side-doors — worth knowing, not the architecture

- **Phone → TD over USB as a UVC webcam** (Android 14 "phone as webcam" on both
  Pixels → TD Video Device In TOP): zero code, near-zero latency — but occupies
  the USB-C port that HDMI needs (R-topology), and it streams the *camera*, not
  PocketVJ's output. Rehearsal utility only.
- **Phone HDMI → capture card → TD**: zero code, lowest possible latency, rock
  solid — but costs the projector output and a capture card. Good emergency
  plan B for S3 at a gig where WiFi is hopeless.

---

## 4. The decision in one table

| Path | Latency | Bandwidth /stream | Phone-side work | Verdict |
|---|---|---|---|---|
| Full NDI | ~1–2 frames | **~150 Mbps** | Android SDK port + NsdManager glue | NO (bandwidth, no Android plugin) |
| NDI\|HX | good | 8–40 Mbps | **Advanced SDK license** | NO (licensing) |
| WebRTC | best-in-class | 2–8 Mbps | **libwebrtc GDExtension from scratch** | NO (Godot has no media tracks) |
| **H.264/MediaCodec + SRT/raw** | **35–70 ms proven** | **4–8 Mbps** | one Kotlin plugin, parts proven | **YES — production** |
| MJPEG GDScript | ~1 frame + net | 8–15 Mbps @640×360 | none | Stage 0 prototype |
| RTSP | 2–3 s in TD | 4–8 Mbps | server impl | NO |
| Touch In/Out | n/a | huge | impossible (proprietary) | NO |
| USB webcam / HDMI capture | ~0 | n/a | none | rehearsal / plan B |

---

## 5. Staged plan

### Stage 0 — MJPEG mesh, zero native code (prototype the *product*, not the codec)

Everything in GDScript + one TD Script TOP. Deliberately low-res (≤640×360@24).

1. Discovery beacon (§6.1) — phones and TD find each other, name themselves.
2. `NetSource` (§6.3) — received stream as a deck-mixable texture on the phone.
3. `NetSender` (§6.2) — tap → downsample → JPEG → socket. Reuses the DDP tap.
4. TD .tox: Script TOP receiver + a sender that JPEG-encodes a TOP via Python.
5. Camera mode on the 9a: Godot 4.5+ native `CameraServer` feed (NV12 two-plane,
   combined in a small shader) → the same `NetSender`.

Exit criteria: S1+S2+S3 all demonstrably mixing live; discovery survives IP
changes; measured latency + phone frame-budget numbers recorded (§9).

### Stage 1 — hardware transport swap (same product, real codec)

1. Kotlin Godot Android plugin `pocketvj-videolink`:
   - **Receive:** socket → MediaCodec H.264 decode → SurfaceTexture latched
     straight onto the `ExternalTexture`'s OES name. (Correction to the first
     draft: no AHardwareBuffer leg — the engine's GLES3 external-texture path
     is the SurfaceTexture route, and the AHB/Vulkan half never merged
     upstream.) Zero-copy; replaces `NetSource`'s decoder while its scene API
     stays identical. Wire format: §6.6.
     **IN PROGRESS 2026-08-06** — plugin (`PocketVJVideoLink`) and the
     `NetSource` h264 body landed behind `[link] codec="h264"` (default
     stays `jpeg`); the §9-M7 latency rematch against the 224 ms Stage 0
     baseline is what closes this item.
   - **Send:** MediaCodec encoder, low-latency config (no B-frames, CBR,
     1 s GOP — intra-refresh deliberately skipped, §6.6 allows either). v1
     feeds it via the measured 720p readback (buffer input); v2 GPU-blits
     into a Surface input.
     **v2 LANDED 2026-08-13 (milestone 2.5(b), first half)** — default feed:
     the encoder takes `createInputSurface()` and the render thread GPU-blits
     NetSender's SubViewport texture into it via the recorder's shared
     `GlBlitter` machinery, `eglPresentationTimeANDROID` as PTS. The whole
     per-frame CPU bill (`get_image` readback, RGBA8→RGB8, RGB→YUV convert —
     the ~70 %-of-a-core burn that re-throttled the 9a at 60 fps) is deleted,
     not optimized. Wire, destination and refusal contracts unchanged; the
     encoded-frame mailbox keeps latest-wins (a drop heals via on-demand IDR,
     the fresh-connection rule applied mid-stream) so a stalled peer costs
     drops, never render-thread swap-block. `[link] encoder_feed="cpu"` is
     the escape hatch; a pre-2.5(b) APK or a refused Surface encoder falls
     back to the v1 feed automatically, loudly. The second half of 2.5(b) —
     camera→encoder direct for S2, skipping the SubViewport render pass too —
     remains open.
     **IN PROGRESS 2026-08-06** — both halves are in: `NetSender` grows an
     h264 body behind its unchanged API (readback → the plugin's
     `push_frame`, single destination per §6.6), the control `start` verb
     carries the requester's codec (§6.4), auto-pull/panel PULL pass it, and
     the plugin's encoder landed the same day (`start_send` / `push_frame` /
     `stop_send` / `get_send_stats`: own encode thread, 1-deep latest-wins
     mailbox, connects out and speaks framing v1 per §6.6 — the connect is
     asynchronous with a 2 s redial, so a dead peer is a LOST layer that
     heals, never a failed start). Closes when the §9-M7 mirror rematch
     runs against the 224 ms Stage 0 baseline.
2. Framing: raw NAL stream phone↔phone; MPEG-TS-over-SRT to/from TD.
   **PHONE→TD HALF SHIPPED + LIVE-VERIFIED 2026-08-17 (SESSION_30_NOTES.md
   part 2)** — `TsMuxer.kt` (hand-rolled single-program TS, execution-
   validated via a Python port + ffprobe) + an SRT caller twin in
   GpuSender's tx path (srtdroid-core 1.9.5, LIVE/1316/latency-120,
   exponential redial backoff capping srtdroid's per-dial JNI-global-ref
   leak). Selected per-ask: the control `start` verb's new `transport`
   field → `set_send_transport` (probeable; pre-M3 APKs refuse loudly).
   srt is h264 + GPU-feed only, no tcp fallback. First live ask
   (`request_stream('Pixel 8', codec='h264', transport='srt', port=4861)`)
   decoded 1280×720@60 in srt_in0 within 45 ms of the dial.
   **RECEIVE HALF SHIPPED + LIVE-VERIFIED same day (SESSION_30 part 3)** —
   `TsDemuxer.kt` (PID discovery from PAT/PMT, execution-validated) + an SRT
   caller mode in the plugin Receiver (`start_receive_srt`): ring `srt_arm`
   on ctrl 4850, settle 200 ms, dial 4860 with leak backoff; RCVTIMEO makes
   a mid-session TD wedge self-heal (drop → re-arm → re-dial). GDScript:
   `NetSource.pull_srt`, pull-flow branch on beacon codec `srt` (NOTE the
   phone-side field is `codec`, TD's Python table says `fmt` — that one-word
   drift cost a build cycle), STOP sends the new `srt_disarm` verb. The
   beacon now advertises `srt|4860`. Live: PULL on the TD-MAIN row →
   LINK RX 60fps 6.2Mb de11.8 LIVE, TD's layer composited on the deck.
   **M3 is bidirectional; remaining: the §8/§9 latency rematch.**
3. TD .tox v2: Video Stream In (SRT, hwdecode, tuned buffers) ×2 + Video Stream
   Out (SRT listener, NVENC low-latency) — replaces the Script TOPs.
   **TD SIDE BUILT + ffmpeg-VERIFIED 2026-08-17 (SESSION_30_NOTES.md)** —
   `srt_out` listener :4860 (NVENC h264 low-latency CBR 6/8, 60 fps, GOP 60,
   no B-frames), `srt_in0/1` listeners :4861/:4862 (hwdecode, 32 KB / queue 2),
   Stage-0 Script TOPs kept alongside. Two TD gotchas are load-bearing:
   Video Stream In only listens while cooked (the frame pump force-cooks
   them), and Video Stream Out serves exactly ONE client session per Active
   cycle with no detectable error after — so the control channel grew an
   **`srt_arm` verb (TCP 4850): a peer re-arms TD's listener before every
   dial of :4860, including redials**. Phone-side SRT (MPEG-TS mux/demux +
   SRT caller in the Kotlin plugin) is the remaining half of this item.
4. Beacon unchanged. `NetSource`/`NetSender` scene API unchanged.
   (Stage-1 note: TD still beacons `jpeg|4852`; announcing `srt` + the ingest
   ports must land together with phone-side parsing.)

### Stage 2 — sequencer 2.0 hooks (out of scope here, enabled by this)

The control channel (§6.4) that ships in Stage 0 is the door: BPM/beat-phase
share, remote scene triggers, cross-device sequencing.

---

## 6. PocketVJ architecture

Mirrors the shapes that already work in this codebase (`DdpOutput`, `LifeSource`).

### 6.1 Discovery — `LinkBeacon` (autoload)

- UDP broadcast, port **4849**, 1 Hz: `PVJ1 <name> <role> <proto> <video-port> <ctrl-port>`.
- Every peer broadcasts and listens; peer list with 5 s timeout. No mDNS (Android
  mDNS is the part even NDI can't make reliable; dumb broadcast is what already
  works on this LAN for DDP).
- TD side: one UDP In DAT + a few lines of Python — the .tox both announces TD
  and populates its peer table.
- UI: settings panel lists live peers by *name* ("PIXEL-9A CAM", "TD-MAIN"), never
  by IP. Pick a peer, not an address (R3).

### 6.2 Send — `NetSender` (node, owned by pipeline)

- Taps `output_world` exactly like `DdpOutput` does; second consumer of the same
  two-stage downsample pattern (target 640×360 in Stage 0, 1280×720 in Stage 1).
- Fixed-size frame queue, depth 1: **drop, never buffer** (R5 — a slow link stales
  the remote layer, never blocks the local pipeline).
- Stage 0 body: `save_jpg_to_buffer` on a worker thread → UDP chunks (DDP-style
  offset+push framing, reuse the packetizer thinking) . Stage 1 body: plugin call.

### 6.3 Receive — `NetSource` (node, registered like `LifeSource`)

- Exposes `get_texture()`; the pipeline registers it as a **deck source / layer
  input** so the whole existing effect+mix chain applies to remote video for free
  — same trick as LIFE-as-DDP-source.
- Stage 0 body: reassemble → `load_jpg_from_buffer` (worker thread) →
  `ImageTexture.update`. Stage 1 body: `ExternalTexture` bound to the plugin's
  decoder — API identical from the scene's point of view. (Landed 2026-08-06:
  selected by `[link] codec="h264"`, wire format §6.6; missing plugin degrades
  to the Stage 0 body with one warning.)
- Freshness state (LIVE / STALE >250 ms / LOST >2 s) surfaced to the UI; on LOST,
  hold last frame or fade per user setting (R5).

### 6.4 Control — `LinkControl` (TCP, port 4850)

- Newline-delimited JSON to the same peers the beacon found: `hello` (capabilities),
  `start/stop stream`, `stats` (fps, kbps, drops), later `beat` (Stage 2).
- This is where "mix the camera phone from the main phone" lives: the main phone
  *requests* the 9a's stream; nobody touches the 9a at showtime.
- **Empty-ip rule** (v1, from the first live test): a `start` whose `ip` is `""`
  means "stream to whoever is asking" — the receiving side substitutes the TCP
  connection's remote address. Requesters rarely know their own LAN IP; the far
  end of the socket always does.
- **Codec field** (v1, milestone 2): `start` carries an optional `"codec"` —
  `"jpeg"` (default) or `"h264"` — the *requester's* effective receive codec,
  i.e. what the port in the same message speaks, so the sender picks the body
  that matches where it is being aimed. A missing field means jpeg, and unknown
  JSON fields are ignored on both ends, so Stage 0 peers interoperate
  unmodified. The honest limit of that tolerance: a pre-milestone-2 *sender*
  also ignores an `"h264"` ask and aims MJPEG/UDP at the TCP port, where it
  silently vanishes — the requester's layer just stays LOST and its retry keeps
  asking. That is not only the requester's problem: the deceived sender pays
  readback + encode + WiFi at the asked cadence (60 fps for an h264 pull since
  milestone 2.5) into a socket nobody reads, indefinitely,
  because the auto-pull path never stops a stream that never fed it — the
  sender-side twin of the dead-port burn the pull refusal exists to prevent.
  So the requester defends the only way this wire allows: while its h264
  listener is up it also holds a **UDP tripwire on the same port number**.
  MJPEG chunks arriving there can only be a sender that ignored the field —
  the requester sends that peer a `stop` (ending a burn the sender cannot see)
  and stands its auto-pull down for that ip until the peer's beacon next
  reappears (an upgrade is an app restart is a >TTL beacon gap). A manual PULL
  still tries — the operator outranks the latch — and just trips the wire
  again if nothing changed.

### 6.5 Camera mode (the 9a's job in S2)

- **Uses the deck's existing `CameraEngine`** (`camera_engine.gd`, the CAMERA
  deck source from the masks work) — NOT a new camera stack. It already owns
  the CameraServer traps this spec would otherwise re-learn: format must be
  selected before activation, `get_datatype()` lies (reports RGB) until the
  first frame, YCbCr→RGB via `camera_ycbcr.gdshader`. One camera owner, ever.
  (Stage 0 build initially shipped a duplicate `CameraSource`; it fought
  CameraEngine over the device and was deleted the same night.)
- Stream 1 = `camera_engine.get_texture()` into `NetSender`; the link holds a
  `_link_uses_camera` flag so a deck-source switch on the cam phone can't power
  down a camera the main phone is watching.
- `CAMERA` permission was already in the preset; CameraEngine handles the
  request dialog + retry internally.

### 6.6 Stage 1 receive — FRAMING v1 (TCP **4853**)

Spec first, then code — same rule as the Stage 0 header, and the same warning:
this wire format is shared with every sender (the PC test sender today, the
phone/TD send paths of milestones 2–3 tomorrow). Stage 0's UDP framing (§6.2)
and ports 4849–4852 are **untouched**; a phone advertising `h264` has simply
opened one more door.

- **Transport:** TCP. The *receiving* phone listens on **4853**; the sender
  connects and pushes — the same shape as `NetSource.listen()` (receiver
  binds, peers aim at it, `is_listening()` is checked before anyone streams).
  One sender at a time, served **serially**: the listener reads one
  connection until it ends (drop, or the 4 s idle timeout below) and only
  then accepts the next. ⚠️ A second sender's `connect()` still *succeeds* —
  the TCP handshake completes in the kernel backlog — so a sender must never
  treat a successful connect as ownership of the decoder; it is being read
  only once the previous sender is gone. Every connection that *is* served
  starts a fresh decoder and must begin with fresh SPS/PPS. (Preemption —
  new connection kicks the old — is a milestone-2 decision, made when there
  are peers to arbitrate between.)
- **Framing v1:** per payload, a **u32 big-endian length prefix**, then
  exactly that many bytes: **one Annex-B NAL unit, start code included**. A
  sender that glues a whole access unit (SPS+PPS+IDR) into one payload is
  tolerated — the receiver walks start codes, not payload boundaries.
- **Stream rules:** SPS and PPS first, resent at least on every reconnect
  (ideally with every IDR); **no B-frames**; short GOP or intra-refresh. The
  receiver renders each frame the moment it decodes — there is no reorder
  buffer for B-frame latency to hide in, and no jitter buffer to bloat.
- **Failure discipline** (mirrors `NetSource`'s): a length outside
  (0, 2 MiB] means the framing itself is lost, and a length-prefixed stream
  cannot resync — drop the *connection*, keep the *listener*. A payload that
  scans to more than **64 NAL units** is the same class of failure: a real
  access unit is a handful of NALs (a multi-slice IDR at worst a few dozen),
  while a payload of wall-to-wall start codes is lost framing wearing a
  valid length — drop the connection. A sender silent for 4 s is presumed
  dead: connection closed, listener re-accepts. A payload with no start code
  is skipped; a decoder error rebuilds the codec from the cached SPS/PPS
  (throttled).
- **Discovery:** the beacon's codec field (§6.1) says `h264` and its
  `video-port` says 4853 while this path is listening — and it advertises the
  *effective* codec, so a phone whose plugin is missing (fallen back to
  Stage 0) keeps honestly saying `jpeg`/4851. The 6-field line format does
  not change; the codec field existed for exactly this day.
- **Send side (milestone 2):** the phone's sender has the same connection
  shape as the PC test sender — it **connects** to the receiving peer's 4853
  listener and pushes this exact framing, fed by the v1 720p readback (§3.4)
  through the plugin's own encode thread, 1-deep latest-wins mailbox: drop,
  never buffer, NetSender's jpeg policy verbatim. v1 h264 is
  **single-destination**: the far end serves one connection at a time
  (serial accept, above), so a fan-out would stream into a kernel backlog
  nobody reads and believe it was live — a second h264 `start` therefore
  **replaces** the destination (old connection closed, new one opens, and
  the reconnect is what guarantees fresh SPS/PPS). Only the h264 body is
  single-destination; the MJPEG fan-out on 4851 is untouched.
- **One wire format at a time (cross-codec rule):** while consumers of the
  *other* codec hold the stream, a cross-codec `start` is **refused**, not
  honoured. Honouring it (last-writer-wins, the stream_id rule) would clear
  the other side's targets, whose 3 s LOST-retry would steal the stream
  straight back — both consumers strobing LIVE/LOST forever, the exact
  oscillation the jpeg fan-out join was built to kill, cross-codec edition.
  The asker's own entry leaves its old pool first (it is opting out of that
  wire either way), so a *sole* consumer flipping its posture wins the flip
  the moment the pool empties. `NetSender.start()` returns this call's fate
  (true = took effect) precisely so the sending side can put a refusal on
  screen instead of flashing a success it inferred from `is_active()` — which
  any *other* still-running stream keeps true.
- **The kernel must not smuggle latency:** the send socket caps `SO_SNDBUF`
  small (~128 KiB effective ≈ 260 ms at 4 Mbps). Left to auto-tune, Android
  grows it to megabytes and `write()` — the only backpressure the enc thread
  feels — would not block until *seconds* of CBR video sat queued beyond the
  mailbox's reach, with every stat looking healthy. Capped, a slow path
  degrades by dropping frames (visible in `frames_dropped`), never by running
  seconds behind. And because Java sockets have no write deadline, a write
  blocked past **4 s** (a peer whose kernel ACKs while its frozen app never
  reads — no FIN, no RST, ever) is cut by a watchdog from the push/stats
  threads: closing the socket makes the write throw, which is the ordinary
  peer-loss redial path, not a wedged-forever thread.

---

## 7. TouchDesigner side — one .tox, two generations

| | Stage 0 (`pvj_link_proto.tox`) | Stage 1 (`pvj_link.tox`) |
|---|---|---|
| Receive phone streams | Script TOP: UDP → cv2.imdecode → copyNumpyArray (×2) | Video Stream In TOP, SRT, hwdecode on, Network Buffer 32 KB / Queue 2 / Pre-Read low (×2) |
| Send TD layer | Python JPEG encode of a TOP @ ≤24 fps | Video Stream Out TOP: SRT **listener**, NVENC H.264, "Low-Latency" preset, intra-refresh |
| Discovery + control | UDP In DAT beacon + Python peer table (both stages, unchanged) | same |

~~Constraint to verify before Stage 1: Video Stream Out requires an NVIDIA GPU~~
**Verified (§9-M5, 2026-08-05): TD 2025.33070 on an RTX 5080** — NVENC out and
NVDEC in both present; the SRT path is fully available in both directions.

---

## 8. Budgets

### Latency (per link, Stage 1 targets)

| Link | Path | Budget |
|---|---|---|
| 9a → Pixel 8 (S2) | cam → encode → WiFi → decode(0-buffer) → texture | **≤ 80 ms** (scrcpy-class) |
| Pixel 8 ↔ 9a video | tap → encode → WiFi → decode → texture | ≤ 80 ms |
| TD → phone (S1) | NVENC → SRT → phone decode | ≤ 120 ms |
| phone → TD (S3) | encode → SRT → NVDEC + tuned buffers | ≤ 150 ms (TD ingest buffering dominates) |

Stage 0 will be worse (readback + CPU JPEG both ends) — that's fine; it's the
UX prototype, and its numbers (§9) are what justify Stage 1.

### Bandwidth (worst case, everything on: S1+S2+S3 + DDP)

| Stream | Stage 0 | Stage 1 |
|---|---|---|
| 3 × video | 3 × ~12 Mbps = 36 Mbps | 3 × ~6 Mbps = 18 Mbps |
| DDP to board | ~6 Mbps | ~6 Mbps |
| control + beacon | negligible | negligible |
| **Total** | **~42 Mbps** — run 2 streams if the AP chokes | **~24 Mbps** — comfortable |

---

## 9. Measurements that gate implementation (run BEFORE building)

- **M1 — real WiFi throughput**, phone↔phone and phone↔PC (`iperf3`; Termux or a
  tiny Godot echo tool). The 50 Mbps assumption in R2 is unverified.
- **M2 — `save_jpg_to_buffer` cost** on the Pixel 8 at 640×360/960×540, on-device.
- **M3 — readback cost**: `get_image()` at 640×360 and 1280×720 from the
  downsample chain — extends the DDP spec §5 measurement we already owe.
- **M4 — `load_jpg_from_buffer` + `ImageTexture.update`** at 30 fps on-device,
  while a deck plays (R4: measure the *deck's* frame time, not just the decoder's).
- **M5 — the TD machine**: ✅ DONE 2026-08-05 — TD 2025.33070, RTX 5080, reached
  via the tdmcp bridge on port 9980 (bearer auth). NVENC gate cleared (§7).
- **M6 — Script TOP JPEG ingest** at 24–30 fps in TD (unbenchmarked per forum).
- **M7 — glass-to-glass latency, S2 loop**: ✅ DONE 2026-08-06 — mirror method:
  the 9a's camera films the P8 showing the received stream, so the burned-in
  ms stamp nests one loop deep and a single receiver screencap holds both
  numbers, both from the SENDER's clock (no external camera, no cross-device
  clock math). Six samples: 206/211/212/220/241/256 ms — **mean ~224 ms,
  always 5–6 sender frames at 24 fps** (Δseq cross-check matched every
  sample). Includes camera exposure/ISP — the loop starts at photons.
  **Stage 0 misses R1's ≤150 ms layered-live bar → Stage 1 is justified.**
  **REMATCH 2026-08-06 night (Stage 1 hardware path, same method, same rig):
  212–288 ms, mean ~255 — statistically unchanged from MJPEG, and the seq
  delta says why: the loop is still 5–7 captured frames deep. Latency is
  STAGE COUNT × CAPTURE CADENCE (41.7 ms slots at 24 fps), not codec
  compute.** What the codec DID buy: 4 Mb/s CBR at 1280x720 vs ~6 Mb/s at
  640x360 — 4× the pixels for ⅔ the bandwidth (R2 secured). The latency
  levers are therefore: (a) 60 fps capture cadence → same stages ≈
  85–115 ms; (b) removing stages — v2 GPU-blit encoder feed, and
  camera→encoder direct for S2 (open). That is milestone 2.5, the latency
  hunt. **BOTH LEVERS MEASURED FAIR 2026-08-13 (mirror rematch, cool
  starts, Δseq × 16.7 ms cross-check per sample; samples failing the
  cross-check discarded):**
  - **(a) CPU feed @60 (TAKEN 2026-08-07, `LINK_H264_FPS`):** valid
    60 fps-cadence samples 198/213/239/262/263 ms, mean ~235 —
    **statistically UNCHANGED from every 24 fps baseline (224/255), and
    the model above is FALSIFIED: depth scaled from 5–6 slots to 13–16 as
    the slots shrank. The S2 loop's latency is CADENCE-INVARIANT — it
    lives in fixed-TIME stages (camera exposure/ISP/HAL pipeline, decode
    and display queues), not in capture slots.** Cadence also collapsed
    within ~63 s of a 33 °C start (samples read 31 ms slots = ~32 fps;
    the governor oscillates) — the ~70 %-core convert re-throttles the
    9a, so (a) alone is neither faster nor sustainable.
  - **(b) GPU feed @60 (TAKEN + measured 2026-08-13, §5 Stage 1 send
    v2):** early samples 189–226 ms (mean ~212), and **at 4 minutes of
    sustained load, 39 °C: 209/224/232 — flat.** The convert's removal
    shaves its ~20 ms and, the real win, 58–60 fps holds indefinitely
    (blit swap ~0.32 ms; the same soak at 42→44 °C never dropped
    cadence). The old-build P8 decoded the GPU-fed stream untouched —
    wire identical.
  - **Consequence for the ≤80 ms S2 budget (§8): unreachable by cadence
    or send-path stage removal — the ~210 ms floor is the camera
    pipeline itself.** Next lever is 2.5(b)'s second half
    (camera→encoder direct) judged against what the camera HAL can
    actually deliver, and/or accepting ~210 ms as the camera-LAYER
    number (fine for texture mixing, not for IMAG).
- Method notes: memory files already cover the traps — vsync hides GPU headroom
  (use the Mali DVFS proxy), and latency is measured with a frame-counter burned
  into the image and diffed on camera, both phones in one shot.
- **M8 — TD-leg latency rematch (§8 budgets): ✅ MEASURED 2026-08-19, loopback
  mirror.** Method: the phone streams its stamped composited output to TD
  (SRT :4861); TD returns it HALF-SIZE (`srt_in0` → transform 0.5/BR →
  `send_fit` → `srt_out` :4860); the phone composites the return as lane B
  (crossfade 1.0) into the very output it streams. Every TD-side frame grab
  of `srt_in0` then holds the live stamp AND the nested returned stamp —
  both on the phone's clock: **one frame = one round-trip sample, no
  external camera, no clock skew** (and the shrink stops the fresh burn
  covering the returned stamp — the trap of a full-frame loopback). The
  half-size copies nest recursively, so one frame often yields 2–3 deltas.
  **n=10: RTT 674–723 ms, median 706, mean ~703** — every sample's Δseq
  (39–44 frames) matching its ms within one 16.7 ms slot.
  **Verdict: the §8 budgets are BUSTED as configured** — combined
  TD→phone + phone→TD budget is 270 ms; measured round trip (minus a
  ~30 ms TD-turnaround estimate) puts the per-leg average at ~335 ms,
  over 2× each leg's budget. **The dominant identified term: srtdroid's
  hardcoded `LATENCY=120`** on the phone's SRT sockets BOTH directions —
  SRT negotiates each leg's window to max(both ends), so the phone pins
  every TD leg to ≥120 ms of protocol buffer regardless of TD-side
  settings (TD-side experiments cannot reduce it). Corroboration: the
  phone↔phone deck path (raw-NAL TCP, no protocol window) measures
  100–160 ms one-way on the same WiFi.
  **Levers, in order:** L1 — make the SRT latency window configurable
  (`[link] srt_latency_ms`, LAN default 20–40 ms; APK change) ≈ −160 to
  −200 ms RTT. L2 — audit the phone RX → lane-B display path for hidden
  frames. L3 — TD turnaround (cook ordering) is minor (~1–2 frames).
  Honesty notes: the loopback pays the phone's display+recapture leg once
  (~2–3 frames), slightly inflating the per-leg average; and `srt_in0`'s
  ingest tuning was verified still at the §7 numbers (disablebuffering on,
  queue 2, 32 KB) before believing any of this.
  **L1 TAKEN + REMATCHED same day: RTT 706 → 358 ms median — halved by
  one knob.** Kotlin: `SRT_LATENCY_MS` became the default behind a
  `@Volatile var srtLatencyMs`, set from GDScript via the new probeable
  `set_srt_latency(ms)` (probe by null; a pre-M8 APK keeps its 120).
  GDScript: `[link] srt_latency_ms` cfg (default 40, clamped 10–4000 to
  match the Kotlin coerceIn), applied at link init before anything dials.
  TD: all three SRT TOP urls grew `&latency=40` (libsrt's own default is
  ALSO 120 — the TD side had to come down with the phone or the
  negotiation would have re-pinned it). Same loopback mirror, n=9:
  **RTT 326–399 ms, median 358, mean ~368**, Δseq 20–24 frames,
  cross-check clean. The −348 ms exceeds the 2×80 window arithmetic —
  SRT releases packets AT the window boundary, so each leg pays its full
  window, twice over the loop, plus scheduler slack around it. Verdict vs
  §8: the loop minus TD turnaround (~30 ms) and the phone's
  display+recapture (~35–50 ms) puts the two-leg sum at ~280–295 ms
  against the 270 ms combined budget — **essentially AT budget**, from
  2.6× over. Next lever if a gig wants tighter: `srt_latency_ms=20`
  (thinner retransmission margin — soak on show WiFi before trusting it),
  then L2. Session note: TD crashed and restarted while the SRT TOP urls
  were edited live (listeners re-listen on a url change) — edit those
  parked, not serving.

## Open questions

- Q1: Stage 0 resolution/fps floor that still "reads as a layer" on a projector —
  480p24 acceptable? (Taste call, decided at the first prototype session.)
- Q2: Does S2 need camera *and* PocketVJ-output from the 9a simultaneously, or is
  camera-mode exclusive? (Affects whether the 9a runs two senders — bandwidth ×2.)
- Q3: Audio over the link — out of scope for v1 (recording scope memory says
  phone-mic-only); revisit at Stage 2 with beat-phase share, which may be enough.
- Q4: TCP vs UDP for phone↔phone NAL stream in Stage 1 — scrcpy uses TCP and
  hits 35 ms on LAN; start there, only get clever if measurements say so.

---

## 10. Sources

**NDI** — SDK/Android: docs.ndi.video "Platform Considerations", "Decoding with
NDI" (HX decode unsupported on Android; pass-through = Advanced SDK); licensing:
NDI SDK License Agreement PDF + ndi.video/for-developers/ndi-advanced; bandwidth:
docs.ndi.video white paper (150 Mbps @1080p60), jemproductions.fi, magewell.com;
godot-ndi: github.com/unvermuthet/godot-ndi (`.gdextension` + CI matrix = no
Android); Android mDNS instability: github.com/keijiro/KlakNDI issue #216.

**Godot** — WebRTC data-only: docs.godotengine.org networking/webrtc +
github.com/godotengine/webrtc-native issue #13 + godot-proposals #2553;
ExternalTexture: docs.godotengine.org class_externaltexture (4.4+, Android-only,
both renderers); Android camera: godot PR #106094 (merged, 4.5, Camera2 NDK,
NV12 two-texture); readback pain: godot issue #75877; JPEG API: class_image
(save_jpg_to_buffer / load_jpg_from_buffer); prior-art RTSP attempt (readback
bottleneck): github.com/Williangalvani/udp-rtsp-gdextension; Android encoder
libs: github.com/pedroSG94/RootEncoder, github.com/ThibaultBee/StreamPack.

**TouchDesigner** — docs.derivative.ca: Video_Stream_In_TOP (RTSP/HLS/SRT/WebRTC;
no RTMP/MJPEG ingest), Video_Stream_Out_TOP (SRT caller/listener, NVENC-only),
NDI, NDI_In_TOP (HX hwdecode), WebRTC_DAT + Palette:webRTC (LAN-only signaling),
Touch_In/Out_TOP (TD-to-TD, Hap/uncompressed), Script_TOP (copyNumpyArray);
forum.derivative.ca: RTSP 2–3 s latency thread #197594 (buffer 32/queue 2 fix),
SRT latency thread #315463 (12–37 frames, fixes in 2022.32230+).

**scrcpy** — github.com/Genymobile/scrcpy README + doc/video.md: 35–70 ms,
MediaCodec H.264, zero-buffer client.
