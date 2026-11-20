## DriveBrowserUI.gd — Google Drive folder browser overlay.
## Attach to scenes/DriveBrowser.tscn. Requires the pro DriveAuth + DriveClient nodes.
##
## - Breadcrumb navigation of the Drive folder tree (folders first, then video files)
## - Tap a folder to descend; tap a crumb to jump back up
## - Tap a video to select/deselect → selecting auto-downloads to the clip cache
## - When not linked, shows the device-code panel to link the Google account
##
## Downloads + the resulting clip_engine.scan() are owned by pipeline.gd (it connects
## DriveClient.download_done); this overlay only browses, selects, and shows progress.

extends Control

@onready var refresh_btn: Button       = $VBox/Toolbar/RefreshBtn
@onready var close_btn: Button         = $VBox/Toolbar/CloseBtn
@onready var breadcrumb: HBoxContainer = $VBox/Breadcrumb
@onready var auth_panel: VBoxContainer = $VBox/AuthPanel
@onready var code_label: Label         = $VBox/AuthPanel/CodeLabel
@onready var url_label: Label          = $VBox/AuthPanel/UrlLabel
@onready var wait_label: Label         = $VBox/AuthPanel/WaitLabel
@onready var link_btn: Button          = $VBox/AuthPanel/LinkBtn
@onready var list: VBoxContainer       = $VBox/Scroll/List
@onready var status_label: Label       = $VBox/Bottom/StatusLabel

const ROW_HEIGHT: int = 56
const GREEN: Color = Color(0.0, 1.0, 0.255)   ## #00FF41 — the single accent
const RED: Color = Color(1.0, 0.267, 0.133)    ## #FF4422 — errors only

# Folder navigation stack: each entry { "id": String, "name": String }
var _stack: Array = []
# Selected video file_id -> filename (pending / in playlist)
var _selected: Dictionary = {}
# Live row buttons by file_id, so progress updates can find them
var _rows: Dictionary = {}
var _loading: bool = false
# Inline error state (red dot + message + RETRY), inserted under the toolbar.
var _err: M8ErrorBar

# Pro only: created by core/features.gd, not autoloads.
@onready var DriveAuth: Node = get_node("/root/DriveAuth")
@onready var DriveClient: Node = get_node("/root/DriveClient")


func _ready() -> void:
	DriveAuth.auth_started.connect(_on_auth_started)
	DriveAuth.authorized.connect(_on_authorized)
	DriveAuth.auth_failed.connect(_on_auth_failed)
	DriveAuth.auth_required.connect(_on_auth_required)
	DriveClient.folder_listed.connect(_on_folder_listed)
	DriveClient.list_failed.connect(_on_list_failed)
	DriveClient.download_progress.connect(_on_download_progress)
	DriveClient.download_done.connect(_on_download_done)
	DriveClient.download_failed.connect(_on_download_failed)

	_err = M8ErrorBar.new()
	var vbox := $VBox as VBoxContainer
	vbox.add_child(_err)
	vbox.move_child(_err, 1)          # directly under the toolbar

	refresh_btn.pressed.connect(_refresh)
	close_btn.pressed.connect(hide)
	link_btn.pressed.connect(func() -> void: DriveAuth.begin_auth())

	auth_panel.visible = false
	if DriveAuth.is_authorized():
		_open_root()
	else:
		_show_auth_prompt("LINK YOUR GOOGLE ACCOUNT TO BROWSE DRIVE.")


# ── Auth UI ───────────────────────────────────────────────────────────────────

func _show_auth_prompt(msg: String) -> void:
	auth_panel.visible = true
	list.get_parent().visible = false
	code_label.text = ""
	url_label.text = ""
	wait_label.text = msg
	link_btn.visible = true
	link_btn.text = "LINK ACCOUNT"


func _on_auth_started() -> void:
	auth_panel.visible = true
	link_btn.visible = false
	code_label.text = ">>"
	url_label.text = "A BROWSER OPENED — APPROVE ACCESS THERE,"
	wait_label.text = "THEN RETURN HERE. WAITING…"


func _on_authorized() -> void:
	_err.clear()
	auth_panel.visible = false
	list.get_parent().visible = true
	status_label.text = "LINKED OK"
	_open_root()


func _on_auth_failed(message: String) -> void:
	wait_label.text = ""
	link_btn.visible = true
	link_btn.text = "TRY AGAIN"
	_err.show_error("AUTH FAILED - %s" % message, func() -> void: DriveAuth.begin_auth())


func _on_auth_required() -> void:
	_show_auth_prompt("SESSION EXPIRED — RE-LINK YOUR GOOGLE ACCOUNT.")


# ── Navigation ────────────────────────────────────────────────────────────────

