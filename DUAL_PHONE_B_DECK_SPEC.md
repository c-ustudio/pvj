# DUAL-PHONE B DECK — the remote instrument as lane B

Status: **N1 SHIPPED** (b36b42d), **N2 SHIPPED** (d6e26bc — the rig ran
live: the 9a's composited deck on the P8's crossfade), **N3 MEASURED**
(2026-08-18, results in §4), **N4 SHIPPED** (the shared grid + remote triggers — the rig is musical). Remaining: U4 projector eyeball; TD pars with the TD work. Companion to
`SEQUENCER_2_SPEC.md` (whose MixWorld/lane architecture this extends) and
`VIDEO_LINK_SPEC.md` (whose wire this rides). The headline Sequencer 2.0
feature: two full VJ instruments, crossfaded on one projector.

## 1. The vision

Lane B's source becomes a choice, and the crossfade means the same thing for
all of them:

```
lane B source = { LOCAL CLIP  |  REMOTE CAMERA  |  REMOTE COMPOSITED DECK }

  P8 (mixing seat)                        9a (second instrument)
  ┌───────────────────────────┐           ┌──────────────────────────┐
  │ lane A: ClipEngine A      │           │ full PocketVJ: clips,    │
  │ lane B: ◄─── h264 stream ─┼───────────┤ sequences, FX, masks —   │
  │   XFADE, then masks/FX/   │           │ its composited output    │
  │   warp on the MIX         │           │ GPU-blit encoded out     │
  └───────────────────────────┘           └──────────────────────────┘
```

This *unifies the override collision*: an incoming stream stops being a layer
drawn over the mixer (or a camera override replacing the deck) and becomes
deck B — under the crossfade, inside the mask/FX/warp chain, degrading to
pure deck A when the link drops.

## 2. What already exists (survey — the head start is large)

- **The sender side is DONE.** `_on_link_stream_requested`
  (pipeline.gd:3126) already selects the capture by `stream_id`: stream 1 =
  `camera_engine.get_texture()`, **stream 0 = `output_world.get_texture()` —
  the full composited output** (decks, mix, masks, FX, warp). The S3/TD leg
  proved this texture streaming live at 1280×720@60 over the GPU-blit
  encoder feed (M2.5(b)) while the sending phone held 58.6–59.9 fps.
  "Stream your deck to me" is `start` with `stream: 0` — a verb every
  current build already honors. No new sender capability, no new wire verbs.
- **OES-in-a-viewport is proven.** The h264 receive texture is an Android
  ExternalTexture: it may only reach the canvas through a
  `samplerExternalOES` uniform (`LINK_OES_SHADER`, pipeline.gd:304) over a
  1×1 white placeholder, with `modulate` flowing through vertex COLOR. The
  link layer already does this INSIDE `output_world` — the same trick works
  on `_deck_b_rect` inside MixWorld, and `modulate.a` on that rect *is
  already the crossfade*.
- **Freshness is already policy** (`_on_link_freshness`, R5): LIVE shows,
  STALE holds the last frame, LOST hides. Mapped to lane B: LOST hides the
  B rect → the mix degrades to pure deck A. The deck never dies with the
  link.
- **Pull machinery is battle-tested**: `_link_pull_from` handles provider
  retirement, SRT-vs-TCP, stop bookkeeping, validate-then-retire.
- **The constraint**: the Kotlin receiver is single-instance (SEQ2 §3.5) —
  ONE incoming stream. Lane-B-remote and a TD overlay are mutually
  exclusive until the two-slot receiver registry (SEQ2 Stage 3).

## 3. The unified design

`_lane_b_source ∈ { CLIP, NET }`. Cam-vs-deck is NOT a lane B mode — it is
which stream the operator pulled (stream 1 vs stream 0). Lane B consumes
"the incoming stream," whatever it is.

- **CLIP** — Stage 1 exactly as shipped. Engine B renders, the sequencer
  drives it.
- **NET** — `_deck_b_rect` carries the OES material (h264) or the plain
  NetSource texture (jpeg); **engine B sleeps entirely** (the disarm
  discipline). A cost WIN: remote lane B replaces a GoZen software decode
  with hardware MediaCodec. The B sequencer stands down (`_lane_b_drives()`
  gains the CLIP term); the pattern survives untouched for the switch back.
  Grid/strip taps aimed at deck B refuse with a flash — silence reads as
  broken.
- **The over-the-top `_link_layer` stands down** while lane B owns the
  stream (`armed ∧ source==NET`); it returns the moment lane B releases it
  (disarm or switch to CLIP). One NetSource, one destination, no
  double-draw.
- Crossfade, MaskWorld, ShaderSlot, QuadWarp: unchanged. The mix stays
  opaque-black; remote frames are opaque, so MaskOverlay's multiply law
  holds. The MixWorld warm-handoff (e4c2933) covers NET arming for free.
