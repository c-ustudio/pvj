extends SceneTree
## Headless checks for the storage rework (docs/STORAGE_REWORK_PLAN.md):
## layout 2 — the library is user://clips, imports copy into it — and the
## migration of a beta tester's linked folder into it.
##
##   godot --headless --path <project> --script tools/verify_storage_migration.gd
##
## Checks:
##   1. A launch removes unfinished import copies (".name.part", two levels)
##      and leaves real clips alone.
##   2. The old files-dir thumbs / demo_stage folders move into the cache dir
##      by rename, once; an existing target is never overwritten.
##   3. An import's rescan keeps the deck: clips that sort BEFORE the playing
##      and the cued clip do not move either of them (scan_keeping_deck).
##   4. Missing clips never erase curation: a mask loaded with clips that are
##      not in the library writes its stored keys back untouched, keeps them
##      at the end of an edited list; the playlist merge keeps unresolved keys
##      and drops the one REMOVE named.
##   5. The layout decision at launch (a fake plugin): no folder → own library;
##      a granted folder that lists → legacy; a granted folder that errors, or
##      a recorded folder whose grant is gone → own library with the curation
##      kept (clips_missing) and the grant released; a finished copy → own
##      library at the next start, grant released, play-copy cache dropped.
##   6. The copy prep: an app-storage clip named like a folder clip but a
##      different file moves to OLDER IMPORTS/, the same file stays, a demo
##      clip the folder lacks is deleted (and comes back with LOAD DEMO CLIPS).
##   7. Storage panel: the report counts a folder's clips and bytes; folder
##      REMOVE deletes only that folder and refuses "", nested and hidden names.
##   8. A staged setup restore moves into place at launch (replacing what is
##      there) and marks the clips missing on a demo-only library; an
##      unfinished stage (no .complete) is thrown away, never applied.
##
## Works under user:// with names prefixed _vsm_; removed again at the end.
## The Storage node is driven directly: under --script the `Storage`
## identifier does not resolve (the FeaturesS trap, core/features.gd).

const CLIPS := "user://clips"
const SUB := "_vsm_sub"

var _fails: int = 0
var _checks: int = 0
var _st: Node     ## the Storage autoload


func _initialize() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
	print("%s  %s%s" % ["ok  " if cond else "FAIL", what, ("  — " + detail) if detail != "" else ""])


func _write(path: String, text: String = "x") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Removes a directory tree under user:// (test data only).
func _rmrf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		DirAccess.remove_absolute(path)
		return
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_rmrf(path.path_join(sub))
	DirAccess.remove_absolute(path)


func _cleanup() -> void:
	_rmrf(CLIPS.path_join(SUB))
	_rmrf(CLIPS.path_join("_vsm_panel"))
	for f in ["_vsm_a.mp4", "._vsm_a.mp4.part", "._vsm_top.mp4.part"]:
		DirAccess.remove_absolute(CLIPS.path_join(f))
	_rmrf("user://_vsm_deck")
	_rmrf("user://_vsm_lib")
	_rmrf("user://_vsm_old")
	_rmrf("user://_vsm_cache")


