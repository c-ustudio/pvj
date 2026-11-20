# PVJ storage rework — plan (Steps 1–2, no code yet)

Branch: `release/public-beta` only. Written 2026-10-22 from a read-only audit of `a07eaf6`, then
adversarially reviewed against the code (the fixes from that review are folded in).

**Status (2026-10-23): IMPLEMENTED** on `release/public-beta` (Session 43, commits 872b952 … see
SESSION_43_NOTES.md), device-tested on the Pixel 8. Q8 was done last as the safety net (the signing
check says Play can take the sideload key). Deviations from the text below are listed in
SESSION_43_NOTES.md §2.

**Status (2026-10-22): APPROVED** with the defaults for Q1, Q4, Q5, Q6, Q7, Q9 and Q11.
**All pro work is deferred** (Q10 = later). **Q8 is still open**: it
depends on whether the sideload signing key can become Play's app signing key (see "Signing (summary)" below the open questions).
Implementation starts at commit 2, over USB, at high effort.

## Context

The goal is to ship PVJ on Google Play with no broad storage or media permission and no INTERNET.
The audit shows the **permission side is already done**. Since `55d4ec7` (2026-09-29), no build under
the `studio.cu.pvj` id has declared any storage permission, so neither beta1 nor beta2 ever did.

What still needs changing is the **storage model**. Today PVJ *links* a folder the performer picks
(an SAF tree grant) and plays every clip from a copy in `cache/clipcache`. Clips cannot be played
straight from the folder: GoZen only opens file paths, and Android refuses access to a SAF file
through a `/proc/self/fd` path. This model:

- **Blocks the main thread.** A cue that misses the 2 GB cache, and a thumbnail of an uncached clip,
  each copy the whole file synchronously (`core/storage.gd:416-434`, `scripts/thumbnail_service.gd:95`).
  A library bigger than 2 GB hitches on cue. This breaks the "never block the render thread" rule.
- **Wastes space.** Up to 2 GB of duplicate copies sit in the cache.
- **Ties IMPORT PACK to a folder.** It refuses to run in app storage.
- **Doesn't match the privacy policy and store listing**, which half-describe an import model already.
- **Loses Android 10 recordings.** They go to `Android/data`, so they never reach the gallery and are
  deleted on uninstall. The policy says otherwise.

The new model:
- Everything the performer brings in is **copied into PVJ's own storage** through the system picker.
- Recordings land in the gallery.
- **Existing beta setups survive.**

**The biggest constraint the audit found:** testers who sideloaded beta1/beta2 must **uninstall**
before installing from Play. The sideload is signed with the upload key and Play signs with Google's
key (`docs/STORE_LISTING.md:96-100`). With `allowBackup=false`, that uninstall wipes every byte of
PVJ's internal data. An in-app migration therefore only helps **sideload → sideload** updates
(beta2 → the next site APK). The Play move needs something else: §E2.

---

# STEP 1 — AUDIT (nothing changed)

## 1.1 Every file PVJ reads or writes

`user://` = `/data/user/0/<pkg>/files` (internal; no permission; deleted on uninstall).

| Data | Location | Code | Notes |
|---|---|---|---|
| **Clips, folder mode** | User-picked SAF tree (usually `Movies/PVJ`) plus its direct sub-folders, as virtual paths `saf://<label>/[<sub>/]<name>` | `core/storage.gd:238-310`, `StoragePlugin.kt:170-218` (`listMedia`) | Grant kept in SharedPreferences `vjmix_storage/tree_uri` (`kt:68-69, 815`) and re-checked against `persistedUriPermissions` |
| Clips, app mode | `user://clips/<name>` (top level only in practice) | `storage.gd:40, 290-302` | Used with no folder (NOT NOW) and for the 8 demo clips copied there at first launch (`storage.gd:117-145`) |
| Play copies | `<cacheDir>/clipcache/%08x_<name>`, LRU, 2048 MB cap, background prefetch after every scan | `kt:316-397`, `storage.gd:61, 388-434` | `/proc/self/fd` access is refused (EACCES), so every folder clip plays from here |
| Demo staging | `user://demo_stage/<name>` (ident, splash) | `storage.gd:151-172` | Refresh fix covers only this folder. The `user://clips` ident copy is never refreshed |
| **Clip id** | `"%08x" % Storage.rel(path).hash()`: path **relative to the clips folder** | `clip_library.gd:206-207` | Same layout means same ids. Folder label, URI and location are not part of the id |
| Thumbnails | `user://thumbs/<id>.webp` | `thumbnail_service.gd:21, 123`; created `clip_library.gd:88` | Files dir, so Android's "Clear cache" can't free them. Orphans never cleaned |
| | `user://thumb_cache/` | `drive_client.gd:51-52` | Pro Drive thumbs, but the folder is created in **every** build (autoload) |
| Working sequences | `user://sequence.tres`, `user://sequence_b.tres` | `pipeline.gd:1144-1145, 10030-10048` | Lists of clip **ids**. Boot load keeps dead ids |
| Slots | `user://sequences/slot_N.tres` (N = 1–6) | `pipeline.gd:1150, 10063-10205` | LOAD drops missing ids, then **autosaves the trimmed working sequence** (`:10169` → `:10036`). The slot file itself is only written by SAVE |
| Play order / parked | `user://playlist.cfg` `[playlist] order` (rel keys), `live` (**bare names**) | `pipeline.gd:9747-9775, 10254-10271` | Saving writes only present clips. `_rescan` never re-applies it. With a live set in place, new clips start PARKED |
| Masks / regions | `user://regions.cfg`: `[region_N] clip/clips` (rel keys), `[raster_mask] path` (absolute) | `region_editor.gd:39, 1630-1638, 1705-1727`; `mask_overlay.gd:104-134` | **Load drops unresolved clips**, and the next DONE / set save writes the trimmed lists |
| Mask sets | `user://mask_sets/set_N.cfg` | `region_editor.gd:43, 1148-1238` | Rel keys |
| Mask images | `user://masks/mask_<unix>.png` | `storage.gd:500-505`, `kt:746-756, 842-855` | Copied in through SAF `pickImage`. Old images never deleted |
| Warp | `user://warp.cfg` `[slot_N]` | `warp_editor.gd:68, 1162-1180` | Geometry only |
| Calibration | `user://calibration.cfg`, `user://calib_dump/` (only if it already exists) | `calib_editor.gd:87, 155, 348-352` | No paths |
| Settings | `user://settings.cfg`, `user://storage.cfg` | `pipeline.gd:10826-10961`; `storage.gd:531-540` | `[deck] clip` is an **index**. `storage.cfg` `folder_uri` is written but never read |
| Recordings | API 30+: `Movies/PVJ Recordings/set_<stamp>/partNN.mp4`, raw path. API 29: `Android/data/<pkg>/files/Movies/recordings/…` | `kt:764-777`, `SurfaceRecorder.kt:187-190`, `SegmentMuxer.kt:226-227` | Browser = `DirAccess` (`pipeline.gd:9262-9296`). Open/share via Godot's FileProvider (`PresentationPlugin.kt:281-355`). Free space through `_hdmi.getFreeMb` (StatFs, `pipeline.gd:3267-3273`) |
| Pack temp | `<cacheDir>/pack_entry.tmp` | `kt:558-564` | Only for zips that can't be seeked into |
| Perf / log | `user://s4_*.csv` (pro + `[perf]` only); engine `logs/`, `shader_cache/` | `frame_sampler.gd:49-51` | — |
| Pro Drive / OAuth | `user://drive_auth.cfg`, `user://drive_cache.cfg`; downloads into `DriveClient.cache_dir` | `drive_auth.gd:34`, `drive_client.gd:141-161, 253-266`, `pipeline.gd:1310-1311` | `cache_dir` is set once, at boot |
| Pro ClipServer | `clips_dir.path_join(filename)` | `pipeline.gd:10276-10300` | Broken while a SAF folder is set (it targets a `saf://…` path) |