- Local camera is NOT a lane B source (SEQ2 Q2 stands): SRC CAMERA still
  replaces the whole deck. The *remote* camera is just stream 1 landing in
  lane B.

**Warp on the feeding deck (v1 convention):** stream 0 captures post-warp
`output_world`. A phone feeding a mixer runs identity warp — operational
convention, documented in the runbook. A "feeding-a-mixer" pre-warp capture
flag is a later nicety, only if the convention chafes.

## 4. Performance — measured vs. unknown

In hand:
- Deck + GPU-blit encode simultaneously: held 58.6–59.9 fps on the **weaker**
  phone (P8/G3, Session 30 S3 live test). The 9a (G4) takes this role.
- Receiver cost is *below* an already-passed gate: spike S1 passed dual
  1080p GoZen decodes; NET lane B swaps one for hardware MediaCodec
  (12–16 ms measured decode, separate silicon) plus one OES sample.

To measure (Stage N3, before any gig):
- **U1** — 9a under full show load (SEQ auto + heavy FX) + encode, 10 min:
  fps + mali ladder. The S3 test was not a full show load.
- **U2** — P8 with lane B = NET under show load: hitch distribution vs the
  S1 baseline.
- **U3** — phone→phone glass-to-glass latency, h264 GPU path, mirror method
  (stamp machinery exists). Stage-0 jpeg baseline was ~224 ms; this path is
  expected far lower but is UNMEASURED. Decides how live the crossfade
  feels; feeds the beat-alignment budget.
- **U4** — encoder settings for projection: 720p60@4M (current) vs
  1080p30@more; TCP vs SRT phone→phone. Eyeball on the projector.

Latency honesty: the 9a's cuts arrive ~U3 ms late on the projector. Within
bar-level musicality once SEQ2 Stage 2's `beat` verb (law v2, measured)
slaves the 9a's grid; `phase_trim_ms` absorbs the fixed one-way delay.

### N3 MEASURED (2026-08-18 — 10 min soak at full rig load, both phones)

Load: 9a = SEQ auto @142 BPM + Trails (buffer-backed) + 60 fps GPU-blit
encode, USB-powered but thermally not-charging at 43 °C, 20 % battery;
P8 = SEQ auto + one FX on the mix + MediaCodec decode + MixWorld, on
battery, operator actively driving panels throughout. Valid window
t=0–465 s (see the lock event below).

- **U1 — 9a (sender) PASS.** Delivered encode held 58–62 fps for the whole
  window (measured at the P8's LINK RX row — a zero-perturbation remote
  probe), encode 12–26 ms, Mali 419–521 MHz (mid-ladder, headroom above),
  temp steady ~43 °C. Trails + sequencing + encode coexist.
- **U2 — P8 (receiver) PASS-with-note.** Two 170 s screenrecord windows
  (20 278 frames): mean 59.6/59.7 fps, p50 16.63 ms, p95 ~19.1 ms,
  p99 ~23.7 ms, >20 ms 2.5–2.8 %, >34 ms 0.34–0.36 %, max 67 ms. Hitchier
  than spike S1's sterile dual-decode baseline (0.58 % >20 ms) — but the
  run included live panel driving, an FX pass, beat flip AND screenrecord's
  own encoder. Mali 419–649 MHz climbing with temp (38.4→41.7 °C), no
  throttle plateau. Steady-state 60 fps at the gate.
- **U3 — glass-to-glass, mirror method (n=10): full camera loop median
  222 ms (204–250).** Statistically the Stage-0 jpeg baseline (~224 ms) —
  because BOTH measurements are dominated by the shared term: the Android
  camera pipeline (~60–120 ms on these Pixels). The h264/60fps path's win
  lives in the non-camera half. **Deck-path latency (what the crossfade
  feels; no camera in the chain) ≈ loop − camera ≈ 100–160 ms**, matching
  the §9-M2.5 estimate (85–115 ms + display). Method granularity ±17 ms.
  Decomposing tighter needs an external camera; not worth it unless a gig
  says otherwise.
- **U4 — encoder settings: deferred to the first projector session.**
  Current wire: 1280×720@60, ~3.5–4.5 Mb/s observed, TCP, quality 0.75.
  No visible starvation at these numbers on phone screens; the projector
  eyeball decides whether 1080p30@higher-rate earns its bandwidth.
