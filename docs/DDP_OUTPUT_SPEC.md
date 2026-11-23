# PocketVJ — DDP output to a 64x64 LED panel (spec)

**Goal:** stream the render pipeline to an Adafruit MatrixPortal S3 driving a
64x64 HUB75 panel, over WiFi, at 40–60 fps, without costing the deck its 60 fps.

Receiver firmware, wire format and panel details live in the LED bridge
project (**LED bridge: coming soon**). Its TouchDesigner sender targets the
same board with the same packet format; this module is the PocketVJ-side
equivalent.

Reference implementation: [`ddp_output.gd`](ddp_output.gd) — drop-in, no engine
changes, no plugin, GDScript only.

---

## 0. The one thing that determines the design

`get_texture().get_image()` is a GPU→CPU sync. `MAPPING_TOOLS_SPEC.md` §3
measured it at **10–30 ms at full resolution** and rules it *"one-shot only,
never per-frame."* The frame budget at 60 fps is 16.6 ms. A per-frame 1080p
readback is therefore not a tuning problem — it cannot work at all.

**The way out is that the panel is 64x64.** Render the source down to 64x64 *on
the GPU*, then read back only that: 4096 px instead of 2 073 600, a ~500x cut in
transferred bytes. That is the same shape as `ThumbnailService`'s "tiny 36k-px
readback" (PROJECT_STATE), which already sustains 60 fps — and this readback is
~9x smaller again.

> ⚠️ **Do not read the output viewport directly and scale on the CPU.** That
> reinstates exactly the per-frame full-resolution readback the spec forbids.
> Every other decision here is downstream of this one.

### Two downsample stages, not one

1920x1080 → 64x64 in a single bilinear step samples 4 texels out of every ~500
and throws the rest away. On live video that reads as violent shimmer and
crawling edges, and at 64x64 there is no detail left to hide it. An intermediate
256x256 pass gives each final texel a real neighbourhood to average over. Both
passes are over tiny targets and cost far less than the artefact costs
perceptually.

```
source viewport ──► tap1 (SubViewport 256x256) ──► tap2 (SubViewport 64x64)
                                                          │
                                              get_image() │ 12 288 bytes
                                                          ▼
                                          9 DDP packets ──► UDP :4048 ──► panel
```

---

## 1. Where it hangs in the pipeline

`DdpOutput` is a **sink**, not a stage. It consumes a viewport's texture the way
`ShaderSlot` consumes `ClipEngine`'s, and produces no visual output, so it can
attach to any stage without disturbing it. Nothing downstream depends on it and
removing it changes nothing else.

```
OutputWorld (SubViewport 1920x1080)
├── ClipEngine (DecoderA/B)
├── ShaderSlot
├── RegionCompositor
└── QuadWarp ──────────► texture ──┬──► projector (EGL bridge, DUAL·TEX)
                                   └──► DdpOutput ──► LED panel
```

It sits alongside the existing projector path rather than in it. The EGL bridge
consumes the output texture's native GL handle; this consumes the same texture
through ordinary GDScript. They do not interact.

**Depends on the §1 scene restructure in `OUTPUT_ARCHITECTURE_SPEC.md`** — the
one that puts the rendered output in its own `OutputWorld` SubViewport. That is
already shipped (DUAL·TEX, Session 14), so the seam exists. Point `set_source()`
at the same viewport the EGL bridge uses.

---

## 2. Modes

| Mode | Streams | Status |
| --- | --- | --- |
| `MIRROR` | The final composited output — warp, masks and shaders included. What the projector shows, the panel shows. | **Working.** |
| `INDEPENDENT` | A specific deck or bus, decoupled from the phone's main display. | **Stub** — see below. |

### INDEPENDENT is a stub, deliberately

Phase 2 dual-deck is *designed now, built later*
(`PocketVJ_Architecture.md` §Scope), so there is no second deck to point at yet.
The module's plumbing is complete and fully exercised by `MIRROR` — the mode
switch, the source rebinding and the fallback all work today. The only missing
piece is a source to select.

When `DeckB_Render` lands, its `DeckController` calls
`set_independent_source(viewport)` with the viewport behind
`deck.get_output_texture()` and `INDEPENDENT` starts working with **no further
change to this module**. That is the whole point of the architecture's
"every widget emits intent, a per-deck controller translates it" rule
(`PocketVJ_Architecture.md` §19) — the sink never learns which deck it is on.

Selecting `INDEPENDENT` before then falls back to the mirror source and warns.
It does not go black mid-set, because going black mid-set is the worst possible
failure for a performance tool.

---

## 3. Wire format

Byte-identical to the TouchDesigner sender, so one firmware build serves both.
Full table in the LED bridge firmware README (**LED bridge: coming soon**).
Summary:

