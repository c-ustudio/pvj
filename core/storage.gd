extends Node
## Storage — where clips come from, without broad storage permissions.
##
## LAYOUT 2 (docs/STORAGE_REWORK_PLAN.md): the library is PVJ's own
## `user://clips` (= filesDir/clips) — top-level clips plus one level of
## folders, the clip grid's dir: chips. Everything the performer brings in is
## COPIED there by the plugin's import jobs (system picker, no permission).
##
## LEGACY (beta1/beta2 testers): a Storage Access Framework TREE the performer
## linked once (VJMIXStorage plugin, android/…/StoragePlugin.kt) still plays
## and curates as before until its clips are copied into PVJ. The engine thinks
## in a folder of paths — ALL/LIVE/PARKED, playlists and thumbnails key on file
## NAMES — so the tree is presented as a VIRTUAL directory:
##
##     saf://<folder label>/<file name>
##     saf://<folder label>/<sub-folder>/<file name>
##
## `clips_dir()` returns that directory (or app-private user://clips when no
## folder is set), `scan()` lists it — the folder AND its direct sub-folders,
## one level (beta2 §1.2; a starter pack that unzips into its own folder) —
## and everything that hands a path to GoZen asks `playable(path)` first.
## Playlists and per-mask clip lists key on the path RELATIVE to the clips
## dir (`rel()`): a top-level file's key is its bare name, as before.
##
## ⚠️ GoZen only takes a PATH, and the /proc/self/fd/N route is REFUSED for local
## SAF documents (EACCES, measured on the Pixel 8 / Android 17). So a tree clip
## plays from an LRU-capped copy in the app cache (CACHE_CAP_MB). scan() starts
## a background prefetch of the folder into that cache, so a cue is normally a
## cache HIT; a miss copies synchronously (~4 ms/MB measured — a 40 MB clip is
## a ~160 ms hitch, logged as "[storage] … cached copy in N ms").
##
## Off Android (desktop, headless) there is no plugin: clips_dir() is
## user://clips and every call is the plain filesystem, as before.

signal image_picked(path: String)                        ## "" = cancelled / failed
signal demo_clips_done(copied: int, skipped: int)        ## load_demo_clips() finished
## The import jobs (StoragePlugin.kt, "Import jobs"). job 0 = the picker was
## cancelled, -1 = refused (another import is running); see the plugin for the
## plan / result fields.
signal import_planned(job: int, plan: Dictionary)
signal import_progress(job: int, file_name: String, i: int, n: int, bytes_done: int, bytes_total: int)
signal import_finished(job: int, result: Dictionary)
signal storage_report_ready(report: Dictionary)          ## request_report() — see StoragePlugin.storageReport
signal setup_done(kind: String, status: String)          ## "save"/"restore", "ok:<n>" / "cancelled" / "error:…"

const SCHEME := "saf://"
const APP_CLIPS := "user://clips"
const MASK_DIR := "user://masks"
const CFG_PATH := "user://storage.cfg"
## The demo clips that ship inside the build (the presets' include_filter
## packs demo_clips/*.mp4). GoZen plays FILES and a pack entry is not one, so:
## on the first launch they are copied into APP_CLIPS, and a new install opens
## on a playing deck instead of an empty one; LOAD DEMO CLIPS (load_demo_clips)
## copies them into the performer's folder. A build without the folder
## (desktop from a bare checkout) copies nothing.
const DEMO_DIR := "res://demo_clips"
const DEMO_CLIPS: Array[String] = [
	"POP_box_glitchtex_05_loop02.mp4", "POP_box_glitchtex_05_loop04.mp4",
	"TERRAIN_NOISE_001_loop01.mp4", "TERRAIN_NOISE_003_loop01.mp4",
	"pvj-ident-720.mp4",
	"pvj_loop_03.mp4", "pvj_loop_04.mp4", "pvj_loop_05.mp4",
]
## Where demo_stage and thumbs used to live (files dir). Since layout 2 they
## are in the CACHE dir (cache_dir()), so Android's "Clear cache" can free
## them; _ready moves an old folder over by rename (same filesystem).
const OLD_DEMO_STAGE := "user://demo_stage"
const OLD_THUMB_DIR := "user://thumbs"
## LRU cap for the copy fallback (cache/clipcache). Only used when a provider
## will not hand out a re-openable fd — local storage does.
const CACHE_CAP_MB := 2048
const VIDEO_EXTS := ["mp4", "mov", "mkv", "webm", "m4v", "avi"]

var _plugin: Object = null
var _tree_uri: String = ""
var _label: String = ""
var _docs: Dictionary = {}          ## relative path -> {document_uri, size, mtime, folder}
var _index: Dictionary = {}         ## relative path -> true, for the last scan of either kind
var _folders: Array[String] = []    ## the sub-folders the last scan saw, sorted
var _stamp: String = ""             ## folderStamp() at the last virtual scan
var _setup_done: bool = false       ## the first-run prompt was answered
var _demo_installed: bool = false   ## the demo clips were copied into app storage once
var _fd_refused: bool = false       ## the provider refused the /proc re-open once: stop asking
var _clips_missing: bool = false    ## curated clips are known to be absent (an old folder not copied in yet)
# --- Layout 2 migration (STORAGE_REWORK_PLAN §E), all in storage.cfg ---
var _layout: int = 0                ## 0 = not decided yet (first launch of this code), 1 = legacy folder, 2 = own library
var _switch_pending: bool = false   ## COPY CLIPS INTO PVJ finished: switch to the own library at the next start
var _copy_offered: bool = false     ## the one-time "PVJ NOW KEEPS ITS OWN COPY" offer was shown
var _old_label: String = ""         ## an old clips folder that could not be reached ("" = none)
var _old_notice: bool = false       ## its one-time message is still to be shown


## The autoload, for scripts that headless tools/ compile under --script before
## the `Storage` identifier resolves (the FeaturesS trap, core/features.gd).
## Those scripts do `const StorageS := preload("res://core/storage.gd")` and
## call through this.
static func node() -> Node:
	return (Engine.get_main_loop() as SceneTree).root.get_node("Storage")


