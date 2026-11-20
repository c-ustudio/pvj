# PocketVJ — Clip Browser & Sequencer Architecture

**Target:** Godot 4.x, GDScript only, Android (Pixel 9a / Tensor G4), single HDMI output via Android Presentation API, 55+ fps.
**Scope:** Phase 1 (one deck, visual browser + sequencer) built now; Phase 2 (dual deck) designed now, built later.
**Audience:** Claude Code, implementing directly from this document.

---

## 0. Key verdicts up front

**GoZen two simultaneous instances — YES, with a CPU caveat.**
GoZen is a GDExtension that wraps **FFmpeg** and exposes a `VideoPlayback` node. Decode is **software** (FFmpeg), not Android MediaCodec. Two consequences:

1. Two `VideoPlayback` nodes = two independent FFmpeg decode contexts. There is **no shared global hardware-decoder session to exhaust** (the thing that limits concurrent `MediaCodec` instances on Android). So instancing two decks is architecturally fine.
2. The binding constraint is **CPU**, not decoder count. Two simultaneous software decodes compete for the Tensor G4 cores. This is exactly why the **720p-per-deck** strategy is correct — it cuts per-stream decode cost ~2.25× vs 1080p. Endorsed strongly.

**Action:** validate empirically before building the full Phase 2 UI — a two-node smoke test (two 720p clips decoding + a trivial composite) measuring frame time on the actual Pixel 9a. If it blows the CPU budget, fall back to a pre-transcoded, decode-friendly clip library (see §7, risk 1). GoZen also supports HTTPS stream playback and single-stream alpha video — noted where relevant below.

**One structural decision that makes Phase 2 nearly free:** every UI widget emits *intent* signals (`clip_activated`, `clip_queued`, `slot_selected`, …). A per-deck **DeckController** translates intent into concrete `ClipEngine` commands. No UI widget ever calls `ClipEngine` directly. Adding deck B = instantiate a second controller + render pipeline and route intent by focus. Build Phase 1 this way even though there's only one deck.

---

## 1. Design principles

1. **Two worlds, cleanly separated.**
   - **Output world** — a `SubViewport` whose texture your existing Presentation routing sends to HDMI. Contains only the render pipeline. Receives no touch input, never shows UI chrome.
   - **Control surface** — a `Control` tree on the device Window (the phone touchscreen). Contains grid, strip, transport. Never appears in projector output.
   - *Assumption:* your working Presentation setup already displays a viewport texture on HDMI. Treat `OutputWorld` (SubViewport) as the seam and keep your Presentation wiring untouched.

2. **Intent-signal decoupling** (see §0). UI → intent signals → `DeckController` → `ClipEngine`.

3. **Model separate from view.** `Sequence` (data resource: ordered clip IDs) is rendered by `SequenceStrip` (view). Drag / reorder / shuffle mutate the model; the view rebuilds from it. Same for `ClipGrid` rendering a `Folder`. Session save/load is just serializing the models.

4. **One clock.** Formalize your BPM tap into a `BeatClock` autoload emitting `beat`, `bar`, `downbeat` and exposing `bpm` / `phase`. Auto-advance, and later deck-sync and launch quantization, all subscribe to it.

5. **Render subtree vs logic node.** SubViewport rendering requires render nodes to live *inside* the SubViewport. So each deck splits into:
   - `DeckRenderPipeline` (under `OutputWorld`): the actual GPU pipeline.
   - `Deck` (logic node, main tree): the API surface + `Sequence` model + index + auto-advance state, holding a reference to its render pipeline. This split is what lets two decks share one clean controller pattern.

---

## 2. Phase 1 — scene tree