| Offset | Size | Field | Value |
| --- | --- | --- | --- |
| 0 | 1 | Flags | `0x40` mid-frame, `0x41` with PUSH on the last packet |
| 1 | 1 | Sequence | 1–15, wrapping; 0 means "unused" |
| 2 | 1 | Data type | `0x0B` — standard, RGB, 8 bits/channel |
| 3 | 1 | Destination ID | `1` |
| 4–7 | 4 | Data offset, bytes | **big-endian** |
| 8–9 | 2 | Data length, bytes | **big-endian** |
| 10+ | n | Payload | RGB triples, row-major from top-left |

A 64x64 frame is 12 288 bytes → **9 packets**: 8 of 1440 payload bytes plus a
768-byte remainder. 1440 keeps each datagram at 1478 bytes on the wire including
UDP and IP headers, under a 1500-byte MTU, so nothing fragments.

> ⚠️ Offset and length are **big-endian**, which is the opposite of
> `PackedByteArray.encode_u32()`. `_build_header()` writes the bytes explicitly
> for this reason. Do not "tidy" it into `encode_*` calls.

The last packet's PUSH flag is what makes the firmware swap its double buffer.
Lose the tail and the frame is never pushed, so the previous frame stays up.
Lose a *middle* packet and the frame is still pushed with a hole in it, and
because the receiver double-buffers, that hole holds what was written two frames
ago — a spatial composite of frame N and N−2, not the previous frame. The
guarantee is no horizontal tearing, not no torn frames.

### Control channel — status, discovery, provisioning

`ddp_output.gd` also carries the firmware's control protocol, on DDP's own
reserved device IDs: **251** for JSON status (read-only) and **250** for JSON
config (authenticated read/write). Full definition in the LED bridge firmware README, "Control protocol"
(**LED bridge: coming soon**).

The builders — `build_status_query()`, `build_nonce_query()`,
`build_config_write()`, `parse_control_reply()` — emit bytes identical to the
TouchDesigner sender's, and the bridge repo's round-trip tests assert that
directly, so the two cannot drift apart without a test failing.

Three things this buys PocketVJ:

- **Status.** `fps`, `lost`, `rejected` and RSSI from the board, which is the
  measurement §7's EMI risk actually needs. `lost` comes from sequence gaps and
  is the only number that sees over-the-air loss.
- **Discovery.** Send the status query to a broadcast address and the board
  answers unicast with its own IP. The panel's address is only as stable as its
  DHCP lease, so a hardcoded `target_ip` is a latent failure.
- **Provisioning.** Credential writes are HMAC-SHA256 signed against a
  board-issued single-use nonce, refused unless somebody has physically armed
  the board, refused while a stream is running, and rolled back automatically if
  the board cannot associate. `HMACContext` covers the signing; PocketVJ needs
  no new dependency.

> The signature is not sufficient on its own — that is why the nonce exists. A
> signed write with no nonce stays valid forever, so a captured packet could
> reprovision the panel at any later date.

### Arbitration with the other sender

The firmware is last-sender-wins at frame granularity: a packet at offset 0
claims the panel for its source IP, and packets from anyone else are dropped
until they start a frame of their own. If PocketVJ and TouchDesigner stream at
once the panel flicks between them; it never blends them. No coordination is
needed on this side.

---

## 4. Integration

1. Copy `ddp_output.gd` to `scripts/ddp_output.gd`.
2. Add a `DdpOutput` node under `OutputWorld` (or anywhere — it is a plain
   `Node`; the tap viewports are its children).
3. Wire the source once, after the output viewport exists:

   ```gdscript
   @onready var _ddp: DdpOutput = $DdpOutput

   func _ready() -> void:
       _ddp.set_source(output_world)   # the same SubViewport the EGL bridge uses
   ```

4. Surface `enabled`, `target_ip` and `send_fps` in settings. Everything else has
   a working default.

`enabled` is **off by default** and allocates nothing until switched on — an
install with no panel pays nothing, not even the tap viewports. Same lazy-build
rule `ShaderSlot` follows for its history buffer.

### Settings

| Setting | Default | Notes |
| --- | --- | --- |
| `enabled` | `false` | Off allocates nothing. |
| `target_ip` | `192.168.1.50` | Must match `STATIC_IP` in the firmware's `secrets.h`. |
| `target_port` | `4048` | DDP. |
| `send_fps` | `60` | 40–60 is the working range. |
| `mode` | `MIRROR` | |
| `flip_vertical` | `false` | Toggle if the panel image is upside down. |
| `swap_red_blue` | `false` | Toggle if the panel is BGR-wired. |
| `auto_retarget` | `false` | Follow the panel's address when a status reply arrives from somewhere other than `target_ip`. Leave off if two panels share a subnet. |