func _ready() -> void:
	if Engine.has_singleton("VJMIXStorage"):
		_plugin = Engine.get_singleton("VJMIXStorage")
		_plugin.connect("image_picked", func(p: String): image_picked.emit(p))
		_plugin.connect("prefetch_done", func(n: int, mb: int):
			print("[storage] prefetch: %d new cop%s, %d MB cached" % [n, "y" if n == 1 else "ies", mb]))
		_plugin.connect("import_planned", func(job: int, json: String):
			import_planned.emit(job, _dict(json)))
		_plugin.connect("import_job_progress", func(job: int, n: String, i: int, c: int, done: int, total: int):
			import_progress.emit(job, n, i, c, done, total))
		_plugin.connect("import_finished", func(job: int, json: String):
			import_finished.emit(job, _dict(json)))
		_plugin.connect("storage_report", func(json: String):
			storage_report_ready.emit(_dict(json)))
		_plugin.connect("setup_done", func(kind: String, status: String): setup_done.emit(kind, status))
	var cfg := ConfigFile.new()
	var recorded := ""   ## the tree an older build linked, as storage.cfg recorded it
	var recorded_label := ""
	if cfg.load(CFG_PATH) == OK:
		_setup_done = bool(cfg.get_value("storage", "setup_done", false))
		_demo_installed = bool(cfg.get_value("storage", "demo_installed", false))
		_clips_missing = bool(cfg.get_value("storage", "clips_missing", false))
		_layout = int(cfg.get_value("storage", "layout", 0))
		_switch_pending = bool(cfg.get_value("storage", "switch_pending", false))
		_copy_offered = bool(cfg.get_value("storage", "copy_offered", false))
		_old_label = str(cfg.get_value("storage", "old_folder_label", ""))
		_old_notice = bool(cfg.get_value("storage", "old_folder_notice", false))
		recorded = str(cfg.get_value("storage", "folder_uri", ""))
		recorded_label = str(cfg.get_value("storage", "folder_label", ""))
		# Device tests (T7a): pretend the phone is nearly full. The plugin honours
		# it only in a debuggable build (studio.cu.pvj.debug), never in release.
		# One launch only: the key is erased as soon as it is read.
		if cfg.has_section_key("debug", "fake_free_mb"):
			if _plugin != null:
				_plugin.setFakeFreeMb(int(cfg.get_value("debug", "fake_free_mb", -1)))
			cfg.erase_section("debug")
			cfg.save(CFG_PATH)
	if _layout == 0:
		_snapshot()
	_apply_restore_stage()
	_decide_layout(recorded, recorded_label)
	DirAccess.make_dir_recursive_absolute(APP_CLIPS)
	_move_to_cache(OLD_THUMB_DIR, thumb_dir())
	_move_to_cache(OLD_DEMO_STAGE, demo_stage_dir())
	_clean_parts()
	_install_demo_clips()
	var cleaned := self_clean()
	print("[boot] %d ms storage ready (self-clean: %d files, %d KB)" % [Time.get_ticks_msec(),
		int(cleaned.n), int(cleaned.bytes) >> 10])
	print("[storage] clips = %s%s" % [clips_dir(),
		"" if _plugin != null else " (no SAF plugin: desktop/editor)"])


# --- Layout 2 migration (STORAGE_REWORK_PLAN §E) ------------------------------

## The config files a first launch of layout-2 code copies aside, once.
const SNAPSHOT_DIR := "user://pre_layout2"
const SNAPSHOT_FILES := ["settings.cfg", "playlist.cfg", "sequence.tres", "sequence_b.tres",
	"regions.cfg", "warp.cfg", "calibration.cfg", "storage.cfg"]
const SNAPSHOT_DIRS := ["sequences", "mask_sets"]
## Where COPY CLIPS INTO PVJ moves app-storage clips whose names collide with
## the old folder's (a different file of the same name) — one flat chip.
const OLDER_IMPORTS := "OLDER IMPORTS"


## Which library this launch uses, before any engine reads clips_dir():
##   switch pending  → the copy finished last time: release the folder's grant,
##                     drop the play-copy cache, PVJ's own library from now on;
##   a granted tree that lists → LEGACY (play + curate as beta2, offer the copy);
##   a tree recorded but gone (grant revoked, folder deleted) → own library, the
##                     curation kept (clips_missing) and a one-time message;
##   nothing → own library (fresh installs, NOT NOW users).
func _decide_layout(recorded: String, recorded_label: String) -> void:
	_tree_uri = ""
	_label = ""
	if _plugin != null and _switch_pending:
		_plugin.clearFolder()
		_drop_clip_cache()
		_switch_pending = false
		_clips_missing = false
		_layout = 2
		print("[storage] layout 2: the copied library is PVJ's own from this start; the folder grant is released")
		_save()
		return
	var granted := str(_plugin.getFolderUri()) if _plugin != null else ""
	if granted != "":
		var label := str(_plugin.getFolderLabel(granted))
		if JSON.parse_string(str(_plugin.listMedia(granted))) is Array:
			_tree_uri = granted
			_label = label
			_layout = 1
			print("[storage] legacy folder mode: %s (play and curate; COPY CLIPS INTO PVJ offered)" % label)
			_save()
			return
		_forget_old_folder(label if label != "" else recorded_label)
		return
	if recorded != "" and _plugin != null:
		_forget_old_folder(recorded_label)
		return
	if _layout != 2:
		_layout = 2
		_save()


## The old folder can't be reached: own library from now on; its curation is
## kept (clips_missing) until the folder is re-imported with its layout.
func _forget_old_folder(label: String) -> void:
	_plugin.clearFolder()
	_drop_clip_cache()
	_old_label = label if label != "" else "clips"
	_old_notice = true
	_clips_missing = true
	_layout = 2
	print("[storage] the old clips folder '%s' can't be reached — own library; masks, slots and order kept" % _old_label)
	_save()