- **The lock event (t≈480 s) — runbook law.** The 9a's screen LOCKED
  mid-soak (hot enough to refuse charge, so stay-awake didn't hold): its
  app paused, the stream died, the P8 held the last frame then degraded
  to pure deck A (R5 doing its job), and the rig auto-healed when the
  screens woke. **A gig rig keeps the feeding phone's display awake and
  cool** — max display timeout, real charging, shade.

## 5. UI and control

- **LANE B panel section**: `B source: NET` toggle (the destination switch —
  one knob, persisted `[seq] lane_b_source`). Refuses NET when the link is
  disabled; boot-restore with the link off falls back to CLIPS out loud.
- **Peer rows** (N2): `PULL DECK` (stream 0) beside the cam pull. Both are
  one `request_stream` through the existing `_link_pull_from`.
- Strip honesty (N2 polish): B chip carries a NET badge; ghost playhead
  hides while nothing local steps.
- Roles stay `main|cam` for now; a `deck` role for prettier peer labeling is
  deferred until the rig proves itself.

## 6. Hazards

1. **ExternalTexture lifetime**: link teardown/rebuild (role flip, link
   disable) frees the receiver under a NET lane B — teardown must degrade
   lane B to CLIPS (toggle mirrored, flash) before the texture dies.
2. **One receiver**: a TD SRT pull and a phone pull fight over the single
   NetSource exactly as today — the destination just moves the collision's
   face. The peer-row bookkeeping (`_link_rx_*`) already referees; lane B
   shows whatever won.
3. **Engine B wake ordering** on NET→CLIP: rebind `active_texture()` BEFORE
   waking the engine, and guard `_on_lane_b_texture_changed` by source, so
   a swap emitted mid-switch can't clobber the OES material.
4. **The shader compiles at runtime** (LINK_OES_SHADER is code-built):
   cache the material — a mid-set source flip must not pay a compile hitch
   twice.
5. **Freshness vs. crossfade**: LOST hides the rect (pure A), it must NOT
   touch `modulate.a` — the crossfade position belongs to the operator.

## 7. Staged plan

- **N1 — the stream lands in lane B** (smallest real step, resolves the
  collision). `_lane_b_source` + OES material on the B rect + freshness →
  rect visibility + engine B sleeps in NET + layer standdown + panel toggle
  + persistence + teardown fallback. Exit: an incoming stream blends A↔B
  under the crossfade on the P8; LOST degrades to pure A; restart restores
  the source; CLIPS switchback resumes the local deck.
- **N2 — PULL DECK.** Stream-0 ask on the peer rows + NET badge + identity-
  warp runbook note. Exit: the 9a's composited deck rides the P8's
  crossfade — the dual-phone rig exists.
- **N3 — the measurements. DONE 2026-08-18** — results in §4: both phones
  held ~60 at full rig load; camera-loop latency 222 ms median with the
  deck path bounded ~100–160 ms; U4's projector eyeball deferred.
- **N4 — the rig becomes musical. SHIPPED 2026-08-18** (phone↔phone; the
  TD par half of SEQ2 Stage 2 stays with the TD work). `beat` verb 1/bar +
  on tempo change/tap, master = role main; slave law IS spike S3's law v2
  (median-5 → 20 ms deadband → 2-bar slew via `BeatClock.slew` → snap only
  on a filtered half-beat); `seq` verb (slot/auto, bar-quantized) applied
  through the same paths as the local widgets; `[link] phase_trim_ms` cfg +
  panel row. **The strip IS the remote**: with lane B on NET, the slot
  bank's LOAD and the AUTO chip command the streaming peer's lane A.
  Verified live: 9a took the master's 40 BPM on the first line and
  cold-joined with exactly ONE snap (+2918 ms, boot misalignment); 91
  messages later corrections oscillate ±20–63 ms, no further snaps —
  at R3's 50 ms gate with ±33 ms of frame-quantization noise inside the
  measurement itself (both ends sample `phase` at frame boundaries), so
  the true grid error sits well under. Remote slot load applied on the
  9a's next bar ("slot 1 → lane A"); remote AUTO verbs delivered and
  applied (caveat: with the peer's deck in SEQUENTIAL mode its own switch
  clock keeps advancing clips — sequencer-auto and mode-clock are
  different drivers, spec §2 as designed). Refinement levers if the gate
  ever pinches: timestamp-compensate phase to the frame boundary, and a
  deadband ≥ the 33 ms measurement noise.

## 8. Open questions

- **Q1** Destination grain: is the one persisted toggle enough, or does a
  gig want per-pull routing (this stream to lane B, that one to the
  layer)? Decide after playing N2; the two-slot receiver (SEQ2 Stage 3)
  reopens this anyway.
- **Q2** Does the 9a want a "performing to a mixer" preset (identity warp +
  encoder settings in one tap)? Decide at the first real rig session.
- **Q3** jpeg fallback path through lane B is untested by design (h264 is
  the show path) — is Stage-0 jpeg worth a single verification pass, or is
  NET lane B documented h264-only?