```
Main (Node)
│   [Autoloads: ClipLibrary, ThumbnailService, BeatClock, SessionStore]
│
├── OutputWorld (SubViewport)                 # texture → HDMI via existing Presentation routing
│   ├── DeckA_Render (SubViewport, 1080p)     # Phase 2: drops to 720p
│   │   ├── ClipEngine        # GoZen VideoPlayback wrapper + double-buffer (existing, refactored)
│   │   ├── ShaderChain        # ordered effect passes (was ShaderSlot)
│   │   └── MaskCompositor     # polygon masks + per-mask video assignment (existing)
│   └── QuadWarp               # final geometry correction — MOVED here, out of the deck
│
├── Decks (Node)
│   └── DeckA (Node)           # logic: Sequence model, current_index, auto_advance; → DeckA_Render
│
└── ControlSurface (Control)   # phone touchscreen
    ├── FolderTabBar           # top: 2–3 tabs
    ├── ClipGrid               # thumbnail matrix → emits clip_activated / clip_queued
    ├── SequenceStrip          # bottom scrollable row → emits slot_selected / reorder_requested
    └── TransportBar           # BPM tap, play/pause, shuffle, auto-advance toggle
```

`DeckA` (logic) receives intent from `ControlSurface` and drives `DeckA_Render`. In Phase 1 there is one deck; nothing about this tree needs to change conceptually to add a second — you add a sibling render pipeline, a sibling `Deck`, a `Compositor`, and deck-focus routing (see §6).

---

## 3. Phase 1 — components & responsibilities

### Autoloads

**`ClipLibrary`** — source of truth for folders & clips.
- `Folder { id, name, clip_ids: Array[String] }`
- `ClipData { id, source_type: LOCAL|DRIVE, path_or_drive_id, display_name, duration, resolution, thumb_cache_path }`
- `id` = stable hash of local path or Drive file id (survives re-scan).
- Signals: `folder_updated(folder_id)`, `library_ready`.
- Phase 1: enumerate local directories. Phase 1 step 9: Drive folders as additional tabs.

**`ThumbnailService`** — async thumbnail generation + disk cache. Perf-critical (§7, risk 2).
- API: `request(clip_id)`; emits `thumbnail_ready(clip_id, Texture2D)`.
- Cache: `user://thumbs/{clip_id}.webp`, capped at ~256 px longest edge.
- Cache hit → load `ImageTexture` (cheap) → emit.
- Cache miss:
  - **LOCAL** → enqueue frame extraction. GoZen textures are main-thread/render-bound, so extraction runs **time-sliced on the main thread with a hard budget** (≤1 generation per frame; skip if the frame is already over budget), using a small pool of hidden extractor `VideoPlayback` nodes seeked to a mid-timestamp. Show a placeholder until ready.
  - **DRIVE** → **no local decode needed.** Google Drive's API returns a `thumbnailLink` for video files. Fetch it via async `HTTPRequest`, cache, emit. Big win — Drive thumbnails cost a network GET, not a decode.

**`BeatClock`** — formalized BPM tap.
- Exposes `bpm: float`, `phase: float` (0..1 within the bar), `beats_per_bar: int`.
- Signals: `beat(beat_index)`, `bar(bar_index)`, `downbeat`.
- Tap tempo feeds `bpm`. This replaces the ad-hoc BPM system; keep the tap UI, route it here.

