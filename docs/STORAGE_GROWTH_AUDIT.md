# Storage growth audit (beta4, 2026-11-02)

A beta tester reported PVJ getting slower session after session, and a reinstall bringing it back.
This is what the app writes, what grows, what was measured, and what changed. Measured on the Pixel 9a
(Android 17 / API 37, 4 KB pages, debug app `studio.cu.pvj.debug`, the owner's real app untouched) and
an Android 17 / API 37.2 16 KB-page emulator. **Short version: the report did not reproduce.** Nothing in
app storage grows from session to session in a way that costs time, and neither repeated sessions nor
a 508-clip library slowed launch or playback. What was found and fixed: the thumbnail work after an
import (it cost about 10% dropped frames while performing), and four things that grew without bound
on disk.

## 1. Every place the app writes files

`files/` = `user://` (filesDir). `cache/` = getCacheDir() (`Storage.cache_dir()`; Android's "Clear
cache" empties it). "Bounded" means something keeps it from growing without limit.

| What | Path | Written when | Cleaned up | Bounded | beta4 |
|---|---|---|---|---|---|
| Imported clips | `files/clips/`, `files/clips/<folder>/` | IMPORT CLIPS / FOLDER / PACK (StoragePlugin.copyClip) | REMOVE folder, clip delete | By the performer (free-space check + 512 MB reserve) | — |
| Import temp copy | `files/clips/[<folder>/].<name>.part` | During each copy; renamed into place after fsync + probe | Deleted on any failure; leftovers (process killed) at every start (`_clean_parts`) | Yes: one at a time | — (already right) |
| Demo clips | `files/clips/*.mp4` (8) | First launch, LOAD DEMO CLIPS | Like any clip | Yes | — |
| Staged demo copies | `cache/demo_stage/` | Idle loop, splash, a demo clip deleted from the library | CLEAR CACHE; re-staged when the packed size changes | Was not: a renamed demo clip's copy stayed for ever | Self-clean removes names this build does not ship |
| Thumbnails | `cache/thumbs/<id>.webp`, id = hash of the clip's relative path | First time a clip is shown or prewarmed | CLEAR CACHE; in-app delete/rename of that clip | Was not: a clip that left any other way (restore, renamed folder, symlinks gone) kept its thumbnail | Orphans removed once per launch (`Storage.prune_thumbnails`) |
| Legacy play copies | `cache/clipcache/` | beta1/beta2 linked-folder mode only: prefetch + cache misses | LRU at 2 GB; dropped when the library switches to layout 2 | Yes (2 GB) | `.part` leftovers removed; any copy outside legacy mode removed |
| Mask images | `files/masks/mask_<unix>.png` | Each LIB ▸ MASK IMAGE pick (a NEW file every time) | Never | **No**: every replaced image stayed | Self-clean removes images no saved mask names |
| Settings / play order / curation | `files/settings.cfg`, `playlist.cfg`, `regions.cfg`, `warp.cfg`, `calibration.cfg`, `storage.cfg` | Debounced on change | Overwritten | Size yes; but `playlist.cfg` kept the key of every clip that ever left (below) | Unresolved keys kept only while clips are expected back |
| Sequences | `files/sequence.tres`, `sequence_b.tres`, `sequences/slot_<1..6>.tres` | SAVE, lane changes | Overwritten; DEL | Yes (fixed slot count) | — |
| Mask sets | `files/mask_sets/set_<n>.cfg` | SAVE SET | Overwritten | Yes (fixed count) | — |
| Layout-2 snapshot | `files/pre_layout2/` | Once, first launch of layout-2 code | Never (insurance, a few KB) | Yes (once) | — |
| Setup restore staging | `files/restore_stage/` | RESTORE SETUP | Applied/removed at the next start | Yes | — |
| Saved setups | system picker location (SAF) | SAVE SETUP | Performer's file | n/a (not app storage) | — |
| Recordings | `Movies/PVJ Recordings/set_<stamp>/partNN.mp4` | REC | Performer's files | n/a (shared storage, not app storage) | — |
| Godot shader cache | `files/shader_cache/<ShaderClass>/<source hash>/*.cache` | Godot's GL renderer, first use of each shader variant | Never | Per version yes (~0.3 MB); **not across updates**: a changed shader leaves its old folder | Capped at 16 MB: over it, the whole cache is cleared |
| S4 frame logs (pro, armed by hand) | `files/s4_<run>_<unix>.csv` | One per armed run | Never | No | Newest 5 kept |
| Calibration dumps | `files/calib_dump/` | Only if the folder was created by hand (adb) | Never | n/a (developer only) | — |
| Old thumbnail folder | `files/thumb_cache/` | beta1/beta2 (DriveClient was an autoload); pro Drive thumbs | Never | — | Removed in builds without Drive |
| Drive cache (pro) | `files/drive_cache.cfg`, `drive_auth.cfg` | Pro Drive browser | — | — | — |
| Logs | none on Android (`debug/file_logging` is off on mobile) | — | — | — | — |

## 2. What grows: measured

See §4 for the table. With a fixed library, nothing in app storage grows from session to session
except the shader cache, which stops once each effect has been used (15 → 21 files, ~290 KB). Launch
time does not move. Growing the library 28 → 108 → 508 clips does not move launch time or the
steady-state frame rate either; the first session after an import pays for its thumbnails.

## 3. Startup: what runs at launch

- `Storage._ready`: reads storage.cfg, layout decision, `.part` cleanup (2 directory listings), the
  demo-clip copy (first launch only), self-clean (beta4). No clip is opened or probed.
- `ClipEngine._start`: one directory listing (top level + one level of folders) and ONE decoder open
  (the restored clip). Clips are not probed: a dead clip is found when it is cued (4 s skip).
- `ClipLibrary.rebuild`: one pass over the list (ids are string hashes).
- `pipeline._load_playlist_order`: resolves every saved key against the scan — the list that used to
  keep every departed clip's key.
- 2 s after boot, `ThumbnailService.request_all`: before beta4 it queued EVERY cached thumbnail for a
  decode (three per frame) for nobody to see, and generated the missing ones on the main thread
  (lossless WebP encode, tens of ms each: the 45 boot-window hitches after an 80-clip import). Now it
  only generates missing ones, and the encode runs on a worker.

## 4. Before / after (Pixel 9a, debug app)

How a session ran (`session.sh`, kept out of the repo): force-stop, `am start -W`, 25 s for the boot
window, 2 min of performing (a cut every 4 s, an FX change every 16 s, so new shader variants compile),
then LIB ▸ CLIP GRID, long-press a clip into SEQ A, SAVE slot 1, HOME, force-stop, `du` of files/ and
cache/ with `run-as`. "before" = 0.8.0-beta3 + the timing lines only; "after" = this change.
Clips 29–508 were symlinks to the 20 imported clips (hard links are refused by SELinux): the same
listing, ids, thumbnails and decoding as real files, with no disk cost. Timing lines are in logcat:
`[boot]` / `[perf]` (scripts/boot_timing.gd); "storage ready" and "interactive" are ms since the
ENGINE started (the splash clip takes ~5 s by design); `am start` is Android's TotalTime.

| build | s | clips | am start ms | storage ready | interactive | boot >50 ms | perf >33 ms per 30 s | files KB / n | cache KB / n | thumbs | shader files | note |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| before | 1 | 28 | 454 | 1611 | 6977 | 2 | 15 / 12 / 16 / 10 | 140583 / 52 | 2075 / 29 | 28 | 15 | 20 clips imported (IMPORT PACK) before s1 |
| before | 2 | 28 | 439 | 1457 | 6559 | 2 | 13 / 13 / 13 / 14 | 140659 / 58 | 2075 / 29 | 28 | 21 | |
| before | 3 | 28 | 872 | 2003 | 7235 | 2 | 14 / 12 / 17 / 21 | 140659 / 58 | 2075 / 29 | 28 | 21 | |
| before | 4 | 28 | 791 | 1864 | 7193 | 2 | 11 / 13 / 11 / 14 | 140659 / 58 | 2075 / 29 | 28 | 21 | |
| before | 5 | 28 | 439 | 1469 | 6722 | 2 | 14 / 12 / 16 / 13 | 140659 / 58 | 2075 / 29 | 28 | 21 | |
| before | 6 | 108 | 298 | 1422 | 6640 | **45** | 12 / 8 / 14 / 15 | 140675 / 58 | 6303 / 109 | 108 | 21 | +80 clips: thumbnails generated |
| before | 7 | 108 | 447 | 1425 | 6523 | 2 | 22 / 16 / 16 / 12 | 140675 / 58 | 6303 / 109 | 108 | 21 | |
| before | 8 | 508 | 279 | 1606 | 6827 | **46** | **167 / 155** / 11 / 10 | 140727 / 58 | 27439 / 509 | 508 | 21 | +400 clips: thumbnails generated |
| before | 9 | 508 | 358 | 1514 | 6827 | 3 | 17 / 20 / 10 / 15 | 140727 / 58 | 27439 / 509 | 508 | 21 | |
| after | 1 | 508 | 425 | 1492 | 6768 | 4 | **80 / 59** / 13 / 12 | 140353 / 44 | 27439 / 509 | 508 | 0 ¹ | +400 new clips, 400 orphaned thumbnails pruned |
| after | 2 | 508 | 657 | 1322 | 6401 | 3 | 13 / 15 / 11 / 12 | 140710 / 61 | 27439 / 509 | 508 | 17 | |
| after | 3 | 508 | 290 | 1547 | 6849 | 3 | 13 / 13 / 17 / 14 | 140762 / 65 | 27439 / 509 | 508 | 21 | |
| after | 4 | 28 | 430 | 1516 | 6880 | 3 | 17 / 13 / 12 / 13 | 140232 / 44 | 2075 / 29 | 28 | 0 ¹ | 480 orphaned thumbnails pruned |
| after | 5 | 28 | 357 | 1454 | 6521 | 1 | 12 / 11 / 12 / 11 | 140615 / 59 | 2075 / 29 | 28 | 15 | |
| after | 6 | 28 | 281 | 1509 | 6769 | 1 | 11 / 10 / 18 / 15 | 140691 / 65 | 2075 / 29 | 28 | 21 | |

¹ A planted 17 MB fake shader folder pushed the cache over the cap, so the whole cache was cleared;
Godot does not write it again in the same run (the folders it made at start are gone), and it was
back to 21 files two sessions later with no visible cost. File counts of 59/65 include planted test
files (S4 logs, masks). Frame rate was 59.7–60.1 fps in every window of every session.

Self-clean checked by planting one of each leftover in the debug app before after-s1 and after-s4: a
mask image no config names (removed) and one a mask set names (kept), a stale demo copy, a `.tmp`, a
clipcache `.part` outside legacy mode, `files/thumb_cache/`, seven S4 logs (the newest five kept), the
17 MB shader folder. All as intended.

⚠️ `FileAccess.get_modified_time` did not ORDER files correctly on the 9a (seven files dated Oct 1–7
with `touch -d` came out with 1 and 7 the "oldest"). The first self-clean build sorted on it and
deleted the wrong S4 logs and the live shader folders before the fake one. Nothing here uses it now:
S4 logs sort on the unix time in their name, the shader cache is cleared whole.

## 5. The Android 17 / API 37 16 KB emulator

`system-images;android-37.2;google_apis_ps16k;x86_64` r07 (sha1 19653fc4…), AVD `pvj_api37_16k`
(6 cores, 6 GB, 1080x2400, host GPU through WHPX). `getconf PAGESIZE` = 16384. The image is x86_64
with `libndk_translation` for arm64 (`ro.product.cpu.abilist=x86_64,arm64-v8a`), and PVJ ships
arm64 only, so ALL of PVJ runs translated.

- Both the public beta3 APK and the debug APK install and run: `pageSizeCompat=0`, no linker
  warnings, first-run dialog, demo deck, thumbnails, the welcome tour, self-clean.
- Different from the Pixels, all from translation (performance figures here mean nothing):
  first launch `storage ready` 54.9 s (10.3 s from the second launch on, once translated code is
  cached; 9a ~1.5 s); 13–24 fps; the splash clip misses its 2.0 s open timeout, so the still
  fallback shows; `OS.get_memory_info()` reports -1 for everything; `am start -W` times out.
- Graphics: Godot reports OpenGL ES 3.1 through the emulator's translator (the 9a: OpenGL ES 3.2,
  Mali-G715). No `SHADER ERROR` on either.
- The debug APK packs the pro MediaPipe `.so` files, which are 4 KB-aligned. The public build does
  not load them, so nothing failed; a pro build on a 16 KB device would need them rebuilt or would run
  in compat mode.
- A real arm64 16 KB device (the Pixel 8 with the 16 KB developer option, or Android 17 hardware
  that ships 16 KB) is still the only test of decode speed under 16 KB pages.

## 6. What changed in beta4, and what is still open

Changed (core/storage.gd, scripts/thumbnail_service.gd, scripts/clip_library.gd, scripts/pipeline.gd,
StoragePlugin.kt, scripts/boot_timing.gd):

1. **Thumbnail prewarm generates only what is missing.** Before, every launch queued every cached
   thumbnail for a decode nobody saw. The grid and the sequence strip still load theirs on demand.
2. **The thumbnail WebP encode + write runs on a worker.** After a 400-clip import, frames over 33 ms
   while performing: 167 / 155 per 30 s → 80 / 59; boot-window stalls 46 → 4.
3. **Startup self-clean** (`Storage.self_clean`, logged in the `[boot] storage ready` line): stale demo
   copies, temp files, interrupted cache copies, unreferenced mask images (they used to pile up: every
   pick wrote a new PNG), S4 logs beyond five, the old `thumb_cache/` folder (builds without Drive),
   shader cache over 16 MB.
4. **Orphaned thumbnails** removed once per launch against the real library (never with an empty one).
5. **Playlist keys of departed clips** are no longer kept for ever: only while clips are expected
   back (an old folder not re-imported, legacy mode). The merge is linear now, not quadratic.
6. **LIB ▸ STORAGE** shows `CLIPS · CACHE · OTHER · PHONE FREE`; CLEAR CACHE became **CLEAR
   TEMPORARY FILES** (the old clear + self-clean). It never touches clips, sequences, mask images in
   use, settings or saved setups. Sizes under 1 MB show in KB.
7. `[boot]` / `[perf]` lines in logcat (BootTiming), so a tester's log can answer this next time.

Not reproduced, so still open: what slowed the tester's phone. Candidates the bench cannot simulate:
- **A nearly full phone.** Clips live in app storage, so a big library eats the free space, and f2fs
  slows down when it is nearly full. A reinstall deletes the clips and frees it all. (The 9a here
  was at 95% full and did not slow down, but it was not filled DURING the runs.)
- **A beta1/beta2 tester still in legacy folder mode**: the 2 GB play-copy cache, and synchronous
  copies on a cache miss (~4 ms/MB on the main thread). Reinstalling drops the folder grant and
  the cache.
- **Unplayable clips**: a dead clip is found again every launch (4 s skip on the deck, 5 s in the
  thumbnail queue) because neither is remembered between runs.
- Heat: Android throttles a warm phone; a long session is slower than the first minutes.
Ask the tester for: LIB ▸ STORAGE (the new line), how they upgraded (beta2 with a linked folder?),
phone model and free space, and a logcat with the `[boot]` / `[perf]` lines from a slow session.

