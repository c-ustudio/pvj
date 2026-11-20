class_name SequenceStrip
extends Control
## SequenceStrip — the scrollable slot row at the bottom of the sequencer (Step 5).
##
## A VIEW over a Sequence model: it renders `Sequence.entries` as a horizontal row
## of pooled, virtualized slot cells (only the visible span + a margin is realized,
## textures freed on scroll-off — Architecture §7 risks 3 & 7). It emits intent
## (`slot_selected`, and in Step 6 `reorder_requested`); pipeline wires those to the
## Sequence model + ClipEngine. The strip never calls the engine.
##
## Gestures mirror ClipGrid: tap a slot -> slot_selected(index); horizontal drag ->
## scroll; long-press + drag -> reorder (Step 6). Rebuilds only on the model's
## `changed` signal, never per drag-frame.

signal slot_selected(index: int)
## SEQ2 §3.6: one strip, two models — which lane the strip is showing/editing.
signal lane_selected(lane: int)
## Reorder intent — kind = REORDER_MOVE (internal drag) or REORDER_REMOVE (dragged
## a slot off the strip). from = source slot; to = destination (unused for REMOVE).
signal reorder_requested(kind: int, from_index: int, to_index: int)
## Step 7 transport — the strip hosts the controls but only emits intent.
signal auto_advance_toggled(enabled: bool)
signal shuffle_pressed
signal beats_per_slot_changed(beats: int)
signal clear_pressed
## Named slot save/load — pipeline does the file I/O (Session 12, follow-up).
signal save_slot_pressed(slot: int, label: String)
## LOAD opens a slot picker; pipeline builds it (it owns the slot files) and
## loads + arms the slot that is picked (Session 42).
signal load_menu_requested
signal clear_slot_pressed(slot: int)   ## delete the armed slot's file (behind a confirm)

enum { REORDER_MOVE, REORDER_REMOVE }

const SLOT_COUNT := 6
## Drag a lifted slot this far ABOVE the strip (into the grid) to arm removal.
const REMOVE_MARGIN := 44.0

# Shared M8 palette (see M8Palette).
const GREEN := M8Palette.GREEN
const AMBER := M8Palette.AMBER   ## deck B — see the palette's note on why a second accent exists
const TEXT := M8Palette.TEXT
const DIMTEXT := M8Palette.DIMTEXT
const LABEL := M8Palette.LABEL
const LINE := M8Palette.LINE
const BLACK := M8Palette.BLACK

const STRIP_H := 172.0
const TITLE_H := 52.0     ## holds the slot group + label field at a hittable size
const SLOT_W := 132.0
const THUMB_H := 74.0
const SLOT_LABEL_H := 26.0
## The type + target scale, named once (see ClipGrid's note: these are LOGICAL
## px, scaled 1.667x on the 9a). The chrome was 13 px on 32 px-tall buttons —
## below the 48 dp touch minimum and the smallest text in the app. BTN_H 44
## clears that once scaled; CHROME_FS is the one knob for every button here.
const CHROME_FS := 17
const BTN_H := 44.0
const TITLE_FS := 20      ## "SEQ A · 10" — was 14 at 60% alpha, the dimmest thing on screen
const LABEL_MIN_W := 110.0  ## the LABEL field is the one stretchy box in the title row
const ROW_SEP := 6
## Compact title row, for screens narrower than the Pixels' ~1404-1454 logical px
## (an 18:9 or 16:9 phone). Switched on only when the full row would not fit.
const DECK_BTN_W_COMPACT := 72.0
const LABEL_MIN_W_COMPACT := 80.0
const BTN_MARGIN := 12.0
const BTN_MARGIN_COMPACT := 7.0
const TOAST_HOLD := 1.2   ## + TOAST_FADE: the save/load result is up ~1.5 s
const TOAST_FADE := 0.3
const DECK_BTN_W := 104.0 ## the A|B chips become real buttons, not 40 px slivers
const SLOT_LABEL_FS := 15
const SLOT_BADGE_FS := 15
const SLOT_H := THUMB_H + SLOT_LABEL_H
const GAP := 10.0
const PAD := 14.0
const TAP_SLOP := 16.0
const LONGPRESS_SEC := 0.4     ## hold this long (no move) to arm a reorder drag (Step 6)

var _seq: Sequence
var _font_label: Font

var _ids: Array[String] = []
var _scroll_x: float = 0.0
var _content_w: float = 0.0
var _active_index: int = -1
var _playhead: float = 0.0     ## 0..1 progress through the active slot (Step 7)

var _cells: Dictionary = {}    ## slot index -> Panel (realized)
var _id_to_cells: Dictionary = {}  ## clip id -> Array[Panel] (a clip may repeat)
var _pool: Array[Panel] = []

# tap / drag tracking
var _press_pos: Vector2 = Vector2.ZERO
var _press_index: int = -1
var _moved: float = 0.0
var _dragging: bool = false
var _saw_touch: bool = false
var _longpress_t: float = 0.0
var _armed_reorder: bool = false  ## Step 6: long-press armed a reorder drag
## Help cards: set by the pipeline; true = this touch opened a card, so no tap,
## no reorder, and no chrome button fires on the release (CLEAR would clear).
var press_gate: Callable = Callable()
var _reorder_from: int = -1
var _remove_pending: bool = false ## the lifted slot is dragged off → drop removes it

var _bg: ColorRect
var _rule: ColorRect            ## top hairline; chrome, so it follows the armed deck
var _content: Control
var _title: Label
var _empty: Label
var _ph_rect: ColorRect        ## playhead fill on the active slot
var _marker: ColorRect         ## insertion marker during a drop/reorder (Step 6)
var _proxy: TextureRect        ## lightweight drag proxy for internal reorder (Step 6)
var _remove_hint: Label        ## "✕ REMOVE" shown while a lifted slot is dragged off