**`SessionStore`** — save/load a set (folder config, each deck's `Sequence`, focused deck) to `user://session.tres`. Lets a set survive an app restart at a festival.

### Control widgets

**`FolderTabBar`** — 2–3 tabs → `folder_selected(folder_id)` → `ClipGrid` repopulates.

**`ClipGrid`** — thumbnail matrix (Resolume-style).
- Renders `ClipLibrary.get_folder(folder_id).clip_ids`.
- **Virtualized**: only instance cells that are visible + a small margin; pool cell nodes; free off-screen textures (§7, risk 3).
- On populate, calls `ThumbnailService.request(clip_id)` per visible cell; updates on `thumbnail_ready`.
- Gestures → intents:
  - tap → `clip_activated(clip_id)` (play immediately)
  - long-press → `clip_queued(clip_id)` (append to sequence)
  - drag → provides drag payload `{clip_id}` for the strip to accept (`_get_drag_data`).

**`SequenceStrip`** — horizontal scrollable slot row (bottom).
- `ScrollContainer` + `HBoxContainer` of slot cells; renders the focused deck's `Sequence`.
- tap slot → `slot_selected(index)`.
- accepts grid drag drop at an insertion index → `reorder_requested(INSERT, clip_id, index)`.
- internal drag reorder → `reorder_requested(MOVE, from_index, to_index)`.
- Rebuild the view **only on drop**, not per drag-frame; move a lightweight proxy during the drag (§7, risk 6). Pool slot cells.
- Highlights the active slot (driven by `Deck.current_index`).

**`TransportBar`** — BPM tap (→ `BeatClock`), play/pause, **shuffle** button, **auto-advance** toggle, beats-per-slot selector (default: advance on `bar`).

### Logic

**`Deck`** (per-deck; one in Phase 1) — the API surface. No UI, no rendering.
- Holds: `sequence: Sequence`, `current_index: int`, `auto_advance: bool`, `render: DeckRenderPipeline`.
- Methods:
  - `play_clip(clip_id)` — immediate cut; resolve `ClipData.path`, `render.clip_engine.play(path)`.
  - `jump_to(index)` — set `current_index`, play that entry.
  - `advance()` — `current_index = (current_index + 1) % sequence.size()`, play, emit `active_slot_changed`.
  - `shuffle()` — Fisher–Yates on `sequence`, emit `sequence_changed` (option: keep-current vs restart).
  - `preload(clip_id)` — arm the double-buffer with the next clip.
  - `get_output_texture()` — the deck's rendered texture (used by Phase 2 compositor).
- Subscribes to `BeatClock.bar`: if `auto_advance`, call `advance()`.
- Receives intent from `ControlSurface` (wired in Phase 1 directly; in Phase 2 via deck focus).

`Sequence` (Resource): `entries: Array[String]` (clip ids) + `append/insert/move/remove/shuffle`. Serializable for `SessionStore`.

---

## 4. Phase 1 — signal flow

```
ClipGrid.clip_activated(clip_id) ─────────────► Deck.play_clip(clip_id) ──► ClipEngine.play(path)

ClipGrid.clip_queued(clip_id) ────────────────► Deck.sequence.append(clip_id)
                                                    └► Deck.sequence_changed ──► SequenceStrip.rebuild()

ClipGrid drag ──► SequenceStrip._drop_data ───► Deck.sequence.insert(index, clip_id) ──► rebuild

SequenceStrip internal drag ──────────────────► Deck.sequence.move(from, to) ──► rebuild

SequenceStrip.slot_selected(index) ───────────► Deck.jump_to(index)

BeatClock.bar ──► (Deck.auto_advance?) ────────► Deck.advance() ──► ClipEngine.play(next)
                                                    └► active_slot_changed ──► SequenceStrip highlight

TransportBar.shuffle_pressed ─────────────────► Deck.shuffle() ──► rebuild

ClipGrid populate / scroll ───────────────────► ThumbnailService.request(clip_id)
ThumbnailService.thumbnail_ready(id, tex) ────► ClipGrid cell updates its texture
```

---

## 5. What changes in the existing ClipEngine

Your current chain (`ClipEngine → ShaderSlot → QuadWarp → HDMI`) is almost certainly a linear pipeline where `ClipEngine` draws toward the screen and `QuadWarp` is the final stage in the same chain. Refactor it into composable, texture-producing pieces so Phase 2 needs no rewrite:

1. **Render to a texture, not the screen.** `ClipEngine` output becomes a `SubViewport`/`ViewportTexture` and exposes `get_output_texture()`. In Phase 1 that texture still flows to `QuadWarp` → HDMI; structurally it's now composable. *If it currently draws straight to the main Window, this redirection is the main Step-0 task.*

2. **Parameterize internal resolution.** Add `render_size` and size the deck's SubViewport to it. Phase 1: 1080p. Phase 2: 720p per deck.

3. **Give it a deck identity.** Add `deck_id`. Namespaces temp/cache paths and keeps two GoZen instances from sharing mutable state.

4. **Own decode + preload only — not final geometry.** Move `QuadWarp` **out** of the deck to `OutputWorld` root (post-composite in Phase 2). `ShaderChain` and `MaskCompositor` stay **per-deck** (each deck has its own look and its own masked content).

5. **`ShaderSlot` → `ShaderChain`.** Generalize the single slot into an ordered list of viewport-to-viewport passes with add/remove/reorder + per-pass params. You already have 6 chainable shaders; this is needed regardless and unblocks per-deck looks.

6. **Explicit preload API.** Formalize the working double-buffer into `preload(path)` + `swap()` so the sequencer can cue the next clip deterministically and (Phase 2) Deck B can arm while Deck A plays.

7. **Playback events.** Emit `clip_started`, `clip_ended`, `clip_looped` so the sequencer can advance on clip-end as well as on beat.

Nothing here changes visible behavior in Phase 1 — it's a scaffolding refactor with the same output.

---

## 6. Phase 2 — dual deck (design now, build later)

### Scene tree additions

```
OutputWorld (SubViewport, 1080p)
├── DeckA_Render (SubViewport, 720p)   # ClipEngine → ShaderChain → MaskCompositor → texA
├── DeckB_Render (SubViewport, 720p)   # ClipEngine → ShaderChain → MaskCompositor → texB
├── Compositor (full-screen quad, 1080p)   # blend(texA, texB, crossfade, mode) → comp
└── QuadWarp (1080p)                    # warps comp → HDMI

Decks
├── DeckA   # Sequence, index, auto_advance → DeckA_Render
└── DeckB   # Sequence, index, auto_advance → DeckB_Render

ControlSurface
├── DeckSelector (A | B)          # routes ClipGrid/SequenceStrip intent to the focused deck
├── ClipGrid                      # shared; shows focused deck's folder
├── SequenceStrip                 # focused deck's sequence (or two thin strips)
├── Crossfader (0..1)             # → Compositor.crossfade
├── BlendModeSelector             # cut | crossfade | add | multiply → Compositor.mode
└── TransportBar                  # global BeatClock; per-deck sync options
```

### Compositor

A single 1080p full-screen fragment shader sampling `texA`, `texB` with uniforms `crossfade: float` and `mode: int`:
- **cut** — hard A or B by threshold on `crossfade`.
- **crossfade** — `mix(A, B, crossfade)`.
- **add** — `clamp(A*(1-t) + B*t + overlap, 0, 1)` weighted by crossfade (tune to taste).
- **multiply** — `mix(A, A*B, crossfade)` or straight `A*B` gated by crossfade.

The crossfader drives `crossfade`; the blend mode selects the math. One 1080p pass — cheap. `QuadWarp` runs once, after the composite.

### UI recommendation for the Pixel 9a screen

Prefer a **shared grid + A/B focus** (via `DeckSelector`) over two side-by-side grids — the ~6.3" screen is too tight for two comfortable matrices. Keep the **crossfader** and **blend-mode selector** always visible. Show the **focused deck's** sequence strip (or two slim stacked strips if you want both visible). This is a UX call, flagged as such.

### Cross-deck preloading (critical for clean crossfades)

While Deck A plays, `DeckB.preload(next)` so B's first frame is decoded and armed before the fade. **Do not start B's decode at fade time** — that's a CPU spike at the worst possible moment (§7, risk 8). Arm B a bar ahead (first frame decoded, paused / not yet composited), then fade in.

### Why 720p-per-deck → 1080p composite is the right strategy

- **CPU (the real risk):** GoZen decode is software. Two 720p decodes cost ~2.25× less than two 1080p decodes. This is the dominant win.
- **GPU fill:** per-deck shader chains run at 720p (2 × 0.92 Mpx ≈ 1.84 Mpx) instead of 1080p (2 × 2.07 Mpx ≈ 4.15 Mpx) — ~55% less per-deck fragment work. Only the composite + warp run once at 1080p (2.07 Mpx).

Both budgets that threaten 55 fps are protected by the same decision. Endorsed.

---

## 7. Performance risks (flagged)

1. **Two simultaneous software (FFmpeg) decodes on Tensor G4 — highest Phase 2 risk.** Mitigate: 720p per deck; a **pre-transcoded clip library** at a decode-friendly codec/bitrate (H.264 baseline/main, moderate bitrate, GOP-friendly for loops); cap concurrent preloads to one armed clip; run the **two-node smoke test early** (before the full dual UI). Fallbacks if it won't hold: pre-decoded frame sequences for short loops; fewer/lighter shader passes on the non-focused deck.
2. **Thumbnail generation stalls.** Local frame extraction is expensive and GoZen textures are main-thread bound. Mitigate: disk cache (WebP); lazy generation with a per-frame time budget (≤1/frame, skip when over budget); Drive uses `thumbnailLink` (no decode); placeholders until ready.
3. **Grid texture VRAM.** Mitigate: cap thumbs ~256 px; virtualize the grid (instance only visible + margin); pool cells; free off-screen textures.
4. **SubViewport / pass count.** Per-deck chain = N full-screen passes × 2 decks + composite + warp. Mitigate: keep chains short; fold simple effects into one uber-pass where feasible; per-deck passes at 720p; only composite + warp at 1080p.
5. **Network on the main thread (Drive).** Mitigate: all Drive I/O async (`HTTPRequest`); **download-to-cache before a set** rather than streaming mid-performance (GoZen *can* stream HTTPS, but a live festival set shouldn't depend on the network).
6. **Drag/reorder rebuild churn.** Mitigate: rebuild the strip only on drop; move a lightweight proxy during drag; mutate model → rebuild once.
7. **Allocation / GC hitches on scroll.** Mitigate: pool grid and strip cell nodes; avoid per-frame `new`/`free`.
8. **Crossfade decode spike.** Arming Deck B at fade time starts a second decode at the worst moment. Mitigate: pre-arm B a bar ahead (§6).

---

## 8. Phase 1 — build order (usable at each step)

**Step 0 — Refactor scaffold (no visible change).**
Extract `BeatClock` autoload from the BPM tap. Wrap the existing pipeline into `Deck` (logic) + `DeckRenderPipeline` (`ClipEngine → ShaderChain → MaskCompositor`). Move `QuadWarp` to `OutputWorld` root. Make `ClipEngine` render to a texture and expose `get_output_texture()`. Expose `Deck.play_clip()`. **Verify:** app still runs, still outputs HDMI, shaders/masks/BPM intact. This is the safety net before any UI work. *(Optional: drop in the two-node 720p decode smoke test here to de-risk Phase 2 early.)*

**Step 1 — `ClipLibrary` + local folders.** Model clips/folders from local dirs (name list is fine, no thumbnails yet). **Verify:** library enumerates.

**Step 2 — `ThumbnailService` (local, cached, time-sliced).** Generate + disk-cache local thumbs; placeholder → ready. **Verify:** thumbs appear with no frame drops during generation.

**Step 3 — `ClipGrid` replaces the playlist; tap-to-play.** ⭐ **First usable milestone** — a visual browser that plays clips to HDMI on tap.

**Step 4 — `FolderTabBar`.** 2–3 tabs switch the grid source.

**Step 5 — `SequenceStrip` + `Sequence` model; long-press add; tap-slot jump.** ⭐ Manual sequencing works.

**Step 6 — Drag & drop.** Grid→strip insert at position; reorder within strip. ⭐ Full manual control of order.

**Step 7 — `BeatClock` auto-advance.** Toggle; advance on `bar` (configurable beats-per-slot); highlight active slot; wrap. ⭐ Hands-free sequencing.

**Step 8 — Shuffle.** Fisher–Yates on the strip (keep-current or restart option).

**Step 9 — Google Drive.** Drive folders as tabs; thumbnails via `thumbnailLink`; **download clips to cache** for playback (don't stream mid-set). ⭐ Cloud clip library.

Every step from 3 onward leaves a usable app.

---

## 9. Assumptions & open questions

- **Presentation seam:** assumes `OutputWorld` is a SubViewport whose texture your existing Presentation routing displays on HDMI. Keep that wiring; treat the SubViewport as the integration point.
- **ClipEngine → texture:** assumes `ClipEngine` can be redirected to render to a texture rather than the main Window. If it currently draws straight to the Window, that redirection is the bulk of Step 0.
- **Phase 2 grid UX:** shared grid + A/B focus recommended for the screen size — confirm before building; two grids is possible if you prefer.
- **Launch quantization:** advance exactly on `bar` vs immediate — exposed as a setting; default bar-quantized for musicality.
- **GoZen two-instance CPU headroom:** the one thing to verify empirically on-device (two-node 720p smoke test) before committing the Phase 2 UI.