Status arrives on its own: `_poll_status()` runs from `_process`, queries once a
second, and fills `get_panel_status()` / `get_status_age()`. Surface those in
settings or a debug overlay — `fps`, `lost` and `rssi` are the numbers §7's EMI
risk actually needs, and `get_status_age()` is what stops a stale reading being
read as a current one.

> The socket is `bind(0)`-ed before `set_dest_address()`. `PacketPeerUDP` sends
> fine unbound but cannot receive, so without the bind the status path fails
> silently — packets go out, nothing ever comes back, and
> `get_available_packet_count()` sits at zero. Do not "simplify" it away.

`flip_vertical` is a switch rather than a guess because Godot viewport textures
are commonly bottom-left origin and the panel scans from the top — the same trap
`OUTPUT_ARCHITECTURE_SPEC.md` §3 flags for the EGL bridge's UVs. Which way it
lands depends on the renderer, so it gets tested on device, not assumed.

---

## 5. What needs measuring on device

The design is sound on the numbers above, but two things want a Pixel 9a
measurement before this is called done:

1. **Readback cost.** A 64x64 `get_image()` should be ~0.1 ms of transfer, but
   the *sync* is the real cost, not the bytes. `await RenderingServer.frame_post_draw`
   puts it at a point where the pipeline is already synchronising, which should
   make it near-free — but "should" is doing work in that sentence. Measure frame
   time with the panel on and off.
2. **Two extra viewport passes.** 256x256 and 64x64 targets are small, but they
   are still two passes per frame. Expect them to disappear into the noise;
   confirm it.

If either bites, `send_fps` at 30 halves both costs and is still usable on a
64x64 panel — that is the fallback, and it needs no code change.

---

## 5b. Picking this up in the PocketVJ repo

This file and `ddp_output.gd` are the whole handoff — deliberately, since they
move to `c-ustudio/pocketvj` and leave the bridge repo's context behind.

**Done here, ready to copy:** the frame path, the two-stage downsample, the
control-protocol builders and parser, status polling with `get_panel_status()` /
`get_status_age()`, and `discover()`. `ddp_output.gd` is drop-in; it needs no
engine changes, no plugin, and no new dependency (`HMACContext` is built in).

**Left to do on the PocketVJ side:**

1. Wire `set_source()` to the `OutputWorld` viewport (§4) and surface `enabled`,
   `target_ip` and `send_fps` in settings.
2. Surface the status readout — at minimum `fps`, `lost`, `rssi` and
   `get_status_age()`. Without the age a dead panel's last numbers read as live.
3. Resolve `flip_vertical` and `swap_red_blue` to actual measured values on
   device rather than leaving them at "probably".
4. Take the §5 measurements.
5. Provisioning, if wanted, is builders-only here: `build_nonce_query()` and
   `build_config_write()` exist, but nothing drives the two-step exchange. It is
   also the piece that least needs to exist on PocketVJ — the panel is usually
   provisioned once, from the captive portal or TouchDesigner.

**Verified how far:** every message type is checked byte-for-byte against the
TouchDesigner sender by `tests/test_ddp_roundtrip.py` in the bridge repo (86
checks), so the wire format is known-good. The GDScript itself has not been run
under Godot — that is what the on-device pass in §5 is for.

## 6. Acceptance criteria

- Panel shows the **rendered pipeline** — warp, masks and shaders applied.
- **Deck holds 60 fps** with the panel live. This is the one that matters; a
  panel that costs the projector its frame rate is not worth having.
- Panel sustains **40–60 fps**, confirmed against the firmware's `[stats]` serial
  line (fps, packets/sec, lost, rejected, RSSI, source IP). `lost` is the link
  number — it comes from gaps in the sequence field, so it sees over-the-air
  loss; `rejected` only counts packets the firmware received and refused. Note
  that `fps` counts buffer flips, so a static source reads as full rate.
- Image orientation and colour order correct (`flip_vertical` / `swap_red_blue`
  resolved to actual values, not left at "probably").
- Disabling the output returns the deck to its baseline frame time — no residual
  viewport passes.
- Enabling with no panel on the network does not stall or crash; it warns.
- Unplugging the panel mid-set does not crash the app. UDP is fire-and-forget so
  this should be free, but confirm.

---

## 7. Known risk on the receiving end

Worth knowing before blaming this module for stutter: the panel library's own
README says of the MatrixPortal S3, *"does not work well with this library. Do
not buy if you want to use with this library and WiFi."* The HUB75 DMA bus
radiates into the ESP32-S3's PCB antenna and desensitises the radio.

It is a signal-margin problem, not a hard failure — reduced range and rising
packet loss, worse the further from the AP. The firmware already ships
mitigations (reduced I2S clock, reduced brightness, WiFi sleep off). If the panel
stutters while PocketVJ's own frame time is unchanged, the link is the suspect,
not this module. Details and further options in the firmware README.