func _run() -> void:
	_st = root.get_node_or_null("Storage")
	if _st == null:
		_st = load("res://core/storage.gd").new()
		_st.name = "Storage"
		root.add_child(_st)
	_cleanup()

	_check_part_cleanup()
	_check_cache_move()
	await _check_keep_deck()
	await _check_curation_kept()
	_check_layout_decision()
	_check_copy_prep()
	await _check_storage_panel()
	_check_restore_stage()

	_cleanup()
	print("%d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)


# 1 ─────────────────────────────────────────────────────────────────────────
func _check_part_cleanup() -> void:
	_write(CLIPS.path_join("_vsm_a.mp4"))
	_write(CLIPS.path_join("._vsm_top.mp4.part"))
	_write(CLIPS.path_join(SUB).path_join("._vsm_b.mp4.part"))
	_write(CLIPS.path_join(SUB).path_join("_vsm_b.mp4"))
	_st._clean_parts()
	_ok(not FileAccess.file_exists(CLIPS.path_join("._vsm_top.mp4.part")), "a top-level .part is removed at launch")
	_ok(not FileAccess.file_exists(CLIPS.path_join(SUB).path_join("._vsm_b.mp4.part")), "a folder's .part is removed at launch")
	_ok(FileAccess.file_exists(CLIPS.path_join("_vsm_a.mp4")) and FileAccess.file_exists(CLIPS.path_join(SUB).path_join("_vsm_b.mp4")),
		"real clips next to them are kept")


# 2 ─────────────────────────────────────────────────────────────────────────
func _check_cache_move() -> void:
	_write("user://_vsm_old/abc.webp", "thumb")
	_st._move_to_cache("user://_vsm_old", "user://_vsm_cache/thumbs")
	_ok(FileAccess.file_exists("user://_vsm_cache/thumbs/abc.webp"), "an old thumbs folder moves into the cache dir")
	_ok(not DirAccess.dir_exists_absolute("user://_vsm_old"), "… by rename (the old folder is gone)")
	_write("user://_vsm_old/def.webp", "other")
	_st._move_to_cache("user://_vsm_old", "user://_vsm_cache/thumbs")
	_ok(FileAccess.file_exists("user://_vsm_old/def.webp") and not FileAccess.file_exists("user://_vsm_cache/thumbs/def.webp"),
		"an existing target is never overwritten (the old folder stays put)")
	_ok(str(_st.thumb_dir()).begins_with(str(_st.cache_dir())) and str(_st.demo_stage_dir()).begins_with(str(_st.cache_dir())),
		"thumbs and demo_stage live under the cache dir", "%s, %s" % [_st.thumb_dir(), _st.demo_stage_dir()])


# 3 ─────────────────────────────────────────────────────────────────────────
func _check_keep_deck() -> void:
	var dir := "user://_vsm_deck"
	for n in ["m.mp4", "p.mp4", "z.mp4"]:
		_write(dir.path_join(n))
	# Never added to the tree: no decoders, just the list (as verify_library_rescan).
	var engine: Node = load("res://scripts/clip_engine.gd").new()
	engine.clips_dir = dir
	engine.scan()
	engine.current_index = engine.clips.find(dir.path_join("p.mp4"))
	engine._cued_index = engine.clips.find(dir.path_join("z.mp4"))
	engine._cue_ready = true
	_write(dir.path_join("a.mp4"))          # an import that sorts first
	_write(dir.path_join("b.mp4"))
	engine.scan_keeping_deck()
	_ok(engine.clips.size() == 5, "the rescan sees the two new clips", str(engine.clips.size()))
	_ok(engine.clips[engine.current_index] == dir.path_join("p.mp4"), "the playing clip is still the playing clip",
		engine.clips[engine.current_index])
	_ok(engine.cued_index() >= 0 and engine.clips[engine.cued_index()] == dir.path_join("z.mp4") and engine.is_cue_ready(),
		"the cued clip is still cued, and still warm")
	var plain: Node = load("res://scripts/clip_engine.gd").new()
	plain.clips_dir = dir
	DirAccess.remove_absolute(dir.path_join("a.mp4"))
	DirAccess.remove_absolute(dir.path_join("b.mp4"))
	plain.scan()
	plain.current_index = plain.clips.find(dir.path_join("p.mp4"))
	_write(dir.path_join("a.mp4"))
	plain.scan()
	_ok(plain.clips[plain.current_index] != dir.path_join("p.mp4"), "(control) a bare scan() moves the index onto another clip")
	engine.free()
	plain.free()
	await process_frame


# 4 ─────────────────────────────────────────────────────────────────────────
func _check_curation_kept() -> void:
	var lib := "user://_vsm_lib"
	_write(lib.path_join("a.mp4"))
	_write(lib.path_join("b.mp4"))
	_st.scan(lib)                                   # resolve() reads the last scan
	# Playlist merge (Storage.keep_unresolved).
	var merged: PackedStringArray = _st.keep_unresolved(lib, PackedStringArray(["b.mp4", "a.mp4"]),
		PackedStringArray(["gone.mp4", "a.mp4", "b.mp4", "removed.mp4"]), PackedStringArray(["removed.mp4"]))
	_ok(merged == PackedStringArray(["b.mp4", "a.mp4", "gone.mp4"]),
		"the playlist keeps a missing clip's key and drops the REMOVEd one", str(merged))

	# Masks: the real RegionCompositor + RegionEditor, regions.cfg put back after.
	var save_path: String = RegionEditor.SAVE_PATH
	var had := FileAccess.file_exists(save_path)
	var keep := FileAccess.get_file_as_bytes(save_path) if had else PackedByteArray()
	var cfg := ConfigFile.new()
	cfg.set_value("regions", "count", 2)
	var tri := PackedVector2Array([Vector2(0.1, 0.1), Vector2(0.3, 0.1), Vector2(0.2, 0.4)])
	cfg.set_value("region_0", "points", tri)
	cfg.set_value("region_0", "clip", "a.mp4")
	cfg.set_value("region_0", "clips", PackedStringArray(["a.mp4", "gone.mp4", "b.mp4"]))
	cfg.set_value("region_1", "points", tri)
	cfg.set_value("region_1", "clip", "gone2.mp4")
	cfg.save(save_path)
	var comp := RegionCompositor.new()
	comp.output_size = Vector2(1920, 1080)
	root.add_child(comp)
	comp.setup([{"name": "Off", "shader": null}])
	var ed := RegionEditor.new()
	root.add_child(ed)
	ed.setup(comp, PackedStringArray(["Off"]), lib)
	ed.output_size_provider = func() -> Vector2: return Vector2(1920, 1080)
	ed.load_saved()
	_ok(comp.get_clip_list(0).size() == 2 and comp.get_clip(1) == "",
		"(setup) the load resolves what is here: a 2-clip list, no clip on mask 2", str(comp.get_clip_list(0)))
	ed._save()
	var back := ConfigFile.new()
	back.load(save_path)
	_ok(back.get_value("region_0", "clips") == PackedStringArray(["a.mp4", "gone.mp4", "b.mp4"])
		and back.get_value("region_0", "clip") == "a.mp4",
		"an untouched mask is written back exactly as stored", str(back.get_value("region_0", "clips")))
	_ok(back.get_value("region_1", "clip") == "gone2.mp4", "a mask whose only clip is missing keeps it",
		str(back.get_value("region_1", "clip")))
	comp.remove_from_list(0, lib.path_join("b.mp4"))
	ed._save()
	back.load(save_path)
	_ok(back.get_value("region_0", "clips") == PackedStringArray(["a.mp4", "gone.mp4"]),
		"an edited list keeps the edit, and the missing key at its end", str(back.get_value("region_0", "clips")))
	ed.queue_free()
	comp.queue_free()
	if had:
		var f := FileAccess.open(save_path, FileAccess.WRITE)
		f.store_buffer(keep)
		f.close()
	else:
		DirAccess.remove_absolute(save_path)
	await process_frame


## A stand-in for the VJMIXStorage plugin: the calls _decide_layout makes.
const FAKE_PLUGIN := """extends RefCounted
var granted := ""
var listing := "[]"
var cleared := 0
var planned := ""
func getFolderUri() -> String: return granted
func getFolderLabel(_t: String) -> String: return "PVJ"
func listMedia(_t: String) -> String: return listing
func clearFolder() -> void:
	cleared += 1
	granted = ""
func planTreeCopy(t: String) -> void: planned = t
"""


func _fake() -> RefCounted:
	var g := GDScript.new()
	g.source_code = FAKE_PLUGIN
	g.reload()
	return g.new()


func _decide(fake: RefCounted, recorded: String, pending: bool = false, label: String = "PVJ") -> void:
	_st._plugin = fake
	_st._switch_pending = pending
	_st._clips_missing = false
	_st._old_notice = false
	_st._old_label = ""
	_st._layout = 0
	_st._decide_layout(recorded, label)


# 5 ─────────────────────────────────────────────────────────────────────────
func _check_layout_decision() -> void:
	var had := FileAccess.file_exists(_st.CFG_PATH)
	var keep := FileAccess.get_file_as_bytes(_st.CFG_PATH) if had else PackedByteArray()
	var saved := [_st._plugin, _st._tree_uri, _st._label, _st._layout, _st._clips_missing]

	var f := _fake()
	_decide(f, "")
	_ok(not _st.is_legacy() and _st._layout == 2 and _st.clips_dir() == CLIPS, "no folder → PVJ's own library")

	f = _fake()
	f.granted = "content://tree/PVJ"
	_decide(f, "content://tree/PVJ")
	_ok(_st.is_legacy() and _st._layout == 1 and _st.clips_dir() == "saf://PVJ" and f.cleared == 0,
		"a granted folder that lists → legacy folder mode, grant kept", _st.clips_dir())
	_st._copy_offered = false
	_ok(_st.copy_offer_due(), "… and the copy is offered once")
	_ok(_st.copy_into_pvj() and f.planned == "content://tree/PVJ", "COPY CLIPS INTO PVJ plans a mirror of that folder")

	f = _fake()
	f.granted = "content://tree/PVJ"
	f.listing = '{"error": "folder not listable"}'
	_decide(f, "content://tree/PVJ")
	_ok(not _st.is_legacy() and _st.clips_missing() and f.cleared == 1 and _st.old_folder_notice() == "PVJ"
		and _st.old_folder_label() == "PVJ",
		"a granted folder that errors → own library, curation kept, grant released, message due")

	f = _fake()
	_decide(f, "content://tree/OLD", false, "MyClips")
	_ok(not _st.is_legacy() and _st.clips_missing() and _st.old_folder_notice() == "MyClips",
		"a recorded folder whose grant is gone → the same, with the recorded name")
	_st.old_folder_restored()
	_ok(not _st.clips_missing() and _st.old_folder_notice() == "" and _st.old_folder_label() == "",
		"a completed re-import clears it")

	DirAccess.make_dir_recursive_absolute(_st.cache_dir().path_join("clipcache"))
	_write(_st.cache_dir().path_join("clipcache").path_join("0000_a.mp4"))
	f = _fake()
	f.granted = "content://tree/PVJ"
	_decide(f, "content://tree/PVJ", true)
	_ok(not _st.is_legacy() and _st._layout == 2 and f.cleared == 1 and not _st.switch_pending()
		and not DirAccess.dir_exists_absolute(_st.cache_dir().path_join("clipcache")),
		"a finished copy → own library at the next start, grant released, play copies dropped")

	_st._plugin = saved[0]
	_st._tree_uri = saved[1]
	_st._label = saved[2]
	_st._layout = saved[3]
	_st._clips_missing = saved[4]
	if had:
		var fa := FileAccess.open(_st.CFG_PATH, FileAccess.WRITE)
		fa.store_buffer(keep)
		fa.close()


# 6 ─────────────────────────────────────────────────────────────────────────
func _check_copy_prep() -> void:
	_write(CLIPS.path_join("_vsm_same.mp4"), "same bytes")
	_write(CLIPS.path_join("_vsm_diff.mp4"), "local version")
	var docs := {
		"_vsm_same.mp4": {"size": 10}, "_vsm_diff.mp4": {"size": 999}, "sub/_vsm_x.mp4": {"size": 5},
	}
	# Every demo clip already in user://clips counts as "in the folder" — except
	# one, which the prep must delete (and LOAD DEMO CLIPS restores below).
	var victim := ""
	for d: String in _st.DEMO_CLIPS:
		var p: String = CLIPS.path_join(d)
		if FileAccess.file_exists(p):
			if victim == "" and _st._same_size(p, _st.DEMO_DIR.path_join(d)):
				victim = d
			else:
				docs[d] = {"size": _st._file_size(p)}
	var saved_docs: Dictionary = _st._docs
	_st._docs = docs
	_st._prepare_copy()
	_st._docs = saved_docs
	_ok(FileAccess.file_exists(CLIPS.path_join("_vsm_same.mp4")), "the same file under the same name stays (the copy skips it)")
	_ok(not FileAccess.file_exists(CLIPS.path_join("_vsm_diff.mp4"))
		and FileAccess.file_exists(CLIPS.path_join(_st.OLDER_IMPORTS).path_join("_vsm_diff.mp4")),
		"another file under a folder clip's name moves to OLDER IMPORTS/")
	if victim != "":
		_ok(not FileAccess.file_exists(CLIPS.path_join(victim)), "a demo clip the folder lacks is deleted", victim)
		_st._copy_demo_to_app_storage(victim)
		_ok(FileAccess.file_exists(CLIPS.path_join(victim)), "… and LOAD DEMO CLIPS brings it back")
	DirAccess.remove_absolute(CLIPS.path_join("_vsm_same.mp4"))
	DirAccess.remove_absolute(CLIPS.path_join(_st.OLDER_IMPORTS).path_join("_vsm_diff.mp4"))
	DirAccess.remove_absolute(CLIPS.path_join(_st.OLDER_IMPORTS))


# 7 ─────────────────────────────────────────────────────────────────────────
func _check_storage_panel() -> void:
	var dir := CLIPS.path_join("_vsm_panel")
	_write(dir.path_join("_vsm_p1.mp4"), "12345")
	_write(dir.path_join("_vsm_p2.mp4"), "1234567")
	_write(dir.path_join("README.txt"), "not a clip")
	var got: Array = []
	var cb := func(r: Dictionary) -> void: got.append(r)
	_st.storage_report_ready.connect(cb)
	_st.request_report()
	await process_frame
	_st.storage_report_ready.disconnect(cb)
	var mine := {}
	if not got.is_empty():
		for f: Variant in got[0].get("folders", []):
			if str(f.get("name", "")) == "_vsm_panel":
				mine = f
	_ok(int(mine.get("n", -1)) == 2 and int(mine.get("bytes", -1)) == 12, "the report counts a folder's clips and bytes", str(mine))
	_ok(not _st.delete_folder("") and not _st.delete_folder("a/b") and not _st.delete_folder(".hidden"),
		"folder REMOVE refuses the library itself, nested and hidden names")
	_ok(_st.delete_folder("_vsm_panel") and not DirAccess.dir_exists_absolute(dir), "folder REMOVE deletes the folder, README and all")


# 8 ─────────────────────────────────────────────────────────────────────────
func _check_restore_stage() -> void:
	# Real desktop files under user:// are put back afterwards.
	var keep := {}
	for f in ["warp.cfg", "mask_sets/set_9.cfg", "storage.cfg"]:
		if FileAccess.file_exists("user://" + f):
			keep[f] = FileAccess.get_file_as_bytes("user://" + f)
	var st: String = _st.RESTORE_STAGE
	_write(st.path_join("warp.cfg"), "[slot_1]\nrestored=true\n")
	_write(st.path_join("mask_sets/set_9.cfg"), "[regions]\ncount=0\n")
	_st._apply_restore_stage()
	_ok(not FileAccess.file_exists("user://warp.cfg") or FileAccess.get_file_as_string("user://warp.cfg") != "[slot_1]\nrestored=true\n",
		"an unfinished stage (no .complete) is never applied")
	_ok(not DirAccess.dir_exists_absolute(st), "… and is thrown away")
	_write(st.path_join("warp.cfg"), "[slot_1]\nrestored=true\n")
	_write(st.path_join("mask_sets/set_9.cfg"), "[regions]\ncount=0\n")
	_write(st.path_join(".complete"), "2")
	var was_missing: bool = _st._clips_missing
	_st._apply_restore_stage()
	_ok(FileAccess.get_file_as_string("user://warp.cfg") == "[slot_1]\nrestored=true\n"
		and FileAccess.file_exists("user://mask_sets/set_9.cfg"), "a complete stage replaces the files, sub-folders included")
	_ok(not DirAccess.dir_exists_absolute(st), "… and the stage is gone")
	_ok(_st._clips_missing == (not _st._library_has_own_clips()), "clips are marked missing exactly when the library has none of its own")
	_st._clips_missing = was_missing
	for f in ["warp.cfg", "mask_sets/set_9.cfg", "storage.cfg"]:
		if keep.has(f):
			var fa := FileAccess.open("user://" + f, FileAccess.WRITE)
			fa.store_buffer(keep[f])
			fa.close()
		else:
			DirAccess.remove_absolute("user://" + f)
