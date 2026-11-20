# PocketVJ v0.3 — Deck Preload Fix (REV 2, post-Task-0)

**Supersedes** `PocketVJ_v0.3_Preload_Fix.md`. Task 0 (commit `94f8bb4`, `SESSION_10_TASK0.md`) measured the switch cost on device and **the original attribution was wrong**. §1, §2.3 and §7 are rewritten around what was actually measured. The two-decoder ping-pong is still the right fix — for a different reason, and it is now a *simpler* job than REV 1 assumed.

**Base:** `PocketVJ-v0.2/`, branch `refactor/deck-preload`, Godot 4.6.3, GL Compatibility, GDScript, warnings-as-errors.
**Verify every step on the Pixel 9a.** Headless compile proves nothing.

---

## 0. Measured reality (this replaces every cost assumption in REV 1)

720p library (1280×720), 4 consecutive switches, MANUAL + FX Off + **audio-switch off**, 0 masks:

| | typical |
|---|---|
| `set_video_path()` return — "the open" | **15–35 ms** (not 90) |
| ↳ of which `close()` | **~25 ms** — essentially all of it |
| open → first rendered frame | ~130 ms |
| ↳ main thread **blocked** on demux | **~118 ms** |
| ↳ `video.open()` on worker (CPU demux) | ~120 ms |
| ↳ Y/U/V/A texture create (GPU) | **1–4 ms** |
| tap → first frame | 139–167 ms |

**Total ≈ 150 ms/switch** ≈ 30% of budget at 123 BPM → matches Session 9c's 31–47 fps. The arithmetic held; the attribution did not.

Three conclusions that drive this document:

1. **There is no GPU upload problem.** Real texture creation is 1–4 ms at 720p (~5–10 ms including the following frame's overshoot; ~12 ms at 1080p). REV 1 was built on hiding a "130 ms main-thread-bound GPU upload." That thing does not exist.
2. **The ~118 ms is wasted parallelism, not work.** The demux already runs on a worker thread. `VideoPlayback._process` calls `wait_for_task_completion()` on the very next frame, so of ~120 ms of threaded work we use ~2 ms of overlap and block for ~118. **We are not making anything faster — we are just going to stop waiting.** ~~That falls straight out of having a second decoder: the front keeps drawing while the back loads.~~ **Correction (2026-07-23): it does NOT fall out of the second decoder** — the wait blocks the main thread, which both decoders share, so a second decoder alone changes nothing. Not-waiting is a separate fix (poll `is_task_completed()`); the second decoder is what makes it *usable*. See §2.3 step 4.
3. **`close()` is irreducible main-thread work.** ~25 ms of FFmpeg context teardown, and *not* a worker wait (`_video_thread` is already -1). It cannot be threaded away — it can only be moved off the cut.

**Renderer note:** REV 1 §1 argued GL Compatibility blocked an off-thread open. Measured: the open is *already* off-thread and creates **no GL resources**. That constraint does not bind here. No threading engineering is warranted.

---

## 1. Strategy

Two decoders, front and back. Output samples the front. The next clip is opened into the back **during the slack between switches**, so the ~118 ms demux wait and the ~25 ms teardown both happen while the front decoder is still drawing normally. The swap itself becomes a pointer flip.

**Cue-lead constraint (new, and it bounds the sequencer):**

> Cue lead time must exceed demux time, or the swap will stall waiting on an unfinished cue.

- 720p ≈ **120 ms** demux vs a 490 ms gap at 123 BPM — comfortable. **Updated 2026-07-23: that figure was the old ~4-6 Mbps library. The current `pvj_loop_*` set (720p30, 10 s, ~11 Mbps) demuxes ≈195 ms typical, 251 ms worst — bitrate, not duration, drives demux cost.** Still comfortable at 123 BPM; worst case is half the gap.
- 1080p ≈ **285 ms**, 1440×1080 ≈ 189 ms — fits at 123 BPM, but the margin collapses at higher BPM or sub-bar slot lengths.

This is an independent argument for a 720p library, separate from the Phase 2 dual-deck case. **Transcoding the four remaining 1080p clips is a real, cheap win** — it more than halves their switch stall — and should be done regardless.

If a swap arrives before its cue has completed, **do not block**: hold the current clip and swap on the next opportunity (or accept one stall), and log it. A dropped swap is better than a frozen deck.

---

## 2. Implementation

### 2.1 Node change (unchanged from REV 1)

`ClipEngine` becomes a manager `Node` owning two decode `SubViewport`s:

```
ClipEngine            (Node)          class_name ClipEngine     # was SubViewport
├── _dec_a            (SubViewport)   UPDATE_ALWAYS
│     └── VideoPlayback (GoZen)
└── _dec_b            (SubViewport)   UPDATE_ALWAYS
      └── VideoPlayback (GoZen)
```

- `_front` / `_back`; `active_texture()` returns `_front.get_texture()`.
- New signal `active_texture_changed(tex: Texture2D)` → `pipeline` re-points `ShaderSlot.set_input()`. Re-pointing a texture reference is free; no GPU copy.
- Keep the existing public surface (`scan()`, `clips`, `current_index`, `play_index()`, `next_clip()`, `prev_clip()`, `random_clip()`, `clips_ready`, `clip_changed`, `clip_missing`) so `pipeline` and the browsers barely change. Grep `clip_engine.` for SubViewport-typed uses (`get_texture()`, `.size`, `.render_target_update_mode`) and route them via `_front`.
- Set `profile = false` on both deck players by default (Task 0 instrumentation stays, disabled).

### 2.2 API

```gdscript
# Open clips[index] into the BACK decoder. This is where the ~118 ms demux wait
# and the ~25 ms teardown are spent — during slack, off the visible cut.
func cue(index: int) -> void

# Flip front/back. Pointer swap + play(). Must contain NO close(), NO open,
# NO wait_for_task_completion.
func swap() -> void

# Tap-a-slot jump. If index == _cued_index -> swap() (instant).
# Otherwise synchronous open + swap (one accepted stall), then re-cue.
func jump(index: int) -> void
```

### 2.3 `cue(index)` — rewritten

1. `var path := ProjectSettings.globalize_path(clips[index])`.
2. **Tear down the back decoder's previous clip here** — this is where `close()`'s ~25 ms belongs. Never at swap time.
3. `set_video_path(path)` on the back player; let its worker demux run.
4. ~~**Let the wait happen in slack.** The back decoder's `_process` will block on `wait_for_task_completion()` for ~118 ms — that is fine and expected *here*, because the front decoder is unaffected and keeps drawing. Do not try to eliminate this wait; only its timing matters.~~
   **❌ WRONG — disproved on device 2026-07-23 (commit `a18e4db`).** `wait_for_task_completion()` blocks the **calling** thread, `_process` runs on the **main** thread, and **both decoders' `_process` run on it**. A blocking wait during a cue therefore freezes the whole app — front decoder included — exactly as hard as a switch does today. It would have *moved* the freeze off the cut, not removed it; the dropped-frame count per switch cycle would have been unchanged, and SEQUENTIAL would still measure 31-47 fps.
   **The wait must be eliminated, not just re-timed.** `VideoPlayback._process` now polls `WorkerThreadPool.is_task_completed()` and picks the video up on a later frame (`wait_for_task_completion` is still called, to release the task, but returns immediately). Measured, one switch, MANUAL + FX Off: frame deltas `16.7 [124.5] [22.8] …` → flat `16.7`; the wait itself 118 ms → 0.01 ms; **SEQUENTIAL 31-47 fps → 59-60 fps**. This poll — not the pre-rendered first frame — is where the frame rate actually comes back. §0 conclusion 2's "that falls straight out of having a second decoder" was the error: it does not fall out of anything, it is a separate one-line fix, and the second decoder is what makes it *usable* (the front has something to show while the back loads).
5. Seek frame 0 and **pause**. Let the back viewport render its first frame while paused (`UPDATE_ALWAYS`) — this pre-pays the 1–4 ms texture creation and makes the swap deterministic. **Nice-to-have, not the win** (REV 1 wrongly treated this as the point of the exercise).
6. **Mute the back player.** GoZen `enable_audio` defaults true; two live decoders = doubled audio. Only `_front` is audible.
7. `_cued_index = index`; set a `_cue_ready` flag when the first frame has rendered.

### 2.4 `swap()` — rewritten

Must be free of *all* blocking work:

1. If `not _cue_ready`: log, and either hold or accept a stall (§1) — do not block.
2. `var t := _front; _front = _back; _back = t`.
3. `_front` player: unpause/`play()`, unmute.
4. `_back` (old front): mute, pause. **Leave its FFmpeg context open** — it is torn down by the *next* `cue()` (step 2), in slack. Closing here would put the ~25 ms straight back onto the cut.
5. `current_index = _cued_index`; emit `active_texture_changed`, `clip_changed`.
6. Auto-cue the next target (§3).

**Boot:** `play_index(0)` = synchronous open into `_front`, then `cue(next)`.

---

## 3. Cue targets by mode (in `pipeline._process`)

The switch clock stays as-is; the boundary action changes from "load next" to `clip_engine.swap()`.

- **SEQUENCER (Phase 1 target):** next slot in the arrangement. Fully deterministic — the ideal case.
- **SEQUENTIAL:** `(current_index + 1) % count`.
- **LFO:** next per LFO position.
- **RANDOM:** **pick-and-remember.** Choose the random target at cue time and store it; `swap()` must use the same index. Do **not** re-randomize at swap.
- **AUDIO:** see §5 — cueable when it advances a sequence, not when it picks at random.

On mode change or manual prev/next: re-cue.

---

## 4. Bug to fix first (separate commit, before the ping-pong)

`pipeline._audio_switch()` calls `next_live_clip()` **regardless of switch mode** — it fired during Task 0 setup in MANUAL and advanced the deck three clips. That is a correctness bug, not just a test artifact: in MANUAL the performer has explicitly said *don't advance*, and once the sequencer exists a stray mic transient would jump the arrangement.

**Gate `_audio_switch()` on switch mode.** Small, isolated, commit it on its own.

---

## 5. Audio reactivity — architecture

Keep audio reactivity, and split it into **two channels that behave completely differently**. Conflating them is why the current implementation causes trouble.

### 5.1 The split

| | **Triggers** (discrete) | **Modulation** (continuous) |
|---|---|---|
| What | onset/transient → fire an event | envelope → drive a value each frame |
| Targets | `swap()`, effect toggle, shuffle | shader uniforms, warp, mask params, speed |
| Cost | ~150 ms today → ~0 after ping-pong | **free** — a uniform write per frame |
| Risk | mistimed cut | none |

**Modulation is the underexploited half.** It costs a uniform update, never touches the decoder, and gives continuous audio-reactive motion between cuts. Most of the "feels alive" quality in a VJ set comes from this, not from switching.

### 5.2 The key structural point about audio triggers

REV 1 treated audio-switch as inherently un-preloadable ("reactive, may still stall"). **With a sequence, that is no longer true.** The trigger determines *when* to advance; the arrangement determines *what* comes next. So the next clip is known at cue time even though the trigger's timing isn't.

- **Audio-advance-through-sequence → fully cueable.** Cue right after each swap; the transient just fires `swap()` whenever it lands. Works exactly like SEQUENTIAL, only clocked by the music instead of the bar.
- **Audio-random → not cueable.** Target unknown until the transient. Either use pick-and-remember (choose the random target at cue time, fire it on the next transient — still random, still cueable) or accept the stall. **Prefer pick-and-remember**; it makes every audio mode cueable.

**Rate limit regardless.** A refractory window (min. ms between triggers, e.g. 150–250 ms) prevents a dense passage from firing swaps faster than cues can complete — the §1 constraint. Snare rolls will otherwise machine-gun the deck.

### 5.3 Trigger modes worth having

1. **Broadband onset** (current) — energy jump vs a short rolling average. Simple, fires on everything, needs the refractory window.
2. **Band-gated onset** — split into low / mid / high and trigger from one band. **This is the biggest practical upgrade over what you have:** trigger on kick only (low), or hats only (high). Musically far more controllable than broadband, and cheap. Route different bands to different targets — kick advances the clip, hats poke an effect.
3. **Beat-quantized trigger** — a transient *arms* the switch, and it fires on the next `BeatClock` beat/bar. Combines audio responsiveness with musical timing, and conveniently guarantees cue lead time. Good default for a sequenced set.
4. **Sustained-level gate** — fire when energy stays above a threshold for N ms (a build or drop, not a single hit). Good for section changes rather than per-beat cutting.
5. **Silence / drop detection** — energy below threshold for N ms → blackout, freeze, or cut to a designated clip. Very effective on breakdowns, and trivially cheap.

### 5.4 Modulation sources worth having

1. **RMS / loudness envelope** → effect intensity, warp scale, mask opacity. The workhorse. Add attack/release smoothing so it breathes rather than jitters.
2. **Band envelopes** (low/mid/high, separately smoothed) → three independent modulators. Bass to pixelate size, highs to RGB shift, etc. Best value per line of code.
3. **Spectral brightness (centroid)** → any "sharpness" parameter — ASCII density, chroma amount. Tracks timbre rather than volume, so it moves when loudness doesn't.
4. **Beat phase from `BeatClock`** (0..1 within the bar) → not audio analysis at all, but the same kind of modulator, and perfectly stable. Ramp/pulse shapes locked to tempo.
5. **Peak-hold / decay follower** → a value that snaps up on a transient and decays smoothly. Gives a "hit" feel to continuous parameters — arguably the single most useful modulator for VJ work.

### 5.5 Suggested implementation shape

An `AudioAnalyser` node exposing:
- `rms: float`, `low: float`, `mid: float`, `high: float`, `centroid: float` (all smoothed, 0..1)
- `signal transient(band: int, strength: float)`

...and a small **modulation matrix**: (source → target, amount, curve), so any source can drive any exposed parameter without hardcoding pairs. That is the part that makes it feel like an instrument rather than a preset. Ship it with two or three sources and one or two targets first; the matrix is what makes it grow cheaply.

**Do this after the ping-pong lands** — modulation is free, but it's a feature, and the switch stall is a defect.

---

## 6. Build order

1. **Gate `_audio_switch()` on switch mode** (§4). Isolated commit.
2. **Transcode the four remaining 1080p clips to 720p** — halves their switch stall, and buys cue-lead margin (§1). No code.
3. **Two-viewport restructure** (§2.1): ClipEngine → manager, `active_texture()`, `active_texture_changed`, fix the `pipeline`/browser ripple. Verify playback, manual next/prev, MIRROR output. **No perf change expected yet.**
4. **`cue()`** (§2.3) — the win. Verify SEQUENTIAL @123 BPM: expect a jump from 31–47 toward 60.
5. **`swap()`** + wire into the switch clock (§2.4, §3) for SEQUENTIAL/LFO. Verify no `close()` or wait on the cut path.
6. **RANDOM pick-and-remember**, then **`jump()`** with the un-cued fallback.
7. **Audio: pick-and-remember + refractory window** (§5.2), so audio-switch becomes cueable too.
8. Verify **no doubled audio** at the swap; capture **cue-window frame time** (this is the two-concurrent-GoZen-instance load — your free Phase 2 dual-deck smoke test).

**Success:** SEQUENTIAL @123 BPM at 720p holds ~55–60 fps, and no `close()`/`wait_for_task_completion` appears on the swap path.

---

## 7. Measurement protocol (from Task 0 — reuse it)

- **MANUAL is not enough to freeze the deck. Turn audio-switch OFF too** (until §4 lands).
- Verify the clip index is stable for 15 s before trusting a capture.
- **Godot's `delta_smoothing` spreads a stall across frames** (one 281 ms block reported as `[138.2] [41.3]`). Trust the usec spans from `SwitchProfiler`, not the on-screen FPS — the readout is smoothed the same way.
- Discard any run whose log shows `[ClipEngine] thumb captured` (extra viewport readback).
- Keep the `profile` flag off for mask decoders so they can't contaminate a capture.

---

## 8. Open items

- **Cue-lead margin at high BPM / short slots.** 720p ≈ 120 ms is safe at 123 BPM; document the practical floor once the sequencer exposes beats-per-slot. This is the number that bounds how fast a set can cut.
- **Two-decoder RAM/CPU during the cue window** — measure (§6.8). It's the Phase 2 dual-deck read.
- **Sub-frame swap timing:** if cuts feel late, check whether `swap()` lands before or after the frame's draw; may want to swap at the top of `_process`.