func _drop_clip_cache() -> void:
	var dir := cache_dir().path_join("clipcache")
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


## First launch of layout-2 code: the small config files, copied aside once
## (a few KB), as insurance for one version.
func _snapshot() -> void:
	var any := false
	for f: String in SNAPSHOT_FILES:
		if FileAccess.file_exists("user://".path_join(f)):
			any = true
	if not any or DirAccess.dir_exists_absolute(SNAPSHOT_DIR):
		return
	DirAccess.make_dir_recursive_absolute(SNAPSHOT_DIR)
	var n := 0
	for f: String in SNAPSHOT_FILES:
		if FileAccess.file_exists("user://".path_join(f)) \
				and DirAccess.copy_absolute("user://".path_join(f), SNAPSHOT_DIR.path_join(f)) == OK:
			n += 1
	for sub: String in SNAPSHOT_DIRS:
		var d := DirAccess.open("user://".path_join(sub))
		if d == null:
			continue
		DirAccess.make_dir_recursive_absolute(SNAPSHOT_DIR.path_join(sub))
		for f in d.get_files():
			if DirAccess.copy_absolute("user://".path_join(sub).path_join(f), SNAPSHOT_DIR.path_join(sub).path_join(f)) == OK:
				n += 1
	print("[storage] snapshot: %d config files copied to %s" % [n, SNAPSHOT_DIR])


# --- Setup save / restore (§E2, Q8) ---------------------------------------------

const RESTORE_STAGE := "user://restore_stage"


## SAVE SETUP…: sequences, slots, masks and their images, warp, calibration and
## settings into one zip the performer keeps (StoragePlugin.saveSetup). No clips,
## and not storage.cfg (which library this phone uses is not a setup).
func save_setup() -> bool:
	if _plugin == null:
		return false
	var files: Array = []
	for f: String in SNAPSHOT_FILES:
		if f != "storage.cfg" and FileAccess.file_exists("user://".path_join(f)):
			files.append({"path": ProjectSettings.globalize_path("user://".path_join(f)), "name": f})
	for sub: String in SNAPSHOT_DIRS + ["masks"]:
		var d := DirAccess.open("user://".path_join(sub))
		if d == null:
			continue
		for f in d.get_files():
			files.append({"path": ProjectSettings.globalize_path("user://".path_join(sub).path_join(f)),
				"name": sub.path_join(f)})
	var day := Time.get_date_string_from_system()
	_plugin.saveSetup("PVJ setup %s.zip" % day, JSON.stringify(files))
	return true


## RESTORE SETUP…: pick a setup zip; it is staged and takes over at the next start.
func restore_setup() -> bool:
	if _plugin == null:
		return false
	_plugin.restoreSetup()
	return true


## A restore staged last time (complete, marked by the plugin) moves into place
## now — before anything reads a config file — by rename, replacing what is
## there. With no clips of its own yet, the library is "missing clips" until the
## old folder is re-imported (the curation guards keep every key meanwhile).
func _apply_restore_stage() -> void:
	if not FileAccess.file_exists(RESTORE_STAGE.path_join(".complete")):
		if DirAccess.dir_exists_absolute(RESTORE_STAGE):
			_rmtree(RESTORE_STAGE)   # an unfinished restore never applies
		return
	var n := 0
	for rel: String in _stage_files(RESTORE_STAGE, ""):
		var dst := "user://".path_join(rel)
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		if FileAccess.file_exists(dst):
			DirAccess.remove_absolute(dst)
		if DirAccess.rename_absolute(RESTORE_STAGE.path_join(rel), dst) == OK:
			n += 1
	_rmtree(RESTORE_STAGE)
	_setup_done = true
	if not _library_has_own_clips():
		_clips_missing = true
		_old_label = "clips"
	print("[storage] setup restored: %d files%s" % [n, " — clips not in PVJ yet" if _clips_missing else ""])
	_save()


