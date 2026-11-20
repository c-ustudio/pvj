## ClipBrowserUI.gd
## Attach to a Control node. Requires the pro ClipServer node.
##
## Scene tree suggestion:
##   ClipBrowser (Control)
##     VBoxContainer
##       HBoxContainer (toolbar)
##         Label ("clips")
##         Button (RefreshBtn)
##         Label (StorageLabel)
##       ScrollContainer
##         VBoxContainer (ClipList)
##       HBoxContainer (bottom bar)
##         Label (StatusLabel)
##         Button (LoadBtn)       ← loads selected into ClipEngine
##         Button (DeleteBtn)     ← deletes selected from server

extends Control

# ── Node refs (assign in Inspector or adjust paths) ───────────────────────────
@onready var clip_list: VBoxContainer    = $VBox/Scroll/ClipList
@onready var status_label: Label         = $VBox/Bottom/StatusLabel
@onready var storage_label: Label        = $VBox/Toolbar/StorageLabel
@onready var load_btn: Button            = $VBox/Bottom/LoadBtn
@onready var delete_btn: Button          = $VBox/Bottom/DeleteBtn
@onready var refresh_btn: Button         = $VBox/Toolbar/RefreshBtn

# ── State ─────────────────────────────────────────────────────────────────────
var _clips: Array = []
var _selected: String = ""
var _drive_poll_timer: Timer
# Inline error state (red dot + message + RETRY), inserted under the toolbar.
var _err: M8ErrorBar

# Emit this to tell ClipEngine to load a URL
signal load_clip_requested(url: String, filename: String)

# ── Preload a simple row scene or build inline ────────────────────────────────
const ROW_HEIGHT := 48

# Pro only: created by core/features.gd, not an autoload.
@onready var ClipServer: Node = get_node("/root/ClipServer")

func _ready() -> void:
	ClipServer.clips_loaded.connect(_on_clips_loaded)
	ClipServer.clip_deleted.connect(_on_clip_deleted)
	ClipServer.storage_updated.connect(_on_storage_updated)
	ClipServer.drive_pull_started.connect(_on_drive_pull_started)
	ClipServer.drive_pull_status.connect(_on_drive_pull_status)
	ClipServer.request_failed.connect(_on_request_failed)

	_err = M8ErrorBar.new()
	var vbox := $VBox as VBoxContainer
	vbox.add_child(_err)
	vbox.move_child(_err, 1)          # directly under the toolbar

	refresh_btn.pressed.connect(_refresh)
	load_btn.pressed.connect(_load_selected)
	delete_btn.pressed.connect(_confirm_delete)

	load_btn.disabled = true
	delete_btn.disabled = true

	_setup_drive_poll_timer()
	_refresh()


func _refresh() -> void:
	_err.clear()
	status_label.text = "LOADING…"
	ClipServer.fetch_clips()
	ClipServer.fetch_storage()


# ── Clip list rendering ───────────────────────────────────────────────────────

func _on_clips_loaded(clips: Array) -> void:
	_clips = clips
	_selected = ""
	_rebuild_list()
	status_label.text = "%d CLIP%s" % [clips.size(), "S" if clips.size() != 1 else ""]
	_update_buttons()


func _rebuild_list() -> void:
	for child in clip_list.get_children():
		child.queue_free()

	for clip in _clips:
		var row := _make_row(clip)
		clip_list.add_child(row)


func _make_row(clip: Dictionary) -> Control:
	var btn := Button.new()
	btn.custom_minimum_size.y = ROW_HEIGHT
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.text = "  %s   %s MB" % [clip.get("name", "?"), clip.get("size_mb", 0)]

	var clip_name := str(clip.get("name", "?"))
	btn.pressed.connect(func(): _select(clip_name, btn))

	# Dim row if currently downloading (server sends null when not downloading)
	var status: Variant = clip.get("downloading")
	if status != null and str(status) != "done":
		btn.modulate.a = 0.5
		btn.text += "  [%s]" % str(status)

	return btn


func _select(filename: String, btn: Button) -> void:
	_selected = filename
	# Reset all row tints
	for child in clip_list.get_children():
		child.modulate = Color.WHITE
	btn.modulate = Color(0.0, 1.0, 0.255)  # M8 green selection
	_update_buttons()


func _update_buttons() -> void:
	var has_sel := _selected != ""
	load_btn.disabled = not has_sel
	delete_btn.disabled = not has_sel


# ── Actions ───────────────────────────────────────────────────────────────────

func _load_selected() -> void:
	if _selected.is_empty():
		return
	var url: String = ClipServer.clip_url(_selected)
	load_clip_requested.emit(url, _selected)
	status_label.text = "LOADING — %s" % _selected


func _confirm_delete() -> void:
	if _selected.is_empty():
		return
	# M8-styled in-app modal (M8Dialog), not an OS ConfirmationDialog. Destructive
	# → red accent.
	M8Dialog.confirm(self, "DELETE CLIP",
		"DELETE %s FROM SERVER STORAGE?" % _selected,
		"DELETE", func(): _do_delete(), M8Dialog.M8_RED)


func _do_delete() -> void:
	status_label.text = "DELETING %s…" % _selected
	ClipServer.delete_clip(_selected)


func _on_clip_deleted(filename: String, freed_mb: float) -> void:
	status_label.text = "DELETED %s (FREED %.1f MB)" % [filename, freed_mb]
	_selected = ""
	_update_buttons()
	# Refresh list and storage
	ClipServer.fetch_clips()
	ClipServer.fetch_storage()


# ── Storage display ───────────────────────────────────────────────────────────

func _on_storage_updated(info: Dictionary) -> void:
	storage_label.text = "%.1f MB USED · %.1f GB FREE" % [
		info.get("used_mb", 0),
		info.get("disk_free_gb", 0)
	]


# ── Drive pull polling ────────────────────────────────────────────────────────

var _polling_file: String = ""

func _setup_drive_poll_timer() -> void:
	_drive_poll_timer = Timer.new()
	_drive_poll_timer.wait_time = 2.0
	_drive_poll_timer.timeout.connect(_poll_drive)
	add_child(_drive_poll_timer)


func _on_drive_pull_started(filename: String) -> void:
	_polling_file = filename
	_drive_poll_timer.start()
	status_label.text = "PULLING FROM DRIVE — %s…" % filename


func _poll_drive() -> void:
	if _polling_file.is_empty():
		_drive_poll_timer.stop()
		return
	ClipServer.poll_drive_status(_polling_file)


func _on_drive_pull_status(filename: String, status: String, downloaded_mb: float) -> void:
	status_label.text = "%s — %s (%.1f MB)" % [filename, status.to_upper(), downloaded_mb]
	if status == "done" or status.begins_with("error"):
		_polling_file = ""
		_drive_poll_timer.stop()
		_refresh()


# ── Error handling ────────────────────────────────────────────────────────────

func _on_request_failed(endpoint: String, error: String) -> void:
	status_label.text = ""
	_err.show_error("%s FAILED - %s" % [endpoint.to_upper(), error], _refresh)
	push_warning("ClipServer error on %s: %s" % [endpoint, error])
