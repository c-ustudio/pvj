> **SUPERSEDED by `PocketVJ_v0.3_Preload_Fix_REV2.md`.** Task 0 disproved the cost assumptions in this document. Do not implement from it.

# PocketVJ v0.3 — Deck Preload Fix (Claude Code handoff)

**Goal:** kill the clip-switch stall (31–47 fps in SEQUENTIAL @123 BPM, measured Session 9c) by turning ClipEngine into a two-decoder ping-pong that cues the next clip ahead of the beat and swaps instantly.
**Why now:** this is the prerequisite for the visual sequencer (BPM-synced auto-advance fires a switch on every beat/bar) **and** the substrate for Phase 2 dual deck (two concurrent GoZen instances). One fix, three payoffs.
**Base:** `PocketVJ-v0.2/`, Godot 4.6.3.stable, **GL Compatibility renderer**, GDScript with **warnings-as-errors**. Verify every step **on hardware** (Pixel 9a) — headless compile proves nothing about frame time.

---

## 0. What we already measured (don't re-litigate this)

From Session 9c, MANUAL mode + fixed clip (so switching can't contaminate the numbers):

- Effect cost is ~2 fps. **Clip switching costs 15–30 fps.** Do not touch shaders for this.
- Per switch: **~90 ms `set_video_path` (open) + ~130 ms GPU upload.** ~220 ms ≈ 45% of the frame budget at 123 BPM (switch every ~490 ms) — lands exactly on the observed 31–47.

The 90 ms and the 130 ms need **different** fixes. The 130 ms is the bigger half and the easy one.

### Task 0 — confirm the split before building (profile first)

One instrumented build, MANUAL mode, one switch triggered manually. Log wall-clock around:
1. `set_video_path()` return (the open),
2. first rendered frame of the new clip (the upload/first-frame cost).

Split the 90/130 further: how much of the "open" is CPU demux/codec init (potentially deferrable across frames) vs. GPU texture creation (main-thread-bound under GL Compatibility, not deferrable). **This number decides whether the residual open needs engineering or just decoupling from the cut.** Read the on-screen FPS/timings from a screenshot; don't add a build cycle for temporary UI.

---

## 1. Renderer constraint that shapes everything

**GL Compatibility (OpenGL) creates GPU resources on the main thread only.** So we **cannot** move the decode-open to a `WorkerThread` to hide it — GoZen creates the video texture during open, and that must be on the main/render thread. The viable strategy is therefore:

- **Hide the 130 ms upload** by pre-rendering the back decoder's first frame *ahead of the swap*, on the main thread, during the ~490 ms slack — not by threading.
- **Decouple the ~90 ms open from the visible cut** by running it right after the previous swap (on the incoming clip), so the hitch — if any remains — lands on a clip that isn't on screen yet, not on the cut the audience sees.

If Task 0 shows the open is mostly CPU demux (not texture creation), that portion *may* be threadable — treat as a later optimization, not part of this fix.

---

## 2. Design — two-viewport ping-pong ClipEngine

### 2.1 Node change

`clip_engine.gd` today is `class_name ClipEngine extends SubViewport` and *is* the single decoder; `pipeline.gd` feeds `ShaderSlot.set_input(clip_engine.get_texture())`.

Change ClipEngine to a **manager** that owns two decode viewports:

```
ClipEngine            (Node)          class_name ClipEngine     # was SubViewport
├── _dec_a            (SubViewport)   1920x1080, UPDATE_ALWAYS   # decoder A
│     └── VideoPlayback (GoZen)       loop=true
└── _dec_b            (SubViewport)   1920x1080, UPDATE_ALWAYS   # decoder B
      └── VideoPlayback (GoZen)       loop=true
```

- `_front: SubViewport` = the live decoder; `_back: SubViewport` = the cued/idle one.
- `active_texture() -> ViewportTexture` returns `_front.get_texture()`.
- New signal `active_texture_changed(tex: Texture2D)` fires on every swap so `pipeline` re-points `ShaderSlot`'s input (the ViewportTexture object identity changes when `_front` flips — re-pointing a texture reference is free, **no GPU copy**).

**Ripple to fix (warnings-as-errors, so all explicit types):** every reference that treated ClipEngine as a SubViewport — `clip_engine.get_texture()`, `.size`, `.render_target_update_mode` — moves onto `_front`/`active_texture()`. Grep for `clip_engine.` in `pipeline.gd` and the browsers.

### 2.2 Preserve the existing public surface

Keep the names `pipeline` already calls, re-implemented over cue/swap: `scan()`, `clips`, `current_index`, `play_index(i)`, `next_clip()`, `prev_clip()`, `random_clip()`, signals `clips_ready(count)`, `clip_changed(name,index,count)`, `clip_missing(dir)`. Internally they route through the new API below.

### 2.3 New API

```gdscript
# Open clips[index] into the BACK decoder and pre-render its first frame,
# paused on frame 0. This is the ~220 ms of work — done during slack, off the cut.
func cue(index: int) -> void

# Flip front/back: play the (already-warm) back decoder, mute the old front,
# emit active_texture_changed + clip_changed, set current_index.
# Instant — no set_video_path, no upload spike.
func swap() -> void

# Tap-a-slot jump. If index == the cued index -> swap() (instant).
# Else -> un-cued jump: synchronous open into back + immediate swap (one stall,
# acceptable for a manual jump), then re-cue the new next.
func jump(index: int) -> void
```

**`cue(index)` steps:**
1. `var path := ProjectSettings.globalize_path(clips[index])` (GoZen needs a real FS path).
2. Back `VideoPlayback.set_video_path(path)`; seek to frame 0; **pause** (not play).
3. **Mute the back decoder** — GoZen `enable_audio` defaults true; two live decoders = doubled audio. Only `_front` is audible.
4. Let the back viewport render its first frame while paused (it's `UPDATE_ALWAYS`, so the first-frame texture is created and uploaded **now**, during slack — this is what removes the 130 ms from the swap).
5. Store `_cued_index = index`.

**`swap()` steps:**
1. `var t := _front; _front = _back; _back = t`.
2. `_front` VideoPlayback: unpause/`play()`, unmute.
3. `_back` (old front): mute (leave decoding paused or stop — see §4 cost note).
4. `current_index = _cued_index`.
5. `emit_signal("active_texture_changed", active_texture())`.
6. `emit_signal("clip_changed", name, current_index, clips.size())`.
7. **Auto-cue the next** per mode (§3).

**Boot / first load:** `play_index(0)` = synchronous open into `_front` (no preload possible on the very first clip), then `cue(next_index)`.

---

## 3. Cue-ahead, driven by the mode (in `pipeline._process`)

`pipeline._process` already runs the switch clock and today calls `next_clip()`/`random_clip()` (which does the blocking `set_video_path`). **Change the switch-boundary call from "load next" to `clip_engine.swap()`** — the clock logic stays; only the boundary action changes. ClipEngine cues the following clip internally after each swap.

Next-index rule by mode:
- **SEQUENCER (new):** next slot in the arrangement — always deterministic, the ideal case.
- **SEQUENTIAL:** `(current_index + 1) % count`.
- **LFO:** next per the LFO position — deterministic enough to cue the immediate next.
- **RANDOM:** pick-and-remember — choose the random target **one cue ahead** and store it, so `cue()` and the eventual `swap()` use the *same* index (do **not** re-randomize at swap).
- **AUDIO-switch:** reactive. Cue next-in-list as a guess; if the actual mic trigger picks a different clip, accept one stall (or restrict audio-switch to advance-in-sequence). **Ship preload for the deterministic modes first; leave audio-switch on the old path if it complicates this.**

On mode change or manual `prev`/`next`: re-cue the appropriate target.

---

## 4. Two-decoder cost (this is also the Phase 2 smoke test)

Between `cue` and `swap`, keep the back decoder **paused on frame 0**, not free-running: GoZen paused ≈ not continuously decoding, so CPU sits near single-decode except during the cue burst. The **cue burst overlaps the live front decode** — that window is the true two-instance load. **Log frame time during the cue window**; if it spikes, that's your early read on Phase 2 dual-deck feasibility on the Pixel, captured for free.

Mute the inactive decoder always (see `cue` step 3 / `swap` step 3).

---

## 5. HDMI / MIRROR note

For the Waking Life MIRROR use case, HDMI mirrors the phone screen, which shows the `ShaderSlot → QuadWarp` output. So the swap only needs to re-point `ShaderSlot`'s input (via `active_texture_changed`); MIRROR carries it automatically. The DUAL/Presentation (ExoPlayer) path is separate and **out of scope** for this fix (that's the blocked Goal 2). Don't wire swap into the Presentation surface.

---

## 6. Build order

1. **Task 0 — confirm the 90/130 split** (§0). One instrumented build. Don't skip; the ASCII session is the cautionary tale.
2. **Two-viewport restructure** (§2.1–2.2): ClipEngine → Node manager, two decode viewports, `active_texture()`, `active_texture_changed`, fix the `pipeline`/browser ripple. Verify: playback + manual next/prev still work, MIRROR still shows output. No perf change expected yet.
3. **`cue()` + pre-rendered back frame** (§2.3 steps 1–4): kills the **130 ms upload**. Verify on hardware: SEQUENTIAL @123 BPM should jump well off 31 fps.
4. **`swap()` + wire into the switch clock** (§2.3, §3) for SEQUENTIAL/LFO/SEQUENCER. Verify smooth auto-advance.
5. **RANDOM pick-ahead**, then **`jump()`** with the un-cued fallback.
6. **Audio mute** verified (no doubled audio at the swap), **cue-window frame-time log** captured (§4).
7. Leave **audio-switch** on the old path if it's fighting the cue model; note it.

**Success:** SEQUENTIAL @123 BPM holds playable fps (target ~55–60; if a residual hitch remains it's the ~90 ms open, now decoupled from the visible cut — that's the next optimization, not this task's blocker).

---

## 7. Open risks / assumptions

- **Residual ~90 ms open.** Pre-rendering removes the upload half; the open half is decoupled from the cut but may still hitch on the incoming clip. Task 0 tells us how much is CPU-demux (deferrable) vs. texture creation (main-thread-bound under GL Compatibility). Tackle only if it's audible after step 3.
- **GoZen off-thread open — unverified, and likely blocked by GL Compatibility.** Don't design around threading unless Task 0 proves the open is pure CPU with no GL resource creation.
- **Routing assumption:** two decode viewports promoted out of a single one. If you'd rather juggle two `VideoPlayback` nodes inside one viewport (smaller change), confirm first that GoZen keeps decoding a hidden instance — but the two-viewport form is preferred because it *is* the dual-deck substrate.
- **GoZen pause semantics:** confirm `pause()` actually halts decode (assumed for the §4 cost model). If a paused instance still decodes, the two-decoder CPU cost is higher between cue and swap — measure it.

---

## 8. What this unlocks (next handoff, not this one)

Once the swap is instant, the sequencer sits cleanly on top: a `Sequence` (ordered array of clip ids) becomes the source of truth for `cue()`'s next-index, the sequence strip renders it, tap-a-slot calls `jump()`, and BPM auto-advance is just the switch clock calling `swap()` down the arrangement. Because cueing is already sequence-aware here, the strip UI is additive — no rework of the decode path.