Absolute paths remain in only two places: the desktop fallback `REC_DIR` (`pipeline.gd:175`) and the
desktop-only Local Files browser (`local_browser_ui.gd:98-101`, shown only `if not Storage.available()`).

## 1.2 Permissions and SDK in the final merged manifests (from aapt2 on the artifacts)

| APK | Package | uses-permission | min / target |
|---|---|---|---|
| public `pvj-0.7.0-beta2` (apk + aab) | `studio.cu.pvj`, code 2 | `CAMERA`, `RECORD_AUDIO`, `studio.cu.pvj.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` (an app-defined androidx signature permission, not a storage one) | 29 / 36 |
| debug | `studio.cu.pvj.debug`, code 2 | Same three | 29 / 36 |
| pro (sideload; stale build, Oct 7) | `com.pocketvj.app`, code 7 | Adds `INTERNET`, `WAKE_LOCK`, `ACCESS_NETWORK_STATE` | 29 / 36 |

- **All three:** `allowBackup=false`, `requestLegacyExternalStorage=false`.
- **No MediaProjection, no foreground service, no `foregroundServiceType`.** The only service is
  godot-lib's `GodotDownloaderService` (unused).
- **Where the permissions come from:**
  - presets `export_presets.cfg` L63 / L132 / L201;
  - `src/public/AndroidManifest.xml` removes media3's `ACCESS_NETWORK_STATE`;
  - min 29 comes from the preset, target 36 is Godot's default (`config.gradle:9`).
- **Gap:** `release_build.sh:147` prints the permissions but never fails on an unexpected one.
  `docs/RELEASE.md:105-113` and `STORE_LISTING.md:92-94` list `MODIFY_AUDIO_SETTINGS`/`VIBRATE` (public)
  and `FOREGROUND_SERVICE*` (pro). Those are wrong.

## 1.3 Set recording

- **How it works:** Android MediaCodec H.264 at 12 Mbps / 60 fps, fed from OutputWorld's GL texture.
  `GlBlitter` draws into the encoder's input surface on Godot's render thread
  (`SurfaceRecorder.kt:193-205`, `GlBlitter.kt:69-155`). It is **not** MovieWriter, MediaRecorder or
  MediaProjection.
- **Audio:** Godot's own mic stream, passed as PCM to an AAC encoder (`AudioEncoder.kt`).
- **Segments:** a new standalone MP4 every 5 min (adjustable 1–15), never joined.
  `MediaMuxer(path)` takes a **path string** (`SegmentMuxer.kt:227`).
  - ⚠️ The roll (close + open the next file) runs **inside `writeVideo`, under the muxer lock, on the
    drain thread** (`SegmentMuxer.kt:119-124`). Anything slow added there backs up the encoder, and
    then `GlBlitter.blit` on the render thread.
- **Play impact:** no foreground-service declaration and no demo video needed. Recording stops with
  the app.
- **How files reach the gallery:** on Android 11+, a media file an app creates under `Movies/` by
  path is inserted into MediaStore by the system's storage layer. Today's recordings are therefore
  already gallery items on 11+. Only Android 10 misses out.

## 1.4 Drive import

- **Public:** "Import clips (Drive…)" is the system picker, where Drive appears as one provider.
  Copies go into the linked folder via `createDocument` (no dedupe, so the provider makes `name (1)`
  duplicates), or into `user://clips` (`StoragePlugin.kt:419-429, 857-875`). No OAuth, no network:
  the Drive app does the download.