# Transport (Step 7) — buttons in the title row, right-aligned.
var _btn_bps: Button
var _btn_shuffle: Button
var _btn_auto: Button
var _btn_clear: Button
var _bps_options: Array[int] = [1, 2, 4, 8]
var _bps_index: int = 2         ## -> 4 beats = 1 bar (default)
var _auto_on: bool = false

# Named slot save/load (follow-up) — a left-of-centre group in the title row.
var _btn_slot: Button
var _btn_save: Button
var _btn_load: Button
var _btn_clear_slot: Button
# Lane chips (SEQ2 §3.6): A|B selector + the hidden lane's ghost playhead.
var _btn_lane_a: Button
var _btn_lane_b: Button
var _lane: int = 0
var _lane_b_badge: String = ""   ## "" = plain "B"; "NET" = remote-sourced lane (N2)
var _ghost_rect: ColorRect
var _label_edit: LineEdit
## SAVED / LOADED / refusals, as a toast over the slot row (the grid overlay covers
## the main status bar). It used to be a Label at the END of the slot group, which
## grew the group under CLEAR · 1 BAR/SLOT · SHUFFLE (Session 42).
var _toast: PanelContainer
var _status_lbl: Label
var _toast_tween: Tween
var _title_row: HBoxContainer
var _toast_tap: bool = false     ## this touch began on the toast → it dismisses, no slot
var _compact: bool = false
var _slot: int = 1
## Every button built by _mk_button. They are CHROME — "the UI is lit", not "this
## belongs to a deck" — so they take the armed lane's hue. The deck A|B buttons
## are deliberately NOT in here: they keep their own fixed identity colours.
var _chrome_buttons: Array[Button] = []
var _slot_labels: PackedStringArray = PackedStringArray(["", "", "", "", "", ""])


func _ready() -> void:
	custom_minimum_size = Vector2(0, STRIP_H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	set_process(false)

	_bg = ColorRect.new()
	_bg.color = BLACK
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_rule = ColorRect.new()
	_rule.color = _hairline()
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rule.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_rule.offset_bottom = 1.0
	add_child(_rule)

	_content = Control.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_content)

	_ph_rect = ColorRect.new()
	_ph_rect.color = GREEN
	_ph_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ph_rect.visible = false
	_content.add_child(_ph_rect)

	# The HIDDEN lane's slim playhead (SEQ2 §3.6): a 2 px line under the title
	# row, spanning the strip width by run fraction — keeps the other lane honest.
	_ghost_rect = ColorRect.new()
	_ghost_rect.color = Color(GREEN, 0.45)
	_ghost_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost_rect.visible = false
	_ghost_rect.position = Vector2(0.0, TITLE_H - 2.0)
	_ghost_rect.size = Vector2(0.0, 2.0)
	add_child(_ghost_rect)

	# The title lives in the title row (see _build_title_row) and is sized by its
	# text — never cut: a fixed 150 px cell showed "SEQ A · …" on the 9a. The
	# LABEL field gives up the width a longer count takes.
	_title = Label.new()
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# The deck's name in the deck's colour, at full opacity. It was 14 px at 60%
	# alpha — the dimmest text on the screen naming the thing that decides where
	# every grid tap lands.
	_title.add_theme_font_size_override("font_size", TITLE_FS)
	_title.add_theme_color_override("font_color", _accent())
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_empty = Label.new()
	_empty.text = "LONG-PRESS A CLIP TO ADD IT TO THE SEQUENCE"
	_empty.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_empty.offset_top = TITLE_H
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.add_theme_font_size_override("font_size", 15)
	_empty.add_theme_color_override("font_color", LABEL)
	_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_empty)

	_build_title_row()
	_build_toast()

	# Drop marker + drag proxy on top of the cells (Step 6).
	_marker = ColorRect.new()
	_marker.color = GREEN
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.visible = false
	add_child(_marker)

	_proxy = TextureRect.new()
	_proxy.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_proxy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_proxy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_proxy.modulate = Color(1, 1, 1, 0.85)
	_proxy.visible = false
	add_child(_proxy)

	_remove_hint = Label.new()
	_remove_hint.text = "✕ REMOVE"
	_remove_hint.add_theme_font_size_override("font_size", 16)
	_remove_hint.add_theme_color_override("font_color", M8Palette.RED)
	_remove_hint.add_theme_color_override("font_outline_color", BLACK)
	_remove_hint.add_theme_constant_override("outline_size", 6)
	_remove_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_remove_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_remove_hint.visible = false
	add_child(_remove_hint)

	resized.connect(_relayout)
	resized.connect(_fit_title_row)


func setup(seq: Sequence, font_label: Font) -> void:
	_seq = seq
	_font_label = font_label
	if _font_label != null:
		_title.add_theme_font_override("font", _font_label)
		_empty.add_theme_font_override("font", _font_label)
		for b: Button in [_btn_bps, _btn_shuffle, _btn_auto, _btn_clear, _btn_slot, _btn_save, _btn_load, _btn_clear_slot, _btn_lane_a, _btn_lane_b]:
			b.add_theme_font_override("font", _font_label)
		_label_edit.add_theme_font_override("font", _font_label)
		_status_lbl.add_theme_font_override("font", _font_label)
		_remove_hint.add_theme_font_override("font", _font_label)
	if not _seq.changed.is_connected(rebuild):
		_seq.changed.connect(rebuild)
	if not ThumbnailService.thumbnail_ready.is_connected(_on_thumb_ready):
		ThumbnailService.thumbnail_ready.connect(_on_thumb_ready)
	rebuild()
	_fit_title_row()   # the label font changes every button's width


