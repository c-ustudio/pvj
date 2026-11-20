## LocalBrowserUI.gd — on-device file browser overlay.
## Attach to scenes/LocalBrowser.tscn. Mirrors drive_browser_ui.gd's interaction
## (breadcrumb folder tree → tap a video to add it to the playlist), but over the
## phone's local storage (DCIM/, Movies/, Download/) instead of Google Drive.
##
## Because the files are already on the device there is no network download — a
## tapped clip is IMPORTED (a fast chunked copy, spread across frames so the UI
## never stalls) into the same clips folder the Drive/server paths use, so it
## flows straight into the existing GoZen scan → playlist → thumbnail pipeline.
##
## pipeline.gd owns the result: it sets dest_dir and connects clip_imported, then
## rescans + plays + refreshes the playlist (same handler the Drive path uses).

extends Control

@onready var refresh_btn: Button       = $VBox/Toolbar/RefreshBtn
@onready var close_btn: Button         = $VBox/Toolbar/CloseBtn
@onready var breadcrumb: HBoxContainer = $VBox/Breadcrumb
@onready var list: VBoxContainer       = $VBox/Scroll/List
@onready var status_label: Label       = $VBox/Bottom/StatusLabel

const VIDEO_EXTS: Array[String] = ["mp4", "mov", "mkv", "webm", "m4v", "avi"]
const ROW_HEIGHT: int = 56
const GREEN: Color = Color(0.0, 1.0, 0.255)   ## #00FF41 — the single accent
const RED: Color = Color(1.0, 0.267, 0.133)    ## #FF4422 — errors only
const COPY_CHUNK: int = 4 * 1024 * 1024   ## bytes copied per frame during import

## Emitted once a clip has been imported into dest_dir (full local path).
signal clip_imported(local_path: String)

## SELECT mode only: emitted with the tapped file's full path (no copy).
signal file_selected(path: String)

## Emitted by the per-row SHARE button (only built when `show_share`).
signal file_share_requested(path: String)

## Destination clips folder (set by pipeline.gd to clip_engine.clips_dir).
var dest_dir: String = ""

## SELECT mode (mask images etc.): tapping a file emits file_selected instead
## of importing it, and `exts` filters the listing. Set both before add_child.
var select_only: bool = false
var exts: PackedStringArray = PackedStringArray(VIDEO_EXTS)
## SELECT mode: label for an optional "none" row at the root, which emits
## file_selected("") — the caller's clear action. "" = no such row.
var clear_label: String = ""

## Open straight into this directory instead of the storage-shortcuts root.
## The recordings view points it at PocketVJ/recordings/, which makes the
## set_<timestamp>/ folders the top level — the existing folder→file navigation
## then gives the two-level set→part browse with no extra code.
var root_dir: String = ""
## Breadcrumb name for that root.
var root_label: String = "FILES"
## Add a SHARE button to every file row (emits file_share_requested).
var show_share: bool = false
## Annotate folder rows with how many matching files they hold and their total
## size — for recordings this is what tells one set apart from another.
var summarize_folders: bool = false

# Folder navigation stack: each entry { "path": String, "name": String }.
# The root entry has path "" — it shows the named storage shortcuts instead of a
# real directory listing.
var _stack: Array = []

# In-progress chunked copy state.
var _copy_active: bool = false
var _src: FileAccess = null
var _dst: FileAccess = null
var _copy_total: int = 0
var _copy_done: int = 0
var _copy_dest_path: String = ""
var _copy_btn: Button = null
var _copy_name: String = ""
# Inline error state (red dot + message + RETRY), inserted under the toolbar.
var _err: M8ErrorBar


func _ready() -> void:
	_err = M8ErrorBar.new()
	var vbox := $VBox as VBoxContainer
	vbox.add_child(_err)
	vbox.move_child(_err, 1)          # directly under the toolbar

	refresh_btn.pressed.connect(_load_current)
	close_btn.pressed.connect(hide)
	set_process(false)
	_open_root()


# ── Storage shortcuts (the root) ───────────────────────────────────────────────

# The named entry points shown at the top level. OS.get_system_dir maps these to
# the real shared-storage paths on Android; we fall back to the canonical
# /storage/emulated/0/* paths if the OS returns an empty string.
func _shortcuts() -> Array:
	var out: Array = []
	_add_shortcut(out, "DCIM", OS.get_system_dir(OS.SYSTEM_DIR_DCIM), "/storage/emulated/0/DCIM")
	_add_shortcut(out, "Movies", OS.get_system_dir(OS.SYSTEM_DIR_MOVIES), "/storage/emulated/0/Movies")
	_add_shortcut(out, "Downloads", OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS), "/storage/emulated/0/Download")
	_add_shortcut(out, "Pictures", OS.get_system_dir(OS.SYSTEM_DIR_PICTURES), "/storage/emulated/0/Pictures")
	if dest_dir != "":
		out.append({"name": "POCKETVJ CLIPS", "path": dest_dir})
	return out


func _add_shortcut(out: Array, label: String, primary: String, fallback: String) -> void:
	var p: String = primary if primary != "" else fallback
	if p != "" and DirAccess.dir_exists_absolute(p):
		out.append({"name": label, "path": p})


# ── Navigation ────────────────────────────────────────────────────────────────

func _open_root() -> void:
	# A configured root replaces the shortcuts list entirely — there is nothing
	# above it to navigate to, which is the point for a scoped view.
	if root_dir != "":
		_stack = [{"path": root_dir, "name": root_label}]
	else:
		_stack = [{"path": "", "name": "FILES"}]
	_load_current()


func _navigate_into(path: String, folder_name: String) -> void:
	_stack.append({"path": path, "name": folder_name})
	_load_current()


func _jump_to_crumb(index: int) -> void:
	if index < 0 or index >= _stack.size():
		return
	_stack.resize(index + 1)
	_load_current()


func _load_current() -> void:
	if _stack.is_empty():
		return
	_err.clear()
	_rebuild_breadcrumb()
	for child: Node in list.get_children():
		child.queue_free()

	var top: Dictionary = _stack[_stack.size() - 1]
	var path: String = str(top["path"])
	if path == "":
		_list_shortcuts()
	elif path == root_dir and not DirAccess.dir_exists_absolute(path):
		# The recordings folder does not exist until the first recording is
		# made. That is an empty state, not a failure worth a red error bar.
		status_label.text = "NO %s YET" % root_label
	else:
		_list_directory(path)


func _list_shortcuts() -> void:
	if select_only and clear_label != "":
		var btn := Button.new()
		btn.custom_minimum_size.y = ROW_HEIGHT
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.focus_mode = Control.FOCUS_NONE
		btn.text = "  [OFF]  %s" % clear_label
		btn.pressed.connect(func() -> void: file_selected.emit(""))
		list.add_child(btn)
	var shortcuts: Array = _shortcuts()
	for entry: Dictionary in shortcuts:
		list.add_child(_make_folder_row(str(entry["name"]), str(entry["path"])))
	status_label.text = "%d LOCATION(S)" % shortcuts.size()