- **Pro only:** OAuth/PKCE Drive browser (`drive_auth.gd`, `drive_client.gd`) and ClipServer.
  Gated in the UI only.
- ⚠️ **Network code in the public build.** All three are **autoloads in every build**
  (`project.godot:49-51`). The public `.pck` therefore ships their scripts, including the
  **hard-coded OAuth client id/secret** (`drive_auth.gd:23-24`). They send nothing without INTERNET,
  but the public build contains network code it never needs.

## 1.5 What beta users have on disk

- **Package:** both betas are `studio.cu.pvj` (beta1 code 1 from `6153955`, beta2 code 2 from
  `a114df5`; no git tags exist). Beta1 updated to beta2 in place.
- **Clips:** in the user's own folder, typically `Movies/PVJ`, top level plus one sub-folder level
  (sub-folders only since beta2). Pack contents were flattened into the folder **root**.
- **Persisted tree grant:** survives app updates.
- **Internal data:** `settings.cfg`, `storage.cfg`, `playlist.cfg`, `sequence*.tres`,
  `sequences/slot_1..6.tres`, `regions.cfg`, `mask_sets/`, `masks/*.png`, `warp.cfg`,
  `calibration.cfg`, `thumbs/`, `clips/` (the 8 demo clips; NOT NOW users' imports too), `demo_stage/`.
- **Cache:** `cache/clipcache`, up to 2 GB.
- **Recordings:** `Movies/PVJ Recordings/set_*/` on Android 11+.
- **Ids:** beta1 ids were `hash(file name)`, which equals beta2's `hash(rel)` for top-level clips,
  so ids carry over.
- **Migration testing:** `git diff a114df5 a07eaf6` touches none of the storage, library, region or
  mask files. A debug build of today's code is therefore a faithful stand-in for beta2.

## 1.6 Side findings (outside this rework unless you say so — Q9)

1. **DUAL·PLAYER can't play any clip.** It passes `clip_engine.clips[i]` (`saf://` or `user://`) to
   `Uri.fromFile` (`pipeline.gd:10686`, `PresentationPlugin.kt:137`). It needs `Storage.playable()`.
   (DUAL·TEX is not affected.)
2. **Parked list keyed by bare name, order by rel key** (`pipeline.gd:9773` vs `9752`).
   `_rescan` never re-applies the order.
3. **Pro download targets.** ClipServer targets a `saf://` path. Drive `cache_dir` is fixed at boot.
4. **Mask images and thumbnails are never cleaned up.** Old mask images and orphan thumbnails pile up.
5. **ThumbnailService wedges on an unplayable file.** GoZen emits nothing on a failed open, so
   `_busy_id` stays set and every later thumbnail stops (`thumbnail_service.gd:92`).
6. **OAuth secret and network autoloads in the public `.pck`** (1.4).
7. **No permission assertion in the release script.** RELEASE.md / STORE_LISTING permission lists
   are wrong (1.2).
8. **Stale names.** "VJMIX Recordings" / "PocketVJ/recordings" in comments.

---

# STEP 2 — DESIGN

## Principle: one library, owned by PVJ

The library is always **`user://clips/`**: top-level clips plus **one level of folders**, which become
the existing `dir:<name>` chips. The ALL/LIVE/PARKED model is unchanged.

Every import is a job on the Kotlin worker:
1. **pick → plan:** a JSON list of `{source, target rel path, size, action}` plus totals and free space.
2. Godot shows a confirm dialog only when the plan doesn't fit in free space; otherwise it starts
   straight away.
3. **run:** progress and per-file results.

Godot only updates labels, then rescans `user://clips` (a cheap `DirAccess`) and keeps both decks on
their current clips. Nothing heavy runs on the main or render thread.

Clip ids stay `hash(rel path)`, so a layout copied as-is keeps every sequence, slot, mask and
thumbnail.

### Storage location — internal `filesDir/clips` (= `user://clips`)

| | `filesDir` (internal) — **chosen** | `getExternalFilesDir` |
|---|---|---|
| Permission / uninstall | none / deleted | none / deleted |
| Free space | same flash pool on the Pixels | same |
| Code | `user://` paths; demo clips already play from here; no path conversion | absolute paths everywhere |
| Access by others | none | sometimes reachable over USB MTP (not on all Android 11+ phones); invites edits that bypass the importer |
| Already holds clips | NOT NOW users + demo clips → nothing to migrate | everyone migrates |

Auto Backup is off (`allowBackup=false`), so a large `filesDir` affects nothing.

## A. Clip import (SAF → app storage)

### Kotlin (`StoragePlugin.kt`) — one job runner, three pickers, no persisted grants

**Pickers:**
- `pickImportFiles()`: `ACTION_OPEN_DOCUMENT`, `CATEGORY_OPENABLE`, `EXTRA_ALLOW_MULTIPLE`,
  `EXTRA_MIME_TYPES = ["video/*"]` (images: Q4). Multi-select comes back as `ClipData`.
  Drive, Dropbox, Downloads and USB-OTG all arrive through the same picker.
- `pickImportFolder()`: `ACTION_OPEN_DOCUMENT_TREE`, using the picker's temporary grant only.
  **No `takePersistableUriPermission`.** Nothing resumes a job after a process death, and releasing a
  grant could revoke a legacy user's linked folder if they pick the same tree.
  - The folder becomes **one chip** named after it. Its direct files plus one level of sub-folders
    are flattened into that chip. Deeper levels are counted as "too deep".
- `pickImportPack()`: see §B.

**Signals** (byte counts declared `Long::class.javaObjectType`; Godot silently drops a signal whose
argument types don't match, and Int overflows at 2 GB):
- `import_planned(job, json)`
- `import_progress(job, name, i, n, bytes_done, bytes_total)`, throttled to about 4 Hz
- `import_finished(job, json{imported, duplicates, renamed, failed:[{name, reason}], cancelled, bytes})`

**Plan rules:**
- Size comes from `OpenableColumns.SIZE`. It can be unknown (some cloud providers), and is then
  shown as "?".
- **Type:** the extension must be in `VIDEO_EXTS` (`mp4 mov mkv webm m4v avi`). A missing or odd
  extension is taken from the MIME type (`video/mp4` → `.mp4`, `video/quicktime` → `.mov`,
  `video/webm`, `video/x-matroska`). Anything else (3gp, ts, mpg) fails with `UNSUPPORTED TYPE`.
  Otherwise such a file would be copied but never listed.
- **Library-wide dedupe:** a file whose name **and** size already exist anywhere in `user://clips`
  is skipped as `ALREADY IN PVJ (<folder>)`. Re-imports are idempotent, and a beta2 user re-importing
  a pack that beta2 flattened to the top level gets no duplicate.
- Same name, different size, in the target folder: `name (2).ext` (today's pack rule).
- Names are sanitized (`/ \ : * ? " < > |` and control characters replaced), at most 200 bytes,
  never `.` or `..`, and never a leading `.`.
- `PVJ Recordings` folders are always skipped.

**Free space:**
- Plan check: `StatFs` on `filesDir`, minus a **512 MB** reserve (the recorder's).
  Not fitting → "NEEDS 3.2 GB · 1.1 GB FREE" with **IMPORT WHAT FITS** / **CANCEL**.
- At copy time, on the worker: `StorageManager.allocateBytes(fd, size)` on the `.part` before
  writing. It actually frees other apps' cache, and fails early instead of at 90%.

**Copy:**
- Stream with `openInputStream`, 1 MB buffer, into `<target>.part`, checking the cancel flag between
  chunks.
- `FileDescriptor.sync()`, then rename.
- Never more than 1 MB in memory, so a 1 GB+ file is fine.
- Out of space (`ENOSPC`) or an I/O error: delete the `.part`, record a per-file failure, and stop
  the batch on ENOSPC.
- **Cancel** keeps the files already finished and deletes the current `.part`:
  "CANCELLED — 3 OF 7 IMPORTED".

**Probe after copy:**
- `MediaExtractor` checks for a video track and reads its mime and width × height.
- **No video track** (audio-only, zero bytes, corrupt): delete, `NOT A VIDEO`.
- **Above 1920 × 1080, or HEVC 10-bit / AV1:** kept, with the warning `MAY STUTTER (3840×2160 HEVC)`.
  GoZen's FFmpeg build decodes almost everything in software, so the risk is speed, not support.
- **A container MediaExtractor can't parse:** kept, and the thumbnail pass decides (see the fix below).

**Containment and crash safety:**
- Every target is checked with `canonicalPath` and must sit inside `filesDir/clips/`.
- `Storage._ready` deletes every `*.part` under `user://clips` (two levels). The scan already ignores
  them: their extension is `part`.

### Godot side

**`core/storage.gd`:**
- `clips_dir()` returns `user://clips`, except in legacy mode (§E).
- New `import_files()` / `import_folder()` / `import_pack()`, `cancel_import()`, `free_mb()`.

**`pipeline.gd` LIB ▸ SOURCES:**
- Rows: `Clip Grid…`, `Import clips…`, `Import folder…`, `Import pack (.zip)…`, `Load demo clips`
  (into app storage, idempotent), `Get more clips…`, `Recordings…`, `Storage…` (§F), `Rescan`.
  `Clips folder` goes away.
- **Refused while recording:** "STOP REC FIRST". A picker activity pauses the GL thread that feeds
  the encoder (the same reason `handOff` refuses at `PresentationPlugin.kt:290-296`), and an import
  would eat the recording's 512 MB reserve.
- **Progress:** the status/toast line shows `IMPORTING 3/7 · NAME · 412/1200 MB` with a **CANCEL**
  cell.
- **Summary:** `IMPORTED 12 · 3 ALREADY IN PVJ · 1 NOT A VIDEO`. Tapping it lists the failures
  (`M8Dialog.pick`).
- **After import:**
  - a new helper, **`_rescan_keep_deck()`**: save the paths playing and cued on A and B, scan both
    engines, put both decks back on those paths (today only `_remove_clip_file` does this);
  - imported clips **join the live set** when one exists (today they arrive PARKED);
  - `_load_playlist_order()`.
- **First run:** "CHOOSE YOUR CLIPS FOLDER" (`pipeline.gd:8955-8975`) becomes "PLAY YOUR OWN CLIPS?"
  with IMPORT CLIPS / IMPORT FOLDER / IMPORT PACK / NOT NOW.

**ThumbnailService fix:** a 5 s timeout per thumbnail. A clip that never produces a frame gets a
`CAN'T PLAY` cell, and the queue moves on.

⚠️ **Risk to measure (T2/T5):** after a big import, thumbnails are generated one by one through a
GoZen open. If that hitches the deck, throttle generation while the deck is live. Today the same
happens after any rescan.

## B. Starter-pack zip import

The existing streaming reader is kept: `StoragePlugin.kt:483-744`, a central-directory reader for
seekable files and a `ZipInputStream` fallback for cloud streams, with CRC check and cancel.
Only the destination changes, from a tree to a `File` directory, and it gains hardening.

**Destination:** `user://clips/<pack name>/`. The pack name is the zip's display name without `.zip`,
sanitized. It shows up automatically as a `dir:` chip.

**Entries:**
- Internal paths are flattened to the file name. Name collisions inside the pack become `(2)`.
- Library-wide dedupe (§A) means re-importing a pack is a no-op.
- The streamed path writes straight to `<pack>/.<name>.part`. No `pack_entry.tmp` double write in a
  cache Android may clear under low storage.

**Zip-slip and hardening:**
- Split names on both `/` and `\`, keep only the last segment, and drop `""`, `.` and `..`.
- Skip absolute and drive-letter names, NUL or control characters, and any hidden segment
  (`__MACOSX`, `._x`, `.DS_Store`).
- Run the canonical-path containment check before every write.
- **Zip bomb:** stop an entry that inflates past its declared size, and cap the pack at 10 000
  entries.
- Zip64 (over 4 GB) falls back to streaming, as today.

**Media filter:** `VIDEO_EXTS` only. Images are skipped (Q4). So are `README*`, `.txt` and
everything else, counted as `NOT A CLIP`.

**Free space:** a seekable zip gives the total uncompressed size up front, so the plan dialog can
refuse early. A streamed zip is checked entry by entry (`allocateBytes`).

## C. Recordings — gallery without touching the recorder

**Recommended: raise minSdk 29 → 30 and keep today's writer** (Q6).

- **Why:**
  - On Android 11+, `Movies/PVJ Recordings/set_*/partNN.mp4` written by path is already a MediaStore
    item: in Photos, shareable, no permission. That path is tested on both phones.
  - The explicit MediaStore API would only be *needed* for Android 10. That is also the only level
    we can't test: no device, and the arm64-only APK won't run on an API 29 x86 emulator.
  - The explicit API is also not free. `insert` + `openFileDescriptor` + `update(IS_PENDING=0)` are
    cross-process calls. They would land inside the segment roll under the muxer lock (1.3), so they
    would need a pre-opened next part on a helper thread to avoid stalling the render thread.
- **What changes:**
  1. `export_presets.cfg` min_sdk "30" in all three presets.
  2. `recordingsDir()` loses its API 29 branch. The debug build writes to `Movies/PVJ debug Recordings`,
     so test recordings never mix with real ones.
  3. On REC stop, `MediaScannerConnection.scanFile` on the set's parts. It's async, outside the
     recorder, so they show in Photos at once.
  4. The browser keeps listing its own files. It gains a footer: "Recordings from before a reinstall
     are in Movies/PVJ Recordings: open them in Photos or Files." (After a reinstall Android hides
     the old files from PVJ without READ_MEDIA_VIDEO.)
  5. Store listing / beta page: "Android 11 or newer".
- **Alternative if you want explicit MediaStore or Android 10 kept:** a MediaStore writer
  (`RELATIVE_PATH "Movies/PVJ Recordings/"`, `IS_PENDING`, `MediaMuxer(FileDescriptor)`, next part
  pre-opened on a helper thread, pending rows cleaned at launch). About +0.5 session. It touches the
  recorder's drain thread.
- **Recordings stay in `Movies/PVJ Recordings`, not `Movies/PVJ`** (Q5). Testers' clips folder *is*
  `Movies/PVJ`, so recordings there would mix with clips and get swept into the migration copy.
- **No `WRITE_EXTERNAL_STORAGE` / `maxSdkVersion=28` in either option:** minSdk is already ≥ 29.

## D. Final permission list

**Nothing to remove.** No storage permission, no READ_MEDIA_*, no all-files UI exists in the public
build. Final public and debug manifest:

```
android.permission.CAMERA            (runtime, asked on first SRC → CAMERA)
android.permission.RECORD_AUDIO      (runtime, asked on first mic use)
<pkg>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION   (androidx, app-private signature permission)
```

- No INTERNET, no ACCESS_NETWORK_STATE, no FOREGROUND_SERVICE, no storage permission.
  minSdk 30 (Q6) / targetSdk 36.
- **Add an allowlist assertion** to `tools/release_build.sh`: `aapt2 dump permissions` on the public
  artifact, and **fail** on anything outside these three.
- Fix the lists in `docs/RELEASE.md` and `docs/STORE_LISTING.md`.

## E. Migration

**Snapshot first.** On the first launch of the new code, copy every small config file to
`user://pre_layout2/`: settings, playlist, sequence*, sequences/, regions, mask_sets/, warp,
calibration, storage. A few KB, kept for one version as insurance.

### Missing clips must never erase curation (needed by E1 and E2; today they do)

- **Masks:** `region_editor.load_saved` keeps each region's **stored** `clip`/`clips` keys next to the
  resolved paths. `_save()` / mask-set save write unresolved keys back:
  - a region whose list wasn't edited is written as stored;
  - when the list was edited, unresolved keys are kept at the end.
- **Slots:** while clips are missing (legacy-unreachable, or before a re-import), slot LOAD with
  missing ids refuses with `SLOT 2: 9 CLIPS NOT IN PVJ YET` instead of autosaving a trimmed working
  sequence. Normal "k DROPPED" behaviour is unchanged otherwise.
- **Playlist:** `_save_playlist_order/live` **merge**: keys of clips not present are kept.
- **Deck:** `settings.cfg [deck]` also stores the rel key of the playing clip, and boot prefers it
  over the index.

### E1. Sideload update (beta2 APK → next APK)

| State found at boot | What happens |
|---|---|
| No tree (fresh install, NOT NOW users) | The library is already `user://clips`. Done (`layout=2`). |
| **Tree grant valid and listable** (most testers) | **Legacy folder mode: play and curate only.** The deck works exactly like beta2 (tree + cache copies). The import / pack / demo rows are replaced by **`Copy clips into PVJ…`** (because imports would go where legacy mode doesn't look). REMOVE keeps its "deletes the file in your folder" wording. One-time dialog at launch: "PVJ NOW KEEPS ITS OWN COPY OF YOUR CLIPS. Copy 31 clips (412 MB) from PVJ? Sequences, masks and settings stay as they are. Your files in Movies/PVJ are not changed." **COPY CLIPS** / **LATER**. |
| Tree recorded but unreachable (grant revoked, or `listMedia` errors) | Library = `user://clips`. One-time message, plus a LIB row **`Re-import old clips folder…`**: "Your clips folder 'PVJ' can't be reached any more. Re-import it and your sequences, masks and settings find the clips again." The curation guards above keep everything. |

`listMedia` is changed to return an error marker instead of `[]`, so a deleted folder that keeps its
grant is "unreachable", not "copy 0 clips". That would otherwise be a vacuous success that releases
the grant.

**The copy (COPY CLIPS, or Re-import with "keep its layout"):**
- Runs on the same job runner and **mirrors** the tree: top level → top level, sub-folders →
  chips. Every id is unchanged.
- A clip already in `clipcache` with the right size is copied from there. That's local and fast;
  prefetch is paused during the copy.
- **Before it starts:** top-level `user://clips` files whose **names collide** with tree files move
  to a flat `OLDER IMPORTS/` chip. Demo clips that aren't in the tree and match the packaged size are
  deleted (LOAD DEMO CLIPS gets them back). Nothing the user imported is deleted, and nothing is
  nested two deep.
- **It never switches the library live.** When every clip is copied (or already present at the same
  size), it records `layout=2 pending` and says: "DONE — PVJ PLAYS ITS OWN COPY FROM THE NEXT START.
  RESTART NOW / LATER".
  - The switch happens at the next cold start, in `Storage._ready`, before ClipEngine reads
    `clips_dir()`. That boot also releases the tree grant and deletes `cache/clipcache`.
  - Why not live: decks, region editor, masks and thumbnails all hold `saf://` paths, and a live
    switch would cut the deck mid-set.
  - RESTART NOW uses Godot's restart (godot-lib ships ProcessPhoenix). If Android won't restart, it
    says "close and reopen PVJ" (to verify on device).
- **On any failure:** stay in legacy mode and report `COPIED 29 OF 31 — 2 FAILED`. RETRY is cheap,
  because finished files dedupe.
- **No "delete the originals" step** (Q7).

### E2. Sideload → Play (uninstall wipes everything internal) — SAVE / RESTORE SETUP (Q8)

- **SAVE SETUP…** (LIB ▸ Storage…) writes a zip through `ACTION_CREATE_DOCUMENT`
  (`PVJ setup 2026-10-22.zip`, the user picks Downloads or Drive). It holds the snapshot list plus
  `masks/*.png`, without `storage.cfg`. **No clips.**
- **RESTORE SETUP…**, on a fresh install:
  1. It first offers `Re-import old clips folder…` (keep its layout) when the library is empty.
  2. Then it reads the zip through `ACTION_OPEN_DOCUMENT`, accepting only allowlisted names,
     size-capped, writing them to `user://` with `layout=2`.
  3. Then it restarts. One restart; the ids match because the layout was mirrored.
- The raster-mask path stays absolute. Same package means the same `/data/user/0/studio.cu.pvj/...`,
  so `regions.cfg`'s format is untouched.
- **Ships in the next sideload build**, so testers have it *before* they uninstall for Play.

## F. Storage management

**LIB ▸ Storage…** opens an `M8Dialog` list built from a Kotlin `storageReport()` JSON, computed on
the worker and returned by signal.
- Header: `CLIPS 4.2 GB · 63 · PHONE FREE 23.1 GB · CACHE 180 MB`.
- One row for the top level, plus one row per folder chip: `PVJ_STARTER_PACK_V2 · 22 CLIPS · 303 MB · REMOVE`.
  - REMOVE asks for confirmation.
  - It refuses if the clip on deck A or B is inside (same messages as clip REMOVE).
  - It deletes the files and their thumbnails, and strips the ids from both lanes in one save.
- Rows for `CLEAR CACHE · 180 MB` (thumbnails and temp files), `SAVE SETUP…` and `RESTORE SETUP…`.

**Clip REMOVE** reuses the existing flow (`pipeline.gd:9619-9737` → `Storage.delete`). In layout 2
the confirm text says "Remove NAME from PVJ? PVJ's copy is deleted; the file you imported it from is
not touched."

**Cache dirs:**
- `user://thumbs` and `user://demo_stage` move to `OS.get_cache_dir()` (`context.getCacheDir()` on
  Android) **by rename**: same filesystem, nothing regenerated.
- (`DriveClient` creating an empty `user://thumb_cache` in the public build is left alone: it is
  pro-script work, see "Later: pro".)
- After this, Android's **Settings ▸ Apps ▸ PVJ ▸ Clear cache** is always safe, and **Clear storage**
  wipes clips plus setup. The help text says so.

## G. Pro build parity — deferred

Moved to "Later: pro" at the end of this document.

## H. Test plan (debug build `studio.cu.pvj.debug` only; real `studio.cu.pvj` never launched or written)

### Pre-flight, every session

1. Run `adb devices -l`, then `adb -s <serial> shell getprop ro.product.model` for each phone, to
   map Pixel 8 / Pixel 9a. Every command after that uses `-s`.
2. Build the debug APK with `GODOT=… tools/release_build.sh 0.7.0-beta2 debug`. One target per run;
   restart adb afterwards.
3. `install -r` on both phones, then `tools/backup_device_data.sh -s <serial> studio.cu.pvj.debug`.

### Test data

- Made on the PC (ffmpeg plus python `zipfile`) in the scratchpad.
- Pushed only to new folders `/sdcard/Download/pvj_test/` and `/sdcard/Movies/PVJ_MIGRATION_TEST/`,
  deleted at the end (Q11).
- **Set A:** 10 × 720p/1080p H.264, one 4K HEVC, one VP9 `.mkv`, an audio-only `.mp4`, a zero-byte
  `.mp4`, a `.3gp`, an extension-less `video/mp4`, two files with the same name and different sizes,
  a corrupt file followed by good ones.
- **1.2 GB clip:** 1080p, about 16 Mbps × 10 min.
- **Zips:**
  - pack with 3-deep folders + `__MACOSX` + `._x` + `README.txt` + `.DS_Store`;
  - evil zip with entries `../../evil.mp4`, `/sdcard/evil.mp4`, `a\..\b.mp4`, plus a lying-size entry;
  - stored + deflated mix;
  - truncated zip.

### Tests

| # | Test | Pass |
|---|---|---|
| T1 | Fresh install: demo clips play; new first-run prompt; `dumpsys package` permissions | Exactly CAMERA + RECORD_AUDIO (+ the receiver permission); minSdk 30 |
| T2 | Import set A (multi-select from Downloads), deck playing | Progress; `NOT A VIDEO` ×2; `UNSUPPORTED TYPE` for 3gp; extension-less becomes `.mp4`; `MAY STUTTER` on 4K; `(2)` rename; corrupt file → `CAN'T PLAY` and later thumbs still appear; 2nd run = `ALREADY IN PVJ` only; deck keeps its clip; fps during thumbnailing logged |
| T3 | **Drive**: 2 clips in your Drive → Import clips → Drive provider; airplane mode mid-download | Clips land; the interrupted one fails cleanly, no `.part` left |
| T4 | Import folder (with a sub-folder and a 3-deep level); import while REC runs | One chip; deeper levels reported; during REC: `STOP REC FIRST` |
| T5 | **1.2 GB clip** while the deck plays | Byte progress smooth; **Pixel 8 fps ≥ 55 throughout** (fps readout + logcat); the clip cues and plays |
| T6 | Zips: nested/junk, evil, truncated, cancel mid-pack, a Drive-hosted zip (streaming path), re-import of the same pack | Only media, inside `files/clips/<pack>/`; `find files -newer marker` shows nothing outside; cancel leaves no partial; re-import = 0 new |
| T7 | **Low storage**: (a) debug-only fake free-space override; (b) optional real ENOSPC via a balloon file in the debug app's own files dir | Refusal / clean mid-copy failure; balloon removed afterwards |
| T8 | Picker cancelled; mic revoked (`pm revoke … RECORD_AUDIO`) then REC | `NOTHING IMPORTED`; video-only recording, no crash |
| T9 | **Killed mid-import** (`am force-stop` during T5 and during a pack) | Relaunch: no `.part`, grid intact, re-import completes |
| T10 | **Reinstall** debug | `files/clips` gone; recordings stay in Photos; the browser shows the footer; new recording no collision |
| T11 | Recording: 1-min parts × 2, share, disk-full guard | Parts in `Movies/PVJ debug Recordings`, visible in Photos right after stop; share sheet works |
| T12 | **Migration**: install a debug build of today's code → pick `PVJ_MIGRATION_TEST` (12 clips + 1 sub-folder + an extra top-level clip named like a demo clip) → slots 1–2, park 2, mask with a clip list, raster mask, warp → back up → `install -r` the new build | Legacy mode plays; COPY runs while the deck plays (fps logged); "next start" message; after restart: every slot `0 DROPPED`, parked same, masks show their clips, raster mask + warp same, thumbnail ids same, grant released, clipcache gone. **Variants:** LATER (legacy keeps playing; imports hidden); folder deleted before upgrade (message; masks/slots untouched on disk; re-import + restart restores them); not enough space; a tree that is the whole `Movies` (no `PVJ Recordings` swept in); finishing mid-set (deck never cut) |
| T13 | SAVE SETUP → uninstall → reinstall → re-import → RESTORE (and RESTORE *before* re-import) | Slots `0 DROPPED`, masks/warp back, in both orders |
| T14 | **DUAL·TEX after import**: overlay display 1920x1080/320 as in S42 | `TEXTURE OUTPUT LINK ok` + periodic `blit … fps`; 60 fps for 30 s on the Pixel 8; imported 1080p cuts |
| T15 | Storage panel | Sizes match `run-as du`; folder REMOVE refuses the playing clip; CLEAR CACHE then thumbs regenerate; Android "Clear cache" safe |

**Headless:**
- New `tools/verify_storage_migration.gd` with a fake plugin: the layout decisions, collisions moving
  to OLDER IMPORTS, the pending switch at boot, rel keys preserved, playlist merge, region and slot
  guards.
- Still passing: `verify_library_rescan`, `verify_sequence_strip_layout` (as a scene), `verify_help`.
- Kotlin zip and import rules are proven by T2/T6 on the device.

## Not touched

- Render pipeline, OutputWorld, `EglBridge`/`GlBlitter`/the PresentationPlugin texture path.
- **The recorder** (`SurfaceRecorder`/`SegmentMuxer`/`AudioEncoder`), with option C as recommended.
- ClipEngine decode/cue, sequencer logic.
- **Slot/sequence file format, `regions.cfg` format, `warp.cfg`.**
- **Touched near those:**
  - `region_editor` load/save (unresolved keys kept);
  - slot LOAD (refusal while clips are missing);
  - ThumbnailService (timeout);
  - `export_presets.cfg` min_sdk.

## Files

- **Kotlin:** `android/build/src/main/java/com/pocketvj/StoragePlugin.kt` (job runner, pickers, zip
  hardening, probe, `storageReport`, `allocateBytes`, setup zip, `recordingsDir`, `scanFile`;
  `listMedia` error marker).
- **GDScript:**
  - `core/storage.gd` (library dir, legacy mode, layout state + pending switch, snapshot, cleanup);
  - `scripts/pipeline.gd` (LIB rows, prompts, progress, `_rescan_keep_deck`, storage panel,
    playlist merge, live-set join, deck key, REC guard, rec browser footer);
  - `scripts/region_editor.gd` (keep stored keys);
  - `scripts/thumbnail_service.gd` + `clip_library.gd` (thumb dir, timeout);
  - `scripts/help_text.gd`.
- **Config / tools / docs:** `export_presets.cfg` (min_sdk 30), `tools/release_build.sh` (permission
  allowlist), `tools/verify_storage_migration.gd` (new), `docs/PRIVACY_POLICY.md` (§17, §37
  rewritten for the import model), `docs/STORE_LISTING.md`, `docs/BETA2_NOTES.md`-style page copy
  (Android 11+), `docs/RELEASE.md`, `PROJECT_STATE.md`, `SESSION_43_NOTES.md`.

## Commit sequence (small, on `release/public-beta`, never amended)

1. `DOCS: storage rework plan` (this file → `docs/STORAGE_REWORK_PLAN.md`)
2. `STORAGE (kotlin): import job runner — files/folder/pack into app storage, plan → run, progress, cancel, free space, zip hardening, probe`
3. `STORAGE: library is user://clips; .part cleanup; thumbs + demo_stage moved to the cache dir`
4. `LIB: import rows, progress + cancel, summary, REC guard; _rescan_keep_deck; imports join the live set; thumbnail timeout`
5. `CURATION: missing clips never erase masks, slots, playlist; deck clip by key`
6. `MIGRATION: snapshot, legacy folder mode, copy into PVJ, switch at next start, unreachable folder`
7. `LIB: Storage… panel — sizes, folder remove, clear cache`
8. `SETUP: save / restore setup zip` (if Q8)
9. `REC: minSdk 30, debug recordings folder, scan on stop, browser footer`
10. `TOOLS: release_build.sh fails on unexpected permissions`
11. `DOCS: privacy policy, store listing, RELEASE.md, help text` → then `SESSION 43 NOTES` + PROJECT_STATE

No version bump and no release build: those come after the final audit.

## Open questions (my default in **bold**)

**Answered 2026-10-22:** defaults accepted for Q1, Q4, Q5, Q6, Q7, Q9, Q11. Q10 = later (pro
deferred). **Q8 open**, pending the signing check below.

| Q | Question | Default |
|---|---|---|
| Q1 | Import-only for everyone, or keep "linked folder" as an option? | **Import-only** (your brief). Linked mode survives only as legacy play-and-curate until a beta user copies |
| Q4 | Your brief says `video/*` **and** `image/*`, but the deck can't play stills: that would be a deck feature. Images in packs? | **Video only**; pack images skipped. A stills feature is separate |
| Q5 | Recordings in `Movies/PVJ` (your brief) or keep `Movies/PVJ Recordings`? | **Keep `Movies/PVJ Recordings`** (it doesn't collide with testers' clips folder) |
| Q6 | ⚠️ **Deviates from your brief.** minSdk 30 + today's writer (already in the gallery on 11+), or minSdk 29 + an explicit MediaStore writer (+0.5 session, recorder change, the Android 10 path untestable here)? | **minSdk 30, recorder untouched** |
| Q7 | Migration: copy only, or also offer "delete the originals" after a verified copy? | **Copy only** |
| Q8 | SAVE / RESTORE SETUP for the Play uninstall, in this rework? | **OPEN.** Needed only if testers must uninstall to move to Play. If the sideload key can be Play's app signing key, Play updates the sideload in place and nothing is wiped |
| Q9 | Include these side fixes: DUAL·PLAYER path, parked list by rel key + rescan re-applies order, release-script permission assertion, doc corrections? Move the OAuth secret / network autoloads out of the public `.pck` now, or at the final audit? | **Side fixes yes; autoload gating at the final audit** |
| Q10 | Pro storage model | **Later** (pro deferred; see "Later: pro") |
| Q11 | OK to create `/sdcard/Download/pvj_test/` and `/sdcard/Movies/PVJ_MIGRATION_TEST/` on both phones (removed after)? The balloon low-storage test (T7b)? Two test clips in your Drive for T3? | **Folders yes; T7b only with your go; Drive clips need you** |

(Settled by the review, no longer open: internal `filesDir`; Import folder is always "its own
chip", and "keep its layout" exists only in the migration and restore flows; a folder grant is never
persisted for imports.)

## Signing (summary)

Q8 turned on whether the sideload signing key could also be Play's app signing key, so that a Play
install updates a sideloaded beta in place and keeps its data. It can, for a new app, until a release
reaches open testing or production. The release keystore and its passwords live outside the
repository; `tools/release_build.sh` reads them through `PVJ_KEYS_ENV`.

## Estimate

About **3½ sessions**: 3 if Q8 is dropped, 4 if Q6 goes the MediaStore way.

1. Kotlin job runner + storage.gd + import UI + thumbnail timeout + headless checks.
2. Curation guards + migration/legacy mode + storage panel.
3. Setup save/restore (if Q8) + recordings bits + docs.
4. Half a session: the full device pass on both phones (T1–T15) + fixes + SESSION_43_NOTES.

adb reconnects after every export are the usual time sink.
