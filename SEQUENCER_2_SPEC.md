# SEQUENCER 2.0 — two mixable lanes, four mixable layers, one clock

Status: **DESIGN — no code.** Follows the house discipline: requirements →
survey → architecture → **spikes before building** → staged plan. Companion
docs: `VIDEO_LINK_SPEC.md` (whose §5 Stage 2 this IS — "BPM/beat-phase
share, remote scene triggers, cross-device sequencing"), `GRID_AS_PRIMARY_SPEC.md`
(the grid stays the single visual interface), `TEMPO_MEMO.md` (the tempo
authority model this must not break), `MODULAR_EFFECT_CHAIN_SPEC.md` (the
per-step-FX hook lands there, not here).

## 1. What it must do

A PocketVJ performance today is one deck, one sequence, one link layer.
Sequencer 2.0 turns each phone into a two-lane instrument and the room into
a four-layer mix:

```
             ┌─ LANE A ──  ClipEngine A ─┐
   local     │                           ├─ XFADE ─┐
             └─ LANE B ──  ClipEngine B ─┘         │
                                                   ├─ MaskWorld → ShaderSlot → QuadWarp → out
   remote    ┌─ peer phone (h264/TCP)  ─ alpha ────┤            (the EXISTING chain, unchanged)
   layers    └─ TouchDesigner (SRT)    ─ alpha ────┘
```

- **Two sequencers per app**: lane A and lane B, each an independent
  beat-quantized clip sequence with its own pattern, its own beats-per-slot,
  its own bank of saved patterns — mixed by one crossfader.
- **The extra layers**: the other phone's stream and the TouchDesigner
  stream ride on top with per-layer alpha, exactly as the link layer does
  today — they become part of the *mix vocabulary*, not a separate feature.
- **One clock everywhere**: every lane on every device counts bars from the
  same tempo and phase, shared over the link control channel.
- **Easy at gigs, flexible underneath**: with lane B off the app is
  byte-for-byte today's app. Arming lane B is one toggle. The whole mixed
  set is playable from a stripped performance surface: crossfader, two
  pattern banks, layer alphas.

### Requirements

| # | Requirement | Bar |
|---|---|---|
| R1 | Default = today | Lane B unarmed ⇒ identical behaviour, identical cost. No regression to the single-deck show build. |
| R2 | Frame budget | 60 fps on the **Pixel 8 (G3 — the limiting GPU)** with 2 live decodes + crossfade + one global FX. This is a SPIKE GATE, not an assumption. |
| R3 | Cut accuracy | Local lane cuts land on the beat ±1 frame (the engine already holds-not-blocks; a skipped cut beats a stalled deck). Cross-device phase agreement ≤ 50 ms (≈ 3 frames) — enough for bar-level musicality; NOT sample-accurate audio sync. |
| R4 | Tempo authority unchanged | Nothing auto-sets tempo. `BeatClock` stays the one grid; the mic onset bus stays separate; DETECT proposes, a human presses SET. The link adds a *distribution* path for the grid, never a new authority. |
| R5 | Degrade gracefully | A cold cue holds; a LOST link layer hides (freshness rules stand); a peer that never heard of the new verbs ignores them (unknown-field tolerance is already the wire's law). |
| R6 | Everything persists | Every knob this spec adds gets a cfg key, load-then-merge. (Repays a standing debt: `beats_per_slot` has NO key today and resets every launch.) |
| R7 | The link cannot eat the frame budget | Standing R4 of the video-link spec — remote layers stay drop-never-buffer, depth-1. |

## 2. What exists today (survey, compressed — file refs are current @ 6f2b8b7)

**The deck is a cue pair, not a mix.** `clip_engine.gd` owns two GoZen
decoders as front/back pointers; `swap()` is a hard pointer flip; the back
decoder renders one frame and stops. There is no blend anywhere. A second
*mixable* deck therefore means a **second ClipEngine instance**, not a reuse
of the back decoder.

**Sequencer 1.0** is: one `Sequence` resource (ordered clip ids), one
`SequenceStrip` (bottom row, BPS 1/2/4/8, AUTO, SHUFFLE, 6 named slots), and
pipeline-owned state (`_seq_index`, `_seq_beats_per_slot`, `_on_seq_beat`
subscribed to `BeatClock.beat`). It drives the ONE deck, gated by
`_seq_drives()` = AUTO ∧ non-empty ∧ mode==SEQUENTIAL. "A switch mode of its
own" is explicitly noted in-source as not-done (pipeline.gd:2008).

**Compositing** is a fixed chain inside `OutputWorld`:
source → (MaskWorld) → ShaderSlot → QuadWarp, with `_refresh_output_source()`
as the one routing authority. "Layer" today means exactly one node: the link
`TextureRect` (`modulate.a` = LAYER ALPHA, OES shader for h264), drawn OVER
the warped output. `RegionCompositor` proves multi-decoder viability
(3 × 720p precedent, `MAX_DECODERS := 3`).

**Clocking**: `BeatClock` autoload (bpm/phase/beat/bar signals, tap/set/reset)
with 14 consumers; `GlobalBus.beat` is the separate mic-onset pulse. Tempo
detection is a ~3.5 s background batch that PROPOSES.

**The link** carries video + `hello/start/stop/stats` (+ `srt_arm`/`srt_disarm`
toward TD). **No tempo/beat message exists yet.** Verb-adding recipe is
mechanical (signal → match-case with old-wire defaults → send_* → wire in
`_build_link`, null-guard for teardown).

**Cut physics** (the numbers that bound the design): cue-lead = 171–308 ms
depending on device and bitrate (bitrate, not duration, drives demux; G3 is
~27 % slower); the engine skips a cut rather than stalling; 60 fps holds to
the 300 BPM ceiling on one deck.

## 3. Architecture

### 3.1 The mix bus — `MixWorld`

A new `SubViewport` (`MixWorld`, `_output_px`) containing two full-rect
`TextureRect`s: `deck_a_rect` (opaque) under `deck_b_rect`
(`modulate.a = xfade`). Its texture becomes the deck source:

```
lane B unarmed:  ClipEngine A ───────────────→ (MaskWorld) → ShaderSlot → QuadWarp
lane B armed:    ClipEngine A ┐
                              ├→ MixWorld ───→ (MaskWorld) → ShaderSlot → QuadWarp
                 ClipEngine B ┘
```

- `_refresh_output_source()` stays the ONE authority; it gains the
  `MixWorld` case. When lane B is unarmed, `MixWorld` is
  `UPDATE_DISABLED` and out of the path entirely (R1 — no idle cost; the
  same gate discipline as MaskWorld).
- Crossfade law: **plain linear alpha-over** for v1 (B over A). Equal-power
  curves are an audio instinct; for video, A-visible-at-0 / B-visible-at-1 /
  both-visible-in-between is the honest behaviour. A taste pass on device
  decides if a midpoint dip needs a gamma tweak (open question Q1).
- Global FX/masks/warp apply to the MIX (post-`MixWorld`), unchanged. Per-lane
  FX is explicitly out of scope (it belongs to the effect-chain spec's
  slot future, where a step can one day carry a chain preset).
- `active_texture_changed` rewiring (the existing pattern at swap time) now
  targets the lane's rect in `MixWorld` instead of ShaderSlot directly —
  same one-liner, two instances.
- ⚠️ `MaskOverlay`'s own docstring flags that deck-B-over-deck-A breaks its
  black-clear multiply assumption. It draws LAST over the composite, so the
  multiply should still be sound *post-mix* — but this is a **verify-by-eye
  item in Stage 1**, not an assumption.

### 3.2 Lanes — `SeqLane`

Extract Sequencer 1.0's pipeline-resident state into a small class, two
instances:

```gdscript
class SeqLane:            # plain object owned by pipeline — not a node
    var sequence: Sequence          # its own .tres
    var engine: ClipEngine          # lane A → existing engine; lane B → the new instance
    var beats_per_slot: int = 4     # per-lane; finally gets a cfg key
    var auto: bool = false
    var index: int = -1             # playhead (id-resolved, see hazards)
    var beat_count: int = 0
    var bar_offset: int = 0         # phase offset in beats (see 3.3)
```

- **Lane A** wraps the existing engine and keeps the *entire* current mode
  system (MAN/SEQ/RANDOM/LFO, audio-switch, LFO sweeps). Nothing moves.
- **Lane B is sequence-only by design.** No modes, no audio-switch, no LFO.
  Its vocabulary: pattern plays on the grid, tap-a-cell-to-pin while armed,
  crossfader decides how much of it you see. This is the easy/flexible line:
  flexibility lives in *what's in the pattern*, not in more machinery.
- Both lanes subscribe to `BeatClock.beat` through one dispatcher
  (`_on_seq_beat` generalized), each counting against its own
  `beats_per_slot`.
- Sequencer 1.0's open decision — "gate `_audio_switch` when AUTO is on" —
  is **resolved here**: the mic transient may only steal a deck that no
  armed lane owns. Lane A armed ⇒ `_on_audio_onset` stands down for engine A
  (it already never touches engine B).

### 3.3 Clocking, quantization, and the cue-lead wall

- Slot boundaries stay beat-quantized on `BeatClock.beat` — Sequencer 1.0's
  model, now ×2.
- **The stagger rule**: when both lanes would cut on the same beat, their
  cue windows collide (two GoZen opens in one 171–308 ms window, on the G3
  that already has ~27 % less headroom — and whether opens serialize on one
  worker is SPIKE S2's question). Default lane B to `bar_offset = 2` beats
  (half-bar against lane A at BPS 4) so cue windows interleave. The offset
  is a lane setting (0 = allowed, on your head; the UI defaults it on).
- Sub-bar slots (BPS 1 at high BPM) already flirt with the cue-lead wall on
  ONE deck. Two decks make the ceiling lower. The existing hold-don't-block
  behaviour is the safety net; the spec adds a visible `HELD` flash on the
  strip when a lane skips (silent skipping at a gig reads as a bug).
- Encode discipline carries over: lane clips at ~6–7 Mbps (bitrate drives
  demux). Worth a `SEQ` doc note in the clip-prep runbook.

### 3.4 Cross-device: three verbs on the existing wire

All ride TCP 4850 newline-JSON, added by the standing recipe (defaults =
old wire's meaning; unknown fields ignored). **The main phone is always
tempo master** (it is the mixing seat; the 9a is "nobody touches it at
showtime"). TD is always a slave.

**`beat` — the grid, distributed** (the Stage-2 promise):
```json
{"t":"beat", "bpm":128.0, "beat":517, "bar":129, "phase":0.23}
```
- Sent by master: on every `bar` (1 per bar ≈ every 2 s) + immediately on
  `bpm_changed` and `reset_grid`. Cheap, self-healing, no clock streaming.
- Slave phone: `BeatClock.set_bpm(bpm)` (bypassing the human-SET rule is
  legitimate here — the value WAS human-set, on the master; R4's authority
  is preserved because the link distributes, never estimates). Phase:
  compute local-vs-master phase error; if |err| > half a beat, hard
  `reset_grid()` snap; else nudge by ±1 % rate for one bar (a visible
  stutter-free correction — video tolerates what audio never would).
- Latency honesty: one-way link delay makes the slave's grid trail by
  ~10–50 ms on LAN. Within R3's 50 ms bar. A per-peer `phase_trim_ms`
  setting (measured once with the latency stamp, stored in cfg) is the
  manual correction; automatic RTT/2 estimation is a later refinement, not
  v1 (measure first — §5 S3).
- TD: `link_thread._handle_msg` queues it; `beacon_exec._apply_cmds` writes
  custom pars on the `pvj_link` COMP (`Bpm`, `Beat`, `Bar`, `Phase`,
  `Lastbeatat`). TD networks bind to pars; the show side decides what beat
  means there. (TD is a *consumer* of the grid, never a source.)

**`seq` — remote pattern triggers** (the "remote scene triggers" promise):
```json
{"t":"seq", "lane":"a", "op":"slot", "slot":3, "at":"bar"}
{"t":"seq", "lane":"a", "op":"auto", "on":true}
```
- Lets the main phone flip the 9a's pattern (or arm/disarm its lane) from
  the mixing seat, quantized to the receiver's next bar (`"at":"now"` for
  panic). Receiver treats it exactly like a local slot-LOAD tap — widgets
  emit intent, pipeline wires; a remote verb is just another widget.
- Sent to TD it is a *scene trigger*: same queue path, applied as a
  `Scene` par change on `pvj_link` — the show file binds it (out of
  PocketVJ's scope beyond delivering the par).

**`stats` extension (free):** lanes report `lane_a`/`lane_b` slot+pattern in
the existing stats dict so the master's peer row can show what the remote
deck is doing. Old peers ignore the fields.

### 3.5 The four-layer mix and its limits

Peer + TD layers stay exactly what they are — link `TextureRect`s with
alpha — but become TWO of them. That requires the one real plugin change in
this spec: **the Kotlin Receiver is single-instance today** (`receiver`
whole-object swap; `start_receive_srt` stops the TCP listener). Plan:
a two-slot receiver registry keyed by texture id (`receiver_tcp`,
`receiver_srt`), each with its own SurfaceTexture/decoder — they already
share nothing. Decode budget: two MediaCodec sessions (peer + TD) on top of
two GoZen decodes is exactly SPIKE S4's question; hardware decoders are
separate silicon (the set-recording lesson) but nothing is assumed.

UI: the link panel's single LAYER ALPHA becomes per-peer rows (the peer
rows already exist — each gains its own alpha slider). `NetSource` grows a
second instance; its freshness/UI plumbing is already per-instance.

**Not in v1**: remote layers entering `MixWorld` pre-FX (they'd gain warp
and effects but cost another full-frame pass and reorder the chain);
audio over the link (the beat verb may make it unnecessary — spec Q3 of the
link doc said exactly this); blend modes beyond alpha.

### 3.6 The gig surface

- **Nav bar**: `MODE` panel gains the LANE B section (arm toggle, BPS,
  bar-offset). No new nav cells — the bar is full and the conventions cap
  labels at 8 chars.
- **SequenceStrip** grows a lane switch (`A | B` chips, M8 green active):
  one strip, two models. The hidden lane keeps running; its slim playhead
  ghost-row (2 px line above the strip) keeps it honest. (648 logical px of
  height is the whole screen — two full strips would eat the preview.)
- **The grid arms per-lane**: tap-to-play targets the *selected* lane; drop
  onto the strip queues into the selected lane's sequence. CURATE stays
  global (the LIVE pool is shared — both lanes draw from one library).
- **PERF strip** — the actual gig surface. PERF mode currently hides all
  chrome; Sequencer 2.0 gives it a minimal always-on-top strip (UI layer,
  never projected): `[A1..A6] ─── XFADE ─── [B1..B6] · [P] [T]` — pattern
  slots as one-tap bar-quantized loads, the crossfader, peer/TD alpha
  micro-faders. Three-finger tap still exits. This is the "easy to use":
  the whole mixed set is those ~15 targets.
- **Crossfader physical mapping**: knob 1 of the macropad is the natural
  crossfader; noting the conflict — the macropad spec has knob 1 penciled
  as FX intensity. Resolution belongs to that spec's rehearsal phase, not
  here; the on-screen fader is the v1 truth.

#### 3.6a Deck colour — AS BUILT 2026-09-19 (`0bdd753` · `01fcb96` · `d268c42`)

The A|B chips above were 40–100 px wide at font 13, and **nothing in the clip
grid referenced a deck at all**: the only thing naming which deck a tap would
fire was `SEQ A` at font 14 / 60 % alpha — the dimmest text on the screen.
Operator verdict on the panel: "hard to know what clips belong to what deck".

**THE RULE, and it is the whole design:**

> **CHROME follows the ARMED deck. IDENTITY does not.**

- **Chrome** (folder tabs, DONE, CURATE, the DECK filter, both rules,
  SLOT/SAVE/LOAD, BAR-SLOT, SHUFFLE, AUTO, the LABEL field, status flash, drop
  marker, and the hairline around every cell and slot) wears the armed lane's
  hue. `M8Palette.AMBER` (#FFB000) is the first secondary accent this palette
  has ever carried; green is lane A, amber is lane B, everywhere.
- **Identity** (the playing rings and the per-cell `A` / `B` / `AB` membership
  badges) does NOT follow the armed lane. **Both decks play at once**, so deck
  A keeps a green ring while deck B is armed — "the other deck is still running
  over there" is exactly what the operator needs to keep seeing. A clip in both
  sequences shows BOTH badges rather than a third hue, which is what keeps
  "green = A, amber = B" true on every surface.
- **RED still outranks the deck**: DEL keeps red text on an amber border.

⚠️ **A LIVE BUG FELL OUT OF THIS.** `ClipGrid` is constructed with deck A's
engine, so with lane B armed a tap set the highlight optimistically and deck A's
`clip_changed` echo pulled it straight back — **the ring pointed at a clip you
had not fired**. One index per deck (`_active_a` / `_active_b`, pipeline pushing
engine B's via `set_deck_active`) makes that structurally impossible.

⚠️ **THE SIZES IN THESE WIDGETS ARE LOGICAL px, SCALED 1.667×.** `project.godot`
sets no base viewport, so Godot's default 1152×648 + `stretch/aspect="expand"`
lays the UI out in **~1454×648** and scales it to the 9a's 2424×1080. The line
above ("648 logical px of height is the whole screen") was right and is now
measured. Consequence: the old 260×176 cells were **433×293 REAL pixels**, which
is why only 5×2 = **10 of 220 clips** fitted while the chrome looked tiny beside
them. Shrinking the cell to 151×115 buys BOTH — **8×3 = 24 clips and bigger
type**. The two goals were never in tension; the oversized cell was.
Type now comes from named scales (`CHROME_FS`, `BTN_H`, `TITLE_FS`, `CELL_FS`,
`DECK_FS`) instead of per-node overrides — which is how this chrome drifted to
13–16 px under a 20 px theme, where raising the theme could never reach it.

**The split, on demand**: a `DECK: ALL → A → B` cycle button filters the grid to
one lane's sequence. A permanently split grid was rejected — at 2 rows it gives
5 clips per deck out of 220. It disarms on open, the same structural rule CURATE
follows, and re-filters on membership change.

⚠️ **Four regressions shipped in `01fcb96` and were fixed in `d268c42`; the
lesson is one lesson.** Taking over a themed control means inheriting everything
the theme was doing for you, not just its colour: a bare `StyleBoxFlat` dropped
the 10 px content margins and the transport row collapsed into `SLOT 1SAVE LOAD
DEL`; and `_mk_button` was silently collecting the deck buttons into the chrome
list, so the chrome pass overwrote their filled styling while the text stayed
BLACK — two invisible buttons. **The headless parse check passed cleanly through
all four.** Invisible buttons, collapsed padding, a green LineEdit and an
inherited scroll position are all valid GDScript; only reading a device capture
caught them.

Device-verified on both phones (9a + P8) with both decks live.

⚠️ **THE PERF STRIP INVERTS THIS RULE, ON PURPOSE** (`dfa8796`). ClipGrid and
SequenceStrip show ONE lane at a time, so their chrome follows whichever is
armed. The PERF strip is `[A1..A6] ─── XFADE ─── [B1..B6] · [P] [T]` — **both
banks are on screen together, so there is no armed lane to follow and everything
in it is identity**: the A row lights GREEN and the B row lights AMBER at the
same time, and the two lane captions carry their deck's hue while
`A · XFADE · B`, `P` and `T` stay neutral. Do not "fix" this strip to follow an
armed lane; it has none.
- The crossfader's FILL is amber and its grabber is WHITE. The fill grows from
  A's end toward B's, so the colour reports **how much deck B is in the mix**
  rather than decorating; the grabber belongs to neither deck and must be
  findable by thumb, in the dark, at either extreme.
- `P` and `T` keep green — the peer phone's and TD's layer levels are not decks.
- ⚠️ `_style_slot`'s `hue` parameter DEFAULTS to GREEN, so the call site in
  `_restyle_slots` passing `AMBER if lane == 1 else GREEN` is the entire change.
  Without it the code compiles, runs, and renders a perfectly green B row. The
  first attempt at that edit failed silently on an indentation mismatch and the
  headless parse check was happy. Verify that line by grep, not by parsing.

### 3.7 Persistence (`[seq]` section — new)

`lane_a_bps`, `lane_b_bps` (repays the missing-key debt), `lane_b_armed`,
`lane_b_bar_offset`, `xfade` (last position, clamped), `lane_a_slot`/
`lane_b_slot` (last-loaded pattern), per-peer `alpha_%s` and
`phase_trim_ms_%s` keyed by peer NAME (never IP). Sequences persist as
today (`sequence.tres` becomes `sequence_a.tres`/`sequence_b.tres`;
migration: existing file loads as lane A). Load-then-merge, every write.

**As built (Stage 3.3, 2026-09-15):** per-peer alpha persists as ONE dictionary,
`[link] peer_alpha = {"Pixel 9a": 0.6, "TD-MAIN": 0.35}`, not as `alpha_%s` keys —
beacon names carry spaces, which ConfigFile keys cannot hold safely. The pre-3.3
`layer_alpha` stays as the default for a peer with no saved level, so an upgrade
changes nothing on screen. A slot's layer shows the level of the peer currently
streaming into it. `phase_trim_ms` is still the one global trim.

## 4. Hazards carried forward (the trap list, now ×2)

1. **`_cued_index` reindexing lies** — the grid spec's rule ("anything that
   reindexes `clips` must re-resolve BOTH decoders by path") now applies to
   FOUR decoders. The lane refactor must route all reorder events through
   one re-resolver that walks both engines.
2. **Widget `setup()` after `add_child`**; `dict.get() as Array` throws on
   miss; `Sequence` reuses `Resource.changed` — no second `changed` signal.
3. **Thumbnail capture lives in `swap()`** — two engines will both capture;
   idempotent by clip id, but verify no worker contention.
4. **Every per-frame write change-gated** — the xfade slider drives
   `deck_b_rect.modulate.a` at gesture rate: gate at >0.02 like every other
   colour write; `MixWorld` disabled when unarmed.
5. **Beat-handler teardown guards** — the new verbs' handlers null-check
   link nodes (queue-freed emitters fire until end of frame).
6. **Foregrounding**: Godot pauses on Android `onPause` — a backgrounded
   slave stops consuming `beat` and drifts; on resume the next bar message
   hard-snaps it (design makes this self-healing; note it in the runbook).
7. **The two ID spaces** (Sequence ids vs engine indices) stay bridged
   per-jump — lane B uses the same `_engine_index_for_clip_id` resolver
   against ITS engine's `clips`.

## 5. Measurements that gate implementation (run BEFORE building — house law)

- **S1 — dual live decode on the G3**: two 1080p@11 Mbps GoZen decodes
  rendering simultaneously + ShaderSlot FX, 10 min: fps distribution + mali
  `cur_freq` ladder position. Variant: B at 720p@6 Mbps. **Gate: 60 fps
  held (dips ≤ the documented pre-existing 52–55 floor). Fail ⇒ lane B is
  720p-only by spec, re-spike.**
  **MEASURED 2026-08-17 — PASS, lane B may be 1080p.** Branch
  `spike/seq2-s1` (`tools/spike_s1.gd`: real `_make_decoder` pattern +
  MixWorld-shaped blend with live sine xfade + one ShaderSlot `rgb_shift`
  pass; 0.5 s windows, 5 s warmup excluded). Pixel 8, all autoloads live
  except BpmSpike:
  - *control* (1×1080p25@10.6M, 180 s): p99 = 16.67 ms, hitches>20 ms
    0.24 %, max 66 ms.
  - *dual* (2× real 1080p25@10.6M, 600 s, 35 350 frames): p50/p90/p95 =
    16.67 ms, p99 = 18.06 ms, p99.9 = 72 ms, max 133 ms, hitches 0.58 %.
    **Steady-state locked 60.** Every sub-55 window sits at the ~30 s
    simultaneous double loop-wrap seek (45–50 fps for ~1 s at t≈31/61/91…)
    — a spike artifact: same-length clips started together. Real lanes
    cue-swap on the pre-armed back decoder and the stagger rule keeps
    wraps apart; still, treat "both lanes seek in the same frame" as the
    known worst case (S2's question).
  - *synth ceiling* (2×1080p60@11M, 300 s): p95 = 16.67 ms, p99 =
    18.06 ms, max 100 ms, hitches 0.74 % — same wrap-only dip signature.
    Dual decode survives even 60 fps content.
  - mali: 85 % of dual-burn samples at 302–337 MHz (synth: ≤419 MHz),
    mid-ladder — decode is CPU-side; **big GPU headroom for more FX**.
- **S2 — cue collision**: both lanes cue in one beat window at 140 BPM,
  100 cycles: does the second open serialize behind the first (one worker?)
  and what's the combined worst-case vs the 171–308 ms budget? **Gate:
  staggered lanes never skip; same-beat lanes skip visibly-but-rarely
  (<2 %).** Decides whether the stagger default is advisory or enforced.
  **MEASURED 2026-08-17 — PASS both modes; stagger stays ADVISORY (default
  on).** `tools/spike_s2.gd` on `spike/seq2-s1`: two front/back lane pairs,
  real 1080p25@10.6M clips, 100 cycles @140 BPM, deadline = cue + 1 beat:
  - **No serialization**: same-frame opens run in parallel on the
    WorkerThreadPool (both start within ~30 ms, both END within ~30 ms —
    not one-behind-the-other).
  - *same-beat*: **0/200 skips**. Opens p50 = 337 ms, p99 = 430 ms — the
    worst open grazes the 428.6 ms beat. But the frame loop pays:
    **3.1 % hitches** (310/10069, ≈3 hitchy frames per collision, worst
    133 ms).
  - *staggered (+2 beats)*: **0/200 skips**, opens p50 = 307 ms, p99 =
    392 ms, and hitches collapse to **0.24 %** (25/10364) — the S1 control
    baseline. Stagger buys back essentially all frame-loop damage.
  - Consequences: (a) enforcement is unnecessary — collisions never skip;
    keep `bar_offset=2` as the default and let openers collide when the
    performer forces it; (b) **the 171–308 ms cue-lead budget is a 720p
    number — 1080p@10.6M on the G3 runs 307–430 ms**, so lane cue-lead
    must be ≥1 beat at ≤140 BPM (2 beats at higher BPM) for 1080p
    content.
- **S3 — beat-share drift**: `beat` at 1/bar between two phones on the show
  WiFi, 15 min: phase-error distribution (log both `BeatClock.phase` on a
  shared trigger; the link latency stamp is the cross-check). **Gate: p95
  ≤ 50 ms with the nudge law; hard-snaps ≤ 1/session after warmup.**
  **MEASURED 2026-08-18 — PASS (marginal), and the naive law is DEAD.**
  `tools/spike_s3.gd` on `spike/seq2-s1`, P8 master → 9a slave, TCP
  newline-JSON 1/bar @140 BPM, 15 min each run, idle link (worst case:
  WiFi power-save jitters delivery by ±100 ms at this packet rate):
  - *Run 1, §3.4's law as written* (react per message, full 1-bar gain):
    **FAILED** — p95 = 120 ms, 8 hard snaps, all snap/counter-snap pairs.
    Diagnosis: corr(delivery-jitter, measured err) = −0.80 and true clock
    bias only +9–15 ms — the law was chasing the NETWORK, not the clock.
  - *Run 2, law v2* (median of last 5 bars, 20 ms deadband, correct over
    2 bars, snap only on filtered half-beat): **0 snaps, filtered phase
    p50 = 18 ms, p95 = 51.0 ms** (raw measurement p95 stays ~100 ms —
    that's the idle-link jitter, absorbed; one 644 ms WiFi stall passed
    through as an 82 ms filtered blip).
  - Verdict: 51.0 vs 50 is at-gate on an idle link; show traffic keeps
    the radio awake (video streaming) so real conditions should sit
    comfortably under. **Consequence for §3.4: the slave correction law
    IS law v2** — median-5 estimator + deadband + 2-bar gain + filtered
    snap; the one-outlier snap in the original text must not be built.
    `phase_trim_ms` still owns the ~15 ms one-way bias.
- **S4 — the full room**: 2 GoZen + peer MediaCodec + TD MediaCodec + mix +
  FX on the G3. **Gate: 60 fps. Fail ⇒ document the supported layer combos
  (e.g. "2 lanes + 1 remote") — a smaller honest instrument beats a
  stuttering big one.**
  **Instrument (built 2026-09-15, `0efb71a`):** `scripts/frame_sampler.gd`, armed
  from settings.cfg `[perf] s4_run / s4_secs / s4_delay` — S1's window +
  percentile law inside the real app, logging `[s4]` lines and
  `user://s4_<run>_<unix>.csv` with a header of what the rig actually was.
  ⚠️ **NOT comparable to S1's numbers:** S1 timed `_process`'s `delta`, and this
  project leaves Godot's `application/run/delta_smoothing` at its default (on);
  S4 times raw `Time.get_ticks_usec()` spans between frames, per the method note
  below. The 9a smoke run (RANDOM, ASCII, 30 s, 5 s after boot) read mean
  59.42 fps but p99 37.9 ms and 24% of spans over 20 ms, window minimums down to
  2.3 ms — uneven `_process` pacing, not dropped frames. So S4's gate is judged
  against S4's OWN control runs (same instrument, same clip, same length, deck in
  MANUAL), never against S1's 18 ms.

  **RESULT (2026-09-18, 9a, HDMI to the NEC P506QL, DUAL·TEX, deck MANUAL,
  effect RGB Shift, three 300 s windows with the same instrument):**

  | run | streams | mean fps | p50 | p95 | p99 | max | spans >20 ms |
  |---|---|---|---|---|---|---|---|
  | `ctrl` | none | 58.85 | 16.52 | 26.35 | 32.11 | 101.6 | 26.4% |
  | `tdlive` | TD on lane B, xfade 0.5 | 58.30 | 16.56 | 26.76 | 34.17 | 94.4 | 27.4% |
  | `full` | peer + TD, both live | 58.20 | 16.61 | 26.91 | 35.07 | 113.0 | 27.8% |

  **Verdict: the full room costs 0.65 fps (1.1%) and +2.96 ms at p99 against its
  OWN control. The combo is supported — nothing needs documenting away.** The
  gate's absolute 60 fps is reached by no run INCLUDING the stream-free control
  (58.85), which is exactly the uneven `_process` pacing the instrument note
  above predicts and not a cost of the room; judged against the control, as this
  section requires, the full room passes. Mali `cur_freq` medians were 580 MHz
  for both `ctrl` (234/300 samples) and `tdlive` (210/300) — a live 1280x720 SRT
  decode plus a 50/50 composite did not move the GPU ladder at all, and the
  projector blit held 58–60 fps at 0.30–0.43 ms swap throughout. TD's stream is
  NOT stable (14 STALE->LIVE round trips in `tdlive`'s 5 min, 10 in `full`) but
  the blips cost nothing measurable: windows within 2 s of one averaged 59.24 fps
  against 58.16 away from them. ⚠️ Thermal state was NOT equal and favours the
  control — `full` ran at thermal 3, `ctrl` at 2, `tdlive` at 1 as the room
  cooled — so the full room's small deficit is partly heat, not layers.
  ⚠️ **Two windows were voided and re-taken; both failures are the lesson.** The
  first control had the deck in SEQUENTIAL with effect Off and TD joined it at
  t=26 mid-window: it read mean 50.78 fps with 434 ms stalls at an IDLE GPU —
  clip-load churn, not stream load, and unattributable after the fact because the
  app's log had rolled out of the ring. A second window armed with
  `lane_b_source=TD` measured an absent stream, because the TD pull is manual
  (both auto-pull paths filter `role == "cam"`) and does not survive the app
  restart every armed run begins with — it must be re-tapped between launch and
  the window, which is what `s4_delay=180` bought.
- Method notes (standing): mali freq proxy not gfxinfo; both phones; a
  control run before attributing regressions; `Time.get_ticks_usec()` spans
  not frame deltas.

## 6. Staged plan

**Stage 0 — spikes S1–S3** (S4 waits for Stage 3's plumbing). Each is a
day-scale throwaway on a branch; numbers land in this file.

**Stage 1 — the local instrument.** `MixWorld` + second `ClipEngine` +
`SeqLane` refactor (lane A absorbs Sequencer 1.0 unchanged) + strip lane
chips + grid arming + `[seq]` persistence + audio-switch gating decision +
the `HELD` flash. Exit: two patterns mixing on one phone, xfade on screen,
R1 verified (lane B off ⇒ old behaviour), MaskOverlay verified by eye,
60 fps per S1's gate.

**Stage 2 — one clock, many devices.** `beat` verb (master send, slave
nudge/snap law, cfg `phase_trim_ms`), `seq` verb (remote slot/auto,
bar-quantized), `stats` lane fields, TD pars (`Bpm/Beat/Bar/Phase/Scene`)
via the queue path. Exit: S3's gate met live; a pattern flip commanded from
the main phone lands on the 9a's next bar; TD pars tick.

**Stage 3 — the four-layer room.** Kotlin two-receiver registry, second
`NetSource`, per-peer alpha rows, PERF strip. Exit: S4 run and its verdict
written here; the PERF strip drives a full mixed set hands-on.

**Stage 3 progress (2026-09-15):**
- **3.1 — two-slot receiver** (`223f387`): `receiverTcp`/`receiverSrt` in the
  plugin, per-slot Stats, slot-scoped stop/is_receiving/get_stats; NetSource's
  rearm made per-slot.
- **3.2 — the TD slot** (`bab1ed2`): TD gets its own lazily-built NetSource,
  layer and provider record; pulls route by transport instead of swapping.
  Lane B's source became CLIPS | PEER | TD, because 2C already rides TD's deck
  on lane B. **Device-verified the same day** — P8 as main, 9a as cam, TD
  `pvj-link.5`:
  - peer and TD live **at once**: `LINK RX 60fps LIVE  TD 64fps LIVE`,
    sustained ≥40 s with no drop;
  - pulling TD did **not** stop the peer — the 9a kept sending at 58–59 fps and
    the P8's TCP :4853 connection stayed ESTABLISHED (pre-3.2 this pull sent
    the 9a a stop);
  - STOP on the TD row stops the TD slot only (UDP :4860 socket gone, peer TCP
    still ESTABLISHED) and parks TD's `srt_out` (Active → False within 2 s,
    instrumented rerun);
  - lane B cycled TD → PEER → CLIPS with both streams live (log-verified).
  - NOT verified: link-teardown `srt_disarm` parting · N4 seq verbs reaching
    TD with lane B on TD · per-slot layer stand-down by eye (captures of a
    playing deck at xfade 0.28 / alpha 0.35 cannot prove it).
  - ⚠️ **S4's first data point:** on the P8, two MediaCodec decodes + the
    GoZen deck + lane B armed took thermal status 2 → 3 → 4 (critical) in
    ~10 min while charging, and deck fps fell 55 → 11. The full room is not
    free on the G3; S4 must run on a cool, unplugged phone with a control.
- **3.3 — per-peer alpha rows** (this commit): each pullable peer row carries its
  own LAYER ALPHA; a slot's layer shows the level of the peer streaming into it;
  levels persist by name in `[link] peer_alpha` (see §3.7 as-built). **Device-
  verified 2026-09-15** (P8 main, 9a cam, TD `pvj-link.5`, both streams LIVE):
  PIXEL 9's `+` → `alpha Pixel 9a = 0.40 (slot: peer)`; TD's `−` →
  `alpha TD-MAIN = 0.40 (slot: td)`; row labels match; the saved dict survived an
  app restart (a post-restart save still held both values). NOT verified: the
  layer opacity by eye (a playing deck cannot prove it). ⚠️ UX hazard seen on the
  way: a stale view of the peer list let two taps meant for PIXEL 9 move TD's
  level — the code attributed them to the row actually under the finger, but with
  one control per peer a shifted list moves the WRONG peer. The PERF strip's
  fixed `[P] [T]` faders are the performance answer; the panel rows are setup.
- **3.4 — the PERF strip** (this commit): `[A1..A6] ─ XFADE ─ [B1..B6] · [P] [T]`
  on the UI layer as the chrome's sibling, shown only in PERF and only in DUAL
  (MIRROR projects the phone screen). Slots are one-tap, bar-quantized loads
  through the `_seq_pending` queue (drained on every downbeat, link or not); with
  lane B on a stream the B row commands that stream's instrument (N4). The
  crossfader is the operator's path (`_set_xfade_manual`, automation yields) and
  follows automation back; P/T move the level of whoever is on each slot (3.3).
  **Device-verified 2026-09-15 on the 9a** (DUAL, lane B unarmed): PERF leaves
  only the strip; an empty slot flashes `SLOT 2 EMPTY`; A1 queues, loads on the
  next bar and lights; the crossfader drags 0.01 → 0.95; BACK restores the UI and
  hides the strip. The first run exposed a latent crash — `_resync_seq_index_to_
  current()` called `_seq_strip` unguarded, and the strip only exists once the
  clip grid has been opened, so ANY non-strip slot load (OSC `/pvj/seq/slot`, a
  link seq verb, PERF) hit a SCRIPT ERROR on such a launch; guarded, retested
  clean. NOT verified: the B row with lane B armed (local and remote), P/T with
  live streams, the MIRROR hide (no HDMI attached), the three-finger exit (adb
  cannot multitouch — BACK was the exit path tested).
- **S4 ran 2026-09-18 and Stage 3 is closed** (numbers and caveats in §5): three
  300 s windows on the 9a — the full room (peer + TD live, lane B armed, FX on,
  DUAL·TEX to the projector) held 58.20 fps mean against a 58.85 fps stream-free
  control, +2.96 ms at p99 and +1.4 points of >20 ms spans. Two remote decodes
  cost about 1%; the supported-combo fallback in the gate is not needed.

**Later / explicitly deferred**: per-step FX-chain presets (owned by
`MODULAR_EFFECT_CHAIN_SPEC.md` once slots exist), remote layers pre-FX,
blend modes, auto latency compensation, Ableton Link (the tempo memo's
"real ceiling" note — if it ever lands it feeds the MASTER, preserving the
authority chain), audio over the link.

## 7. Non-goals

No step-grid drum-machine UI (slots ARE the steps; the grid is the
palette). No per-lane effect chains in v1. No third local lane (two
1080p decodes is already the spike question; the mix vocabulary comes from
four LAYERS, not N decks). No free-topology routing (the node-patcher is
the next app). No tempo estimation changes of any kind.

## 8. Open questions

- **Q1** Crossfade curve: linear alpha vs slight midpoint lift — taste call
  at the first Stage 1 device session.
- **Q2** Does lane B ever take CAMERA as a source? (One camera owner ever —
  it would steal from lane A/link camera mode. Default NO; revisit if a
  gig wants cam-vs-clips mixing.)
- **Q3** Pattern slot count: 6 per lane (12 total) fits the PERF strip;
  does muscle memory want bank pages instead?
- **Q4** Should `seq` slot loads also carry `xfade` scenes (load B + fade
  over 4 bars as one gesture)? Sugar; decide after playing Stage 1.
- **Q5** The 9a as a THIRD sequencer lane (its output is already a layer on
  the main phone): the `seq` verb makes it playable from the main seat —
  is that enough, or does the main phone want to *edit* the remote
  sequence? (v1: play yes, edit no — editing is a walk-over-and-tap.)
