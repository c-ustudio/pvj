extends Node
## ClipLibrary (autoload) — the clip/folder model the visual browser reads.
##
## Additive layer over ClipEngine (sequencer build, Step 1). ClipEngine keeps
## owning scan(), the flat `clips` list, ordering and `live_set` — the sequencer's
## cue targets, the playlist and the browsers are all wired into it. ClipLibrary
## REFLECTS that into the ClipData/Folder model the ClipGrid (step 3) needs —
## stable id, display name, thumb cache path — WITHOUT taking ownership. A later
## session can migrate ownership here if wanted.
##
## FOLDERS ARE FILTERED VIEWS, not directories: all clips live in one physical dir,
## and LIVE/PARKED is a per-clip flag (ClipEngine.live_set). The FolderTabBar
## (step 4) shows ALL / LIVE / PARKED as views over the one LOCAL folder — plus,
## since beta2 (§1.2), one "dir:<name>" view per SUB-FOLDER of the clips folder
## (Storage scans one level down): ALL still shows everything, a chip narrows it
## to that sub-folder. LIVE/PARKED are unchanged.
##
## ClipEngine is a scene node (not an autoload), so pipeline calls bind() to hand
## it over — autoloads init before the main scene, so we can't grab it ourselves.

signal library_ready
signal folder_updated(folder_id: String)

enum SourceType { LOCAL, DRIVE }



class ClipData:
	var id: String
	var source_type: int = SourceType.LOCAL
	var path: String                            ## full path (LOCAL) or drive file id (DRIVE)
	var display_name: String
	var duration: float = 0.0                   ## seconds; 0 = not yet probed (needs a decode)
	var resolution: Vector2i = Vector2i.ZERO    ## ZERO = not yet probed
	var thumb_cache_path: String
	var is_live: bool = true
	var folder: String = ""                     ## sub-folder of the clips dir ("" = top level)


class Folder:
	var id: String
	var name: String
	var clip_ids: Array[String] = []


var _engine: ClipEngine
var _clips: Dictionary = {}         ## id -> ClipData
var _order: Array[String] = []      ## clip ids in ClipEngine.clips order (the "all" view)
var _ready_emitted: bool = false
var _rebuild_pending: bool = false   ## a deferred rebuild is queued (coalesces scans)
var _thumbs_pruned: bool = false     ## orphaned thumbnails were removed this launch


## pipeline hands us the deck. Connect its scan signal and build now if it already
## has clips (bind may land after clips_ready on a rescan).
func bind(engine: ClipEngine) -> void:
	_engine = engine
	if not _engine.clips_ready.is_connected(_on_clips_ready):
		_engine.clips_ready.connect(_on_clips_ready)
	if not _engine.clips_scanned.is_connected(_on_clips_scanned):
		_engine.clips_scanned.connect(_on_clips_scanned)
	if not _engine.clips.is_empty():
		rebuild()


func _on_clips_ready(_count: int) -> void:
	rebuild()


## Any rescan. DEFERRED on purpose: every caller does scan() and THEN restores the
## saved order / live set (set_order, set_live) in the same frame, and `_order`
## mirrors ClipEngine.clips — rebuilding synchronously would capture the
## alphabetical list and the ALL view would jump out of the user's order until
## the next rebuild. One deferred rebuild also coalesces a scan + rescan_b pair.
func _on_clips_scanned(_count: int) -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	rebuild.call_deferred()