# --- Model -> view -------------------------------------------------------

## Rebuild the id snapshot and relayout. Called on the model's `changed` signal.
func rebuild() -> void:
	_ids.clear()
	if _seq != null:
		_ids.assign(_seq.entries)   # keeps _ids typed as Array[String]
	_active_index = clampi(_active_index, -1, _ids.size() - 1)
	_relayout()
	_title.text = _title_text(_compact)
	_fit_title_row()
	_empty.visible = _ids.is_empty() and not (_toast != null and _toast.visible)


func set_active(index: int) -> void:
	if index == _active_index:
		return
	var prev := _active_index
	_active_index = index
	_restyle_index(prev)
	_restyle_index(index)
	_ensure_visible(index)
	_update_playhead()


func active_index() -> int:
	return _active_index


## Step 7: progress (0..1) through the active slot, for the playhead fill.
func set_playhead(phase: float) -> void:
	_playhead = clampf(phase, 0.0, 1.0)
	_update_playhead()


# --- Layout / virtualization (horizontal) --------------------------------

func _relayout() -> void:
	_content_w = float(_ids.size()) * (SLOT_W + GAP)
	_scroll_x = clampf(_scroll_x, 0.0, _max_scroll())
	for idx: int in _cells.keys():
		_free_cell(idx)
	_refresh_visible()
	_update_playhead()


func _max_scroll() -> float:
	return maxf(0.0, _content_w - size.x + PAD * 2.0)


func _slot_x(i: int) -> float:
	return PAD + float(i) * (SLOT_W + GAP) - _scroll_x


func _refresh_visible() -> void:
	if not visible or _ids.is_empty():
		return
	var step := SLOT_W + GAP
	var first := maxi(0, int((_scroll_x - PAD) / step) - 1)
	var last := mini(_ids.size() - 1, int((_scroll_x - PAD + size.x) / step) + 1)
	for idx: int in _cells.keys():
		if idx < first or idx > last:
			_free_cell(idx)
	for i: int in range(first, last + 1):
		var cell := _cells.get(i) as Panel
		if cell == null:
			cell = _acquire_cell()
			_cells[i] = cell
			_configure_cell(cell, i)
		cell.position = Vector2(_slot_x(i), TITLE_H)
		cell.size = Vector2(SLOT_W, SLOT_H)


# --- Cells (pooled) ------------------------------------------------------

func _acquire_cell() -> Panel:
	var cell: Panel
	if not _pool.is_empty():
		cell = _pool.pop_back()
		cell.visible = true
	else:
		cell = _make_cell()
		_content.add_child(cell)
	return cell


func _make_cell() -> Panel:
	var cell := Panel.new()
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_theme_stylebox_override("panel", _cell_sb(false))

	var tr := TextureRect.new()
	tr.name = "thumb"
	tr.position = Vector2(2, 2)
	tr.size = Vector2(SLOT_W - 4.0, THUMB_H)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.clip_contents = true
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(tr)

	var badge := Label.new()
	badge.name = "badge"
	badge.position = Vector2(4, 2)
	badge.size = Vector2(40, 22)
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", SLOT_BADGE_FS)
	badge.add_theme_color_override("font_color", GREEN)
	badge.add_theme_color_override("font_outline_color", BLACK)
	badge.add_theme_constant_override("outline_size", 6)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font_label != null:
		badge.add_theme_font_override("font", _font_label)
	cell.add_child(badge)

	var lbl := Label.new()
	lbl.name = "label"
	lbl.position = Vector2(6, THUMB_H + 2.0)
	lbl.size = Vector2(SLOT_W - 12.0, SLOT_LABEL_H)
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", SLOT_LABEL_FS)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font_label != null:
		lbl.add_theme_font_override("font", _font_label)
	cell.add_child(lbl)
	return cell


func _configure_cell(cell: Panel, i: int) -> void:
	var id := _ids[i]
	cell.set_meta("id", id)
	_register_id_cell(id, cell)
	var cd := ClipLibrary.get_clip(id)
	var tr := cell.get_node("thumb") as TextureRect
	var badge := cell.get_node("badge") as Label
	var lbl := cell.get_node("label") as Label
	tr.texture = null
	badge.text = str(i + 1)
	var active := (i == _active_index)
	lbl.text = (cd.display_name if cd != null else id).to_upper()
	lbl.add_theme_color_override("font_color", _accent() if active else TEXT)
	badge.add_theme_color_override("font_color", _accent())
	cell.add_theme_stylebox_override("panel", _cell_sb(active))
	ThumbnailService.request(id)


func _free_cell(idx: int) -> void:
	var cell := _cells.get(idx) as Panel
	if cell == null:
		return
	_cells.erase(idx)
	if cell.has_meta("id"):
		_unregister_id_cell(str(cell.get_meta("id")), cell)
	(cell.get_node("thumb") as TextureRect).texture = null
	cell.visible = false
	_pool.append(cell)


func _cell_sb(active: bool) -> StyleBoxFlat:
	var hue := _accent()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(hue.r, hue.g, hue.b, 0.10) if active else BLACK
	sb.set_border_width_all(2 if active else 1)
	sb.border_color = hue if active else LINE
	return sb


func _restyle_index(i: int) -> void:
	var cell := _cells.get(i) as Panel
	if cell != null:
		_configure_cell(cell, i)


# A clip id can appear in multiple slots, so route thumbnails to ALL its cells.
# NOTE: `_id_to_cells.get(id) as Array` throws on a missing key (null can't cast
# to the value-type Array) — check has() instead.
func _register_id_cell(id: String, cell: Panel) -> void:
	if not _id_to_cells.has(id):
		_id_to_cells[id] = []
	var arr: Array = _id_to_cells[id]
	if not arr.has(cell):
		arr.append(cell)


