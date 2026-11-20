# PocketVJ — Grid as the Single Visual Interface (Option C spec)

**Status: COMPLETE (2026-08-05).** All five steps shipped and verified on device:

| step | commit | what |
|---|---|---|
| 1 — Piece 1 fixed first | `bde97c9` | all five playback modes working; the non-negotiable prerequisite |
| 2 — grid gains park/unpark | `e681a03` | CURATE mode; tap toggles LIVE/PARKED, writes `live_set` |
| 3 — grid gains ordering | `25fe92e` | drag a clip onto another; writes the deck's clip order |
| 3b — reorder fixes | `cbf1873` | the stuck drag proxy, and a stale `_cued_index` that hung the deck |
| 4a — grid gains REMOVE | `34c72fc` | the one capability the panel had alone; long-press in CURATE |
| 4b — retire the panel | `8d605d3` | `playlist_manager_ui.gd` + `PlaylistManager.tscn` deleted; backend untouched |
| 5 — thumbnail unification | `51c6565` | `_capture_thumb` off the clip-switch path; one cache left |

The original plan below is kept as written. Two things it did not anticipate, both recorded in §"What
actually happened" at the end.

**The goal:** collapse two overlapping systems (CLIP GRID + PLAYLIST) into ONE visual interface — the grid. The grid becomes where you curate the live pool, build sequences, and order clips. The playlist's separate panel is retired. This resolves the "two systems is confusing" problem and realizes the "tie ordering to mode" vision: one visual surface driving one clean backend.

**Why the grid:** it's more visual (thumbnails, immediate feedback) than the playlist's abstract list. Compared live side by side, the grid won decisively. The grid already has the ALL/LIVE/PARKED filter — it can already *show* live/parked; it just can't *change* them yet.

---

## The crucial distinction: backend vs UI

The playlist is TWO things, and only one gets removed:
- **Backend (KEEP):** the ordered clip array (`clip_engine.clips` via `set_order`) and the LIVE pool (`live_set` via `set_live`) that RANDOM/LFO pick from through `live_indices()`. This is load-bearing — the engine reads it. **It stays.**
- **UI (REMOVE/ABSORB):** the `PlaylistManagerUI` list panel (checkboxes, drag-to-reorder). The confusing part. Its capabilities move into the grid; the panel is retired.

So Option C is NOT "delete the playlist" — it's "keep the playlist's data model, move its controls into the grid, remove its panel." Conflating these is the dangerous version.

## What the grid must gain (the real work)

Today `clip_grid.gd` is explicitly **read-only observation** — it emits `clip_activated` + grab signals, but has no park, no unpark, no remove, no reorder. All membership/order decisions still happen in the playlist Tree. So Option C means adding to the grid:

1. **Park/unpark intent** — tap/gesture to toggle a clip LIVE↔PARKED, writing `live_set` (what the playlist checkboxes did). The ALL/LIVE/PARKED filter already displays this; now it becomes editable.
2. **Ordering intent** — reorder clips (for SEQUENTIAL order and the live pool), writing `clip_engine.clips` order (what playlist drag-to-reorder did).
3. **Sequence building** — already exists (the SEQUENCE strip). Stays.
4. **Persistence** — grid writes the same `playlist.cfg` / order the backend reads, so nothing downstream changes.

The backend signals (`set_order`, `set_live`) already exist — the grid just needs to call them instead of the playlist Tree calling them.

## The two ID spaces (a migration sub-problem)

Sequence stores ClipLibrary ids (basename hashes); the engine indexes clips by path; `_jump_to_clip_id` bridges per jump. `clip_library.gd` says it deliberately "REFLECTS ... WITHOUT taking ownership." Fully unifying to one model is the migration that header anticipates. Option C may not need the full collapse — but the grid's new park/unpark/order must resolve ids→paths consistently (reuse `_engine_index_for_clip_id` from Piece 1). Flag this; scope whether full unification is needed or the bridge suffices.

## Ties to the mode→source mapping