func _open_root() -> void:
	_stack = [{"id": DriveClient.ROOT_ID, "name": "DRIVE"}]
	_load_current()


func _navigate_into(folder_id: String, folder_name: String) -> void:
	_stack.append({"id": folder_id, "name": folder_name})
	_load_current()


func _jump_to_crumb(index: int) -> void:
	if index < 0 or index >= _stack.size():
		return
	_stack.resize(index + 1)
	_load_current()


func _refresh() -> void:
	if DriveAuth.is_authorized():
		_load_current()
	else:
		DriveAuth.begin_auth()


func _load_current() -> void:
	if _stack.is_empty():
		return
	_loading = true
	_err.clear()
	status_label.text = "LOADING…"
	_rebuild_breadcrumb()
	var top: Dictionary = _stack[_stack.size() - 1]
	DriveClient.list_folder(str(top["id"]))


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


# ── Listing ───────────────────────────────────────────────────────────────────

func _on_folder_listed(folder_id: String, items: Array) -> void:
	# Ignore stale responses from a folder we already navigated away from.
	if _stack.is_empty() or str(_stack[_stack.size() - 1]["id"]) != folder_id:
		return
	_loading = false
	_rows.clear()
	for child: Node in list.get_children():
		child.queue_free()

	var folder_count: int = 0
	var video_count: int = 0
	for item: Dictionary in items:
		var row := _make_row(item)
		list.add_child(row)
		if bool(item["is_folder"]):
			folder_count += 1
		else:
			video_count += 1
	status_label.text = "%d FOLDER(S) · %d VIDEO(S)" % [folder_count, video_count]


func _make_row(item: Dictionary) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size.y = ROW_HEIGHT
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.focus_mode = Control.FOCUS_NONE
	var item_name: String = str(item["name"])
	var file_id: String = str(item["id"])

	if bool(item["is_folder"]):
		btn.text = "  [DIR]  %s" % item_name
		btn.pressed.connect(func() -> void: _navigate_into(file_id, item_name))
	else:
		var size_mb: float = float(int(item["size"])) / 1048576.0
		btn.text = "  [VID]  %s   %.1f MB" % [item_name, size_mb]
		btn.custom_minimum_size.y = ROW_HEIGHT + 28   # taller to fit the thumbnail
		btn.expand_icon = false
		_rows[file_id] = btn
		if _selected.has(file_id):
			btn.modulate = GREEN
		btn.pressed.connect(func() -> void: _toggle_select(file_id, item_name, btn))
		# Lazy-load the Drive thumbnail (cached); set it as the row icon when ready.
		var thumb_link: String = str(item.get("thumbnailLink", ""))
		if not thumb_link.is_empty():
			DriveClient.fetch_thumbnail(file_id, thumb_link, func(tex: Texture2D) -> void:
				if is_instance_valid(btn) and tex != null:
					btn.icon = tex
			)
	return btn


# ── Selection / download ──────────────────────────────────────────────────────

func _toggle_select(file_id: String, filename: String, btn: Button) -> void:
	if _selected.has(file_id):
		_selected.erase(file_id)
		btn.modulate = Color.WHITE
		btn.text = "  [VID]  %s" % filename
		status_label.text = "DESELECTED %s (CACHED FILE KEPT)" % filename
	else:
		_selected[file_id] = filename
		btn.modulate = GREEN
		btn.text = "  [VID]  %s   …" % filename
		status_label.text = "DOWNLOADING %s…" % filename
		DriveClient.download_file(file_id, filename)


func _on_download_progress(file_id: String, pct: float) -> void:
	var btn: Button = _rows.get(file_id, null)
	if btn != null and _selected.has(file_id):
		btn.text = "  [VID]  %s   %d%%" % [str(_selected[file_id]), int(pct * 100.0)]


func _on_download_done(file_id: String, _local_path: String) -> void:
	var btn: Button = _rows.get(file_id, null)
	if btn != null:
		btn.text = "  [OK]  %s" % str(_selected.get(file_id, "clip"))
		btn.modulate = GREEN
	status_label.text = "ADDED TO PLAYLIST"


func _on_download_failed(file_id: String, message: String) -> void:
	var filename: String = str(_selected.get(file_id, ""))
	_selected.erase(file_id)
	var btn: Button = _rows.get(file_id, null)
	if btn != null:
		btn.modulate = RED
	status_label.text = ""
	# RETRY re-runs the download that just failed.
	_err.show_error("DOWNLOAD FAILED - %s" % message,
		func() -> void: _toggle_select(file_id, filename, btn))


func _on_list_failed(_folder_id: String, message: String) -> void:
	_loading = false
	status_label.text = ""
	_err.show_error("LIST FAILED - %s" % message, _load_current)