func _unregister_id_cell(id: String, cell: Panel) -> void:
	if not _id_to_cells.has(id):
		return
	var arr: Array = _id_to_cells[id]
	arr.erase(cell)
	if arr.is_empty():
		_id_to_cells.erase(id)


func _on_thumb_ready(clip_id: String, tex: Texture2D) -> void:
	if not _id_to_cells.has(clip_id):
		return
	for c: Panel in (_id_to_cells[clip_id] as Array):
		(c.get_node("thumb") as TextureRect).texture = tex


# --- Playhead ------------------------------------------------------------

func _update_playhead() -> void:
	var cell := _cells.get(_active_index) as Panel
	if cell == null or _active_index < 0:
		_ph_rect.visible = false
		return
	_ph_rect.visible = true
	var w := SLOT_W * _playhead
	_ph_rect.position = Vector2(cell.position.x, TITLE_H + SLOT_H - 4.0)
	_ph_rect.size = Vector2(w, 4.0)


func _ensure_visible(i: int) -> void:
	if i < 0:
		return
	var x := PAD + float(i) * (SLOT_W + GAP)   # content-space left edge
	var left := x - _scroll_x
	var right := left + SLOT_W
	if left < PAD:
		_scroll_x = clampf(x - PAD, 0.0, _max_scroll())
		_refresh_visible()
	elif right > size.x - PAD:
		_scroll_x = clampf(x + SLOT_W - size.x + PAD, 0.0, _max_scroll())
		_refresh_visible()


# --- Input (tap-to-jump + horizontal drag-to-scroll) ---------------------

func _gui_input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		_saw_touch = true
		_press((e as InputEventScreenTouch).position, (e as InputEventScreenTouch).pressed)
	elif e is InputEventScreenDrag:
		_drag((e as InputEventScreenDrag).relative, (e as InputEventScreenDrag).position)
	elif e is InputEventMouseButton and not _saw_touch:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_press(mb.position, mb.pressed)
	elif e is InputEventMouseMotion and not _saw_touch:
		var mm := e as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_drag(mm.relative, mm.position)


func _press(pos: Vector2, pressed: bool) -> void:
	if pressed:
		_press_pos = pos
		# A press on the showing toast is a dismiss, never a slot tap. Checked
		# HERE, by geometry, because on the 9a the touch reached the strip while
		# the pill was up (a ScreenTouch is not a mouse event, so the pill's
		# MOUSE_FILTER_STOP did not end its propagation) and jumped the slot under it.
		_toast_tap = _toast != null and _toast.visible \
			and Rect2(_toast.global_position - global_position, _toast.size).has_point(pos)
		_press_index = -1 if _toast_tap else _index_at(pos)
		_moved = 0.0
		_dragging = false
		_armed_reorder = false
		_longpress_t = 0.0
		set_process(_press_index >= 0)   # tick the long-press timer only over a slot
	else:
		set_process(false)
		# Only a release whose PRESS landed here counts. A press taken by another
		# control (the toast) left a stale _press_index behind, and its release
		# alone used to select that old slot.
		var pressed_index := _press_index
		_press_index = -1
		if _toast_tap:
			_toast_tap = false
			if not _dragging:
				hide_toast()
			return
		if _armed_reorder:
			_end_reorder(pos)
		elif press_gate.is_valid() and press_gate.call():
			pass   # a help card took this touch
		elif not _dragging and _press_pos.distance_to(pos) <= TAP_SLOP and pressed_index >= 0:
			slot_selected.emit(pressed_index)


func _drag(rel: Vector2, pos: Vector2) -> void:
	_moved += absf(rel.x) + absf(rel.y)
	if _armed_reorder:
		_update_reorder(pos)
		return
	if _moved > TAP_SLOP:
		_dragging = true
		set_process(false)   # a scroll cancels the pending long-press
	_scroll_x = clampf(_scroll_x - rel.x, 0.0, _max_scroll())
	_refresh_visible()
	_update_playhead()


func _process(delta: float) -> void:
	# Only running while a finger rests on a slot: arm a reorder after LONGPRESS_SEC.
	_longpress_t += delta
	if _longpress_t >= LONGPRESS_SEC and not _dragging and not _armed_reorder:
		set_process(false)
		if press_gate.is_valid() and press_gate.call():
			return   # a help card took this touch
		_begin_reorder()


func _index_at(pos: Vector2) -> int:
	if pos.y < TITLE_H:
		return -1
	var step := SLOT_W + GAP
	var cx := pos.x + _scroll_x - PAD
	if cx < 0.0:
		return -1
	var i := int(cx / step)
	if cx - float(i) * step > SLOT_W:
		return -1   # in the gap
	return i if i >= 0 and i < _ids.size() else -1


# --- Title row: deck · slot bank · label · transport ----------------------

