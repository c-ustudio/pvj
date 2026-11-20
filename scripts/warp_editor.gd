class_name WarpEditor
extends Control
## On-screen editor for the QuadWarp output stage.
##
## When active, draws draggable handles on the warp's CONTROL LATTICE; dragging
## one deforms the surface live for projection mapping. Inactive, it ignores
## input entirely so it never blocks the video, control bar, or VU meter.
##
## S19 — the editor is now LATTICE-BASED, not corner-based. QuadWarp presents
## itself as an N×M grid via edit_cols()/edit_rows()/control_point(); QUAD mode
## simply reports a 2×2 lattice whose four points ARE the corners. So there is
## ONE code path for selection, dragging, nudging and numeric entry, and QUAD is
## not a special case — it is the 2×2 member of the family.
##
## S16 precision additions, all inherited by every control point:
##  - a SELECTED point (last grabbed, or cycled from the pad) that the NUDGE PAD
##    moves in coarse/fine steps — the finger no longer has to cover the handle,
##    and points that sit under chrome or off-screen stay reachable;
##  - a NUM panel with per-corner X/Y readout + entry in output px, plus (S19) a
##    row for the selected point when it is not a corner;
##  - a GRID toggle that shows a test grid on the OUTPUT (pipeline renders it
##    into ShaderSlot so it warps with the footage and reaches the projector).
##
## CAM (global warp only) hands over to CalibEditor, which sets the four corners
## from a camera frame and then returns here for hand-tuning and SAVE.
##
## ⚠️ CHROME OCCLUSION (S19). With a lattice, control points land under the
## nudge pad — a 3×3 grid puts its right-edge midpoint dead centre under it.
## That is the exact "handles unreachable under the toolbar" failure the mask UI
## pass fixed, so the pad can be FLIPPED to the other side (the ◄► cell). The
## bottom strip auto-hides on idle, which frees the bottom row the same way.
##
## Warp presets store corner positions and control-point offsets NORMALIZED to
## the output size (so they survive resolution changes) in user://warp.cfg
## across a few slots. Slot 1 is auto-loaded on boot. A pre-S19 slot has no
## grid/offset keys and loads as a flat 2×2 — pixel-identical to before.
##
## EDIT SURFACE / EDIT CONTENT (PER_REGION_WARP_CONTENT_FIT.md §3). While editing
## a REGION the editor has two sub-modes, because aiming a clip at a real object
## needs two independent things — the surface's shape, and how the source sits
## inside it. Warp points are the wrong tool for the second: dragging them to
## reposition a picture changes the shape of the object you already aligned.
##
##  - EDIT SURFACE (default) — everything above. Drag lattice points.
##  - EDIT CONTENT — the lattice is not drawn and cannot be grabbed, so a drag can
##    only mean "move the content". The nudge pad and NUM entry RETARGET onto the
##    content transform rather than the editor gaining a second set of controls.
##
## ⚠️ THE MODE IS THE DISAMBIGUATOR, and what is DRAWN is what communicates it.
## There is no gesture conflict to arbitrate and no proximity heuristic (those are
## exactly what goes wrong on a phone): the handles simply are not there in EDIT
## CONTENT, so nothing looks draggable-as-geometry. The pair that IS drawn says
## which is which — DASHED bounds stay put (the surface), a SOLID rect moves
## inside them (the content).
##
## The global output warp has no content transform, so the CONTENT cell exists
## only while a region is targeted.

signal closed
signal slot_changed(slot: int)
signal grid_toggled(on: bool)
## Mode/density changed — the deck's WRP cell mirrors it (as MSK does for masks).
signal state_changed
## CAM pressed: set this warp's corners from the camera (CalibEditor). The
## pipeline owns that flow — it needs the lens and the output, this does not.
signal camera_requested

const SAVE_PATH := "user://warp.cfg"
const SLOT_COUNT := 6
const GRAB_RADIUS := 150.0     ## touch grab radius CEILING (~250 device px)
const MIN_GRAB := 44.0         ## …and its floor, so a dense lattice stays finger-sized
## The deck chrome (nav bar + status bar) is hidden while warp mode is open, so
## the strip can sit flush on the bottom edge. Thin, because it auto-hides.
const STRIP_H := 56.0

const CORNER_NAMES: Array[String] = ["TL", "TR", "BR", "BL"]   ## quad corner order
const NUDGE_COARSE := 10.0     ## output px per step
const NUDGE_FINE := 1.0
## Rotation has no px, so the step toggle maps onto degrees for the ROT pad target.
const ROT_COARSE := 1.0        ## degrees per step
const ROT_FINE := 0.1
## What the nudge pad's arrows drive in EDIT CONTENT. Cycled by the pad's centre
## cell, which in EDIT SURFACE cycles the selected control point instead.
## ⚠️ adb cannot do multitouch, so pinch is hands-only and the pad is the only
## verifiable route to a scale or a rotation — hence all three live here rather
## than scale/rotate being gesture-only (spec §6).
enum PadTarget { MOVE, SCALE, ROT }
const PAD_TARGET_NAMES: Array[String] = ["MOVE", "SCALE", "ROT"]
const REPEAT_DELAY := 0.4      ## hold-to-repeat: first repeat after this…
const REPEAT_SEC := 0.06       ## …then one step per interval
const PAD_BTN := 96.0          ## nudge pad cell size (finger target)
## Lattice line samples per control cell — the surface between two control
## points is curved, so the overlay traces it instead of drawing a chord.
const LINE_SAMPLES := 8

## The surface being edited — the GLOBAL output warp by default, or a REGION's
## warp once one is selected (S20). The editor only ever touches the WarpSurface
## contract, so it does not know or care which it has; `_on_changed` is how the
## owner re-renders afterwards (QuadWarp.rebuild, or RegionCompositor.rebuild_region).
var surface: WarpSurface
var _on_changed: Callable = Callable()
## Preset slots are a GLOBAL-warp concept (warp.cfg aligns the whole projection).
## A region's warp is persisted with the region in regions.cfg instead, so the
## SLOT/SAVE/LOAD cells are hidden while editing one.
var _slots_enabled: bool = true
## The region's warp DOMAIN in output px, drawn so the extent being mapped is
## visible while the handles are dragged. Empty Rect2 = the global warp, which
## spans the whole output and needs no separate outline.
var bounds: Rect2 = Rect2()
var active: bool = false
## Output-space seam. The editor overlays the PHONE screen, but the quad it
## edits lives in output space (the OutputWorld SubViewport once the pipeline
## moves there). pipeline injects these; unset they behave as identity, i.e.
## output space == screen space (the pre-OutputWorld world).
var xform_provider: Callable = Callable()        ## -> Transform2D, output -> screen
var output_size_provider: Callable = Callable()  ## -> Vector2, output pixel size
var _grabbed: Dictionary = {}       ## pointer id (touch index, or -1 for mouse) -> control index
var _grab_offset: Dictionary = {}   ## pointer id -> Vector2 (point - touch pos at grab)
var _use_mouse: bool = true         ## desktop only — off on touch devices (avoids double-grab)
var _slot: int = 1