Option C completes "ordering tied to mode":
- **AUTO/SEQ** → grid sequence drives (Piece 1)
- **RANDOM/LFO** → grid-curated LIVE pool drives (the pool the grid now edits)
- **SEQUENTIAL** → grid clip order
- **MANUAL** → grid tap pins
All one interface, one backend. The playlist UI is redundant once the grid can curate the pool — that's when it retires.

## Build order (post Piece-1-fix)

1. **Piece 1 fix first** — all five modes working. Non-negotiable prerequisite; don't rewire on a broken base.
2. **Grid gains park/unpark** — tap-to-toggle LIVE↔PARKED, writes `live_set`. Verify RANDOM/LFO pick from the grid-curated pool. (This alone makes the playlist's checkboxes redundant.)
3. **Grid gains ordering** — reorder writes clip array order. Verify SEQUENTIAL follows grid order.
4. **Retire the playlist panel** — once the grid does curation + ordering + sequencing, remove `PlaylistManagerUI` (or hide it behind a debug flag first, then remove). Keep the backend.
5. **Thumbnail unification falls out** — the playlist's thumbnail bug (reads a different, mostly-empty cache) disappears with the panel; the grid's cache is already fully populated.

## Cautions

- **Backend stays, UI goes** — never remove `set_order`/`set_live`/`live_indices`; RANDOM/LFO depend on them.
- **Load-then-merge** on `playlist.cfg`/order writes (the recurring clobber bug).
- **Verify each mode by eye on device** after each step — the whole point is that these paths are behavioral and only device testing catches regressions (Piece 1's four-mode break proved this).
- **Incremental, not big-bang** — park/unpark, then ordering, then retire the panel. Each step leaves a working build. Don't remove the playlist UI until the grid fully replaces it.
- **One working baseline before starting** — Piece 1 must be fixed and all five modes verified first.

## Why it's worth it

One visual interface instead of two overlapping ones. The grid — the one that won in live use — becomes the single place to curate, sequence, and order, driving one clean backend. Resolves the confusion, keeps the working engine, and realizes the mode→source vision. The playlist's data model lives on invisibly; only its confusing panel disappears.


---

## What actually happened (retrospective, 2026-08-05)

The plan held. Two things it did not anticipate:

**1. REMOVE was a capability, not a control.** The spec framed step 4 as retiring a panel whose
capabilities had all moved. They had not: `remove_absolute` on a clip file existed in exactly one
place in the app — `playlist_manager_ui.gd:161` — and the grid had no equivalent. Retiring the panel
as specified would have deleted the only way to get a clip off the phone, which is why `34c72fc`
(long-press in CURATE) had to be inserted before `8d605d3`.

⚠️ **The general lesson: "move the controls, then remove the panel" is only safe once you have
enumerated the panel's capabilities against the replacement's, one by one.** Five of six matched.
The sixth was invisible until someone grepped for what the panel could do that nothing else could.

**2. `set_order` lied about the warm decoder.** ⚠️ `ClipEngine._cued_index` is an INDEX, and `swap()`
does `current_index = _cued_index` then reports `clips[current_index]`. Reordering moves clips between
slots without touching it, so after a move the engine **announces whichever clip slid into that slot
while the back decoder is really holding the old one**. Everything resolving from `current_index` —
the grid's active cell, the sequence playhead, `_apply_cue_target` — then tracked a clip that was not
playing, and AUTO could re-cue the same wrong target indefinitely. That is what "the clips get hanged
when reordering" meant.

`set_order` already re-resolved the PLAYING clip by path; it now does the same for the cued one. The
bug lived in the engine, so it was reachable from `_load_playlist_order` at startup too, not only from
the grid. **Any function that reindexes `clips` must re-resolve BOTH decoders by path.**

**What the spec got right:** keeping backend and UI separate was the whole game. `set_order`,
`set_live`, `live_indices()` and `playlist.cfg` were never touched by the retirement — only the Tree
panel went. The "incremental, not big-bang" instruction is what made 2 unanticipated problems into two
extra commits rather than a broken deck.