## ONE HBoxContainer across the strip, inset by PAD. It used to be two boxes
## placed independently — the slot group by hand at x=252, the transport pinned
## right with offset_left -700 — and nothing kept them apart: the LABEL field
## already sat over CLEAR, and the status label at the end of the slot group
## drew across 1 BAR/SLOT and SHUFFLE on every SAVE/LOAD (Session 42). Now the
## LABEL field is the only box that stretches, so the row shares the width
## instead of overlapping (tools/verify_sequence_strip_layout.gd checks it).
func _build_title_row() -> void:
	var row := HBoxContainer.new()
	row.name = "TitleRow"
	row.add_theme_constant_override("separation", ROW_SEP)
	row.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	row.offset_left = PAD
	row.offset_right = -PAD
	row.offset_top = 0.0
	row.offset_bottom = TITLE_H
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	_title_row = row
	_title.size_flags_vertical = Control.SIZE_FILL
	row.add_child(_title)

	# Lane chips first (SEQ2 §3.6): A | B, M8-green active. They select which
	# lane the WHOLE strip (and the grid's arming) talks to.
	_btn_lane_a = _mk_button("A", func() -> void: _select_lane(0))
	_btn_lane_b = _mk_button("B", func() -> void: _select_lane(1))
	# ⚠️ OUT of the chrome list. _mk_button adds every button it makes, but these
	# two carry IDENTITY, not chrome: _style_deck_btn fills them with their own
	# deck's hue and sets BLACK text. Leaving them in meant _apply_accent()
	# restyled them back to a black ground on the next lane switch while the text
	# stayed BLACK — two invisible buttons.
	_chrome_buttons.erase(_btn_lane_a)
	_chrome_buttons.erase(_btn_lane_b)
	row.add_child(_btn_lane_a)
	row.add_child(_btn_lane_b)
	set_lane_b_badge(_lane_b_badge)   # a pre-build push lands here
	_restyle_lanes()

	# Named slot bank (warp-slot pattern: SLOT 1–6 · SAVE · LOAD · DEL); pipeline
	# does the file I/O off the emitted intents.
	_btn_slot = _mk_button("SLOT 1", _cycle_slot)
	_btn_slot.add_theme_color_override("font_color", _accent())   # armed slot = the deck's hue
	_btn_save = _mk_button("SAVE", _on_save_slot)
	_btn_load = _mk_button("LOAD", func() -> void: load_menu_requested.emit())
	_btn_clear_slot = _mk_button("DEL", func() -> void: clear_slot_pressed.emit(_slot))
	_btn_clear_slot.add_theme_color_override("font_color", M8Palette.RED)   # destructive
	for b: Button in [_btn_slot, _btn_save, _btn_load, _btn_clear_slot]:
		row.add_child(b)

	_label_edit = LineEdit.new()
	_label_edit.placeholder_text = "LABEL"
	_label_edit.custom_minimum_size = Vector2(LABEL_MIN_W, BTN_H)
	_label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_label_edit.max_length = 24
	_label_edit.expand_to_text_length = false
	_label_edit.add_theme_font_size_override("font_size", CHROME_FS)
	if _font_label != null:
		_label_edit.add_theme_font_override("font", _font_label)
	row.add_child(_label_edit)
	# At BUILD time too, not only on a lane switch: _apply_accent() runs from
	# _select_lane, so a freshly launched app would sit on lane A with the
	# theme's green LineEdit border while everything around it was already green
	# by coincidence — and wrong the moment the default lane ever changes.
	_style_label_edit()

	# Transport (Step 7) — intent-only, at the right end.
	_btn_clear = _mk_button("CLEAR", func() -> void: clear_pressed.emit())
	_btn_clear.add_theme_color_override("font_color", LABEL)
	_btn_bps = _mk_button("1 BAR/SLOT", _on_bps_pressed)
	_btn_shuffle = _mk_button("SHUFFLE", func() -> void: shuffle_pressed.emit())
	_btn_auto = _mk_button("AUTO ▶", _on_auto_pressed)
	for b: Button in [_btn_clear, _btn_bps, _btn_shuffle, _btn_auto]:
		row.add_child(b)
	_restyle_auto()


## "SEQ A · 12"; compact drops the deck letter ("SEQ 12") — the filled A|B
## button right next to it already says which deck the strip shows.
func _title_text(compact: bool) -> String:
	if compact:
		return "SEQ %d" % _ids.size()
	return "SEQ %s · %d" % ["A" if _lane == 0 else "B", _ids.size()]


func _title_w(text: String) -> float:
	var font := _title.get_theme_font("font")
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		_title.get_theme_font_size("font_size")).x


## Switch the title row to compact when the full one is wider than the strip,
## and back. The full row's width is derived (min width + what compact saves),
## so a check costs no restyle; only a real change restyles.
func _fit_title_row() -> void:
	if _title_row == null or size.x <= 0.0:
		return
	var saves := (DECK_BTN_W - DECK_BTN_W_COMPACT) * 2.0 \
		+ (LABEL_MIN_W - LABEL_MIN_W_COMPACT) \
		+ float(_chrome_buttons.size()) * (BTN_MARGIN - BTN_MARGIN_COMPACT) * 2.0
	var full_w := _title_row.get_combined_minimum_size().x + (saves if _compact else 0.0) \
		- _title_w(_title.text) + _title_w(_title_text(false))
	var want := full_w > size.x - PAD * 2.0
	_title.text = _title_text(want)
	if want == _compact:
		return
	_compact = want
	_label_edit.custom_minimum_size.x = LABEL_MIN_W_COMPACT if _compact else LABEL_MIN_W
	for b: Button in _chrome_buttons:
		_style_chrome_btn(b)
	_restyle_lanes()


## The SAVE/LOAD/DEL result (and the grid's refusals): a black pill with the
## deck's hairline, centred over the slot row, faded out by a Tween — never in
## the title row, where there is no free width to put it.
func _build_toast() -> void:
	var holder := CenterContainer.new()
	holder.name = "ToastHolder"
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.offset_top = TITLE_H
	holder.offset_left = PAD
	holder.offset_right = -PAD
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(holder)

	# STOP only while it shows: a tap on the pill dismisses it. Hidden, it is
	# IGNORE as well as invisible, so it can never sit on a thumbnail's touch.
	# Hide on the RELEASE and swallow the press too. ⚠️ This alone did NOT stop a
	# tap reaching the slot under the pill on the 9a — _press() checks the pill's
	# rect itself; this path covers the emulated mouse events.
	_toast = PanelContainer.new()
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	_toast.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventScreenTouch or e is InputEventMouseButton:
			_toast.accept_event()
			if not e.is_pressed():
				hide_toast.call_deferred())   # after this event's emulated twin, too
	holder.add_child(_toast)

	_status_lbl = Label.new()
	_status_lbl.add_theme_font_size_override("font_size", CHROME_FS + 1)
	_status_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font_label != null:
		_status_lbl.add_theme_font_override("font", _font_label)
	_toast.add_child(_status_lbl)
	_style_toast()


func _style_toast() -> void:
	if _toast == null:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = BLACK
	sb.set_border_width_all(2)
	sb.border_color = _accent()
	sb.content_margin_left = 22.0
	sb.content_margin_right = 22.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	_toast.add_theme_stylebox_override("panel", sb)
	_status_lbl.add_theme_color_override("font_color", _accent())


func _cycle_slot() -> void:
	_slot = (_slot % SLOT_COUNT) + 1
	_btn_slot.text = "SLOT %d" % _slot
	_sync_label_field()


# The label field reflects the armed slot's stored label (blank = none / empty slot).
func _sync_label_field() -> void:
	if _label_edit != null and not _label_edit.has_focus():
		_label_edit.text = _slot_labels[_slot - 1]


func _on_save_slot() -> void:
	save_slot_pressed.emit(_slot, _label_edit.text.strip_edges())


## Arm a slot without the cycle button — the LOAD picker arms what it loads, so
## SAVE and DEL then act on the pattern now in the lane.
func arm_slot(slot: int) -> void:
	_slot = clampi(slot, 1, SLOT_COUNT)
	if _btn_slot != null:
		_btn_slot.text = "SLOT %d" % _slot
	_sync_label_field()


## pipeline pushes the 6 stored slot labels (index 0 = slot 1) so the field + cycle
## can show what's in each slot. "" = empty or unlabeled.
func set_slot_labels(labels: PackedStringArray) -> void:
	for i: int in mini(labels.size(), SLOT_COUNT):
		_slot_labels[i] = labels[i]
	_sync_label_field()


func current_slot() -> int:
	return _slot


## Flash a short SAVE/LOAD result in the strip as a toast (fades out).
func flash(text: String) -> void:
	if _toast == null:
		return
	_status_lbl.text = text.to_upper()
	# Never wider than the slot row: long messages ellipsise instead of spilling.
	var font := _status_lbl.get_theme_font("font")
	var fs := _status_lbl.get_theme_font_size("font_size")
	var want := font.get_string_size(_status_lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_status_lbl.custom_minimum_size.x = minf(want + 2.0, maxf(0.0, size.x - PAD * 2.0 - 44.0 - 4.0))
	_status_lbl.clip_text = true
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast.modulate.a = 1.0
	_toast.visible = true
	_toast.mouse_filter = Control.MOUSE_FILTER_STOP
	_empty.visible = false   # the empty-lane hint would stick out either side of the pill
	if not is_inside_tree():
		return
	_toast_tween = create_tween()
	_toast_tween.tween_interval(TOAST_HOLD)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, TOAST_FADE)
	_toast_tween.tween_callback(hide_toast)


## Take the toast down now (a tap on it, or the end of its fade).
func hide_toast() -> void:
	if _toast == null:
		return
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast.visible = false
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty.visible = _ids.is_empty()


## The toast's current text, "" when it is not showing (the verifiers read it).
func toast_text() -> String:
	return _status_lbl.text if _toast != null and _toast.visible else ""


func _mk_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.custom_minimum_size = Vector2(0, BTN_H)
	b.add_theme_font_size_override("font_size", CHROME_FS)
	_chrome_buttons.append(b)   # so _apply_accent can repaint it on a lane switch
	_style_chrome_btn(b)
	if _font_label != null:
		b.add_theme_font_override("font", _font_label)
	b.pressed.connect(func() -> void:
		if press_gate.is_valid() and press_gate.call():
			return   # a hold on this button opened its help card; the release is not a press
		cb.call())
	return b


## The chrome buttons with the help key each answers to (HELP_CARDS_SPEC.md §3).
## Fixed keys, not captions: "1 BAR/SLOT" has a slash in it and AUTO changes.
func help_buttons() -> Array:
	return [[_btn_lane_a, "LANE A"], [_btn_lane_b, "LANE B"],
		[_btn_slot, "SLOT"], [_btn_save, "SAVE"], [_btn_load, "LOAD"], [_btn_clear_slot, "DEL"],
		[_btn_clear, "CLEAR"], [_btn_bps, "BARS PER SLOT"], [_btn_shuffle, "SHUFFLE"], [_btn_auto, "AUTO"]]


func _on_bps_pressed() -> void:
	_bps_index = (_bps_index + 1) % _bps_options.size()
	_btn_bps.text = _bps_label()
	_fit_title_row()
	beats_per_slot_changed.emit(_bps_options[_bps_index])


func _bps_label() -> String:
	var beats := _bps_options[_bps_index]
	# Show musical units where they divide the bar cleanly (4 beats/bar).
	if beats == 4:
		return "1 BAR/SLOT"
	elif beats == 8:
		return "2 BAR/SLOT"
	return "%d BEAT/SLOT" % beats


func _on_auto_pressed() -> void:
	_auto_on = not _auto_on
	_restyle_auto()
	auto_advance_toggled.emit(_auto_on)


func _restyle_auto() -> void:
	if _btn_auto == null:
		return
	_btn_auto.text = "AUTO ■" if _auto_on else "AUTO ▶"
	_btn_auto.add_theme_color_override("font_color", _accent() if _auto_on else LABEL)