func _stage_files(root: String, sub: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(root.path_join(sub))
	if d == null:
		return out
	for f in d.get_files():
		out.append(sub.path_join(f) if sub != "" else f)
	for s in d.get_directories():
		out.append_array(_stage_files(root, sub.path_join(s) if sub != "" else s))
	return out


func _rmtree(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	for s in d.get_directories():
		_rmtree(dir.path_join(s))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


## True when user://clips holds anything besides the demo clips.
func _library_has_own_clips() -> bool:
	var d := DirAccess.open(APP_CLIPS)
	if d == null:
		return false
	for f in _list_videos(d, APP_CLIPS):
		if not f in DEMO_CLIPS:
			return true
	return not _list_subdirs(d).is_empty()


## The library holds only the demo clips (a fresh install): RESTORE offers the
## re-import first.
func library_is_demo_only() -> bool:
	return not is_legacy() and not _library_has_own_clips()


## The legacy folder's size, from the last scan: {n, bytes}.
func legacy_summary() -> Dictionary:
	var bytes := 0
	for e: Dictionary in _docs.values():
		bytes += maxi(0, int(e.get("size", 0)))
	return {"n": _docs.size(), "bytes": bytes}


## True once: the copy offer for a legacy folder (pipeline shows it after the splash).
func copy_offer_due() -> bool:
	return is_legacy() and not _copy_offered and not _switch_pending


func mark_copy_offered() -> void:
	_copy_offered = true
	_save()


## The old folder's name while its one-time "can't be reached" message is due, else "".
func old_folder_notice() -> String:
	return _old_label if _old_notice else ""


func clear_old_folder_notice() -> void:
	_old_notice = false
	_save()


## The old folder's name ("" when there is none to re-import).
func old_folder_label() -> String:
	return _old_label if _clips_missing else ""


## COPY CLIPS INTO PVJ (legacy mode): get user://clips ready, then plan a
## mirror of the folder — every id stays the same (import_planned, "mirror").
func copy_into_pvj() -> bool:
	if _plugin == null or not is_legacy():
		return false
	_prepare_copy()
	_plugin.planTreeCopy(_tree_uri)
	return true


## Before the mirror copy: an app-storage clip that has the name of a top-level
## folder clip but is ANOTHER file moves to OLDER IMPORTS/ (the same file is
## left — the copy skips it); a demo clip the folder does not have is deleted
## (LOAD DEMO CLIPS brings it back). Nothing the performer imported is deleted.
func _prepare_copy() -> void:
	var top := {}
	for r: String in _docs.keys():
		if not r.contains("/"):
			top[r] = int(_docs[r].get("size", -1))
	var d := DirAccess.open(APP_CLIPS)
	if d == null:
		return
	for f in _list_videos(d, APP_CLIPS):
		var path := APP_CLIPS.path_join(f)
		if top.has(f):
			if _file_size(path) == int(top[f]):
				continue
			var dest_dir := APP_CLIPS.path_join(OLDER_IMPORTS)
			DirAccess.make_dir_recursive_absolute(dest_dir)
			var dest := dest_dir.path_join(f)
			var k := 2
			while FileAccess.file_exists(dest):
				dest = dest_dir.path_join("%s (%d).%s" % [f.get_basename(), k, f.get_extension()])
				k += 1
			DirAccess.rename_absolute(path, dest)
			# Its thumbnail is keyed by the NAME, which the folder's clip takes over:
			# left in place, the folder's clip would show this file's picture.
			drop_thumbnail(f)
			print("[storage] copy prep: %s → %s/" % [f, OLDER_IMPORTS])
		elif f in DEMO_CLIPS and _same_size(path, DEMO_DIR.path_join(f)):
			DirAccess.remove_absolute(path)
			print("[storage] copy prep: demo clip %s removed (not in the folder)" % f)


## Deletes the thumbnail of the clip at relative path `rel` (ids are hash(rel)).
func drop_thumbnail(rel: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(thumb_dir().path_join("%08x.webp" % rel.hash())))


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f != null else -1


## The copy is complete: the library switches at the next start (_decide_layout).
func mark_switch_pending() -> void:
	_switch_pending = true
	_copy_offered = true
	_save()


func switch_pending() -> bool:
	return _switch_pending


## The re-import of an old folder completed: its clips are back.
func old_folder_restored() -> void:
	_clips_missing = false
	_old_notice = false
	_save()


## The app's cache dir: Android's getCacheDir() (Settings ▸ Clear cache empties
## it), "user://cache" elsewhere — OS.get_cache_dir() is the user-wide cache on
## a desktop, not this app's.
func cache_dir() -> String:
	if OS.has_feature("android"):
		return OS.get_cache_dir()
	return "user://cache"


## Clip thumbnails ({clip id}.webp) — ClipLibrary and ThumbnailService.
func thumb_dir() -> String:
	return cache_dir().path_join("thumbs")


## Real-file copies of the demo clips (the idle loop, the splash, a demo clip
## the performer deleted from the library).
func demo_stage_dir() -> String:
	return cache_dir().path_join("demo_stage")


## An old files-dir folder into the cache dir, by rename: nothing is copied or
## regenerated. Skipped when the new one already exists (a later launch).
func _move_to_cache(old: String, new_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(old):
		return
	var to := ProjectSettings.globalize_path(new_dir)
	if DirAccess.dir_exists_absolute(to):
		return
	DirAccess.make_dir_recursive_absolute(to.get_base_dir())
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(old), to)
	print("[storage] moved %s → %s%s" % [old, to, "" if err == OK else " FAILED (err %d)" % err])


## A copy the process died in the middle of (".name.part", the plugin's import
## jobs) never survives a launch. Two levels: the library and its folders.
func _clean_parts() -> void:
	var n := _clean_parts_in(APP_CLIPS)
	var d := DirAccess.open(APP_CLIPS)
	if d != null:
		for sub in _list_subdirs(d):
			n += _clean_parts_in(APP_CLIPS.path_join(sub))
	if n > 0:
		print("[storage] removed %d unfinished import cop%s" % [n, "y" if n == 1 else "ies"])


func _clean_parts_in(dir: String) -> int:
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	d.include_hidden = true
	var n := 0
	for f in d.get_files():
		if f.get_extension() == "part" and d.remove(f) == OK:
			n += 1
	return n


## First launch only: the demo clips out of the pack and into app storage.
## Never again afterwards — a performer who deletes one must not get it back
## on every boot. (LOAD DEMO CLIPS is the deliberate way to have them again.)
func _install_demo_clips() -> void:
	if _demo_installed:
		return
	var n := 0
	for fname in DEMO_CLIPS:
		if _copy_demo_to_app_storage(fname) == 1:
			n += 1
	_demo_installed = true
	_save()
	if n > 0:
		print("[storage] demo clips: %d copied to %s" % [n, APP_CLIPS])


## One demo clip into APP_CLIPS: 1 copied, 0 already there, -1 not in this
## build (or the write failed).
func _copy_demo_to_app_storage(fname: String) -> int:
	var src := DEMO_DIR.path_join(fname)
	var dst := APP_CLIPS.path_join(fname)
	if FileAccess.file_exists(dst):
		return 0
	if not FileAccess.file_exists(src):
		return -1
	var bytes := FileAccess.get_file_as_bytes(src)
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if bytes.is_empty() or f == null:
		return -1
	f.store_buffer(bytes)
	f.close()
	return 1


## An absolute path to a real file holding demo clip `fname`: the app-storage
## copy when it is still there, else one staged under demo_stage_dir() (made on
## demand). "" when the clip is not in this build.
func _demo_file(fname: String) -> String:
	var app := APP_CLIPS.path_join(fname)
	if FileAccess.file_exists(app):
		return ProjectSettings.globalize_path(app)
	var staged := demo_stage_dir().path_join(fname)
	var src := DEMO_DIR.path_join(fname)
	# A staged copy survives an app update, so a clip that changed in the
	# package has to be staged again (the splash clip was re-cut 2026-10-08
	# and the phone kept playing the old one). A re-render changes the size.
	if FileAccess.file_exists(staged) and not _same_size(staged, src):
		DirAccess.remove_absolute(staged)
	if not FileAccess.file_exists(staged):
		if not FileAccess.file_exists(src):
			return ""
		DirAccess.make_dir_recursive_absolute(demo_stage_dir())
		var bytes := FileAccess.get_file_as_bytes(src)
		var f := FileAccess.open(staged, FileAccess.WRITE)
		if bytes.is_empty() or f == null:
			return ""
		f.store_buffer(bytes)
		f.close()
	return ProjectSettings.globalize_path(staged)


## True when the two files are the same length; with no source to compare
## against (not in this build) the staged copy is kept.
static func _same_size(staged: String, src: String) -> bool:
	var fb := FileAccess.open(src, FileAccess.READ)
	if fb == null:
		return true
	var fa := FileAccess.open(staged, FileAccess.READ)
	return fa != null and fa.get_length() == fb.get_length()


## LOAD DEMO CLIPS: the bundled clips into the library (user://clips).
## Idempotent: a NAME already there is skipped, so pressing it twice never
## makes a duplicate. Reports by demo_clips_done(copied, skipped). Not in
## legacy folder mode — the library there is the linked folder (pipeline
## refuses first).
func load_demo_clips() -> void:
	var copied := 0
	var skipped := 0
	for fname in DEMO_CLIPS:
		match _copy_demo_to_app_storage(fname):
			1: copied += 1
			0: skipped += 1
	# Deferred so the caller's status line lands before the result, like the
	# plugin's signal does.
	call_deferred("emit_signal", "demo_clips_done", copied, skipped)


## True when app storage holds clips (the demo clips, or imports).
func app_storage_has_clips() -> bool:
	return not scan(APP_CLIPS).is_empty()


## True where the SAF plugin exists (the Android builds).
func available() -> bool:
	return _plugin != null


func has_folder() -> bool:
	return _tree_uri != ""


## First run on Android: no linked folder, and the first-run offer ("PLAY
## YOUR OWN CLIPS?") has not been answered yet.
func needs_setup() -> bool:
	return available() and not has_folder() and not _setup_done


func folder_uri() -> String:
	return _tree_uri


func folder_label() -> String:
	return _label if has_folder() else "PVJ"


## The directory ClipEngine scans: the picked tree (virtual) or app storage.
func clips_dir() -> String:
	if has_folder():
		return SCHEME + (_label if _label != "" else "clips")
	return APP_CLIPS


## True while a beta1/beta2 linked folder is the library (play and curate
## only; imports go to user://clips, which this mode does not scan).
func is_legacy() -> bool:
	return has_folder()


## True while clips that sequences, masks and the play order name are KNOWN to
## be absent — an old clips folder that could not be reached and has not been
## re-imported yet (§E). Curation is then kept, never trimmed: slot LOAD asks
## before dropping ids, and the savers keep keys they cannot resolve.
func clips_missing() -> bool:
	return _clips_missing


func set_clips_missing(on: bool) -> void:
	if _clips_missing != on:
		_clips_missing = on
		_save()


## The first-run offer was answered (an import, or NOT NOW).
func finish_setup() -> void:
	if not _setup_done:
		_setup_done = true
		_save()


func is_virtual(path: String) -> bool:
	return path.begins_with(SCHEME)


## The tree's videos as the plugin reports them: [{name, document_uri, size, mtime}].
func list_media(tree_uri: String) -> Array:
	if _plugin == null or tree_uri == "":
		return []
	var parsed: Variant = JSON.parse_string(str(_plugin.listMedia(tree_uri)))
	return parsed if parsed is Array else []


## Every video in `dir` and its direct sub-folders, sorted by relative path,
## as full (possibly virtual) paths. Records the sub-folders (`folders()`) and,
## for a tree, the change stamp a resume compares against.
func scan(dir: String) -> Array[String]:
	var rels: Array[String] = []
	var folders := {}
	_index.clear()
	if is_virtual(dir):
		_docs.clear()
		for e: Dictionary in list_media(_tree_uri):
			var n := str(e.get("name", ""))
			if n == "" or not n.get_extension().to_lower() in VIDEO_EXTS:
				continue
			var folder := str(e.get("folder", ""))
			var r := folder.path_join(n) if folder != "" else n
			_docs[r] = e
			rels.append(r)
			if folder != "":
				folders[folder] = true
		_stamp = folder_stamp()
		_prefetch(rels)
	else:
		var d := DirAccess.open(dir)
		if d == null:
			push_warning("[storage] could not open %s (err %s)" % [dir, DirAccess.get_open_error()])
			return []
		for n in _list_videos(d, dir):
			rels.append(n)
		for sub in _list_subdirs(d):
			var sd := DirAccess.open(dir.path_join(sub))
			if sd == null:
				continue
			for n in _list_videos(sd, dir.path_join(sub)):
				rels.append(sub.path_join(n))
			folders[sub] = true
	rels.sort()
	_folders.assign(folders.keys())
	_folders.sort()
	var out: Array[String] = []
	for r in rels:
		_index[r] = true
		out.append(dir.path_join(r))
	return out


func _list_videos(d: DirAccess, _dir: String) -> Array[String]:
	var names: Array[String] = []
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if not d.current_is_dir() and entry.get_extension().to_lower() in VIDEO_EXTS:
			names.append(entry)
		entry = d.get_next()
	d.list_dir_end()
	return names


func _list_subdirs(d: DirAccess) -> Array[String]:
	var names: Array[String] = []
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if d.current_is_dir() and not entry.begins_with("."):
			names.append(entry)
		entry = d.get_next()
	d.list_dir_end()
	return names


## The sub-folders the last scan found (names, sorted) — the folder chips.
func folders() -> Array[String]:
	return _folders


## `path` relative to the clips dir: "name.mp4" at the top, "sub/name.mp4" in
## a sub-folder. The key playlists, masks and thumbnails use.
func rel(path: String) -> String:
	var dir := clips_dir()
	if path.begins_with(dir + "/"):
		return path.substr(dir.length() + 1)
	return path.get_file()


## The sub-folder a clip is in ("" at the top level).
func folder_of(path: String) -> String:
	var r := rel(path)
	return r.get_base_dir() if r.contains("/") else ""


## A saved key back to a full path: a relative path as `rel()` writes it, or
## a bare name from an older save that may now live in a sub-folder (the
## first match, sorted). "" when nothing in the last scan has it.
func resolve(dir: String, key: String) -> String:
	if _index.has(key):
		return dir.path_join(key)
	if not key.contains("/"):
		for r: String in _index.keys():
			if r.get_file() == key:
				return dir.path_join(r)
	return ""


## The playlist savers' merge (§E): `names` plus the keys of `old` that
## resolve to no clip in the last scan (and are not in `drop`, the clips that
## left on purpose), so a missing clip never erases the curated order.
##
## Only while such a clip is EXPECTED back — an old folder not re-imported yet
## (clips_missing) or a linked folder that may list short (legacy). Otherwise a
## key that resolves to nothing belongs to a clip that is gone for good, and
## keeping it made the lists, and the work on them at every save and launch,
## grow with every clip that ever left the library.
func keep_unresolved(dir: String, names: PackedStringArray, old: PackedStringArray,
		drop: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	if not (_clips_missing or is_legacy()):
		return names
	var out := names.duplicate()
	var have := {}
	for k: String in out:
		have[k] = true
	for k: String in old:
		if not drop.has(k) and not have.has(k) and resolve(dir, k) == "":
			out.append(k)
			have[k] = true
	return out


## The tree's change stamp now ("" without a tree).
func folder_stamp() -> String:
	if _plugin == null or _tree_uri == "":
		return ""
	return str(_plugin.folderStamp(_tree_uri))


## True when the tree has changed since the last scan (a resume check: one
## cheap query, no listing). False without a tree or without a scan.
func folder_changed_since_scan() -> bool:
	if _stamp == "":
		return false
	var now := folder_stamp()
	return now != "" and now != _stamp


## Copy the folder into the cache ahead of play, in name order, up to the cap.
## A newer scan supersedes an older prefetch (the plugin counts generations).
func _prefetch(names: Array[String]) -> void:
	if _plugin == null or names.is_empty():
		return
	var sorted := names.duplicate()
	sorted.sort()
	var uris: Array[String] = []
	for n: String in sorted:
		uris.append(str(_docs[n]["document_uri"]))
	# (Keys are relative paths; a sub-folder's clips sort after the top level.)
	_plugin.prefetch(JSON.stringify(uris), CACHE_CAP_MB)


func document_uri(path: String) -> String:
	if not is_virtual(path):
		return ""
	var e: Variant = _docs.get(rel(path))
	return str(e["document_uri"]) if e is Dictionary else ""


func exists(path: String) -> bool:
	if is_virtual(path):
		return _docs.has(rel(path))
	return FileAccess.file_exists(path)


## A path GoZen/FFmpeg can open. Real files: globalized as before. Tree
## documents: /proc/self/fd/N, or a cached copy when the provider will not
## allow the re-open (the copy is synchronous — logged, because it stalls).
func playable(path: String) -> String:
	if not is_virtual(path):
		return ProjectSettings.globalize_path(path)
	var uri := document_uri(path)
	if uri == "" or _plugin == null:
		push_warning("[storage] %s is not in the folder any more" % path.get_file())
		return ""
	var p := str(_plugin.cachedPath(uri))
	if p != "":
		return p
	if not _fd_refused:
		p = str(_plugin.playablePath(uri))
		if p != "":
			return p
		_fd_refused = true
	var t0 := Time.get_ticks_msec()
	p = str(_plugin.copyToCache(uri, CACHE_CAP_MB))
	print("[storage] %s: fd refused, cached copy in %d ms" % [path.get_file(), Time.get_ticks_msec() - t0])
	return p


## Deletes a clip file (tree documents need the folder's write grant).
func delete(path: String) -> bool:
	if is_virtual(path):
		var uri := document_uri(path)
		if uri == "" or _plugin == null or not bool(_plugin.deleteDocument(uri)):
			return false
		_docs.erase(rel(path))
		_index.erase(rel(path))
		return true
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK


# --- Import jobs (layout 2) ---------------------------------------------------
# Every import is pick → plan (import_planned) → run_import → import_progress …
# → import_finished, on the plugin's worker. Off Android there is no plugin:
# each returns false and the caller says so.

## IMPORT CLIPS: videos from any provider (Drive, Downloads, USB…) → the top level.
func import_files() -> bool:
	if _plugin == null:
		return false
	_plugin.pickImportFiles()
	return true


## IMPORT FOLDER: a folder → one chip named after it (keep_layout = false), or
## mirrored top → top, sub-folder → chip (keep_layout = true: the re-import of
## an old clips folder, where the clip ids must come out the same).
func import_folder(keep_layout: bool = false) -> bool:
	if _plugin == null:
		return false
	_plugin.pickImportFolder(keep_layout)
	return true


## IMPORT PACK: a .zip → its clips in a chip named after the pack.
func import_pack() -> bool:
	if _plugin == null:
		return false
	_plugin.pickImportPack()
	return true


## Run a plan import_planned delivered. fit_only: only what fits (IMPORT WHAT FITS).
func run_import(job: int, fit_only: bool = false) -> bool:
	return _plugin != null and bool(_plugin.runImport(job, fit_only))


## Drop a plan the performer declined.
func discard_import(job: int) -> void:
	if _plugin != null:
		_plugin.discardImport(job)


## Stop the running import after the current chunk (import_finished follows,
## "cancelled": true; finished files are kept).
func cancel_import() -> void:
	if _plugin != null:
		_plugin.cancelImport()


func import_busy() -> bool:
	return _plugin != null and bool(_plugin.importBusy())


## Free space where the library lives, in MB (-1 unknown / no plugin).
func free_mb() -> int:
	if _plugin == null:
		return -1
	var b := int(_plugin.freeBytes())
	return b >> 20 if b >= 0 else -1


## LIB ▸ Storage…: sizes of the library (top level + each folder), the free
## space and the cache, measured off the main thread on Android → storage_report_ready.
## Off Android it is measured here (small libraries, desktop runs).
func request_report() -> void:
	if _plugin != null:
		_plugin.storageReport()
		return
	var r := {"top_n": 0, "top_bytes": 0, "folders": [], "free": -1}
	var d := DirAccess.open(APP_CLIPS)
	if d != null:
		for f in _list_videos(d, APP_CLIPS):
			r.top_n += 1
			r.top_bytes += _file_size(APP_CLIPS.path_join(f))
		for sub in _list_subdirs(d):
			var sd := DirAccess.open(APP_CLIPS.path_join(sub))
			var n := 0
			var b := 0
			if sd != null:
				for f in _list_videos(sd, ""):
					n += 1
					b += _file_size(APP_CLIPS.path_join(sub).path_join(f))
			(r.folders as Array).append({"name": sub, "n": n, "bytes": b})
	var t := _dir_bytes(thumb_dir())
	var s := _dir_bytes(demo_stage_dir())
	r.merge({"cache_thumbs": t, "cache_demo": s, "cache_clips": 0, "cache_total": t + s,
		"files_total": _tree_bytes("user://")})
	call_deferred("emit_signal", "storage_report_ready", r)


static func _dir_bytes(dir: String) -> int:
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	var n := 0
	for f in d.get_files():
		n += _file_size(dir.path_join(f))
	return n


## Everything under `dir`, sub-folders included.
static func _tree_bytes(dir: String) -> int:
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	d.include_hidden = true
	var n := _dir_bytes(dir)
	for s in d.get_directories():
		n += _tree_bytes(dir.path_join(s))
	return n


## CLEAR TEMPORARY FILES: thumbnails and staged demo copies (both made again on
## demand), temp files, and everything self_clean() removes. Never a clip, a
## sequence, a mask image in use or a setting. The play copies of a LEGACY
## folder stay: without them every cue would copy its clip on the main thread.
func clear_temporary() -> int:
	var n: int = self_clean().n
	for dir: String in [thumb_dir(), demo_stage_dir()]:
		var d := DirAccess.open(dir)
		if d == null:
			continue
		d.include_hidden = true
		for f in d.get_files():
			if d.remove(f) == OK:
				n += 1
	var c := DirAccess.open(cache_dir())
	if c != null:
		for f in c.get_files():
			if f.get_extension() == "tmp" and c.remove(f) == OK:
				n += 1
	if not is_legacy():
		_drop_clip_cache()
	print("[storage] temporary files cleared: %d files" % n)
	return n


# --- Self-clean (beta4: docs/STORAGE_GROWTH_AUDIT.md) -----------------------------
# What the app writes and nothing ever removed. Run at every start (cheap: a few
# directory listings) and by CLEAR TEMPORARY FILES. Each part only deletes files
# that are provably not in use; clips, sequences, settings and setups are never
# looked at.

## The shader cache Godot's GL renderer keeps in user://shader_cache — one folder
## per shader SOURCE, so every update that changes a shader leaves the old ones
## behind. Capped by size (a few hundred KB per version: a bound, not a routine
## cleanup). Over the cap the whole cache goes and Godot compiles each shader
## once more on first use: no ordering, because FileAccess.get_modified_time did
## not order files correctly on the Pixel 9a (2026-11-02).
const SHADER_CACHE := "user://shader_cache"
const SHADER_CACHE_CAP_MB := 16
## FrameSampler's run logs (pro, armed by hand): the newest few are kept, by the
## unix time in the name (s4_<run>_<unix>.csv; frame_sampler.gd).
const S4_LOGS_KEPT := 5
## Pre-layout-2 local-browser thumbnails (and the pro Drive browser's).
const OLD_THUMB_CACHE := "user://thumb_cache"


## Removes what the app wrote and no longer needs: staged demo copies of clips
## this build does not have, temp files, interrupted cache copies, mask images
## no saved mask names, surplus S4 logs, the old thumbnail folder (public builds)
## and shader cache past its cap. → {n, bytes}.
func self_clean() -> Dictionary:
	var out := {"n": 0, "bytes": 0}
	_mask_refs = ""   # re-read: a mask picked since the last pass is saved by now
	var keep_demo := {"pvj-splash-720.mp4": true}
	for f: String in DEMO_CLIPS:
		keep_demo[f] = true
	_remove_where(demo_stage_dir(), func(f: String) -> bool: return not keep_demo.has(f), out)
	_remove_where(cache_dir(), func(f: String) -> bool: return f.get_extension() == "tmp", out)
	var clipcache := cache_dir().path_join("clipcache")
	if is_legacy():
		_remove_where(clipcache, func(f: String) -> bool: return f.get_extension() == "part", out)
	elif DirAccess.dir_exists_absolute(clipcache):
		out.bytes += _dir_bytes(clipcache)
		_drop_clip_cache()
	_remove_where(MASK_DIR, func(f: String) -> bool: return not _mask_in_use(f), out)
	_prune_s4_logs(out)
	var features := get_node_or_null("/root/Features")
	if features != null and not bool(features.get("DRIVE_OAUTH")) and DirAccess.dir_exists_absolute(OLD_THUMB_CACHE):
		out.bytes += _tree_bytes(OLD_THUMB_CACHE)
		out.n += 1
		_rmtree(OLD_THUMB_CACHE)
	_cap_shader_cache(out)
	if int(out.n) > 0:
		print("[storage] self-clean: %d files, %d KB" % [out.n, int(out.bytes) >> 10])
	return out


## Thumbnails of clips that are not in the library any more (deleted outside
## PVJ, a renamed folder, a restore). `ids` = ClipLibrary's ids. Never with an
## empty library: a scan that failed must not look like "every clip is gone".
func prune_thumbnails(ids: Dictionary) -> int:
	if ids.is_empty():
		return 0
	var out := {"n": 0, "bytes": 0}
	_remove_where(thumb_dir(), func(f: String) -> bool:
		return f.get_extension() == "webp" and not ids.has(f.get_basename()), out)
	if int(out.n) > 0:
		print("[storage] %d orphaned thumbnail%s removed (%d KB)" % [out.n, "" if out.n == 1 else "s", int(out.bytes) >> 10])
	return out.n


## Deletes the files in `dir` (not sub-folders) that `pred(name)` picks; counts into `out`.
static func _remove_where(dir: String, pred: Callable, out: Dictionary) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		if pred.call(f):
			var size := _file_size(dir.path_join(f))
			if d.remove(f) == OK:
				out.n += 1
				out.bytes += maxi(0, size)


## A mask image is in use when a saved mask config names it: regions.cfg (its
## [raster_mask] path — the only place an image is referenced), the layout-2
## snapshot of it, and the mask sets (generous: they hold region sections
## today). Matched by file name in the text, so an absolute path from a restore
## still counts.
func _mask_in_use(file_name: String) -> bool:
	if _mask_refs == "":
		var text := FileAccess.get_file_as_string("user://regions.cfg") \
			+ FileAccess.get_file_as_string(SNAPSHOT_DIR.path_join("regions.cfg"))
		var d := DirAccess.open("user://mask_sets")
		if d != null:
			for f in d.get_files():
				text += FileAccess.get_file_as_string("user://mask_sets".path_join(f))
		_mask_refs = text + "\n"   # never "" again this pass, even with no masks saved
	return _mask_refs.contains(file_name)

var _mask_refs: String = ""


func _prune_s4_logs(out: Dictionary) -> void:
	var d := DirAccess.open("user://")
	if d == null:
		return
	var logs: Array[String] = []
	for f in d.get_files():
		if f.begins_with("s4_") and f.get_extension() == "csv":
			logs.append(f)
	if logs.size() <= S4_LOGS_KEPT:
		return
	logs.sort_custom(func(a: String, b: String) -> bool:
		return a.get_basename().get_slice("_", a.get_basename().get_slice_count("_") - 1).to_int() \
			> b.get_basename().get_slice("_", b.get_basename().get_slice_count("_") - 1).to_int())
	for f: String in logs.slice(S4_LOGS_KEPT):
		var size := _file_size("user://" + f)
		if d.remove(f) == OK:
			out.n += 1
			out.bytes += size


## user://shader_cache over SHADER_CACHE_CAP_MB: all of it.
func _cap_shader_cache(out: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(SHADER_CACHE):
		return
	var total := _tree_bytes(SHADER_CACHE)
	if total <= SHADER_CACHE_CAP_MB << 20:
		return
	_rmtree(SHADER_CACHE)
	out.n += 1
	out.bytes += total
	print("[storage] shader cache over %d MB (%d KB): cleared, shaders recompile on first use"
		% [SHADER_CACHE_CAP_MB, total >> 10])


## Deletes a whole library folder (a chip): its clips and anything else in it.
## Only under user://clips, one level, never the library itself.
func delete_folder(folder: String) -> bool:
	if folder == "" or folder.contains("/") or folder.begins_with(".") or is_legacy():
		return false
	var dir := APP_CLIPS.path_join(folder)
	var d := DirAccess.open(dir)
	if d == null:
		return false
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	return DirAccess.remove_absolute(dir) == OK


static func _dict(json: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(json)
	return parsed if parsed is Dictionary else {}


## The idle ident loop as a real file GoZen can open ("" off Android builds
## without it): the ident demo clip, staged like LOAD DEMO CLIPS stages it.
func idle_clip_path() -> String:
	return _demo_file("pvj-ident-720.mp4")


## The launch splash clip: 3 s of the organic ident at 720p (COLLECTIVE
## unconscious eroding into PVJ; tools/ident/make_splash_organic.py), packed
## from demo_clips/ like the others but deliberately NOT in DEMO_CLIPS — it is
## never copied into a clips folder or listed as a clip.
## "" when the build has no clip (the splash then holds the still).
func splash_clip_path() -> String:
	return _demo_file("pvj-splash-720.mp4")


## "versionName (versionCode)" from the package on Android; the project's
## version elsewhere.
func app_version() -> String:
	if _plugin != null:
		var v := str(_plugin.appVersion())
		if v != "":
			return v
	return str(ProjectSettings.get_setting("application/config/version", "dev"))


## Pick one image into app storage (mask images). Result: image_picked(path).
func pick_image() -> bool:
	if _plugin == null:
		return false
	DirAccess.make_dir_recursive_absolute(MASK_DIR)
	_plugin.pickImage(ProjectSettings.globalize_path(MASK_DIR.path_join("mask_%d.png" % Time.get_unix_time_from_system())))
	return true


## A finished recording's parts to the media scanner (Photos shows them at once).
func scan_media(dir: String) -> void:
	if _plugin != null and dir != "":
		_plugin.scanMedia(dir)


## Where set recordings are written — see StoragePlugin.recordingsDir().
func recordings_dir(fallback: String) -> String:
	if _plugin == null:
		return fallback
	var d := str(_plugin.recordingsDir())
	return d if d != "" else fallback


func _save() -> void:
	# The tree uri itself is persisted twice on purpose: the plugin keeps it
	# next to the grant it belongs to, and this file records it with the rest
	# of the app's settings (and whether the first-run prompt was answered).
	var cfg := ConfigFile.new()
	cfg.set_value("storage", "setup_done", _setup_done)
	cfg.set_value("storage", "demo_installed", _demo_installed)
	cfg.set_value("storage", "folder_uri", _tree_uri)
	cfg.set_value("storage", "folder_label", _label)
	cfg.set_value("storage", "clips_missing", _clips_missing)
	cfg.set_value("storage", "layout", _layout)
	cfg.set_value("storage", "switch_pending", _switch_pending)
	cfg.set_value("storage", "copy_offered", _copy_offered)
	cfg.set_value("storage", "old_folder_label", _old_label)
	cfg.set_value("storage", "old_folder_notice", _old_notice)
	cfg.save(CFG_PATH)
