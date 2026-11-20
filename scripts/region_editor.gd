class_name RegionEditor
extends Control
## Freehand mask-region editor.
##
## Draw masks; each shows a video through its shape with its own effect, clip, and
## transform. S15 UI scheme:
##  - GESTURES (selected mask, any mode): two-finger drag PANS its video, pinch
##    ZOOMS it, double-tap inside FITS (resets) it. These replaced the old
##    PAN / ZOOM− / ZOOM+ / FIT buttons.
##  - RADIO MODES [ADD | EDIT | XFORM]: ADD draws a new mask (full-screen);
##    EDIT is full-screen point work — drag vertices, with an ADD PT / DEL PT
##    stack on the left edge and the NUDGE PAD on the right (the warp editor's
##    arrows, moving the SELECTED POINT 10 or 1 output px per step);
##    XFORM is the free-transform box (move/scale/rotate).
##    Full-screen modes hide all chrome except the ESC/DONE pill (the Session-9d
##    pattern); ESC reverts geometry, DONE keeps it.
##  - [VIDEO | NEXT | FX | LOCAL/DECK] build the mask's clip LIST (manual
##    sequence) / step it / cycle the effect / switch every mask between its own
##    clip and the deck · [FIT] warp from the corners ·
##    [DELETE | CLEAR] destructive, confirmed via M8Dialog · [DONE] commit+exit.
## Masked-OUT areas (black on the projector in DUAL·TEX) are shown as dim green
## diagonal stripes — drawn in THIS OVERLAY ONLY, never into OutputWorld.
## Regions persist (points + effect + clip + scale/pan/angle + geo scale/rot) in
## user://regions.cfg and restore on boot.

const StorageS := preload("res://core/storage.gd")   ## static: loads under --script too

signal closed
## Ask the deck to hide/show its nav bar + status bar. Mask mode itself keeps
## them; only full-screen DRAW/EDIT hides everything.
signal deck_chrome(show_it: bool)
## Emitted whenever the editor's visible state changes, so the deck can keep the
## MSK nav cell live (DRAWING / EDITING / n MASKS) instead of only on exit.
signal state_changed
## WARP pressed with a region selected — pipeline opens the lattice editor
## scoped to that region (the inner level of the two-level warp model).
signal warp_region_requested(index: int)

const SAVE_PATH := "user://regions.cfg"
## MASK SETS: whole mappings kept by number — one per venue or object. A set is
## the [regions] + [region_N] sections of regions.cfg, copied out; the image
## mask and the guides choice are not part of it.
const SETS_DIR := "user://mask_sets"
const SET_COUNT := 6
const CLOSE_RADIUS := 60.0
const GRAB_RADIUS := 90.0
const VERT_RADIUS := 12.0        ## small square handles on a CLOSED mask
const DRAFT_VERT_RADIUS := 10.0  ## …smaller still while drawing
const HANDLE_RADIUS := 26.0      ## transform-box corner/rotate grips (bigger targets)
const ROT_OFFSET := 80.0
const STRIP_H := 56.0
## Tap-vs-drag classification, same threshold as SequenceStrip.TAP_SLOP.
const TAP_SLOP := 16.0
const TAP_MAX_MS := 300
const DOUBLE_TAP_MS := 350
const DOUBLE_TAP_DIST := 80.0
## Masked-out stripes: dim green diagonals on the (black) outside-mask area.
const STRIPE_SPACING := 26.0
const STRIPE_COLOR := Color(0.0, 1.0, 0.255, 0.10)   ## ~10% alpha, flat
## Mask mode KEEPS the deck's nav bar + status bar (only full-screen draw/edit
## hides them), so the toolbar has to sit ABOVE the status bar or it is covered.
## Keep in sync with pipeline.STATUSBAR_H.
const BOTTOM_INSET := 52.0
## The gap the hint keeps from the top edge (the deck's nav bar is hidden for
## the whole of mask mode).
const HINT_MARGIN := 22.0
## The nudge pad — the same cells, steps and hold-to-repeat as the warp editor's
## (warp_editor.gd), so the two read as one tool.
const NUDGE_COARSE := 10.0     ## output px per step
const NUDGE_FINE := 1.0
const REPEAT_DELAY := 0.4      ## hold-to-repeat: first repeat after this…
const REPEAT_SEC := 0.06       ## …then one step per interval
const PAD_BTN := 96.0          ## nudge pad cell size (finger target)

var comp: RegionCompositor
var active: bool = false
var effect_names: PackedStringArray
var clips_dir: String = ""
var clip_list_provider: Callable
## Output-space seam. The editor overlays the PHONE screen, but mask geometry
## lives in output space (the OutputWorld SubViewport once the pipeline moves
## there). pipeline injects these; unset they behave as identity, i.e. output
## space == screen space (the pre-OutputWorld world). Touch positions are
## converted ONCE at the top of _press/_drag_to; hit radii go through _hit_r so
## targets stay finger-sized on screen; _draw maps geometry back to screen.
var xform_provider: Callable = Callable()        ## -> Transform2D, output -> screen
var output_size_provider: Callable = Callable()  ## -> Vector2, output pixel size

## Where the finger is, in OUTPUT px, while it is down — MaskGuides draws a
## crosshair there on the projector (the phone has the finger itself).
var cursor_out: Vector2 = Vector2.ZERO
var cursor_on: bool = false
## Whether MaskGuides draws on the projector at all. ON to map an object (the
## guides are how you aim); OFF to draw a mask mid-set without the audience
## seeing lines. The performer's choice, kept across restarts ([guides]).
var projector_guides: bool = true

var _mode: String = "reshape"          ## reshape | transform | addpt | delpt
var _op: String = ""                   ## active drag: "" | vert | draft | t_move | t_scale | t_rotate
var _edit: bool = false                ## EDIT radio: full-screen point work
var _drawing: bool = false
var _draft: PackedVector2Array = PackedVector2Array()
var _selected: int = -1
var _drag_vert: int = -1
## The SELECTED POINT of the selected mask: what the nudge pad moves. A grab or
## an ADD PT selects; the pad's centre cell cycles (the way to reach a point
## that sits under the pad or the pill). -1 = none.
var _sel_vert: int = -1
var _sel_vert_mask: int = -1           ## the mask _sel_vert indexes into
var _fine: bool = false                ## nudge step: false = 10 px, true = 1 px
var _pad_left: bool = false            ## pad docked left (beside ADD PT/DEL PT) instead of right
var _nudge_dir: Vector2 = Vector2.ZERO ## held pad direction (ZERO = none)
var _repeat_wait: float = 0.0
var _last: Vector2 = Vector2.ZERO
var _pivot: Vector2 = Vector2.ZERO
var _last_dist: float = 1.0
var _last_angle: float = 0.0

var _bar: HBoxContainer
var _btn_fx: Button
var _btn_add: Button
var _btn_transform: Button
var _btn_delpt: Button
var _btn_addpt: Button
var _btn_edit: Button
var _ptops: VBoxContainer              ## ADD PT / DEL PT stack, EDIT mode only
var _btn_guides: Button                ## GUIDES ON/OFF — reachable in every editor state
var _btn_checker: Button               ## CHECKER ON/OFF — a board through every mask's warp
var _btn_deck: Button                  ## LOCAL / DECK — every mask's own clip, or the deck's
var _pad: VBoxContainer                ## nudge pad: D-pad + step toggle, EDIT mode only
var _btn_point: Button                 ## pad centre: shows + cycles the selected point
var _btn_step: Button
var _hint: Label
var _picker: PanelContainer
var _picker_vbox: VBoxContainer
var _sets: PanelContainer              ## the MASK SETS panel (SETS cell)
var _sets_rows: Array[Label] = []      ## "SET n · k MASKS" per slot
var _chrome: M8EditorChrome
var _picker_scroll: ScrollContainer
## Full-screen draw/edit: toolbar + deck chrome hidden, only canvas + pill (+
## hint while drawing). Entered by ADD / XFORM / PAN.
var _fullscreen: bool = false
var _snap: Array = []          ## region geometry snapshot, for ESC

# --- gesture state (two-finger texture pan/zoom + double-tap fit) ---------
## Pinch/pan + the single-finger lockout, shared with the warp editor's EDIT
## CONTENT mode (see TouchGestures — the lockout is the part that matters).
var _gest := TouchGestures.new()
var _press_screen: Vector2 = Vector2.ZERO
var _press_ms: int = 0
var _tap_ms: int = 0                   ## last completed tap, for double-tap
var _tap_pos: Vector2 = Vector2.ZERO

# --- masked-out stripes (editor overlay only, NEVER OutputWorld) ----------
var _stripes: Array = []               ## cached clipped polylines, screen px
var _stripes_dirty: bool = true


func setup(compositor: RegionCompositor, fx_names: PackedStringArray, clips_folder: String) -> void:
	comp = compositor
	effect_names = fx_names
	clips_dir = clips_folder
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	comp.decoder_limit_hit.connect(_on_decoder_limit)
	# A gesture needs a selected mask, and must not start over a modal or mid-draw.
	_gest.can_begin = func() -> bool:
		return _selected != -1 and not _drawing and not _modal_open()
	set_process(false)                 # only runs while a nudge is held
	_build_bar()
	_build_pad()
	_build_picker()
	_build_sets()
	# Minimal floating chrome: ESC/DONE pill + auto-hiding bottom strip. The HINT
	# is NOT passed as `extra` — it stays visible at top-centre at all times.
	_chrome = M8EditorChrome.new()
	add_child(_chrome)
	_chrome.setup(null, [] as Array[Control], true)   # bottom-centre pill, no auto-hide
	_chrome.esc_pressed.connect(func(): _exit_fullscreen(true))
	_chrome.done_pressed.connect(func(): _exit_fullscreen(false))


func set_active(on: bool) -> void:
	active = on
	mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	_bar.visible = on
	_hint.visible = on
	_btn_guides.visible = on
	_btn_guides.text = _guides_label()
	_style_radio(_btn_guides, projector_guides)
	_btn_checker.visible = on
	_sync_checker_button()
	_btn_deck.text = _deck_label()
	_style_radio(_btn_deck, comp.follow_deck_all)
	_chrome.set_active(false)   # pill only exists in full-screen draw/edit
	_fullscreen = false
	state_changed.emit()
	_edit = false
	_ptops.visible = false
	_pad.visible = false
	_stop_nudge()
	_gest.reset()
	_mode = "reshape"
	_update_radio()
	_stripes_dirty = true
	if on:
		_hint.text = "TAP A MASK TO SELECT · 2-FINGER PAN/ZOOM · 2×TAP FIT"
		_layout()
	else:
		_drawing = false
		_draft = PackedVector2Array()
		_op = ""
		_drag_vert = -1
		cursor_on = false
		_picker.visible = false
		_sets.visible = false
	queue_redraw()


# --- input ---------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if not active:
		return
	if _sets != null and _sets.visible:
		# Same rule as the picker: a tap outside closes it and does nothing else.
		if event is InputEventScreenTouch and event.pressed \
				and not _sets.get_global_rect().has_point(event.position):
			_sets.visible = false
		return
	if _picker != null and _picker.visible:
		# Tap outside the panel dismisses it; never draw behind an open picker.
		if event is InputEventScreenTouch and event.pressed \
				and not _picker.get_global_rect().has_point(event.position):
			_picker.visible = false
		return
	# A live two-finger gesture owns all input; the trailing single finger after
	# one lifts must not start a stray vertex drag.
	if _gest.eats_input():
		accept_event()
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_press_screen = event.position
			_press_ms = Time.get_ticks_msec()
			_press(event.position)
		else:
			_release(event.position)
		accept_event()
	elif event is InputEventScreenDrag:
		_drag_to(event.position)
		accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# Mouse-from-touch emulation re-delivers every touch as a mouse event —
		# processing both doubled every draft point and made single taps read as
		# double-taps. The touch branch above already handled the real event.
		if event.device == InputEvent.DEVICE_ID_EMULATION:
			accept_event()
			return
		if event.pressed:
			_press_screen = event.position
			_press_ms = Time.get_ticks_msec()
			_press(event.position)
		else:
			_release(event.position)
		accept_event()
	elif event is InputEventMouseMotion and _op != "":
		if event.device == InputEvent.DEVICE_ID_EMULATION:
			accept_event()
			return
		_drag_to(event.position)
		accept_event()


## Common release path: end any drag, restore chrome hidden by fade-on-edit,
## re-cache the stripes, and classify quick touches for the double-tap fit.
func _release(screen_pos: Vector2) -> void:
	var was_op := _op
	_op = ""
	_drag_vert = -1
	cursor_on = false
	if was_op != "":
		_stripes_dirty = true
	if not _fullscreen and active:
		_bar.visible = true
		_hint.visible = true
	_maybe_tap(screen_pos)
	queue_redraw()


func _maybe_tap(pos: Vector2) -> void:
	if pos.distance_to(_press_screen) > TAP_SLOP:
		return
	if Time.get_ticks_msec() - _press_ms > TAP_MAX_MS:
		return
	var now := Time.get_ticks_msec()
	if now - _tap_ms <= DOUBLE_TAP_MS and pos.distance_to(_tap_pos) <= DOUBLE_TAP_DIST:
		_tap_ms = 0
		_double_tap(pos)
	else:
		_tap_ms = now
		_tap_pos = pos


## Double-tap inside the selected mask = FIT its video (reset texture zoom/pan).
func _double_tap(screen_pos: Vector2) -> void:
	if _drawing or _selected == -1:
		return
	var pos := _xf().affine_inverse() * screen_pos
	if comp.region_at(pos) == _selected:
		comp.reset_transform(_selected)
		_hint.text = "VIDEO FIT RESET"


# Two jobs, both needing RAW input (before _gui_input):
#  1. Drag-to-scroll the VIDEO picker (its rows are Buttons, which swallow the
#     drag before the ScrollContainer can see it).
#  2. Multi-touch tracking for the two-finger texture pan/zoom gesture —
#     _gui_input can't be trusted with index >= 1 touches.
func _input(event: InputEvent) -> void:
	if not active:
		return
	if _picker != null and _picker.visible:
		if event is InputEventScreenDrag and _picker.get_global_rect().has_point(event.position):
			_picker_scroll.scroll_vertical -= int(event.relative.y)
		return
	if event is InputEventScreenTouch:
		if _gest.touch(event.index, event.pressed, event.position):
			_op = ""               # a vertex/transform drag in progress yields
			_drag_vert = -1
	elif event is InputEventScreenDrag and _gest.active:
		if _gest.drag(event.index, event.position):
			_apply_gesture()
		get_viewport().set_input_as_handled()


func _modal_open() -> bool:
	if (_picker != null and _picker.visible) or (_sets != null and _sets.visible):
		return true
	for c in get_children():
		if c is M8Dialog:
			return true
	return false


## Two-finger step: pinch ratio -> content zoom, centroid delta -> content pan.
## TouchGestures reports both in SCREEN px; the pan delta converts with
## basis_xform (a delta carries no translation).
func _apply_gesture() -> void:
	if _selected == -1 or _selected >= comp.region_count():
		return
	# Pinch is UNIFORM — the non-uniform axis pair exists for STRETCH / numeric
	# entry, not for two fingers, which cannot express it unambiguously.
	comp.set_content_scale(_selected, comp.get_content_scale(_selected) * _gest.zoom_ratio)
	# ⚠️ PLUS, not minus. content_offset is now the content's own displacement in
	# domain fractions (it used to be a sampling shift in fit units, hence the old
	# negation). Two-finger pan is consequently 1:1 with the fingers at ANY zoom —
	# the move is applied before the scale, so it is no longer multiplied by it.
	var d_out := _xf().affine_inverse().basis_xform(_gest.pan_delta)
	comp.set_content_offset(_selected,
		comp.get_content_offset(_selected) + d_out / comp.warp_domain(_selected).size)


func _press(screen_pos: Vector2) -> void:
	var pos := _xf().affine_inverse() * screen_pos   # output space from here on
	cursor_out = pos
	cursor_on = true
	if _drawing:
		if _draft.size() >= 3 and pos.distance_to(_draft[0]) <= _hit_r(CLOSE_RADIUS):
			_selected = comp.add_region(_draft)
			_drawing = false
			_draft = PackedVector2Array()
			_stripes_dirty = true
			_sync_selected()
			_hint.text = "MASK ADDED · EDIT / XFORM TO SHAPE IT"
			_exit_fullscreen(false)   # drawing finished -> restore the interface
		else:
			# The point lands under the finger and FOLLOWS it until the finger
			# lifts: the performer is looking at the object, and slides the
			# crosshair onto its corner before letting go.
			_draft.append(pos)
			_op = "draft"
		queue_redraw()
		return

	if _selected != -1:
		var handled := false
		match _mode:
			"transform": handled = _press_transform(pos)
			"delpt": handled = _press_delpt(pos)
			"addpt": handled = _press_addpt(pos)
			_: handled = _press_reshape(pos)
		if handled:
			return

	# Fall through: (re)select whichever mask was tapped, or clear.
	_selected = comp.region_at(pos)
	_sync_selected()
	queue_redraw()


func _press_reshape(pos: Vector2) -> bool:
	var pts := comp.get_points(_selected)
	for i in pts.size():
		if pos.distance_to(pts[i]) <= _hit_r(GRAB_RADIUS):
			_drag_vert = i
			_op = "vert"
			_select_vert(i)
			# Fade-on-edit: while a vertex is being dragged the chrome gets out
			# of the way (full-screen modes have no chrome to hide).
			if not _fullscreen:
				_bar.visible = false
				_hint.visible = false
			queue_redraw()
			return true
	return false


func _press_delpt(pos: Vector2) -> bool:
	var pts := comp.get_points(_selected)
	for i in pts.size():
		if pos.distance_to(pts[i]) <= _hit_r(GRAB_RADIUS):
			if comp.delete_point(_selected, i):
				_hint.text = "POINT DELETED"   # stay armed — multi-point work
				_stripes_dirty = true
				if _sel_vert > i:
					_select_vert(_sel_vert - 1)   # the same point, one index down
				else:
					_select_vert(_sel_vert)       # clamps if the last one went
			else:
				_hint.text = "A MASK NEEDS AT LEAST 3 POINTS"
			queue_redraw()
			return true
	return false


## Top-centre hint. In FULL-SCREEN it can hug the top edge; in normal mask mode
## the deck's nav bar is still there, so it has to sit below it or it is covered.
## Full-width + centred alignment means no size measuring (and no await).
func _position_hint() -> void:
	var sz := _area()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.size = Vector2(sz.x, 40.0)
	# The deck's nav bar is hidden for the whole of mask mode, so the hint sits
	# at the top in every state.
	_hint.position = Vector2(0.0, HINT_MARGIN)


## What the deck's MSK nav cell should show. "" = let the deck fall back to the
## mask COUNT (POLYGON / n MASKS); we only override while actively working.
## Kept <= NAV_MAX_CHARS (8) so it can never clip the nav cell.
func nav_state() -> String:
	if not active:
		return ""
	if _drawing:
		return "DRAWING"
	if _edit or _mode != "reshape":
		return "EDITING"
	return ""


# EDIT radio: full-screen point work (fade-on-edit — chrome gone, pill + the
# ADD PT / DEL PT stack only). Needs a mask; auto-selects when there is just one.
func _radio_edit() -> void:
	if not _require_selection("EDIT"):
		return
	_edit = true
	_mode = "reshape"
	_enter_fullscreen(false)
	_ptops.visible = true
	_pad.visible = true
	if _sel_vert == -1:
		_select_vert(0)
	else:
		_select_vert(_sel_vert)   # clamp: the mask may have lost points since
	_layout()
	_hint.visible = true
	_hint.text = "DRAG POINTS · PAD MOVES THE MARKED POINT · ADD PT / DEL PT AT LEFT"
	_position_hint()
	_update_radio()
	state_changed.emit()


func _radio_xform() -> void:
	if not _require_selection("XFORM"):
		return
	_set_mode("transform")


## Shared mode precondition: a selected mask (auto-select the only one).
## Hand the selected region to the lattice editor. Deliberately NOT a radio mode
## here — it swaps to a different full-screen editor, so it behaves like DONE
## rather than like EDIT/XFORM.
func _edit_warp() -> void:
	if not _require_selection("WARP"):
		return
	warp_region_requested.emit(_selected)


func _require_selection(label: String) -> bool:
	if _selected == -1 and comp.region_count() == 1:
		_selected = 0
		_sync_selected()
	if _selected == -1:
		_hint.text = "TAP A MASK FIRST, THEN %s" % label
		return false
	return true


# Insert a point on the CLOSEST EDGE so the outline keeps its shape (appending
# to the end of the array would cut a chord across the polygon instead).
func _press_addpt(pos: Vector2) -> bool:
	var pts := comp.get_points(_selected)
	var n := pts.size()
	if n < 2:
		return false
	var best := 0
	var best_d := INF
	for i in n:
		var seg := Geometry2D.get_closest_point_to_segment(pos, pts[i], pts[(i + 1) % n])
		var d := pos.distance_to(seg)
		if d < best_d:
			best_d = d
			best = i
	pts.insert(best + 1, pos)
	comp.set_points(_selected, pts)
	_select_vert(best + 1)       # a new point is usually the one to nudge next
	_hint.text = "POINT ADDED"   # stay armed — multi-point work
	_stripes_dirty = true
	queue_redraw()
	return true


func _press_transform(pos: Vector2) -> bool:
	var bounds := comp.region_bounds(_selected)
	var center := bounds.get_center()
	var rot_pt := Vector2(center.x, bounds.position.y - ROT_OFFSET)
	if pos.distance_to(rot_pt) <= _hit_r(HANDLE_RADIUS + 24.0):
		_op = "t_rotate"
		_pivot = comp.region_centroid(_selected)
		_last_angle = (pos - _pivot).angle()
		return true
	for c in _rect_corners(bounds):
		if pos.distance_to(c) <= _hit_r(HANDLE_RADIUS + 24.0):
			_op = "t_scale"
			_pivot = comp.region_centroid(_selected)
			_last_dist = maxf(4.0, pos.distance_to(_pivot))
			return true
	if bounds.has_point(pos) or comp.region_at(pos) == _selected:
		_op = "t_move"
		_last = pos
		return true
	return false


func _drag_to(screen_pos: Vector2) -> void:
	var pos := _xf().affine_inverse() * screen_pos   # output space, like _press
	cursor_out = pos
	if _op == "draft":
		if not _draft.is_empty():
			_draft[_draft.size() - 1] = pos
			queue_redraw()
		return
	if _selected == -1:
		return
	match _op:
		"vert":
			var pts := comp.get_points(_selected)
			if _drag_vert >= 0 and _drag_vert < pts.size():
				pts[_drag_vert] = pos
				comp.set_points(_selected, pts)
				queue_redraw()
		"t_move":
			comp.translate_region(_selected, pos - _last)
			_last = pos
			queue_redraw()
		"t_scale":
			var d := maxf(4.0, pos.distance_to(_pivot))
			comp.scale_region(_selected, d / _last_dist, _pivot)
			_last_dist = d
			queue_redraw()
		"t_rotate":
			var a := (pos - _pivot).angle()
			comp.rotate_region(_selected, a - _last_angle, _pivot)
			_last_angle = a
			queue_redraw()


func _rect_corners(r: Rect2) -> Array:
	return [
		r.position,
		r.position + Vector2(r.size.x, 0),
		r.position + r.size,
		r.position + Vector2(0, r.size.y),
	]


# --- toolbar -------------------------------------------------------------

func _build_bar() -> void:
	_hint = Label.new()
	_hint.text = "ADD A MASK · TAP TO PLACE POINTS · TAP THE FIRST POINT TO CLOSE"
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.visible = false
	add_child(_hint)

	# Even full-width cells (like the warp strip and the reference), not chips —
	# grouped by function with thin gaps:
	#   [ADD|EDIT|XFORM|WARP]  [VIDEO|NEXT|FX|LOCAL]  [FIT|SETS]  [DELETE|CLEAR]  [DONE]
	# Pan/zoom/fit are GESTURES now (two-finger pan, pinch zoom, double-tap fit).
	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 0)
	add_child(_bar)
	# modes — radio group
	_btn_add = _make_button("ADD", _start_draw)
	_bar.add_child(_btn_add)
	_btn_edit = _make_button("EDIT", _radio_edit)
	_bar.add_child(_btn_edit)
	_btn_transform = _make_button("XFORM", _radio_xform)
	_bar.add_child(_btn_transform)
	_bar.add_child(_make_button("WARP", _edit_warp))
	_bar.add_child(_gap())
	# assignment
	_bar.add_child(_make_button("VIDEO", _open_picker))
	_bar.add_child(_make_button("NEXT", _next_clip))
	_btn_fx = _make_button("FX: —", _cycle_fx)
	_bar.add_child(_btn_fx)
	_btn_deck = _make_button(_deck_label(), _toggle_deck)
	_bar.add_child(_btn_deck)
	_bar.add_child(_gap())
	_bar.add_child(_make_button("FIT", _fit_warp))
	_bar.add_child(_make_button("SETS", _toggle_sets))
	_bar.add_child(_gap())
	# destructive — confirmed via M8Dialog
	_bar.add_child(_make_button("DELETE", _delete_selected))
	_bar.add_child(_make_button("CLEAR", _clear_all))
	_bar.add_child(_gap())
	_bar.add_child(_make_button("DONE", _done))
	_bar.visible = false

	# Point ops: a vertical stack on the left edge, EDIT full-screen only.
	_ptops = VBoxContainer.new()
	_ptops.add_theme_constant_override("separation", 0)
	_btn_addpt = _make_stack_button("ADD PT", func(): _set_mode("addpt"))
	_ptops.add_child(_btn_addpt)
	_btn_delpt = _make_stack_button("DEL PT", func(): _set_mode("delpt"))
	_ptops.add_child(_btn_delpt)
	_ptops.visible = false
	add_child(_ptops)

	# Its own cell, not a bar cell: the bar is hidden while a mask is being
	# drawn, which is exactly when a performer mid-set wants this.
	_btn_guides = _make_stack_button(_guides_label(), _toggle_guides)
	_btn_guides.visible = false
	add_child(_btn_guides)

	# Same reasoning: the checker is wanted while points are being moved, which
	# is when the bar is gone.
	_btn_checker = _make_stack_button("CHECKER: OFF", _toggle_checker)
	_btn_checker.visible = false
	add_child(_btn_checker)


func _guides_label() -> String:
	return "GUIDES: ON" if projector_guides else "GUIDES: OFF"


func _toggle_guides() -> void:
	projector_guides = not projector_guides
	_btn_guides.text = _guides_label()
	_style_radio(_btn_guides, projector_guides)
	_hint.text = "PROJECTOR SHOWS THE OUTLINES AND YOUR FINGER" if projector_guides \
		else "PROJECTOR SHOWS THE PICTURE ONLY — GUIDES STAY ON THE PHONE"
	# Merge, never fresh-write (see _save): only this one key changes.
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("guides", "projector", projector_guides)
	cfg.save(SAVE_PATH)


## CHECKER: every mask shows a black/white board through its own warp instead
## of its clip, on the phone and the projector. Not saved; closing the mask
## editor turns it off (pipeline._on_region_editor_closed).
func _toggle_checker() -> void:
	comp.set_checker(not comp.checker)
	_sync_checker_button()
	_hint.text = "CHECKER ON EVERY MASK — SQUARE CELLS ON THE OBJECT = WARP IS RIGHT" \
		if comp.checker else "CHECKER OFF — MASKS SHOW THEIR CLIPS"


func _sync_checker_button() -> void:
	_btn_checker.text = "CHECKER: ON" if comp.checker else "CHECKER: OFF"
	_style_radio(_btn_checker, comp.checker)


# --- nudge pad -----------------------------------------------------------
# The warp editor's pad, pointed at a mask's points. Steps are OUTPUT px — the
# space mask points live in — so 1 px is one projector pixel before the global
# warp, whatever the phone's preview scale.

func _build_pad() -> void:
	# D-pad: ▲◄►▼ around a centre cell that shows + cycles the selected point,
	# with the coarse/fine step toggle underneath; the otherwise dead top-left
	# cell carries the side flip. Laid out exactly as warp_editor._build_pad.
	_pad = VBoxContainer.new()
	_pad.add_theme_constant_override("separation", 0)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 0)
	grid.add_theme_constant_override("v_separation", 0)
	var flip := _pad_cell("◄►")
	flip.add_theme_font_size_override("font_size", 18)
	flip.pressed.connect(_flip_pad)
	grid.add_child(flip)
	grid.add_child(_pad_arrow("▲", Vector2(0, -1)))
	grid.add_child(_pad_spacer())
	grid.add_child(_pad_arrow("◄", Vector2(-1, 0)))
	_btn_point = _pad_cell("P1")
	_btn_point.pressed.connect(_cycle_vert)
	_btn_point.add_theme_color_override("font_color", M8_GREEN)
	grid.add_child(_btn_point)
	grid.add_child(_pad_arrow("►", Vector2(1, 0)))
	grid.add_child(_pad_spacer())
	grid.add_child(_pad_arrow("▼", Vector2(0, 1)))
	grid.add_child(_pad_spacer())
	_pad.add_child(grid)
	_btn_step = _pad_cell("STEP %d PX" % int(NUDGE_COARSE))
	_btn_step.custom_minimum_size = Vector2(PAD_BTN * 3.0, STRIP_H)
	_btn_step.add_theme_font_size_override("font_size", 16)
	_btn_step.pressed.connect(_toggle_step)
	_pad.add_child(_btn_step)
	_pad.visible = false
	add_child(_pad)


func _pad_cell(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(PAD_BTN, PAD_BTN)
	b.add_theme_font_size_override("font_size", 22)
	return b


func _pad_arrow(glyph: String, dir: Vector2) -> Button:
	var b := _pad_cell(glyph)
	# button_down/up (not pressed) so holding repeats.
	b.button_down.connect(_start_nudge.bind(dir))
	b.button_up.connect(_stop_nudge)
	return b


func _pad_spacer() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(PAD_BTN, PAD_BTN)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## Select point `i` of the selected mask, clamped to the points it has.
func _select_vert(i: int) -> void:
	var n := comp.get_points(_selected).size() if _selected != -1 else 0
	_sel_vert = clampi(i, 0, n - 1) if n > 0 else -1
	_sel_vert_mask = _selected
	_sync_point_button()
	queue_redraw()


func _sync_point_button() -> void:
	if _btn_point != null:
		_btn_point.text = "P%d" % (_sel_vert + 1) if _sel_vert >= 0 else "—"


## The pad's centre cell: the next point round the mask.
func _cycle_vert() -> void:
	var n := comp.get_points(_selected).size() if _selected != -1 else 0
	if n == 0:
		return
	_select_vert((_sel_vert + 1) % n)
	_hint.text = "POINT %d OF %d SELECTED" % [_sel_vert + 1, n]


func _nudge(dir: Vector2) -> void:
	if _selected == -1:
		return
	var pts := comp.get_points(_selected)
	if _sel_vert < 0 or _sel_vert >= pts.size():
		return
	pts[_sel_vert] += dir * (NUDGE_FINE if _fine else NUDGE_COARSE)
	comp.set_points(_selected, pts)
	# The projector's crosshair follows the point being nudged — the performer
	# is looking at the object, not at the phone.
	cursor_out = pts[_sel_vert]
	_stripes_dirty = true
	queue_redraw()


func _start_nudge(dir: Vector2) -> void:
	cursor_on = true
	_nudge(dir)
	_nudge_dir = dir
	_repeat_wait = REPEAT_DELAY
	set_process(true)


func _stop_nudge() -> void:
	if _nudge_dir != Vector2.ZERO:
		cursor_on = false
	_nudge_dir = Vector2.ZERO
	set_process(false)


## Hold-to-repeat for the pad arrows — only processing while a button is down.
func _process(delta: float) -> void:
	if _nudge_dir == Vector2.ZERO:
		return
	_repeat_wait -= delta
	while _repeat_wait <= 0.0:
		_nudge(_nudge_dir)
		_repeat_wait += REPEAT_SEC


func _toggle_step() -> void:
	_fine = not _fine
	_btn_step.text = "STEP %d PX" % int(NUDGE_FINE if _fine else NUDGE_COARSE)
	_style_radio(_btn_step, _fine)


## Dock the pad on the other side, to uncover points that sit under it.
func _flip_pad() -> void:
	_pad_left = not _pad_left
	_layout()
	_hint.text = "NUDGE PAD: %s" % ("LEFT" if _pad_left else "RIGHT")


## A thin group separator for the toolbar — fixed width, never expands.
func _gap() -> Control:
	var g := Control.new()
	g.custom_minimum_size = Vector2(10, STRIP_H)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return g


## A point-ops stack cell: fixed size, not an expanding bar cell.
func _make_stack_button(text: String, on_press: Callable) -> Button:
	var b := _make_button(text, on_press)
	b.size_flags_horizontal = 0
	b.custom_minimum_size = Vector2(220, STRIP_H)
	return b


func _build_picker() -> void:
	_picker = PanelContainer.new()
	_picker.visible = false
	_picker.custom_minimum_size = Vector2(620, 500)
	_picker_scroll = ScrollContainer.new()
	_picker_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_picker_scroll.custom_minimum_size = Vector2(620, 500)
	_picker_vbox = VBoxContainer.new()
	_picker_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_vbox.add_theme_constant_override("separation", 0)
	_picker_scroll.add_child(_picker_vbox)
	_picker.add_child(_picker_scroll)
	add_child(_picker)



func _layout() -> void:
	await get_tree().process_frame
	var sz := _area()
	_bar.custom_minimum_size = Vector2(sz.x, STRIP_H)
	await get_tree().process_frame
	_bar.position = Vector2(0.0, sz.y - BOTTOM_INSET - _bar.size.y)
	_position_hint()
	_picker.position = Vector2((sz.x - _picker.size.x) * 0.5, (sz.y - _picker.size.y) * 0.5)
	_sets.position = Vector2((sz.x - _sets.size.x) * 0.5, (sz.y - _sets.size.y) * 0.5)
	# Point-ops stack: left edge, vertically centred — thumb-reachable, and it
	# never overlaps the canvas centre where the vertices are.
	_ptops.position = Vector2(0.0, (sz.y - STRIP_H * 2.0) * 0.5)
	# Left edge, above the point-ops stack: clear of the bar, the pill and the hint.
	_btn_guides.position = Vector2(0.0, _ptops.position.y - STRIP_H * 1.5)
	_btn_checker.position = Vector2(0.0, _btn_guides.position.y - STRIP_H)
	# Nudge pad: right edge, vertically centred (the pill is bottom-centre, the
	# hint top). Flipped, it docks just right of the ADD PT / DEL PT stack.
	var pad_sz := _pad.get_combined_minimum_size()
	_pad.position = Vector2(_ptops.size.x + 16.0 if _pad_left else sz.x - pad_sz.x - 16.0,
		(sz.y - pad_sz.y) * 0.5)


# --- modes / actions -----------------------------------------------------

func _set_mode(m: String) -> void:
	_mode = "reshape" if _mode == m else m   # tapping the active mode returns to reshape
	# XFORM is direct canvas manipulation -> full-screen, like drawing.
	if _mode == "transform":
		_enter_fullscreen(false)
	_op = ""
	_update_radio()
	state_changed.emit()
	match _mode:
		"transform": _hint.text = "DRAG INSIDE=MOVE · CORNER=SCALE · TOP HANDLE=ROTATE"
		"delpt": _hint.text = "TAP A VERTEX TO DELETE IT (MIN 3 POINTS)"
		"addpt": _hint.text = "TAP AN EDGE TO ADD A POINT THERE"
		_: _hint.text = "DRAG A VERTEX HANDLE · 2-FINGER PAN/ZOOM · 2×TAP FIT"
	queue_redraw()


# Radio styling: the active mode's cell gets the M8 active-cell treatment —
# green border + green text; inactive cells fall back to the shared theme.
func _update_radio() -> void:
	if _btn_add == null:
		return
	_style_radio(_btn_add, _drawing)
	_style_radio(_btn_edit, _edit)
	_style_radio(_btn_transform, _mode == "transform")
	_style_radio(_btn_addpt, _mode == "addpt")
	_style_radio(_btn_delpt, _mode == "delpt")


func _style_radio(b: Button, on: bool) -> void:
	if b == null:
		return
	if on:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color.BLACK
		sb.set_border_width_all(2)
		sb.border_color = M8_GREEN
		for st in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(st, sb)
		b.add_theme_color_override("font_color", M8_GREEN)
	else:
		for st in ["normal", "hover", "pressed", "focus"]:
			b.remove_theme_stylebox_override(st)
		b.remove_theme_color_override("font_color")


func _start_draw() -> void:
	_enter_fullscreen(true)
	_drawing = true
	_draft = PackedVector2Array()
	_selected = -1
	_picker.visible = false
	_sync_selected()
	_update_radio()
	_hint.text = "TAP TO PLACE A POINT — HOLD AND SLIDE TO AIM IT · TAP THE FIRST POINT TO CLOSE"
	queue_redraw()


func _cycle_fx() -> void:
	if _selected == -1 or effect_names.is_empty():
		return
	comp.set_effect(_selected, (comp.get_effect(_selected) + 1) % effect_names.size())
	_update_fx_label()


# Destructive pair — both confirmed via the in-app M8Dialog (red accent).

func _delete_selected() -> void:
	if _selected == -1:
		_hint.text = "TAP A MASK FIRST, THEN DELETE"
		return
	M8Dialog.confirm(self, "DELETE MASK", "REMOVE THE SELECTED MASK?",
		"DELETE", _do_delete, M8_RED)


func _do_delete() -> void:
	if _selected == -1:
		return
	comp.remove_region(_selected)
	_selected = -1
	_sync_selected()
	_stripes_dirty = true
	queue_redraw()


func _clear_all() -> void:
	var n := comp.region_count()
	if n == 0:
		return
	M8Dialog.confirm(self, "CLEAR ALL MASKS", "REMOVE ALL %d MASKS?" % n,
		"CLEAR", _do_clear, M8_RED)


func _do_clear() -> void:
	comp.clear()
	_selected = -1
	_drawing = false
	_draft = PackedVector2Array()
	_picker.visible = false
	_sync_selected()
	_stripes_dirty = true
	queue_redraw()


## Enter the clean full-screen canvas: hide the toolbar AND the deck chrome,
## show the bottom-centre ESC/DONE pill. The hint stays only while drawing.
func _enter_fullscreen(drawing: bool) -> void:
	if _fullscreen:
		return
	_fullscreen = true
	_snap = _snapshot_regions()
	_bar.visible = false
	_picker.visible = false
	_sets.visible = false
	_ptops.visible = false   # EDIT re-shows it right after entering
	_pad.visible = false     # …and this
	_hint.visible = drawing
	_position_hint()
	_chrome.set_active(true)
	state_changed.emit()
	deck_chrome.emit(false)
	queue_redraw()


## Leave full-screen. `revert` (ESC) rolls the mask geometry back to the
## snapshot taken on entry; DONE keeps whatever was changed.
func _exit_fullscreen(revert: bool) -> void:
	if not _fullscreen:
		return
	if revert:
		_restore_regions(_snap)
	_fullscreen = false
	_drawing = false
	_draft = PackedVector2Array()
	_op = ""
	_drag_vert = -1
	_edit = false
	_mode = "reshape"
	_ptops.visible = false
	_pad.visible = false
	_stop_nudge()
	_update_radio()
	_bar.visible = true
	_hint.visible = true
	_hint.text = "TAP A MASK TO SELECT · 2-FINGER PAN/ZOOM · 2×TAP FIT"
	_position_hint()
	_chrome.set_active(false)
	# NOT deck_chrome.emit(true): the deck's bars stay hidden until the editor
	# itself closes — they covered the top of the picture.
	_stripes_dirty = true
	_sync_selected()
	queue_redraw()


## Geometry snapshot used by the full-screen ESC (points + content transform).
## Rotation is included because XFORM's rotate bumps it (content rides with the
## shape), so an ESC that restored points but not rotation would leave the
## content turned relative to a mask that had gone back.
func _snapshot_regions() -> Array:
	var out: Array = []
	for i in comp.region_count():
		out.append({
			"points": comp.get_points(i).duplicate(),
			"offset": comp.get_content_offset(i),
			"scale": comp.get_content_scale(i),
			"rotation": comp.get_content_rotation(i),
			"pivot": comp.get_content_pivot(i),
			"geo_scale": comp.get_geo_scale(i),
			"geo_rot": comp.get_geo_rot(i),
		})
	return out


func _restore_regions(snap: Array) -> void:
	# A mask ADDED during this session has no snapshot entry -> drop it.
	while comp.region_count() > snap.size():
		comp.remove_region(comp.region_count() - 1)
	for i in mini(snap.size(), comp.region_count()):
		var e: Dictionary = snap[i]
		comp.set_points(i, e["points"])
		comp.set_content_offset(i, e["offset"])
		comp.set_content_scale(i, e["scale"])
		comp.set_content_rotation(i, e["rotation"])
		comp.set_content_pivot(i, e["pivot"])
		# set_points() re-bakes the geometry but not the cumulative bookkeeping.
		comp.restore_geo(i, e["geo_scale"], e["geo_rot"])
	if _selected >= comp.region_count():
		_selected = -1
	_stripes_dirty = true


## Android BACK inside the mask editor (S24 §3). Unwinds ONE level per press —
## picker, the full-screen canvas, then the editor itself — so BACK is
## the mirror of how the performer got in.
##
## ⚠️ Leaving is DONE, never ESC: BACK keeps the masks that are on screen, where ESC
## would reload regions.cfg and discard the whole session. An unfinished draft polygon
## IS dropped (by _exit_fullscreen), which is right — it was never a mask.
func handle_back() -> void:
	if _picker != null and _picker.visible:
		_picker.visible = false
		return
	if _fullscreen:
		_exit_fullscreen(false)
		return
	_done()


# DONE = commit the masks to disk, then leave.
func _done() -> void:
	_save()
	set_active(false)
	closed.emit()


# ESC = discard every change made this session by reloading the last committed
# state from regions.cfg (clear first — load_saved APPENDS).
func _esc() -> void:
	_selected = -1
	comp.clear()
	load_saved()
	_sync_selected()
	set_active(false)
	closed.emit()


# --- mask sets -----------------------------------------------------------

func _build_sets() -> void:
	_sets = PanelContainer.new()
	_sets.visible = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var title := Label.new()
	title.text = "MASK SETS — SAVE THIS MAPPING, OR BRING ONE BACK"
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)
	for i in SET_COUNT:
		var n := i + 1
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := Label.new()
		l.custom_minimum_size = Vector2(300, STRIP_H)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 20)
		row.add_child(l)
		_sets_rows.append(l)
		for spec in [["SAVE", func(): _ask_save_set(n)], ["LOAD", func(): _ask_load_set(n)]]:
			var b := _make_button(str(spec[0]), spec[1])
			b.size_flags_horizontal = 0
			b.custom_minimum_size = Vector2(150, STRIP_H)
			row.add_child(b)
		box.add_child(row)
	_sets.add_child(box)
	add_child(_sets)


func _set_path(n: int) -> String:
	return "%s/set_%d.cfg" % [SETS_DIR, n]


## How many masks set `n` holds; -1 = the slot is empty.
func set_count_of(n: int) -> int:
	var cfg := ConfigFile.new()
	if cfg.load(_set_path(n)) != OK:
		return -1
	return int(cfg.get_value("regions", "count", 0))


func _refresh_sets() -> void:
	for i in SET_COUNT:
		var c := set_count_of(i + 1)
		_sets_rows[i].text = "SET %d · %s" % [i + 1,
			"EMPTY" if c < 0 else ("%d MASK%s" % [c, "" if c == 1 else "S"])]


func _toggle_sets() -> void:
	_sets.visible = not _sets.visible
	if _sets.visible:
		_picker.visible = false
		_refresh_sets()
		_layout()


func _ask_save_set(n: int) -> void:
	if comp.region_count() == 0:
		_hint.text = "NO MASKS TO SAVE"
		return
	if set_count_of(n) >= 0:
		M8Dialog.confirm(self, "OVERWRITE SET %d" % n,
			"SET %d ALREADY HOLDS A MAPPING. REPLACE IT WITH THE %d MASKS ON SCREEN?"
				% [n, comp.region_count()], "OVERWRITE", func(): save_set(n), M8_RED)
	else:
		save_set(n)


func _ask_load_set(n: int) -> void:
	if set_count_of(n) < 0:
		_hint.text = "SET %d IS EMPTY" % n
		return
	if comp.region_count() == 0:
		load_set(n)
		return
	M8Dialog.confirm(self, "LOAD SET %d" % n,
		"REPLACE THE %d MASKS ON SCREEN WITH SET %d? SAVE THEM TO A SET FIRST IF YOU WANT THEM BACK."
			% [comp.region_count(), n], "LOAD", func(): load_set(n), M8_RED)


## The mapping on screen into set `n`: regions.cfg is brought up to date first,
## then its region sections are copied out.
func save_set(n: int) -> bool:
	_save()
	var src := ConfigFile.new()
	if src.load(SAVE_PATH) != OK:
		return false
	var out := ConfigFile.new()
	for sec in src.get_sections():
		if sec == "regions" or sec.begins_with("region_"):
			for k in src.get_section_keys(sec):
				out.set_value(sec, k, src.get_value(sec, k))
	DirAccess.make_dir_recursive_absolute(SETS_DIR)
	if out.save(_set_path(n)) != OK:
		_hint.text = "COULD NOT SAVE SET %d" % n
		return false
	_hint.text = "SET %d SAVED · %d MASKS" % [n, comp.region_count()]
	_refresh_sets()
	return true


## Set `n` replaces the mapping on screen. regions.cfg's region sections are
## swapped for the set's (the image mask and the guides choice stay), then the
## ordinary loader rebuilds the masks from it — one loader, one format.
func load_set(n: int) -> bool:
	var src := ConfigFile.new()
	if src.load(_set_path(n)) != OK:
		return false
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	for sec in cfg.get_sections():
		if sec == "regions" or sec.begins_with("region_"):
			cfg.erase_section(sec)
	for sec in src.get_sections():
		for k in src.get_section_keys(sec):
			cfg.set_value(sec, k, src.get_value(sec, k))
	cfg.save(SAVE_PATH)
	_do_clear()
	load_saved()
	_sets.visible = false
	_hint.text = "SET %d LOADED · %d MASKS" % [n, comp.region_count()]
	return true


## FIT: the selected mask's warp taken from its own corners, so the clip sits
## on the face in its perspective instead of lying flat over the mask's box
## (RegionCompositor.fit_warp_to_mask has the 4- and 3-point cases). A warp
## that was already adjusted by hand is asked about before it is replaced.
func _fit_warp() -> void:
	if not _require_selection("FIT"):
		return
	var n := comp.get_points(_selected).size()
	if n != 3 and n != 4:
		_hint.text = "FIT NEEDS A MASK WITH 3 OR 4 POINTS (THIS ONE HAS %d)" % n
		return
	if comp.warp_is_plain(_selected):
		_do_fit()
	else:
		M8Dialog.confirm(self, "FIT WARP", "REPLACE THIS MASK'S WARP WITH ONE FROM ITS CORNERS?",
			"FIT", _do_fit)


func _do_fit() -> void:
	if _selected == -1 or not comp.fit_warp_to_mask(_selected):
		return
	_hint.text = "WARP FITTED TO THE 4 CORNERS — CHECKER SHOWS IT ON THE OBJECT" \
		if comp.get_points(_selected).size() == 4 \
		else "WARP FITTED TO THE TRIANGLE (FLAT — NO PERSPECTIVE FROM 3 POINTS)"
	queue_redraw()


# --- clip picker ---------------------------------------------------------

func _open_picker() -> void:
	if _selected == -1:
		_hint.text = "SELECT A MASK FIRST, THEN TAP VIDEO"
		return
	_fill_picker()
	_picker.visible = true
	_hint.text = "TAP CLIPS TO LIST THEM · NEXT STEPS THROUGH · TAP A LISTED ONE TO REMOVE IT"
	_layout()


## The picker IS the list editor: it stays open while clips are added, and
## each row shows where it sits in the mask's list ([n]) and which one plays (►).
## Tap outside to close (as before).
func _fill_picker() -> void:
	for c in _picker_vbox.get_children():
		c.queue_free()
	# "" = Follow deck: the mask samples the live deck texture, so it auto-advances
	# through clips with whatever mode is active (Sequential/Random/LFO/Manual).
	# It also clears the mask's list.
	_picker_vbox.add_child(_make_picker_row("FOLLOW DECK (LIVE · ALL MODES)", func(): _pick("")))
	var list := comp.get_clip_list(_selected)
	var playing := comp.get_clip(_selected)
	var paths: Array = []
	if clip_list_provider.is_valid():
		paths = clip_list_provider.call()
	for p: String in paths:
		var path := p
		var at := list.find(path)
		var tag := ""
		if at >= 0:
			tag = "[%d] " % (at + 1)
		if path == playing:
			tag = "► " + tag
		_picker_vbox.add_child(_make_picker_row(tag + path.get_file(), func(): _pick(path)))


func _pick(path: String) -> void:
	if _selected == -1:
		_picker.visible = false
		return
	if path == "":
		comp.set_clip(_selected, "")
		_hint.text = "MASK FOLLOWS THE DECK (AUTO-SEQUENCE)"
		_picker.visible = false
		return
	var list := comp.get_clip_list(_selected)
	if list.has(path) or (list.is_empty() and comp.get_clip(_selected) == path):
		if list.is_empty():
			comp.set_clip(_selected, "")   # the one fixed clip, from before lists
		else:
			comp.remove_from_list(_selected, path)
		var left := comp.get_clip_list(_selected).size()
		_hint.text = "REMOVED · %d IN THE LIST" % left if left > 0 else "LIST EMPTY — MASK FOLLOWS THE DECK"
	elif comp.add_to_list(_selected, path):
		var n := comp.get_clip_list(_selected).size()
		_hint.text = "MASK PLAYS %s" % path.get_file() if n == 1 \
			else "%d CLIPS IN THE LIST · NEXT STEPS THROUGH THEM" % n
	_fill_picker()   # stay open: the list is being built


## NEXT: a selected mask steps; with none selected, every mask with its own
## clip steps at once — one tap changes the whole object. A mask steps through
## its LIST if it has one, otherwise to the next clip in the folder (like the
## deck's NEXT), so NEXT is useful before any list is built.
func _next_clip() -> void:
	if comp.follow_deck_all:
		_hint.text = "MASKS ARE SHOWING THE DECK — SWITCH TO LOCAL FIRST"
		return
	if _selected != -1:
		if _step_mask(_selected):
			var list := comp.get_clip_list(_selected)
			_hint.text = "CLIP %d OF %d · %s" % [comp.get_clip_pos(_selected) + 1, list.size(),
				comp.get_clip(_selected).get_file()] if list.size() >= 2 \
				else "NEXT IN THE FOLDER · %s" % comp.get_clip(_selected).get_file()
		else:
			_hint.text = "THIS MASK FOLLOWS THE DECK — GIVE IT A CLIP IN VIDEO"
		return
	var stepped := 0
	for i in comp.region_count():
		if _step_mask(i):
			stepped += 1
	_hint.text = "%d MASK%s STEPPED" % [stepped, "" if stepped == 1 else "S"] if stepped > 0 \
		else "NO MASK HAS ITS OWN CLIP — GIVE ONE A CLIP IN VIDEO"


## One NEXT for mask `i`: its list if it has 2+ clips, else the folder clip
## after the one it plays (wrapping). False = it follows the deck.
func _step_mask(i: int) -> bool:
	if comp.step_clip(i, 1):
		return true
	var cur := comp.get_clip(i)
	if cur == "" or not clip_list_provider.is_valid():
		return false
	var paths: Array = clip_list_provider.call()
	if paths.is_empty():
		return false
	var at := -1
	for k in paths.size():
		if str(paths[k]).get_file() == cur.get_file():   # saved masks rebuild the path
			at = k
			break
	return comp.set_clip(i, str(paths[(at + 1) % paths.size()]))


func _deck_label() -> String:
	return "DECK" if comp != null and comp.follow_deck_all else "LOCAL"


## LOCAL / DECK: every mask shows its own clip, or all of them show the deck.
## Nothing is forgotten — switching back brings each mask's clip (and list) back.
func _toggle_deck() -> void:
	comp.set_follow_deck_all(not comp.follow_deck_all)
	_btn_deck.text = _deck_label()
	_style_radio(_btn_deck, comp.follow_deck_all)
	_hint.text = "ALL MASKS SHOW THE DECK — THEIR OWN CLIPS ARE KEPT" if comp.follow_deck_all \
		else "EACH MASK SHOWS ITS OWN CLIP"


func _on_decoder_limit(limit: int) -> void:
	_hint.text = "MAX %d MASK VIDEOS AT ONCE (PERF CAP) — FREE ONE FIRST" % limit


# --- selection helpers ---------------------------------------------------

func _sync_selected() -> void:
	# A different mask has different points: start its selection again. The
	# same mask keeps its point (this runs after every add/delete too).
	if _selected != _sel_vert_mask:
		_sel_vert_mask = _selected
		_sel_vert = -1 if _selected == -1 else 0
		_sync_point_button()
	_update_fx_label()
	state_changed.emit()


func _update_fx_label() -> void:
	if _btn_fx == null:
		return
	if _selected == -1 or effect_names.is_empty():
		_btn_fx.text = "FX"
	else:
		_btn_fx.text = "FX %s" % effect_names[comp.get_effect(_selected)].to_upper()


## A VIDEO-picker row. NOT a toolbar cell: it must size to its text and stay
## left-aligned. Sharing _make_button() here is exactly what broke the picker —
## the toolbar's `clip_text = true` + EXPAND_FILL drops a Button's minimum width
## to 0, so inside a ScrollContainer every row collapsed to an empty sliver and
## the menu looked like a black panel.
func _make_picker_row(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text.to_upper()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(580, 68)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 20)
	b.pressed.connect(on_press)
	return b


func _make_button(text: String, on_press: Callable, font: int = 20) -> Button:
	var b := Button.new()
	b.text = text.to_upper()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, STRIP_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # even M8 cells
	b.clip_text = true
	b.add_theme_font_size_override("font_size", font)
	b.pressed.connect(on_press)
	return b


# --- drawing guides ------------------------------------------------------

const M8_GREEN := Color(0.0, 1.0, 0.255)   ## #00FF41 (matches pipeline M8 palette)
const M8_YELLOW := Color(1.0, 0.867, 0.0)  ## #FFDD00 — points while a mask is being drawn
const M8_RED := Color(1.0, 0.267, 0.133)   ## #FF4422 — errors / destructive only

# M8 point handle: a SMALL SQUARE, OUTLINE ONLY (no fill) so it never hides the
# footage under the vertex being placed.
func _handle(p: Vector2, size: float, col: Color) -> void:
	var r := Rect2(p - Vector2(size, size), Vector2(size, size) * 2.0)
	draw_rect(r, col, false, 2.0)


# Masked-out stripes: the output area minus every mask polygon, as 45° diagonal
# polylines. Screen-space (constant density at any zoom), cached until geometry
# changes, and skipped while a drag is live (fade-on-edit + free redraw perf).
# EDITOR OVERLAY ONLY — this Control lives on the UI layer, so nothing here can
# ever reach OutputWorld / the projector.
func _rebuild_stripes() -> void:
	_stripes.clear()
	if comp == null:
		return
	# NOTE: in mask mode the compositor owns the output even with ZERO regions
	# (pipeline._enter_masks) — everything outside a mask is black on the
	# projector, so with no masks the WHOLE canvas stripes.
	var xf := _xf()
	var out_sz := _out_size()
	var origin := xf * Vector2.ZERO
	var rect := Rect2(origin, (xf * out_sz) - origin)
	var polys: Array = []
	for i in comp.region_count():
		var pts := _to_screen(comp.get_points(i))
		if pts.size() >= 3:
			polys.append(pts)
	var total := rect.size.x + rect.size.y
	var k := 1
	while k * STRIPE_SPACING < total:
		var d := k * STRIPE_SPACING
		k += 1
		# 45° line from the top edge to the left edge, clamped into the rect.
		var p1 := Vector2(rect.position.x + d, rect.position.y)
		var p2 := Vector2(rect.position.x, rect.position.y + d)
		if p1.x > rect.end.x:
			p1 = Vector2(rect.end.x, rect.position.y + (d - rect.size.x))
		if p2.y > rect.end.y:
			p2 = Vector2(rect.position.x + (d - rect.size.y), rect.end.y)
		var segs: Array = [PackedVector2Array([p1, p2])]
		for poly in polys:
			var nxt: Array = []
			for s in segs:
				nxt.append_array(Geometry2D.clip_polyline_with_polygon(s, poly))
			segs = nxt
			if segs.is_empty():
				break
		_stripes.append_array(segs)


func _draw() -> void:
	if not active or comp == null:
		return
	# Output boundary + masked-out stripes, under everything else.
	var xf0 := _xf()
	var o := xf0 * Vector2.ZERO
	var out_rect := Rect2(o, (xf0 * _out_size()) - o)
	draw_rect(out_rect, Color(0.0, 1.0, 0.255, 0.25), false, 1.0)
	if _op == "":   # hidden only while a drag is live (fade-on-edit)
		if _stripes_dirty:
			_rebuild_stripes()
			_stripes_dirty = false
		for s: PackedVector2Array in _stripes:
			for j in range(s.size() - 1):
				draw_line(s[j], s[j + 1], STRIPE_COLOR, 2.0)
	# Geometry is output px — draw it at its SCREEN position. Handle sizes and
	# stroke widths stay in screen px (touch targets, not geometry).
	for i in comp.region_count():
		var pts := _to_screen(comp.get_points(i))
		if pts.size() < 2:
			continue
		var sel := i == _selected
		# Faint green fill + bright green outline (brighter when selected).
		if pts.size() >= 3:
			draw_colored_polygon(pts, Color(0.0, 1.0, 0.255, 0.06 if sel else 0.03))
		var col := Color(0.0, 1.0, 0.255, 0.95 if sel else 0.5)
		var n := pts.size()
		for k in n:
			draw_line(pts[k], pts[(k + 1) % n], col, 2.0)
		if not sel:
			continue
		if _mode == "transform":
			_draw_transform_box(comp.region_bounds(i))
		else:
			# Del Pt is the one destructive mode -> error red; everything else green.
			var hcol := M8_RED if _mode == "delpt" else M8_GREEN
			for p in pts:
				_handle(p, VERT_RADIUS, hcol)
			# The pad's point: a second, larger square around it (EDIT only —
			# that is where the pad is).
			if _edit and _sel_vert >= 0 and _sel_vert < pts.size():
				_handle(pts[_sel_vert], VERT_RADIUS * 2.2, hcol)
	# Draft polygon being drawn: points + edges are YELLOW (#FFDD00) while the mask
	# is still OPEN, and flip to green the moment it is closed into a real region.
	if _drawing and _draft.size() >= 1:
		var draft := _to_screen(_draft)
		for k in range(draft.size() - 1):
			draw_line(draft[k], draft[k + 1], M8_YELLOW, 2.0)
		for p in draft:
			_handle(p, DRAFT_VERT_RADIUS, M8_YELLOW)
		# The "tap here to close" target on the first point (CLOSE_RADIUS is a
		# screen-px target; the hit test uses _hit_r to match).
		if draft.size() >= 3:
			draw_rect(Rect2(draft[0] - Vector2(CLOSE_RADIUS, CLOSE_RADIUS),
				Vector2(CLOSE_RADIUS, CLOSE_RADIUS) * 2.0), M8_YELLOW, false, 2.0)


func _draw_transform_box(b: Rect2) -> void:
	# b is output-space; rotate stalk is computed in output space (so the hit
	# test in _press_transform lands on the drawn handle), then mapped to screen.
	var xf := _xf()
	var center := b.get_center()
	var rot_pt := Vector2(center.x, b.position.y - ROT_OFFSET)
	var sb := Rect2(xf * b.position, b.size * xf.get_scale())
	draw_rect(sb, Color(0.0, 1.0, 0.255, 0.5), false, 1.0)
	draw_line(xf * Vector2(center.x, b.position.y), xf * rot_pt, M8_GREEN, 2.0)
	_handle(xf * rot_pt, HANDLE_RADIUS, M8_GREEN)
	for c in _rect_corners(b):
		_handle(xf * c, HANDLE_RADIUS, M8_GREEN)


func _to_screen(pts: PackedVector2Array) -> PackedVector2Array:
	var xf := _xf()
	if xf == Transform2D.IDENTITY:
		return pts
	var out := PackedVector2Array()
	for p in pts:
		out.append(xf * p)
	return out


# --- persistence ---------------------------------------------------------

func _area() -> Vector2:
	var s := size
	return s if s.x > 1.0 and s.y > 1.0 else get_viewport_rect().size


func _xf() -> Transform2D:
	return xform_provider.call() if xform_provider.is_valid() else Transform2D.IDENTITY


## The pixel space mask points live in — the normalization basis for
## persistence. Screen size until pipeline injects the fixed output resolution.
func _out_size() -> Vector2:
	return output_size_provider.call() if output_size_provider.is_valid() else _area()


## A screen-px touch radius expressed in output px. Hit tests compare
## output-space positions, but targets must stay finger-sized ON SCREEN.
func _hit_r(screen_r: float) -> float:
	var s: float = _xf().get_scale().x
	return screen_r / s if s > 0.0 else screen_r


## Persist now, without closing. The warp editor calls this when it hands a
## region back, since a region's warp is part of regions.cfg.
func save_now() -> void:
	_save()


func _save() -> void:
	var cfg := ConfigFile.new()
	# Load-then-merge: the raster mask persists in the SAME file ([raster_mask],
	# see MaskOverlay) — a fresh ConfigFile here would wipe it on every DONE.
	# This file has been clobbered twice (autoload wipe, _save() fresh-write);
	# every writer merges, never fresh-writes.
	cfg.load(SAVE_PATH)
	var sz := _out_size()
	cfg.set_value("regions", "count", comp.region_count())
	cfg.set_value("regions", "follow_deck", comp.follow_deck_all)
	for i in comp.region_count():
		var key := "region_%d" % i
		var norm := PackedVector2Array()
		for p in comp.get_points(i):
			norm.append(Vector2(p.x / sz.x, p.y / sz.y))
		cfg.set_value(key, "points", norm)
		cfg.set_value(key, "effect", comp.get_effect(i))
		# The manual-sequence list, keyed like `clip`: the path relative to
		# the clips folder (the bare name at the top level, "sub/name" in a
		# sub-folder — the folder is the deck's, and may be a saf:// tree).
		# Older builds ignore it.
		var clip_key: String = StorageS.node().rel(comp.get_clip(i)) if comp.get_clip(i) != "" else ""
		var names := PackedStringArray()
		for c in comp.get_clip_list(i):
			names.append(StorageS.node().rel(c))
		var kept := _keep_missing_keys(i, clip_key, names)
		cfg.set_value(key, "clip", kept[0])
		cfg.set_value(key, "clips", kept[1])
		cfg.set_value(key, "clip_pos", comp.get_clip_pos(i))
		# The CONTENT TRANSFORM (spec §2 / §2b). ⚠️ Before this increment only
		# `scale` (a float) and `offset` were written: `angle`, `geo_scale` and
		# `geo_rot` were NEVER persisted, so rotating a mask rotated its content
		# and the rotation was silently lost on the next cold start. Everything
		# the transform consists of is written here, or the round-trip in §6
		# cannot pass for any rotated region.
		cfg.set_value(key, "content_scale", comp.get_content_scale(i))
		cfg.set_value(key, "content_offset", comp.get_content_offset(i))
		cfg.set_value(key, "content_rotation", comp.get_content_rotation(i))
		cfg.set_value(key, "content_pivot", comp.get_content_pivot(i))
		cfg.set_value(key, "content_fit", comp.get_content_fit(i))
		# Cumulative mask geometry, for the numeric panel's ABSOLUTE entry. The
		# points already carry the transform; these two are what makes "150%" mean
		# 150% of the authored shape after a restart instead of 100%.
		cfg.set_value(key, "geo_scale", comp.get_geo_scale(i))
		cfg.set_value(key, "geo_rot", comp.get_geo_rot(i))
		# The superseded S15 keys. Left behind they would read as authoritative to
		# a human and to any future reader — and a stale `scale` next to a live
		# `content_scale` is exactly the two-truths trap this file has suffered
		# from before. The loader still READS them (legacy migration), it just
		# never writes them again.
		for legacy in ["scale", "offset", "angle"]:
			if cfg.has_section_key(key, legacy):
				cfg.erase_section_key(key, legacy)
		# Per-region warp (S20). Same serializer as warp.cfg slots, "warp_"
		# prefixed — an unprefixed "offsets" would sit one character from the
		# texture-pan key "offset" above.
		comp.get_warp(i).save_to(cfg, key, sz, "warp_")
		# The rect that warp is expressed in. Without it a reader cannot tell a
		# region-space warp from a frame-space one and would apply it in the
		# wrong space (see RegionCompositor.adopt_warp_domain).
		var dom := comp.warp_domain(i)
		cfg.set_value(key, "warp_domain", Rect2(
			dom.position / sz, dom.size / sz))
	# ⚠️ Erase region sections ABOVE the new count. Until per-region warp these
	# were harmless litter (load_saved trusts "count", and every key a region
	# owned was rewritten on save), and the old comment here said so. They are
	# NOT harmless now: delete one of three regions (count 3->2) then add
	# another (count->3), and the recreated region_2 would inherit the DELETED
	# region's warp keys off disk. Targeted erase, not a fresh write.
	var stale := comp.region_count()
	while cfg.has_section("region_%d" % stale):
		cfg.erase_section("region_%d" % stale)
		stale += 1
	cfg.save(SAVE_PATH)


## After a region is loaded: when any key it stored does not resolve (a clip
## not in PVJ yet), keep the stored keys and what the load made of them, so
## _save() can tell an untouched region from an edited one.
func _remember_missing_keys(cfg: ConfigFile, key: String, idx: int) -> void:
	var clip := str(cfg.get_value(key, "clip", ""))
	var stored := PackedStringArray()
	for nm in cfg.get_value(key, "clips", PackedStringArray()):
		stored.append(str(nm))
	var missing: bool = clip != "" and (clips_dir == "" or StorageS.node().resolve(clips_dir, clip) == "")
	for k in stored:
		if clips_dir == "" or StorageS.node().resolve(clips_dir, k) == "":
			missing = true
	if not missing:
		return
	var loaded := PackedStringArray()
	for c in comp.get_clip_list(idx):
		loaded.append(StorageS.node().rel(c))
	var cur := comp.get_clip(idx)
	comp.set_saved_keys(idx, {"clip": clip, "clips": stored, "loaded": loaded,
		"loaded_clip": StorageS.node().rel(cur) if cur != "" else ""})


## A clip missing from the library never erases a mask's curation (§E): a
## region loaded with keys that did not resolve writes them back. Untouched
## since the load → exactly what was stored; edited → the edit, plus the
## missing keys at the end of its list. FOLLOW DECK (no clip, no list) is a
## deliberate clear and writes nothing back. Returns [clip key, clip keys].
func _keep_missing_keys(i: int, clip_key: String, names: PackedStringArray) -> Array:
	var saved := comp.get_saved_keys(i)
	if saved.is_empty():
		return [clip_key, names]
	var stored: PackedStringArray = saved.get("clips", PackedStringArray())
	if clip_key == str(saved.get("loaded_clip", "")) and names == saved.get("loaded", PackedStringArray()):
		return [str(saved.get("clip", "")), stored]
	if clip_key == "" and names.is_empty():
		return ["", names]
	var out := names.duplicate()
	for k in stored:
		if not out.has(k) and StorageS.node().resolve(clips_dir, k) == "":
			out.append(k)
	return [clip_key, out]


## Restore saved regions. Call deferred so normalized points map to real px.
func load_saved() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	projector_guides = bool(cfg.get_value("guides", "projector", true))
	var sz := _out_size()
	# So a region created below spans the right rect with its identity warp.
	comp.output_size = sz
	var count := int(cfg.get_value("regions", "count", 0))
	comp.set_follow_deck_all(bool(cfg.get_value("regions", "follow_deck", false)))
	for i in count:
		var key := "region_%d" % i
		if not cfg.has_section_key(key, "points"):
			continue
		var norm: PackedVector2Array = cfg.get_value(key, "points")
		var pts := PackedVector2Array()
		for nrm in norm:
			pts.append(Vector2(nrm.x * sz.x, nrm.y * sz.y))
		var idx := comp.add_region(pts)
		comp.set_effect(idx, int(cfg.get_value(key, "effect", 0)))
		var basename := str(cfg.get_value(key, "clip", ""))
		# A list wins over the single clip; entries whose file has gone are
		# dropped (the position follows the clip that was playing if it is left).
		var listed := PackedStringArray()
		var pos := 0
		if clips_dir != "":
			for nm in cfg.get_value(key, "clips", PackedStringArray()):
				# resolve(): a relative key, or a bare name an older save
				# wrote that may now sit in a sub-folder (SAF-aware).
				var f: String = StorageS.node().resolve(clips_dir, str(nm))
				if f != "":
					if str(nm) == basename:
						pos = listed.size()
					listed.append(f)
		if not listed.is_empty():
			comp.set_clip_list(idx, listed, pos)
		elif basename != "" and clips_dir != "":
			var full: String = StorageS.node().resolve(clips_dir, basename)
			if full != "":
				comp.set_clip(idx, full)
		_remember_missing_keys(cfg, key, idx)
		_load_content_transform(cfg, key, idx)
		# THE MIGRATION: a regions.cfg written before per-region warp existed has
		# no warp_ keys, load_from() returns false, and the region keeps the
		# identity warp add_region() gave it — i.e. every existing mask loads as
		# a region with an identity warp and renders exactly as it always did.
		comp.get_warp(idx).load_from(cfg, key, sz, "warp_")
		# A pre-domain file has no warp_domain: its warp spanned the whole frame,
		# which Rect2() signals. adopt_warp_domain() refits it onto the mask box.
		var nd: Rect2 = cfg.get_value(key, "warp_domain", Rect2())
		# ⚠️ This also REBUILDS. load_from() mutates the surface MODEL only, and
		# add_region() already built this region's mesh from the identity warp, so
		# without a rebuild a saved warp survives a restart in regions.cfg but
		# renders flat — the model and the mesh silently disagree.
		comp.adopt_warp_domain(idx, Rect2(nd.position * sz, nd.size * sz))
	_stripes_dirty = true


## Read one region's content transform, tolerating every older shape of it.
##
## THREE GENERATIONS live on disk, and all of them must land on the same
## behaviour they had when they were written:
##  - pre-S15: no keys at all -> the defaults, i.e. the source fitted to the
##    mask's bounding box.
##  - S15..S20: `scale` as a FLOAT plus `offset`. The float is read as
##    Vector2(s, s) (spec §2 item 3) — a uniform zoom is exactly what it meant.
##  - this increment: the `content_*` keys, which win wherever present.
##
## `angle` never made it to disk (that is the §2b bug), so a legacy file cannot
## carry a rotation and the fallback below only exists for symmetry.
func _load_content_transform(cfg: ConfigFile, key: String, idx: int) -> void:
	var legacy_scale := 1.0
	var scale := Vector2.ONE
	if cfg.has_section_key(key, "content_scale"):
		scale = cfg.get_value(key, "content_scale", Vector2.ONE)
	elif cfg.has_section_key(key, "scale"):
		var raw: Variant = cfg.get_value(key, "scale")
		if typeof(raw) == TYPE_VECTOR2:
			scale = raw
		else:
			legacy_scale = float(raw)
			scale = Vector2(legacy_scale, legacy_scale)
	comp.set_content_scale(idx, scale)
	# ⚠️ A legacy `offset` needs CONVERTING, not copying. It was a sampling shift
	# in fit units applied AFTER the scale; content_offset is the content's own
	# displacement in domain fractions applied BEFORE it. Equating the two
	# expressions gives content_offset = -offset * scale exactly (the domain size
	# cancels because a legacy file's fit rect IS its domain). Without this, any
	# region someone had two-finger panned would come back displaced the wrong way
	# and by the wrong amount.
	if cfg.has_section_key(key, "content_offset"):
		comp.set_content_offset(idx, cfg.get_value(key, "content_offset", Vector2.ZERO))
	else:
		var legacy_off: Vector2 = cfg.get_value(key, "offset", Vector2.ZERO)
		comp.set_content_offset(idx, -legacy_off * legacy_scale)
	comp.set_content_rotation(idx, float(cfg.get_value(key, "content_rotation",
		cfg.get_value(key, "angle", 0.0))))
	comp.set_content_pivot(idx, cfg.get_value(key, "content_pivot", Vector2(0.5, 0.5)))
	comp.set_content_fit(idx, int(cfg.get_value(key, "content_fit",
		RegionCompositor.ContentFit.MANUAL)))
	# Bookkeeping only — the points loaded above are already transformed, so this
	# must NOT go through set_geo_scale()/set_geo_rot().
	comp.restore_geo(idx,
		float(cfg.get_value(key, "geo_scale", 1.0)),
		float(cfg.get_value(key, "geo_rot", 0.0)))