# --- EDIT CONTENT (§3) ----------------------------------------------------
## The region whose CONTENT transform this editor can also edit. Null for the
## global output warp, which has no content transform — the sub-mode does not
## exist there.
var _content: RegionCompositor = null
var _content_index: int = -1
var _content_mode: bool = false      ## false = EDIT SURFACE (the default)
var _pad_target: int = PadTarget.MOVE
## One-finger content pan. Deliberately NOT reusing _grabbed: nothing is grabbed
## in EDIT CONTENT, and a sentinel "control index" there would be a lie that the
## draw code would have to know about.
var _pan_id: int = 0
var _pan_active: bool = false
var _pan_last: Vector2 = Vector2.ZERO    ## output px
## Pinch/two-finger pan, and the single-finger lockout that stops a lifted finger
## snapping the content (shared with the mask editor — see TouchGestures).
var _gest := TouchGestures.new()

## The control point the nudge pad + NUM panel act on (flat lattice index).
## Any grab selects; the pad's centre cell cycles (the only way to reach a point
## that sits under chrome or off-screen).
var _sel_point: int = 0
var _fine: bool = false             ## nudge step: false = 10 px, true = 1 px
var _grid_on: bool = false
var _pad_left: bool = false         ## nudge pad docked left instead of right
var _nudge_dir: Vector2 = Vector2.ZERO   ## held pad direction (ZERO = none)
var _repeat_wait: float = 0.0

var _bar: HBoxContainer
var _btn_slot: Button
var _btn_save: Button
var _btn_load: Button
var _btn_grid: Button
var _btn_cam: Button                 ## camera keystone — global warp only
var _btn_mode: Button                ## QUAD / MESH
var _btn_density: Button             ## 2x2 … 8x8
var _hint: Label
var _chrome: M8EditorChrome
var _pad: VBoxContainer             ## nudge cluster: D-pad + step toggle
var _btn_point: Button              ## pad centre: shows + cycles the selection
var _btn_step: Button
var _numbers: PanelContainer
var _num_x: Array[LineEdit] = []    ## one X/Y pair per corner
var _num_y: Array[LineEdit] = []
var _sel_row: Array[Control] = []   ## selected-point NUM row (label, X, Y)
var _sel_label: Button
var _sel_x: LineEdit
var _sel_y: LineEdit
var _btn_content: Button            ## EDIT SURFACE <-> EDIT CONTENT
var _btn_fit: Button                ## content fit mode (EDIT CONTENT only)
## A SECOND numeric panel, for the content transform. Separate from the surface
## one rather than a mode inside it: the two share no rows, and rebuilding one
## grid in place is how a stale field ends up writing to the wrong parameter.
var _cnum: PanelContainer
var _cnum_fields: Dictionary = {}   ## key -> LineEdit
## The whole warp state as it was when warp mode was ENTERED — ESC restores it.
var _snapshot: Dictionary = {}
## …and the same for the region's CONTENT transform. ⚠️ Separate values because
## they live in different objects (WarpSurface vs RegionCompositor), but they must
## be captured and restored TOGETHER: ESC promises the editor is left as it was
## found, and an ESC that put the surface back while silently keeping content
## moves would be a worse lie than not offering ESC at all.
var _content_snapshot: Dictionary = {}


func setup(target: QuadWarp) -> void:
	target_global(target)
	_use_mouse = not OS.has_feature("mobile")   # touch on device, mouse on desktop
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # transparent to input when idle
	set_process(false)                           # only runs while a nudge is held
	# ⚠️ A pinch may ONLY begin in EDIT CONTENT. EDIT SURFACE supports several
	# fingers on several handles at once by design, and a pinch there would steal
	# them — the mode is what arbitrates, exactly as it does for the drag.
	_gest.can_begin = func() -> bool:
		return _content_mode and _content != null
	_build_bar()
	_build_pad()
	_build_numbers()
	_build_content_numbers()
	# Minimal floating chrome: ESC/DONE pill + auto-hiding bottom strip. The hint
	# rides with the strip so an idle canvas is completely clean.
	_chrome = M8EditorChrome.new()
	add_child(_chrome)
	_chrome.setup(_bar, [_hint] as Array[Control])
	_chrome.esc_pressed.connect(_esc_pressed)
	_chrome.done_pressed.connect(_done_pressed)
	_retarget()   # the bar did not exist during setup()'s first target_global()


# --- retargeting (S20) ---------------------------------------------------
# The editor is a lattice editor, not a QuadWarp editor. Pointing it at a
# region's surface is the whole per-region warp UI — every existing affordance
# (drag, nudge pad, NUM entry, density, QUAD/MESH) comes along unchanged.

## Edit the GLOBAL output warp — the outer level of the two-level model.
func target_global(q: QuadWarp) -> void:
	surface = q.surface
	_on_changed = q.rebuild
	_slots_enabled = true
	bounds = Rect2()   # the global warp IS the frame; no inner extent to show
	# The global output warp has no content transform. Clearing this is what makes
	# the CONTENT cell disappear — and leaving the sub-mode ON here would point the
	# pad and NUM at a region that is no longer being edited.
	_content = null
	_content_index = -1
	_content_mode = false
	_retarget()


## Edit one REGION's warp — the inner level. Content bends within the region's
## mask, which stays put.
func target_region(comp: RegionCompositor, index: int) -> void:
	surface = comp.get_warp(index)
	_on_changed = comp.rebuild_region.bind(index)
	_slots_enabled = false
	bounds = comp.warp_domain(index)
	_content = comp
	_content_index = index
	_content_mode = false   # always arrive on the surface; CONTENT is a deliberate step
	_retarget()


## Whatever just changed, tell the owner to re-render.
func _changed() -> void:
	if _on_changed.is_valid():
		_on_changed.call()


func _retarget() -> void:
	if _btn_slot != null:
		_btn_slot.visible = _slots_enabled
		_btn_save.visible = _slots_enabled
		_btn_load.visible = _slots_enabled
		# The camera solves where the PROJECTOR lands, which is the global warp's
		# job. A region's warp lives inside that aligned frame.
		_btn_cam.visible = _slots_enabled
	if surface == null or _bar == null:
		return
	_snapshot = surface.capture_state()
	_content_snapshot = _capture_content()
	_clamp_selection()
	_sync_mode_buttons()
	_sync_content_buttons()
	_layout_widgets()
	_refresh_numbers()
	queue_redraw()


## Which cells belong to which sub-mode. The surface controls are HIDDEN in EDIT
## CONTENT rather than left inert: a QUAD/MESH cell that does nothing would read
## as broken, and hiding them is the same signal as hiding the handles.
func _sync_content_buttons() -> void:
	if _btn_content == null:
		return
	_btn_content.visible = _content != null
	_style_toggle(_btn_content, _content_mode)
	_btn_mode.visible = not _content_mode
	_btn_density.visible = not _content_mode
	_btn_fit.visible = _content_mode
	if _btn_point != null:
		_btn_point.text = PAD_TARGET_NAMES[_pad_target] if _content_mode \
			else _point_name(_sel_point)
	_sync_fit_button()


# --- activation ----------------------------------------------------------

func set_active(on: bool) -> void:
	active = on
	mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	_bar.visible = on
	_hint.visible = on
	_pad.visible = on
	_chrome.set_active(on)
	if on:
		# Snapshot for ESC before the user can move anything — both halves.
		_snapshot = surface.capture_state()
		_content_snapshot = _capture_content()
		_clamp_selection()
		_sync_mode_buttons()
		_sync_content_buttons()
		_layout_widgets()
		_refresh_numbers()
	else:
		_grabbed.clear()
		_grab_offset.clear()
		_pan_active = false
		_gest.reset()
		_numbers.visible = false
		_cnum.visible = false
		_stop_nudge()
		if _grid_on:   # never leave the test grid on stage after editing
			_grid_on = false
			_style_toggle(_btn_grid, false)
			# …except a REGION's checker: this editor hands back to the mask
			# editor, which is still mapping and turns the checker off itself
			# when it closes.
			if _content == null:
				grid_toggled.emit(false)
	queue_redraw()


# --- control-point dragging ----------------------------------------------
# Uses RAW touch (InputEventScreenTouch/Drag) so it's reliable on Android — one
# finger per point, tracked by pointer index. Mouse is a desktop-only fallback
# (ignored once any real touch is seen). Grab is relative so the handle doesn't
# jump to the finger.

func _gui_input(event: InputEvent) -> void:
	if not active:
		return
	# A live pinch owns all input, and the finger left over when one lifts must not
	# land as a one-finger content pan (TouchGestures.cool).
	if _gest.eats_input():
		accept_event()
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			_try_grab(event.index, event.position)
		else:
			_release(event.index)
		return

	if event is InputEventScreenDrag:
		_drag(event.index, event.position)
		return

	# Desktop mouse (disabled on touch devices to avoid a redundant second grab).
	if _use_mouse:
		if event is InputEventMouseButton:
			if event.pressed:
				_try_grab(-1, event.position)
			else:
				_release(-1)
		elif event is InputEventMouseMotion:
			_drag(-1, event.position)


func _try_grab(id: int, pos: Vector2) -> void:
	# ⚠️ A NO-OP ON THE LATTICE IN EDIT CONTENT (spec §3). Nothing is grabbable, so
	# a drag has exactly one possible meaning — move the content. This is what
	# makes the two sub-modes incapable of cross-triggering from one drag, with no
	# proximity test to get wrong.
	if _content_mode:
		if _content == null:
			return
		_pan_active = true
		_pan_id = id
		_pan_last = _xf().affine_inverse() * pos
		accept_event()
		return
	var c := _nearest_point(pos)
	if c == -1:
		return
	_grabbed[id] = c
	_select_point(c)
	# Grab offset lives in OUTPUT space (point minus finger, both output px).
	_grab_offset[id] = surface.control_point(c) - _xf().affine_inverse() * pos
	queue_redraw()
	accept_event()


func _drag(id: int, pos: Vector2) -> void:
	if _content_mode:
		if not _pan_active or id != _pan_id or _content == null:
			return
		var cur := _xf().affine_inverse() * pos
		_move_content(cur - _pan_last)   # 1:1 in output px — see _uv_at
		_pan_last = cur
		accept_event()
		return
	if not _grabbed.has(id):
		return
	surface.set_control_point(_grabbed[id], _xf().affine_inverse() * pos + _grab_offset[id])
	_changed()
	_refresh_numbers()
	queue_redraw()
	accept_event()


func _release(id: int) -> void:
	if _pan_active and id == _pan_id:
		_pan_active = false
		queue_redraw()
		accept_event()
		return
	if _grabbed.erase(id):
		_grab_offset.erase(id)
		queue_redraw()
		accept_event()


# Multi-touch tracking for the EDIT CONTENT pinch. RAW input, because _gui_input
# cannot be trusted with pointer index >= 1 (the same reason the mask editor does
# this). ⚠️ Only ever engages in EDIT CONTENT: EDIT SURFACE deliberately supports
# several fingers on several handles at once, and a pinch there would steal them.
func _input(event: InputEvent) -> void:
	if not active or _content == null:
		return
	if event is InputEventScreenTouch:
		if _gest.touch(event.index, event.pressed, event.position):
			_pan_active = false   # a one-finger pan in progress yields to the pinch
	elif event is InputEventScreenDrag and _gest.active:
		if _gest.drag(event.index, event.position):
			_apply_pinch()
		get_viewport().set_input_as_handled()


## Pinch = uniform content zoom, two-finger drag = content pan. Both go through
## the same 1:1 output-px seam as the drag and the pad.
func _apply_pinch() -> void:
	if _content == null:
		return
	_content.set_content_scale(_content_index,
		_content.get_content_scale(_content_index) * _gest.zoom_ratio)
	_move_content(_xf().affine_inverse().basis_xform(_gest.pan_delta))
	_refresh_numbers()
	queue_redraw()


## Displace the content by a vector in OUTPUT px. The stored parameter is a
## fraction of the region's DOMAIN (stable across fit modes and mask reshapes), so
## this is the one place that conversion lives.
func _move_content(delta_out: Vector2) -> void:
	if _content == null:
		return
	var dom := _content.warp_domain(_content_index)
	if dom.size.x <= 0.0 or dom.size.y <= 0.0:
		return
	_content.set_content_offset(_content_index,
		_content.get_content_offset(_content_index) + delta_out / dom.size)
	_refresh_numbers()
	queue_redraw()


## Touch target for a control point, in SCREEN px. Capped at just under half the
## neighbour spacing so a dense lattice can never grab across a neighbour, and
## floored at MIN_GRAB so it stays a finger — at 8×8 on the Pixel 8 the spacing
## is ~165 screen px horizontally and ~93 vertically, which without this would
## make every tap ambiguous.
func _grab_radius() -> float:
	var cols := surface.edit_cols()
	var rows := surface.edit_rows()
	var out := _out_size()
	var s: Vector2 = _xf().get_scale()
	var step_x := out.x / float(maxi(1, cols - 1)) * absf(s.x)
	var step_y := out.y / float(maxi(1, rows - 1)) * absf(s.y)
	return clampf(minf(step_x, step_y) * 0.45, MIN_GRAB, GRAB_RADIUS)


func _nearest_point(pos: Vector2) -> int:
	# Hit-test in SCREEN space so the radius stays a finger-sized target
	# regardless of the preview scale.
	var xf := _xf()
	var best := -1
	var best_d := _grab_radius()
	for i in surface.point_count():
		var d := pos.distance_to(xf * surface.control_point(i))
		if d < best_d:
			best_d = d
			best = i
	return best


# --- selection + nudge pad ------------------------------------------------

func _point_name(idx: int) -> String:
	var c := surface.corner_of_index(idx)
	if c >= 0:
		return CORNER_NAMES[c]
	var cols := surface.edit_cols()
	return "R%dC%d" % [floori(float(idx) / float(cols)) + 1, idx % cols + 1]


## Flat lattice index of a quad corner (TL/TR/BR/BL), whatever the density.
func _index_of_corner(c: int) -> int:
	var cols := surface.edit_cols()
	var rows := surface.edit_rows()
	match c:
		1: return cols - 1
		2: return rows * cols - 1
		3: return (rows - 1) * cols
	return 0


## Re-point the selection after the lattice size changed. A flat index means a
## different POINT at a different density, so a corner selection is kept as that
## corner; anything else falls back to TL rather than jumping somewhere random.
func _reselect(keep_corner: int) -> void:
	if keep_corner >= 0:
		_select_point(_index_of_corner(keep_corner))
	else:
		_select_point(0)


func _clamp_selection() -> void:
	_sel_point = clampi(_sel_point, 0, maxi(0, surface.point_count() - 1))


func _select_point(i: int) -> void:
	_sel_point = clampi(i, 0, maxi(0, surface.point_count() - 1))
	if _btn_point != null:
		_btn_point.text = _point_name(_sel_point)
	_refresh_numbers()
	queue_redraw()


## The pad's centre cell. In EDIT SURFACE it cycles the selected control point (the
## only way to reach one that sits under chrome or off-screen); in EDIT CONTENT
## there is no selection, so it cycles what the arrows DRIVE instead.
func _cycle_point() -> void:
	if _content_mode:
		_pad_target = (_pad_target + 1) % PAD_TARGET_NAMES.size()
		_btn_point.text = PAD_TARGET_NAMES[_pad_target]
		_hint.text = _pad_hint()
		return
	var n := surface.point_count()
	if n <= 0:
		return
	_select_point((_sel_point + 1) % n)
	_hint.text = "POINT %s SELECTED" % _point_name(_sel_point)


func _pad_hint() -> String:
	match _pad_target:
		PadTarget.SCALE:
			return "PAD SCALES CONTENT · ◄► X · ▲▼ Y"
		PadTarget.ROT:
			return "PAD ROTATES CONTENT · ►▲ CW · ◄▼ CCW · %.1f°" % _rot_step()
		_:
			return "PAD MOVES CONTENT · %d PX PER STEP" % int(_nudge_step())


func _nudge_step() -> float:
	return NUDGE_FINE if _fine else NUDGE_COARSE


func _rot_step() -> float:
	return ROT_FINE if _fine else ROT_COARSE


func _nudge(dir: Vector2) -> void:
	if _content_mode:
		_nudge_content(dir)
		return
	surface.set_control_point(_sel_point,
		surface.control_point(_sel_point) + dir * _nudge_step())
	_changed()
	_refresh_numbers()
	queue_redraw()


## The pad, retargeted onto the content transform. Steps stay in OUTPUT PX for
## MOVE — the same units the surface nudge uses, and honest because a move is 1:1
## whatever the scale and rotation (see RegionCompositor._uv_at).
func _nudge_content(dir: Vector2) -> void:
	if _content == null:
		return
	var i := _content_index
	match _pad_target:
		PadTarget.MOVE:
			_move_content(dir * _nudge_step())
		PadTarget.SCALE:
			# Per-axis, so STRETCH is reachable from the pad and not only from NUM.
			# The factor is derived from the px step against the domain, so one tap
			# moves the content's edge by roughly that many px at any zoom.
			var dom := _content.warp_domain(i)
			var step := _nudge_step()
			var f := Vector2(1.0 + dir.x * step / dom.size.x,
				1.0 - dir.y * step / dom.size.y)
			_content.set_content_scale(i, _content.get_content_scale(i) * f)
		PadTarget.ROT:
			# Up and right increase the angle; y is negated because screen-up is -y.
			var d := (dir.x - dir.y) * deg_to_rad(_rot_step())
			_content.set_content_rotation(i, _content.get_content_rotation(i) + d)
	_refresh_numbers()
	queue_redraw()


func _start_nudge(dir: Vector2) -> void:
	_nudge(dir)
	_nudge_dir = dir
	_repeat_wait = REPEAT_DELAY
	set_process(true)


func _stop_nudge() -> void:
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
	_style_toggle(_btn_step, _fine)


## Dock the pad on the other side. With a lattice the pad WILL sit on top of
## control points (a 3×3 grid's right-edge midpoint is under it); flipping is
## the direct way to uncover them without hiding the nudge controls.
func _flip_pad() -> void:
	_pad_left = not _pad_left
	_layout_widgets()
	_hint.text = "NUDGE PAD: %s" % ("LEFT" if _pad_left else "RIGHT")


func _build_pad() -> void:
	# D-pad: ▲◄►▼ around a centre cell that shows + cycles the selected point,
	# with the coarse/fine step toggle underneath. Thumb-reachable; the projected
	# surface is across the room, the finger stays off the handle. The otherwise
	# dead top-left corner cell carries the side flip.
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
	_btn_point = _pad_cell(CORNER_NAMES[0])
	_btn_point.pressed.connect(_cycle_point)
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


# --- mode + density -------------------------------------------------------

# --- content fit mode -----------------------------------------------------
# Which rect the source is fitted to. BOUNDS (the mask's own box) is what every
# saved project has always done; FRAME fits the source to the WHOLE OUTPUT, so
# several regions become windows onto one shared composition — the mapping case
# where two real objects should show two parts of the same image.
#
# ⚠️ This is a one-line rect swap in RegionCompositor._fit_rect() and NOT because
# it is trivial: it only became one once the pivot was made explicit and anchored
# to the domain. With the old hardcoded 0.5,0.5 the pivot would have been the
# FRAME's centre here, so zooming a small region's content would have swung it
# across the screen (spec §2 item 1).
#
# Only these two of the five ContentFit values are reachable. FILL/FIT/STRETCH are
# the aspect presets of §2 items 4-5 and are a separate session — see the spec's
# TODO, which the FIT letterbox problem belongs to.

## The two reachable modes, in cycle order.
const FIT_CYCLE: Array[int] = [RegionCompositor.ContentFit.MANUAL,
	RegionCompositor.ContentFit.FULL_FRAME]


func _cycle_fit() -> void:
	if _content == null:
		return
	var cur := _content.get_content_fit(_content_index)
	var at := FIT_CYCLE.find(cur)
	# An unreachable mode loaded off disk cycles forward into BOUNDS rather than
	# sticking, so a file from a later build can always be got back under control.
	var want: int = FIT_CYCLE[0] if at < 0 else FIT_CYCLE[(at + 1) % FIT_CYCLE.size()]
	_content.set_content_fit(_content_index, want)
	_sync_fit_button()
	_refresh_numbers()
	state_changed.emit()
	queue_redraw()
	if want == RegionCompositor.ContentFit.FULL_FRAME:
		_hint.text = "FIT: FRAME — THIS REGION IS A WINDOW ONTO THE WHOLE OUTPUT"
	else:
		_hint.text = "FIT: BOUNDS — THE SOURCE FILLS THIS REGION"


func _sync_fit_button() -> void:
	if _btn_fit == null or _content == null:
		return
	var full := _content.get_content_fit(_content_index) \
		== RegionCompositor.ContentFit.FULL_FRAME
	_btn_fit.text = "FRAME" if full else "BOUNDS"
	_style_toggle(_btn_fit, full)


## Swap sub-mode. Anything mid-drag is dropped: the fingers meant the other thing.
func _toggle_content_mode() -> void:
	if _content == null:
		return
	_content_mode = not _content_mode
	_grabbed.clear()
	_grab_offset.clear()
	_pan_active = false
	_gest.reset()
	_stop_nudge()
	# The visible NUM panel belongs to the mode being left.
	var was_open := _numbers.visible or _cnum.visible
	_numbers.visible = false
	_cnum.visible = false
	if was_open:
		(_cnum if _content_mode else _numbers).visible = true
	_sync_content_buttons()
	_layout_widgets()
	_refresh_numbers()
	state_changed.emit()
	if _content_mode:
		_hint.text = "EDIT CONTENT · DRAG MOVES THE PICTURE · PINCH ZOOMS · PAD + NUM"
	else:
		_hint.text = "EDIT SURFACE · DRAG THE HANDLES TO WARP"
	queue_redraw()


func _toggle_mode() -> void:
	var keep := surface.corner_of_index(_sel_point)   # remap BEFORE the lattice changes
	surface.set_mesh_mode(not surface.mesh_mode)
	_changed()
	_reselect(keep)
	_sync_mode_buttons()
	_layout_widgets()
	state_changed.emit()
	if surface.mesh_mode:
		_hint.text = "MESH %dx%d — DRAG ANY POINT" % [surface.grid_cols, surface.grid_rows]
	else:
		_hint.text = "QUAD — 4 CORNERS"
	queue_redraw()


## Cycle the lattice density. Tapping this in QUAD mode also switches to MESH —
## the control is literally labelled with a grid size, so a dead tap there would
## read as broken; the hint says what happened.
func _cycle_density() -> void:
	var n := surface.grid_cols + 1
	if n > QuadWarp.MAX_GRID:
		n = QuadWarp.MIN_GRID
	var keep := surface.corner_of_index(_sel_point)
	surface.set_grid_size(n, n)
	if not surface.mesh_mode:
		surface.set_mesh_mode(true)
	_changed()
	_reselect(keep)
	_sync_mode_buttons()
	state_changed.emit()
	_hint.text = "MESH %dx%d" % [surface.grid_cols, surface.grid_rows]
	queue_redraw()


func _sync_mode_buttons() -> void:
	if _btn_mode != null:
		_btn_mode.text = "MESH" if surface.mesh_mode else "QUAD"
		_style_toggle(_btn_mode, surface.mesh_mode)
	if _btn_density != null:
		_btn_density.text = "%dx%d" % [surface.grid_cols, surface.grid_rows]
		# Dim while it describes a lattice that is not being applied.
		_btn_density.add_theme_color_override("font_color",
			M8_TEXT if surface.mesh_mode else M8_DIM)


# --- numeric panel (per-corner X/Y, plus the selected point when it isn't one)

## NUM shows the panel for whichever sub-mode is live — the same cell, retargeted.
func _toggle_numbers() -> void:
	var panel: PanelContainer = _cnum if _content_mode else _numbers
	var other: PanelContainer = _numbers if _content_mode else _cnum
	other.visible = false
	panel.visible = not panel.visible
	if panel.visible:
		_refresh_numbers()
		_layout_widgets()


func _build_numbers() -> void:
	_numbers = PanelContainer.new()
	_numbers.visible = false
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	# Row 0: the selected control point — shown only when it is NOT a corner,
	# so QUAD mode keeps exactly the S16 four-row layout.
	_sel_label = Button.new()
	_sel_label.text = "--"
	_sel_label.focus_mode = Control.FOCUS_NONE
	_sel_label.custom_minimum_size = Vector2(76, 76)
	_sel_label.add_theme_font_size_override("font_size", 20)
	_sel_label.add_theme_color_override("font_color", M8_GREEN)
	grid.add_child(_sel_label)
	_sel_x = _num_field(grid, -1)
	_sel_y = _num_field(grid, -1)
	_sel_row = [_sel_label, _sel_x, _sel_y] as Array[Control]
	for i in 4:
		var idx := i
		var b := Button.new()
		b.text = CORNER_NAMES[i]
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(76, 76)
		b.add_theme_font_size_override("font_size", 20)
		b.pressed.connect(func() -> void:
			_select_point(_index_of_corner(idx))
			_hint.text = "CORNER %s SELECTED" % CORNER_NAMES[idx])
		grid.add_child(b)
		_num_x.append(_num_field(grid, idx))
		_num_y.append(_num_field(grid, idx))
	_numbers.add_child(grid)
	add_child(_numbers)


# --- numeric panel for the CONTENT transform ------------------------------
# Retargeting NUM rather than inventing a control (spec §3). Everything is in the
# units a mapping decision is actually made in: OUTPUT PX for the move, per cent
# for scale and pivot, degrees for rotation. That, with the pad, is the whole
# adb-verifiable path — pinch is hands-only.

## label -> the transform field it edits. MOVE is px; SCALE/PIVOT are per cent of
## the region's own box; ROT is degrees.
const CONTENT_ROWS: Array = [
	["MOVE X (PX)", "mx"], ["MOVE Y (PX)", "my"],
	["SCALE X (%)", "sx"], ["SCALE Y (%)", "sy"],
	["ROTATION (°)", "rot"],
	["PIVOT X (%)", "px"], ["PIVOT Y (%)", "py"],
]


func _build_content_numbers() -> void:
	_cnum = PanelContainer.new()
	_cnum.visible = false
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	for row: Array in CONTENT_ROWS:
		var l := Label.new()
		l.text = str(row[0])
		l.add_theme_font_size_override("font_size", 18)
		l.add_theme_color_override("font_color", M8_DIM)
		grid.add_child(l)
		var key := str(row[1])
		var e := LineEdit.new()
		e.custom_minimum_size = Vector2(200, 64)
		e.add_theme_font_size_override("font_size", 22)
		e.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
		e.text_submitted.connect(func(_t: String) -> void: _apply_content_numbers())
		grid.add_child(e)
		_cnum_fields[key] = e
	_cnum.add_child(grid)
	add_child(_cnum)


## Read every field at once. Submitting one commits all of them, which is the
## behaviour the surface panel already has (and it means a typo in one field
## cannot be half-applied while the panel shows something else).
func _apply_content_numbers() -> void:
	if _content == null:
		return
	var i := _content_index
	var dom := _content.warp_domain(i)
	_content.set_content_offset(i, Vector2(
		_field("mx") / dom.size.x, _field("my") / dom.size.y))
	_content.set_content_scale(i, Vector2(
		_field("sx") / 100.0, _field("sy") / 100.0))
	_content.set_content_rotation(i, deg_to_rad(_field("rot")))
	_content.set_content_pivot(i, Vector2(
		_field("px") / 100.0, _field("py") / 100.0))
	_refresh_numbers()
	queue_redraw()


func _field(key: String) -> float:
	return (_cnum_fields[key] as LineEdit).text.to_float()


func _set_field(key: String, value: float) -> void:
	(_cnum_fields[key] as LineEdit).text = "%.1f" % value


func _refresh_content_numbers() -> void:
	if _cnum == null or not _cnum.visible or _content == null:
		return
	var i := _content_index
	var dom := _content.warp_domain(i)
	var mov := _content.get_content_offset(i) * dom.size
	var sc := _content.get_content_scale(i)
	var piv := _content.get_content_pivot(i)
	_set_field("mx", mov.x)
	_set_field("my", mov.y)
	_set_field("sx", sc.x * 100.0)
	_set_field("sy", sc.y * 100.0)
	_set_field("rot", rad_to_deg(_content.get_content_rotation(i)))
	_set_field("px", piv.x * 100.0)
	_set_field("py", piv.y * 100.0)


## `corner` is the quad corner index, or -1 for the selected-point row.
func _num_field(grid: GridContainer, corner: int) -> LineEdit:
	var e := LineEdit.new()
	e.custom_minimum_size = Vector2(190, 76)
	e.add_theme_font_size_override("font_size", 22)
	e.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
	e.text_submitted.connect(func(_t: String) -> void: _apply_numbers(corner))
	grid.add_child(e)
	return e


func _apply_numbers(corner: int) -> void:
	if corner < 0:
		surface.set_control_point(_sel_point,
			Vector2(_sel_x.text.to_float(), _sel_y.text.to_float()))
	else:
		var idx := _index_of_corner(corner)
		surface.set_control_point(idx, Vector2(_num_x[corner].text.to_float(),
			_num_y[corner].text.to_float()))
		_select_point(idx)
	_changed()
	_refresh_numbers()
	queue_redraw()


## Push the live positions (output px) into the panel. Skipped while hidden;
## rewrites every field formatted, so it also normalizes entries.
func _refresh_numbers() -> void:
	_refresh_content_numbers()
	if _numbers == null or not _numbers.visible:
		return
	for i in 4:
		var p := surface.control_point(_index_of_corner(i))
		_num_x[i].text = "%.0f" % p.x
		_num_y[i].text = "%.0f" % p.y
	var on_corner := surface.corner_of_index(_sel_point) >= 0
	for c in _sel_row:
		c.visible = not on_corner
	if not on_corner:
		var sp := surface.control_point(_sel_point)
		_sel_label.text = _point_name(_sel_point)
		_sel_x.text = "%.0f" % sp.x
		_sel_y.text = "%.0f" % sp.y


const M8_GREEN := Color(0.0, 1.0, 0.255)   ## #00FF41 (matches pipeline M8 palette)
const M8_TEXT := Color(0.929, 0.929, 0.929)
const M8_DIM := Color(0.929, 0.929, 0.929, 0.42)

func _draw() -> void:
	if not active or surface == null or surface.corners.size() != 4:
		return
	var xf := _xf()
	_draw_bounds(xf)
	# EDIT CONTENT draws THE PAIR and nothing else (spec §3): the dashed bounds
	# above (the surface's extent, which does not move) and the solid content rect
	# below (which does). No lattice lines, no handles, no selection ring —
	# nothing that could read as draggable geometry, since nothing is.
	if _content_mode:
		_draw_content_rect(xf)
		return
	var cols := surface.edit_cols()
	var rows := surface.edit_rows()
	# M8: faint green fill + bright green outline + green SQUARE handles drawn as
	# OUTLINE ONLY (no fill), so a handle never hides the footage under the point
	# being placed. The fill is only drawn for the plain quad — a deformed mesh
	# boundary can be concave, which draw_colored_polygon does not triangulate.
	if not surface.mesh_mode:
		var c := PackedVector2Array()
		for p in surface.corners:
			c.append(xf * p)
		draw_colored_polygon(c, Color(0.0, 1.0, 0.255, 0.05))
	# Lattice lines, traced along the real surface (between two control points it
	# is curved, so a straight chord would misreport the deformation). Interior
	# lines are thinner and dimmer than the border.
	for j in rows:
		var v := float(j) / float(rows - 1)
		var edge := j == 0 or j == rows - 1
		draw_polyline(_trace_line(xf, v, true, cols),
			M8_GREEN if edge else Color(0.0, 1.0, 0.255, 0.45), 2.0 if edge else 1.0)
	for i in cols:
		var u := float(i) / float(cols - 1)
		var edge_c := i == 0 or i == cols - 1
		draw_polyline(_trace_line(xf, u, false, rows),
			M8_GREEN if edge_c else Color(0.0, 1.0, 0.255, 0.45), 2.0 if edge_c else 1.0)
	# Handles. Corners draw larger than interior points so the quad that drives
	# the homography stays readable inside a dense lattice.
	var held := _grabbed.values()
	for i in surface.point_count():
		var sp := xf * surface.control_point(i)
		var h := 15.0 if surface.corner_of_index(i) >= 0 else 10.0
		var grabbed := i in held
		draw_rect(Rect2(sp - Vector2(h, h), Vector2(h, h) * 2.0),
			M8_GREEN, false, 3.0 if grabbed else 2.0)
	# The SELECTED point (nudge/NUM target): a second outline ring + its name,
	# offset toward the canvas centre so both stay readable at screen edges.
	if _sel_point < surface.point_count():
		var sp2 := xf * surface.control_point(_sel_point)
		var ring := 24.0
		draw_rect(Rect2(sp2 - Vector2(ring, ring), Vector2(ring, ring) * 2.0), M8_GREEN, false, 1.0)
		var toward := (get_rect().size * 0.5 - sp2).normalized()
		draw_string(get_theme_default_font(), sp2 + toward * 56.0 + Vector2(-14, 8),
			_point_name(_sel_point), HORIZONTAL_ALIGNMENT_LEFT, -1, 18, M8_GREEN)


