class_name FolderTabBar
extends Control
## FolderTabBar — the ALL / LIVE / PARKED tabs above the ClipGrid (sequencer
## Step 4). A pure view over ClipLibrary.folder_ids(): it holds no clip state,
## it just emits which view the user picked.
##
## Intent-only: tapping a tab emits `folder_selected(folder_id)`; pipeline wires
## that to ClipGrid.set_folder(). The bar never touches the grid or the engine
## itself (PocketVJ_Architecture §3, §4 — widgets emit intent, pipeline wires).
##
## PARKED clips still play on tap — the grid dims them but leaves them tappable,
## so PARKED is a browse-everything view, not a lockout.

signal folder_selected(folder_id: String)

# Shared M8 palette (see M8Palette).
const GREEN := M8Palette.GREEN
const TEXT := M8Palette.TEXT
const LABEL := M8Palette.LABEL
const LINE := M8Palette.LINE
const BLACK := M8Palette.BLACK

const TAB_W := 128.0
const TAB_H := 48.0
const TAB_GAP := 8.0
const CHIP_W := 96.0          ## a sub-folder chip's floor; it grows with its name
const CHIP_CHARS := 12        ## longer folder names are cut with an ellipsis

var _font_label: Font
## The ARMED deck's hue, pushed by ClipGrid. These tabs are chrome — they say
## "the UI is lit", not "this belongs to a deck" — so they follow whichever lane
## is armed, green for A and amber for B.
var _accent: Color = GREEN
var _active_id: String = "all"
var _buttons: Dictionary = {}   ## folder_id -> Button
var _row: HBoxContainer
var _scroll: ScrollContainer
var _ids: Array[String] = []    ## the ids the buttons were built for
## The width the header can give the bar (ClipGrid sets it). Imported folders
## and packs are chips, so a library easily has more than fit: the row then
## scrolls sideways (a drag) instead of running over the clip count and DONE.
var _max_w: float = INF


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # only the buttons take input
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_scroll)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", int(TAB_GAP))
	_scroll.add_child(_row)


## The most the bar may take; wider rows scroll. No-op when unchanged (the
## grid calls this from its own re-layout, which a size change re-triggers).
func set_max_width(w: float) -> void:
	if is_equal_approx(w, _max_w):
		return
	_max_w = w
	_fit()


func _fit() -> void:
	custom_minimum_size = Vector2(minf(_bar_width(), _max_w), TAB_H)
	size = custom_minimum_size


## font_label = pipeline's wide-tracked micro-caps font. Builds a tab per
## ClipLibrary view id; call after _ready (pipeline does).
func setup(font_label: Font) -> void:
	_font_label = font_label
	refresh()


## Rebuild the buttons when the library's view ids changed (a sub-folder
## appeared or went on a rescan). Cheap and idempotent: same ids, no work.
## A chip whose folder vanished falls back to ALL.
func refresh() -> void:
	var ids := ClipLibrary.folder_ids()
	if ids == _ids:
		return
	_ids = ids
	for b: Button in _buttons.values():
		b.queue_free()
	_buttons.clear()
	for fid: String in ids:
		var nm := ClipLibrary.get_folder(fid).name
		var b := Button.new()
		var chip := fid.begins_with("dir:")
		b.text = nm if not chip or nm.length() <= CHIP_CHARS else nm.left(CHIP_CHARS - 1) + "…"
		b.custom_minimum_size = Vector2(CHIP_W if chip else TAB_W, TAB_H)
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		if _font_label != null:
			b.add_theme_font_override("font", _font_label)
		b.add_theme_font_size_override("font_size", 16)
		b.pressed.connect(_on_tab_pressed.bind(fid))
		_row.add_child(b)
		_buttons[fid] = b
	if not _buttons.has(_active_id):
		_active_id = "all"
		folder_selected.emit(_active_id)
	_restyle()
	_fit()


func _bar_width() -> float:
	var w := 0.0
	for b: Button in _buttons.values():
		w += maxf(b.custom_minimum_size.x, b.get_combined_minimum_size().x)
	return w + float(maxi(0, _buttons.size() - 1)) * TAB_GAP


func active_folder() -> String:
	return _active_id


## Sync the highlight without re-emitting (e.g. if pipeline sets the view directly).
func set_active(folder_id: String) -> void:
	if folder_id == _active_id:
		return
	_active_id = folder_id
	_restyle()


func _on_tab_pressed(folder_id: String) -> void:
	if folder_id != _active_id:
		_active_id = folder_id
		_restyle()
	folder_selected.emit(folder_id)


## Repaint in the armed deck's hue (ClipGrid pushes this on every lane switch).
func set_accent(c: Color) -> void:
	if c == _accent:
		return
	_accent = c
	_restyle()


func _restyle() -> void:
	for fid: String in _buttons.keys():
		var b := _buttons[fid] as Button
		var active := (fid == _active_id)
		for s: String in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(s, _tab_sb(active))
		b.add_theme_color_override("font_color", _accent if active else LABEL)
		b.add_theme_color_override("font_hover_color", _accent if active else TEXT)
		b.add_theme_color_override("font_pressed_color", _accent)


func _tab_sb(active: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(_accent.r, _accent.g, _accent.b, 0.10) if active else BLACK
	sb.set_border_width_all(1)
	sb.border_color = _accent if active else Color(_accent.r, _accent.g, _accent.b, 0.16)
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb
