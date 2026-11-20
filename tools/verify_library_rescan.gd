extends SceneTree
## Headless check that the ClipLibrary follows EVERY ClipEngine.scan(), not just
## the launch one (beta2: the clip grid, the folder chips and the empty-grid
## state read the library, and RESCAN / IMPORT PACK / LOAD DEMO CLIPS / a new
## folder / resume all end in scan()).
##
##   godot --headless --path <project> --script tools/verify_library_rescan.gd
##
## Checks:
##   1. A rescan that finds new top-level + sub-folder clips rebuilds the library
##      (deferred: untouched inside the calling frame, grown by the next one), and
##      the sub-folder gets its "dir:" view.
##   2. Two scans in one frame rebuild once, and an order restored in that same
##      frame (set_order after scan, as every pipeline caller does) is what the
##      ALL view shows.
##   3. A scan of an empty folder leaves the library EMPTY — no stale clips from
##      the previous folder — and the sub-folder view goes.
##
## Uses user://clips (the desktop clips dir rel() is relative to) with files
## prefixed _verify_; they are removed again at the end.

const DIR := "user://clips"
const EMPTY_DIR := "user://_verify_empty"
const SUB := "_verify_sub"
const FILES := ["_verify_a.mp4", "_verify_b.mp4", SUB + "/_verify_c.mp4"]

var _fails: int = 0
var _checks: int = 0
var _ready_count: int = 0
var _lib: Node   ## the ClipLibrary autoload (the identifier does not resolve under --script)


func _initialize() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
	print("%s  %s%s" % ["ok  " if cond else "FAIL", what, ("  — " + detail) if detail != "" else ""])


func _make_files() -> void:
	DirAccess.make_dir_recursive_absolute(DIR.path_join(SUB))
	for f: String in FILES:
		var fa := FileAccess.open(DIR.path_join(f), FileAccess.WRITE)
		fa.store_string("not a video")
		fa.close()


func _cleanup() -> void:
	for f: String in FILES:
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(DIR.path_join(SUB))
	DirAccess.remove_absolute(EMPTY_DIR)


func _all_paths() -> Array:
	var out := []
	for id: String in _lib.get_folder("all").clip_ids:
		out.append(_lib.path_for(id))
	return out


func _run() -> void:
	for nm: String in ["Storage", "ClipLibrary"]:
		if root.get_node_or_null(nm) == null:
			var n: Node = load("res://%s.gd" % ("core/storage" if nm == "Storage" else "scripts/clip_library")).new()
			n.name = nm
			root.add_child(n)
	_lib = root.get_node("ClipLibrary")
	_cleanup()
	DirAccess.make_dir_recursive_absolute(DIR)
	# Never added to the tree: no _start(), no decoders — just the list + scan().
	# Loaded at run time: clip_engine.gd names the Storage autoload, which does
	# not resolve while this tool compiles (the FeaturesS trap, core/features.gd).
	var engine: Node = load("res://scripts/clip_engine.gd").new()
	engine.clips_dir = DIR
	_lib.bind(engine)
	_lib.library_ready.connect(func() -> void: _ready_count += 1)
	engine.scan()
	await process_frame
	var base: int = _lib.get_folder("all").clip_ids.size()
	_ok(base == engine.clips.size(), "the first scan is reflected", "%d vs %d" % [base, engine.clips.size()])

	# 1. new clips on disk → the next scan grows the ALL view and adds the chip.
	_make_files()
	_ready_count = 0
	engine.scan()
	_ok(_lib.get_folder("all").clip_ids.size() == base, "the rebuild is deferred (nothing changes inside the scanning frame)")
	await process_frame
	var n: int = _lib.get_folder("all").clip_ids.size()
	_ok(n == base + 3, "a rescan that found three clips grew the ALL view by three", "%d → %d" % [base, n])
	_ok(_lib.folder_ids().has("dir:" + SUB), "a sub-folder that appeared got its view", str(_lib.folder_ids()))
	_ok(_lib.get_folder("dir:" + SUB).clip_ids.size() == 1, "the sub-folder view holds exactly its clip")
	_ok(_ready_count == 1, "one rebuild per frame", "library_ready × %d" % _ready_count)

	# 2. scan + scan + set_order in one frame: one rebuild, in the restored order.
	_ready_count = 0
	engine.scan()
	engine.scan()
	var rev: Array[String] = engine.clips.duplicate()
	rev.reverse()
	engine.set_order(rev)
	await process_frame
	_ok(_ready_count == 1, "two scans in one frame rebuild once", "library_ready × %d" % _ready_count)
	_ok(_all_paths() == Array(rev), "the order restored in the scanning frame is what the ALL view shows")

	# 3. an empty folder: nothing stale survives, the chip goes.
	DirAccess.make_dir_recursive_absolute(EMPTY_DIR)
	engine.clips_dir = EMPTY_DIR
	engine.scan()
	await process_frame
	_ok(engine.clips.is_empty(), "the empty folder scanned as empty")
	_ok(_lib.get_folder("all").clip_ids.is_empty(), "the library is empty too — no stale clips from the old folder", str(_all_paths().size()))
	_ok(not _lib.folder_ids().has("dir:" + SUB), "the old sub-folder's view went", str(_lib.folder_ids()))

	_cleanup()
	print("%d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