## (Re)build the ClipData model from ClipEngine.clips. Preserves already-probed
## ClipData across a rescan (keyed by stable id) and drops clips no longer on disk.
func rebuild() -> void:
	_rebuild_pending = false
	if _engine == null:
		return
	var thumbs := Storage.thumb_dir()   # the cache dir (layout 2); ClipData.thumb_cache_path points here
	DirAccess.make_dir_recursive_absolute(thumbs)
	var seen := {}
	_order.clear()
	for path: String in _engine.clips:
		var id := _id_for(path)
		_order.append(id)
		seen[id] = true
		var cd: ClipData
		if _clips.has(id):
			cd = _clips[id] as ClipData
		else:
			cd = ClipData.new()
			cd.id = id
			cd.source_type = SourceType.LOCAL
			cd.display_name = path.get_file()
			cd.thumb_cache_path = "%s/%s.webp" % [thumbs, id]
			_clips[id] = cd
		cd.path = path                          # path can move on a rescan
		cd.is_live = _engine.is_live(path)
		cd.folder = Storage.folder_of(path)
	for id: String in _clips.keys():
		if not seen.has(id):
			_clips.erase(id)
	# Once per launch, against the first real library: thumbnails of clips that
	# are gone (Storage.prune_thumbnails refuses an empty list).
	if not _thumbs_pruned and not seen.is_empty():
		_thumbs_pruned = true
		Storage.prune_thumbnails(seen)
	_ready_emitted = true
	print("[ClipLibrary] %d clips · all=%d live=%d parked=%d" % [
		_order.size(), _order.size(), get_folder("live").clip_ids.size(),
		get_folder("parked").clip_ids.size()])
	library_ready.emit()
	_emit_all_folders()


func is_ready() -> bool:
	return _ready_emitted


## The view ids the FolderTabBar (step 4) will offer: the three views, then
## one "dir:<name>" per sub-folder that holds clips (sorted).
func folder_ids() -> Array[String]:
	var ids: Array[String] = ["all", "live", "parked"]
	var dirs := {}
	for id: String in _order:
		var f := (_clips[id] as ClipData).folder
		if f != "":
			dirs[f] = true
	var names: Array[String] = []
	names.assign(dirs.keys())
	names.sort()
	for n in names:
		ids.append("dir:" + n)
	return ids


func get_folder(folder_id: String) -> Folder:
	var f := Folder.new()
	f.id = folder_id
	match folder_id:
		"live":
			f.name = "LIVE"
			for id: String in _order:
				if (_clips[id] as ClipData).is_live:
					f.clip_ids.append(id)
		"parked":
			f.name = "PARKED"
			for id: String in _order:
				if not (_clips[id] as ClipData).is_live:
					f.clip_ids.append(id)
		_:
			if folder_id.begins_with("dir:"):
				f.name = folder_id.substr(4)
				for id: String in _order:
					if (_clips[id] as ClipData).folder == f.name:
						f.clip_ids.append(id)
			else:
				f.name = "ALL"
				f.clip_ids = _order.duplicate()
	return f


func get_clip(id: String) -> ClipData:
	return _clips.get(id) as ClipData


func path_for(id: String) -> String:
	var cd := _clips.get(id) as ClipData
	return cd.path if cd != null else ""


func id_for_path(path: String) -> String:
	return _id_for(path)


## Re-read live/parked from ClipEngine (e.g. after the playlist parks a clip) and
## refresh the LIVE/PARKED views. ClipEngine.live_set stays the source of truth.
func refresh_live() -> void:
	if _engine == null:
		return
	for id: String in _order:
		var cd := _clips[id] as ClipData
		cd.is_live = _engine.is_live(cd.path)
	# ALL too, even though its MEMBERSHIP never changes: the grid dims parked cells, so
	# a park while the ALL view is open still changes what that view must draw. The
	# grid reloads only on its OWN folder id, so without this a park is invisible until
	# the user switches tabs — the exact "filter didn't update" symptom.
	folder_updated.emit("all")
	folder_updated.emit("live")
	folder_updated.emit("parked")


func _emit_all_folders() -> void:
	for fid: String in folder_ids():
		folder_updated.emit(fid)


# Stable id from the path RELATIVE to the clips dir — the bare name for a
# top-level clip (the key every existing thumb cache / playlist.cfg /
# regions.cfg was written with), "sub/name" for a sub-folder's, so two files
# of one name in two folders are two clips. Filesystem-safe for the thumb
# cache path. String.hash() is deterministic across runs/platforms.
func _id_for(path: String) -> String:
	return "%08x" % Storage.rel(path).hash()