func _list_directory(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		status_label.text = ""
		_err.show_error("CANNOT OPEN %s (ERR %d)" % [path, DirAccess.get_open_error()],
			_load_current)
		return

	var folders: Array[String] = []
	var videos: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			if dir.current_is_dir():
				folders.append(entry)
			elif entry.get_extension().to_lower() in exts:
				videos.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()

	folders.sort()
	videos.sort()
	for f: String in folders:
		list.add_child(_make_folder_row(f, path.path_join(f)))
	for v: String in videos:
		list.add_child(_make_video_row(v, path.path_join(v)))
	status_label.text = "%d FOLDER(S) · %d %s(S)" % [folders.size(), videos.size(), _noun()]


# What the listing is made of, derived from `exts` rather than from select_only —
# the mask picker is the only IMAGE consumer, and recordings are SELECT mode too.
func _noun() -> String:
	for e: String in exts:
		if not (e in VIDEO_EXTS):
			return "IMAGE"
	return "VIDEO"


## Let the owner write into the browser's own status line — an open/share result
## belongs where the user is looking, not only on the deck's status bar.
func set_status(text: String) -> void:
	status_label.text = text


# Files in `folder` matching `exts`, and their total bytes.
func _folder_summary(folder: String) -> Array:
	var dir := DirAccess.open(folder)
	if dir == null:
		return [0, 0]
	var n := 0
	var total := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with(".") and not dir.current_is_dir() \
				and entry.get_extension().to_lower() in exts:
			n += 1
			total += _file_size(folder.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	return [n, total]


func _rebuild_breadcrumb() -> void:
	for child: Node in breadcrumb.get_children():
		child.queue_free()
	for i: int in _stack.size():
		var crumb: Dictionary = _stack[i]
		var b := Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.text = str(crumb["name"]).to_upper() if i == 0 else "> %s" % str(crumb["name"]).to_upper()
		var idx: int = i
		b.pressed.connect(func() -> void: _jump_to_crumb(idx))
		breadcrumb.add_child(b)


# ── Rows ──────────────────────────────────────────────────────────────────────

func _make_folder_row(folder_name: String, path: String) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size.y = ROW_HEIGHT
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = "  [DIR]  %s" % folder_name
	if summarize_folders:
		var s: Array = _folder_summary(path)
		btn.text += "   %d PART(S) · %.1f MB" % [int(s[0]), float(s[1]) / 1048576.0]
	btn.pressed.connect(func() -> void: _navigate_into(path, folder_name))
	return btn


# Returns a plain Button normally, or a row with a SHARE button beside it when
# `show_share` — so the tap target for "play" stays the whole row either way.
func _make_video_row(file_name: String, path: String) -> Control:
	var btn := Button.new()
	btn.custom_minimum_size.y = ROW_HEIGHT
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.focus_mode = Control.FOCUS_NONE
	var size_mb: float = float(_file_size(path)) / 1048576.0
	var tag: String = "VID" if file_name.get_extension().to_lower() in VIDEO_EXTS else "IMG"
	btn.text = "  [%s]  %s   %.1f MB" % [tag, file_name, size_mb]
	btn.pressed.connect(func() -> void: _import(path, file_name, btn))
	if not show_share:
		return btn

	var row := HBoxContainer.new()
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(btn)
	var share := Button.new()
	share.custom_minimum_size = Vector2(160, ROW_HEIGHT)
	share.focus_mode = Control.FOCUS_NONE
	share.text = "SHARE"
	share.pressed.connect(func() -> void: file_share_requested.emit(path))
	row.add_child(share)
	return row


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return int(n)


# ── Import (chunked local copy → clips folder) ─────────────────────────────────

func _import(src_path: String, file_name: String, btn: Button) -> void:
	if select_only:
		# No copy — the caller just wants the path (e.g. the raster-mask picker).
		btn.modulate = GREEN
		status_label.text = "SELECTED %s" % file_name
		file_selected.emit(src_path)
		return
	if _copy_active:
		status_label.text = "BUSY — WAIT FOR THE CURRENT IMPORT TO FINISH"
		return
	if dest_dir == "":
		status_label.text = "NO DESTINATION FOLDER SET"
		return
	var dest_path: String = dest_dir.path_join(file_name)
	if FileAccess.file_exists(dest_path):
		# Already imported — just (re)add it to the playlist, no copy.
		btn.text = "  [OK]  %s" % file_name
		btn.modulate = GREEN
		status_label.text = "ALREADY IMPORTED — ADDED"
		clip_imported.emit(dest_path)
		return

	_src = FileAccess.open(src_path, FileAccess.READ)
	if _src == null:
		status_label.text = ""
		_err.show_error("CANNOT READ %s (ERR %d)" % [file_name, FileAccess.get_open_error()],
			func() -> void: _import(src_path, file_name, btn))
		return
	DirAccess.make_dir_recursive_absolute(dest_dir)
	_dst = FileAccess.open(dest_path, FileAccess.WRITE)
	if _dst == null:
		_src.close()
		_src = null
		status_label.text = ""
		_err.show_error("CANNOT WRITE TO CLIPS FOLDER (ERR %d)" % FileAccess.get_open_error(),
			func() -> void: _import(src_path, file_name, btn))
		return

	_copy_active = true
	_copy_total = int(_src.get_length())
	_copy_done = 0
	_copy_dest_path = dest_path
	_copy_btn = btn
	_copy_name = file_name
	btn.modulate = GREEN
	btn.text = "  [VID]  %s   0%%" % file_name
	status_label.text = "IMPORTING %s…" % file_name
	set_process(true)


func _process(_delta: float) -> void:
	if not _copy_active:
		return
	var chunk := _src.get_buffer(COPY_CHUNK)
	if chunk.size() > 0:
		_dst.store_buffer(chunk)
		_copy_done += chunk.size()
		if is_instance_valid(_copy_btn):
			var pct := 0
			if _copy_total > 0:
				pct = int(float(_copy_done) / float(_copy_total) * 100.0)
			_copy_btn.text = "  [VID]  %s   %d%%" % [_copy_name, pct]
	if _src.get_position() >= _copy_total or chunk.size() == 0:
		_finish_copy()


func _finish_copy() -> void:
	if _dst != null:
		_dst.close()
	if _src != null:
		_src.close()
	_src = null
	_dst = null
	_copy_active = false
	set_process(false)
	if is_instance_valid(_copy_btn):
		_copy_btn.text = "  [OK]  %s" % _copy_name
		_copy_btn.modulate = GREEN
	status_label.text = "IMPORTED %s" % _copy_name
	clip_imported.emit(_copy_dest_path)
	_copy_btn = null