## Current beats-per-slot (pipeline reads this to seed its counter on connect).
func beats_per_slot() -> int:
	return _bps_options[_bps_index]


func auto_enabled() -> bool:
	return _auto_on


# --- Lanes (SEQ2 §3.6): one strip, two models -----------------------------

func _select_lane(lane: int) -> void:
	if lane == _lane:
		return
	_lane = lane
	_restyle_lanes()
	_apply_accent()
	_title.text = _title_text(_compact)
	lane_selected.emit(lane)


func _restyle_lanes() -> void:
	if _btn_lane_a == null:
		return
	# The deck buttons are the primary "where does my tap land" signal, so the
	# armed one FILLS with its deck's hue (black on colour) instead of tinting a
	# few px of text. Both were 40-100 px wide at 13 px before.
	_style_deck_btn(_btn_lane_a, GREEN, _lane == 0)
	_style_deck_btn(_btn_lane_b, AMBER, _lane == 1)


## Deck A is ALWAYS green and deck B ALWAYS amber, armed or not — only the FILL
## says which is live. The hue keeps meaning the deck, never the state, which is
## what lets it be read at a glance from across a room.
func _style_deck_btn(b: Button, hue: Color, armed: bool) -> void:
	b.custom_minimum_size = Vector2(DECK_BTN_W_COMPACT if _compact else DECK_BTN_W, BTN_H)
	b.add_theme_font_size_override("font_size", CHROME_FS + 3)
	b.add_theme_color_override("font_color", BLACK if armed else LABEL)
	b.add_theme_color_override("font_hover_color", BLACK if armed else hue)
	b.add_theme_color_override("font_pressed_color", BLACK if armed else hue)
	var sb := StyleBoxFlat.new()
	sb.bg_color = hue if armed else BLACK
	sb.set_border_width_all(2)
	sb.border_color = hue
	for s: String in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(s, sb)


## The one hue question this widget asks: which deck is the strip showing?
func _accent() -> Color:
	return AMBER if _lane == 1 else GREEN


## Re-apply the deck hue to everything that carries it. Called on every lane
## switch — the title, the playhead, the ghost line and every realized slot all
## have to move together, or the screen shows two decks' colours at once.
func _apply_accent() -> void:
	var hue := _accent()
	if _title != null:
		_title.add_theme_color_override("font_color", hue)
	if _ph_rect != null:
		_ph_rect.color = hue
	if _ghost_rect != null:
		_ghost_rect.color = Color(hue, 0.45)
	if _rule != null:
		_rule.color = _hairline()
	if _marker != null:
		_marker.color = hue
	if _btn_slot != null:
		_btn_slot.add_theme_color_override("font_color", hue)
	_style_toast()
	_style_label_edit()
	for b: Button in _chrome_buttons:
		_style_chrome_btn(b)
	_restyle_auto()          # AUTO's lit colour is the deck's too
	for idx: int in _cells.keys():
		_restyle_index(idx)


## A chrome button: black ground, the armed deck's hairline edge, text that
## lights in the deck's hue. DEL keeps RED (destructive outranks the deck) and
## the A|B buttons are styled by _style_deck_btn instead.
func _style_chrome_btn(b: Button) -> void:
	var hue := _accent()
	var sb := StyleBoxFlat.new()
	sb.bg_color = BLACK
	sb.set_border_width_all(1)
	sb.border_color = _hairline()
	# ⚠️ KEEP THE PADDING. A bare StyleBoxFlat has zero content margins, so
	# overriding the theme's stylebox collapsed every button onto its own text
	# and the row ran together as "SLOT 1SAVE LOAD DEL".
	sb.content_margin_left = BTN_MARGIN_COMPACT if _compact else BTN_MARGIN
	sb.content_margin_right = BTN_MARGIN_COMPACT if _compact else BTN_MARGIN
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	for s: String in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(s, sb)
	b.add_theme_color_override("font_hover_color", hue)
	b.add_theme_color_override("font_pressed_color", hue)


## The LABEL field is a LineEdit, so the Button styling above never reached it
## and it kept a green theme border while the rest of the strip went amber.
func _style_label_edit() -> void:
	if _label_edit == null:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = BLACK
	sb.set_border_width_all(1)
	sb.border_color = _hairline()
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	for s: String in ["normal", "focus", "read_only"]:
		_label_edit.add_theme_stylebox_override(s, sb)
	_label_edit.add_theme_color_override("font_color", TEXT)
	_label_edit.add_theme_color_override("caret_color", _accent())


## LINE is GREEN-tinted, which left a green edge on every button and rule even
## with deck B armed. Same 0.16 alpha, the armed deck's hue.
func _hairline() -> Color:
	var a := _accent()
	return Color(a.r, a.g, a.b, 0.16)


func current_lane() -> int:
	return _lane


## Dual-phone N2: the B chip says when lane B is NOT a local pattern ("B·NET")
## — a NET lane ignores slot taps, and the chip is where the eye checks first.
## Stored, then applied, so a push that lands before the chips build sticks.
func set_lane_b_badge(badge: String) -> void:
	_lane_b_badge = badge
	if _btn_lane_b != null:
		_btn_lane_b.text = "B·%s" % badge if badge != "" else "B"
		_fit_title_row()


## Re-point the strip at another lane's Sequence. Pipeline follows with
## set_active/set_beats_per_slot/set_auto — the strip only swaps the model.
func set_model(seq: Sequence) -> void:
	if _seq == seq:
		return
	if _seq != null and _seq.changed.is_connected(rebuild):
		_seq.changed.disconnect(rebuild)
	_seq = seq
	if not _seq.changed.is_connected(rebuild):
		_seq.changed.connect(rebuild)
	_active_index = -1
	rebuild()


## Push a restored/lane-switched BPS into the button WITHOUT emitting (the
## missing setter the cfg debt needed — pipeline restores, strip displays).
func set_beats_per_slot(beats: int) -> void:
	var i := _bps_options.find(beats)
	if i >= 0:
		_bps_index = i
	if _btn_bps != null:
		_btn_bps.text = _bps_label()
		_fit_title_row()


## Reflect the selected lane's run state on the AUTO chip (no emit).
func set_auto(on: bool) -> void:
	_auto_on = on
	_restyle_auto()


## The HIDDEN lane's playhead fraction (0..1); negative hides the ghost row.
func set_ghost_playhead(frac: float) -> void:
	if _ghost_rect == null:
		return
	if frac < 0.0:
		_ghost_rect.visible = false
		return
	_ghost_rect.visible = true
	_ghost_rect.size.x = size.x * clampf(frac, 0.0, 1.0)


# --- Insertion index + marker (shared by reorder + external drop) --------

func _to_local(global_pos: Vector2) -> Vector2:
	return global_pos - global_position


func _local_inside(lp: Vector2) -> bool:
	return lp.x >= 0.0 and lp.x <= size.x and lp.y >= 0.0 and lp.y <= size.y


# Insertion index (0..n) for a strip-local x: which gap the drop lands in.
func _insertion_index(lx: float) -> int:
	var stepw := SLOT_W + GAP
	var content_x := lx + _scroll_x - PAD
	var ins := int(floor((content_x + stepw * 0.5) / stepw))
	return clampi(ins, 0, _ids.size())


func _show_marker(ins: int) -> void:
	var stepw := SLOT_W + GAP
	var x := PAD + float(ins) * stepw - GAP * 0.5 - _scroll_x
	_marker.position = Vector2(x - 1.5, TITLE_H)
	_marker.size = Vector2(3.0, SLOT_H)
	_marker.visible = true


# --- External drop (grid -> strip), driven by pipeline (Step 6) ----------

## Preview a grid clip drop at `global_pos`; shows the marker and returns the
## insertion index, or -1 if the point is outside the strip.
func external_drop_preview(global_pos: Vector2) -> int:
	var lp := _to_local(global_pos)
	if not _local_inside(lp):
		_marker.visible = false
		return -1
	var ins := _insertion_index(lp.x)
	_show_marker(ins)
	return ins


## Commit a grid clip drop: hide the marker and return the insertion index (or -1
## if released outside the strip — pipeline appends in that case).
func external_drop_commit(global_pos: Vector2) -> int:
	_marker.visible = false
	var lp := _to_local(global_pos)
	return _insertion_index(lp.x) if _local_inside(lp) else -1


## Abandon an external drop without inserting anything — used when the release turned
## out to mean something else (a grid reorder). Only the marker needs clearing; nothing
## was mutated on the way in.
func external_drop_cancel() -> void:
	_marker.visible = false


# --- Internal reorder (long-press a slot, drag, drop) --------------------

func _begin_reorder() -> void:
	if _press_index < 0 or _press_index >= _ids.size():
		return
	_armed_reorder = true
	_remove_pending = false
	_reorder_from = _press_index
	var cell := _cells.get(_press_index) as Panel
	if cell != null:
		_proxy.texture = (cell.get_node("thumb") as TextureRect).texture
		cell.modulate = Color(1, 1, 1, 0.3)   # dim the source under the proxy
	_proxy.visible = true
	_position_proxy(_press_pos)
	_show_marker(_reorder_from)


# Dragging a lifted slot up OFF the strip arms removal; dragging back onto the strip
# cancels it and returns to a normal reorder. The proxy stays inside the strip (its
# y is pinned) — only the finger's y decides the mode.
func _update_reorder(pos: Vector2) -> void:
	_position_proxy(pos)
	var off := pos.y < -REMOVE_MARGIN
	if off != _remove_pending:
		_remove_pending = off
		_proxy.modulate = Color(1, 0.4, 0.3, 0.9) if off else Color(1, 1, 1, 0.85)
	if _remove_pending:
		_marker.visible = false
		_remove_hint.visible = true
		_remove_hint.position = Vector2(_proxy.position.x + SLOT_W * 0.5 - 60.0, TITLE_H + THUMB_H * 0.5 - 10.0)
	else:
		_remove_hint.visible = false
		_show_marker(_insertion_index(pos.x))


func _end_reorder(pos: Vector2) -> void:
	_proxy.visible = false
	_proxy.texture = null
	_proxy.modulate = Color(1, 1, 1, 0.85)
	_marker.visible = false
	_remove_hint.visible = false
	var from := _reorder_from
	var removing := _remove_pending
	_armed_reorder = false
	_remove_pending = false
	_reorder_from = -1
	var src := _cells.get(from) as Panel
	if src != null:
		src.modulate = Color(1, 1, 1, 1)   # un-dim (rebuild also resets it if it moves)
	if from < 0:
		return
	if removing:
		reorder_requested.emit(REORDER_REMOVE, from, -1)
		return
	var ins := _insertion_index(pos.x)
	# ins is a pre-removal boundary; a move to the right shifts down by one once the
	# source is pulled out. Emit only on a real change.
	var to := ins if ins <= from else ins - 1
	if to != from:
		reorder_requested.emit(REORDER_MOVE, from, to)


func _position_proxy(local_pos: Vector2) -> void:
	_proxy.position = Vector2(local_pos.x - SLOT_W * 0.5, TITLE_H)
	_proxy.size = Vector2(SLOT_W, THUMB_H)