## Where the SOURCE FRAME's edges land, as a solid quad, plus the pivot the scale
## and rotation turn about.
##
## ⚠️ Drawn in the region's UNDEFORMED domain, the same space as the dashed bounds
## — deliberately. The warp is a later stage, so the content's real edges are
## curved once the surface is deformed; showing that here would put the two rects
## in different spaces and there would be no fixed reference left to read the
## content's position against. Dashed = the extent, solid = the picture in it.
##
## Solid also because the mask edge and the lattice border are solid green: in
## EDIT CONTENT neither of those is on screen, so the vocabulary is free.
func _draw_content_rect(xf: Transform2D) -> void:
	if _content == null:
		return
	var q := _content.content_quad(_content_index)
	if q.size() != 4:
		return
	for i in 4:
		draw_line(xf * q[i], xf * q[(i + 1) % 4], M8_GREEN, 2.0)
	# The pivot: a small cross, not a square — squares are draggable handles here.
	var p: Vector2 = xf * _content.content_pivot_px(_content_index)
	var arm := 14.0
	draw_line(p - Vector2(arm, 0), p + Vector2(arm, 0), M8_GREEN, 2.0)
	draw_line(p - Vector2(0, arm), p + Vector2(0, arm), M8_GREEN, 2.0)


## The region's extent: a dashed outline plus corner ticks, drawn UNDER the
## lattice and dimmer than it. Without it the lattice floats with no reference —
## you cannot tell whether a handle sits inside the surface you are mapping.
## Dashed (not solid) so it never reads as a mask edge or a lattice border, both
## of which are solid green.
func _draw_bounds(xf: Transform2D) -> void:
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	var c := [
		xf * bounds.position,
		xf * Vector2(bounds.end.x, bounds.position.y),
		xf * bounds.end,
		xf * Vector2(bounds.position.x, bounds.end.y),
	]
	var dim := Color(0.0, 1.0, 0.255, 0.30)
	for i in 4:
		_dashed(c[i], c[(i + 1) % 4], dim)
	# Corner ticks read at a glance even when an edge runs off-screen.
	var tick := 26.0
	for i in 4:
		var p: Vector2 = c[i]
		var a: Vector2 = c[(i + 3) % 4]
		var b: Vector2 = c[(i + 1) % 4]
		draw_line(p, p + (a - p).normalized() * tick, M8_GREEN, 2.0)
		draw_line(p, p + (b - p).normalized() * tick, M8_GREEN, 2.0)


func _dashed(a: Vector2, b: Vector2, col: Color, dash := 14.0) -> void:
	var d := b - a
	var n := d.length()
	if n <= 0.0:
		return
	var step := d / n * dash
	var i := 0
	while float(i) * dash < n:
		var p0 := a + step * float(i)
		var p1 := a + step * minf(float(i) + 1.0, n / dash)
		if i % 2 == 0:
			draw_line(p0, p1, col, 1.0)
		i += 1


## Sample one lattice line across the surface. `horizontal` traces constant v
## (a control ROW); otherwise constant u (a control COLUMN). `across` is the
## number of control points on the other axis, so the sample count scales.
func _trace_line(xf: Transform2D, fixed: float, horizontal: bool, across: int) -> PackedVector2Array:
	var steps := maxi(1, across - 1) * LINE_SAMPLES
	var pts := PackedVector2Array()
	pts.resize(steps + 1)
	for k in steps + 1:
		var t := float(k) / float(steps)
		pts[k] = xf * (surface.surface_point(t, fixed) if horizontal
			else surface.surface_point(fixed, t))
	return pts


# --- presets (normalized corners + offsets in user://warp.cfg) ------------

func _area_size() -> Vector2:
	var s := size
	return s if s.x > 1.0 and s.y > 1.0 else get_viewport_rect().size


func _xf() -> Transform2D:
	return xform_provider.call() if xform_provider.is_valid() else Transform2D.IDENTITY


## The pixel space the control points live in — the normalization basis for
## presets and the RESET rect. Screen size until pipeline injects the fixed
## output resolution.
func _out_size() -> Vector2:
	return output_size_provider.call() if output_size_provider.is_valid() else _area_size()


func save_slot(slot: int) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)   # keep other slots; ignore "file missing"
	# One serializer, shared with per-region warps in regions.cfg (WarpSurface):
	# same keys, same normalization against the output size. Slots keep the
	# UNPREFIXED names they have carried since S19, so the on-disk format of
	# warp.cfg is byte-for-byte what it was — no migration.
	surface.save_to(cfg, "slot_%d" % slot, _out_size())
	cfg.save(SAVE_PATH)


func load_slot(slot: int) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return false
	# False = no such slot. A pre-S19 slot has "corners" but no mesh keys and
	# comes back as a flat 2x2 / mesh off, which renders through the identical
	# code path as the old 4-corner warp.
	if not surface.load_from(cfg, "slot_%d" % slot, _out_size()):
		return false
	_changed()
	_clamp_selection()
	_sync_mode_buttons()
	_refresh_numbers()
	state_changed.emit()
	queue_redraw()
	return true


# --- warp control bar (centered, away from the control points) ------------

func _build_bar() -> void:
	_hint = Label.new()
	_hint.text = "DRAG THE HANDLES TO WARP"
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.add_theme_color_override("font_color", Color(0.929, 0.929, 0.929, 0.5))
	_hint.visible = false
	add_child(_hint)

	# M8 bottom bar: even full-width cells.
	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 0)
	add_child(_bar)
	_btn_slot = _make_button("SLOT %d" % _slot, _cycle_slot)
	_btn_slot.add_theme_color_override("font_color", M8_GREEN)   # active slot = green
	_bar.add_child(_btn_slot)
	_btn_save = _make_button("SAVE", _save_pressed)
	_bar.add_child(_btn_save)
	_btn_load = _make_button("LOAD", _load_pressed)
	_bar.add_child(_btn_load)
	_bar.add_child(_make_button("RESET", _reset_pressed))
	# EDIT SURFACE <-> EDIT CONTENT. Region-only, and placed before the surface
	# controls it hides so the bar does not reflow around the cell being pressed.
	_btn_content = _make_button("CONTENT", _toggle_content_mode)
	_btn_content.visible = false
	_bar.add_child(_btn_content)
	# The fit mode: which rect the source is fitted to. EDIT CONTENT only — it is
	# a content decision, and it is meaningless for the global warp.
	_btn_fit = _make_button("BOUNDS", _cycle_fit)
	_btn_fit.visible = false
	_bar.add_child(_btn_fit)
	_btn_mode = _make_button("QUAD", _toggle_mode)
	_bar.add_child(_btn_mode)
	_btn_density = _make_button("2x2", _cycle_density)
	_bar.add_child(_btn_density)
	_bar.add_child(_make_button("NUM", _toggle_numbers))
	_btn_grid = _make_button("GRID", _toggle_grid)
	_bar.add_child(_btn_grid)
	_btn_cam = _make_button("CAM", func(): camera_requested.emit())
	_bar.add_child(_btn_cam)
	_bar.visible = false


func _layout_widgets() -> void:
	await get_tree().process_frame   # let containers compute their size
	var sz := _area_size()
	_bar.position = Vector2(0, sz.y - STRIP_H)
	_bar.custom_minimum_size = Vector2(sz.x, STRIP_H)
	_bar.size = Vector2(sz.x, STRIP_H)
	_hint.position = Vector2((sz.x - _hint.size.x) * 0.5, sz.y - STRIP_H - 34.0)
	# Nudge pad: docked left or right, vertically centred (clear of the ESC/DONE
	# pill top-right). NUM panel: top-centre, clear of the corners.
	var pad_sz := _pad.get_combined_minimum_size()
	_pad.position = Vector2(16.0 if _pad_left else sz.x - pad_sz.x - 16.0,
		(sz.y - pad_sz.y) * 0.5)
	var num_sz := _numbers.get_combined_minimum_size()
	_numbers.position = Vector2((sz.x - num_sz.x) * 0.5, 84.0)
	# The content panel is taller (7 rows) and narrower, so it is docked to the
	# side the pad is NOT on rather than centred over the region being aimed.
	var cnum_sz := _cnum.get_combined_minimum_size()
	_cnum.position = Vector2(sz.x - cnum_sz.x - 16.0 if _pad_left else 16.0, 84.0)


## The warp preset slot currently armed (1..SLOT_COUNT) — shown on the WRP nav cell.
func current_slot() -> int:
	return _slot


func _cycle_slot() -> void:
	_slot = (_slot % SLOT_COUNT) + 1
	_btn_slot.text = "SLOT %d" % _slot
	slot_changed.emit(_slot)


func _save_pressed() -> void:
	save_slot(_slot)
	_hint.text = "SAVED TO SLOT %d" % _slot


func _load_pressed() -> void:
	if load_slot(_slot):
		_hint.text = "LOADED SLOT %d" % _slot
	else:
		_hint.text = "SLOT %d IS EMPTY" % _slot


func _reset_pressed() -> void:
	# RESET resets WHAT IS BEING EDITED. In EDIT CONTENT that is the content
	# transform, not the surface — wiping a carefully warped surface because the
	# picture was in the wrong place would be the worse surprise of the two.
	if _content_mode and _content != null:
		_content.reset_transform(_content_index)
		_refresh_numbers()
		queue_redraw()
		_hint.text = "CONTENT RESET (SURFACE UNTOUCHED)"
		return
	# Back to an undeformed surface over whatever this warp SPANS — the region's
	# bounds, or the whole output for the global warp. Resetting a region to the
	# frame would silently throw it back into frame space.
	if bounds.size.x > 0.0 and bounds.size.y > 0.0:
		surface.reset_all_in(bounds)
	else:
		surface.reset_all(_out_size())   # corners AND the lattice offsets
	_changed()
	_clamp_selection()
	_refresh_numbers()
	state_changed.emit()
	queue_redraw()
	_hint.text = "WARP RESET"


func _toggle_grid() -> void:
	_grid_on = not _grid_on
	_style_toggle(_btn_grid, _grid_on)
	grid_toggled.emit(_grid_on)
	if _content != null:   # a region: pipeline shows the masks' CHECKER instead
		_hint.text = "CHECKER ON THE MASKS — SQUARE CELLS ON THE OBJECT = WARP IS RIGHT" \
			if _grid_on else "CHECKER OFF"
		return
	_hint.text = "TEST GRID ON THE OUTPUT — CHECK THE WALL" if _grid_on else "TEST GRID OFF"


## Show GRID as on/off WITHOUT emitting — for a test pattern something else
## already turned on (the mask editor's CHECKER, when its WARP opens this).
func show_grid(on: bool) -> void:
	_grid_on = on
	_style_toggle(_btn_grid, on)


## M8 active-cell styling for toggle buttons (the region editor's radio look).
func _style_toggle(b: Button, on: bool) -> void:
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


# DONE = commit. The surface is already live on the QuadWarp, so committing is
# simply leaving it in place (and NOT restoring the snapshot).
# NOTE: this deliberately does not write a warp SLOT — SAVE is the explicit
# slot-write action, and silently overwriting the loaded slot on every DONE
# would be a destructive surprise.
func _done_pressed() -> void:
	set_active(false)
	closed.emit()


## Android BACK inside the editor (S24 §3): close the NUM panel if it is up,
## otherwise leave VIA DONE.
##
## ⚠️ DONE, never ESC. DONE keeps the surface exactly as it looks right now; ESC
## rolls the whole thing back to the snapshot taken on entry. A stray BACK press
## must not be able to throw away an alignment — which is the same accident this
## whole change exists to stop.
func handle_back() -> void:
	var num_open := (_numbers != null and _numbers.visible) \
			or (_cnum != null and _cnum.visible)
	if num_open:
		if _numbers != null:
			_numbers.visible = false
		if _cnum != null:
			_cnum.visible = false
		return
	_done_pressed()


func _capture_content() -> Dictionary:
	return _content.capture_content_state(_content_index) if _content != null else {}


# ESC = discard: put the whole thing back exactly as it was when the editor was
# entered — corners, lattice size, offsets, mode, AND (for a region) the content
# transform. The content half is easy to forget because it lives in a different
# object; forgetting it means ESC quietly keeps half the changes.
func _esc_pressed() -> void:
	if not _snapshot.is_empty():
		surface.restore_state(_snapshot)
		_changed()
		_clamp_selection()
		_sync_mode_buttons()
		state_changed.emit()
	if _content != null and not _content_snapshot.is_empty():
		_content.restore_content_state(_content_index, _content_snapshot)
	set_active(false)
	closed.emit()


func _make_button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, STRIP_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # even M8 cells
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(on_press)
	return b
