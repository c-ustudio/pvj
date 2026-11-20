class_name CalibEditor
extends Control
## CAMERA KEYSTONE — calibrate the camera against the projector, then set the
## global warp by pointing at the surface (CAMERA_PROCEDURAL_MASKS_SPEC.md §1,
## POCKETVJ_PRO_NORTHSTAR.md §2.4; the manual four-point version of both).
##
## THREE STEPS, one frozen frame:
##   LIVE     the wall shows the pattern (CalibPattern), the phone shows the
##            camera. Frame all four markers, hold still, FREEZE.
##   MARKERS  tap the four projected markers, in the order they are numbered.
##            That is the calibration: camera px -> output px.
##   SURFACE  tap the four corners of the surface the picture should fill. Each
##            goes through the calibration and becomes a corner of the GLOBAL
##            warp — live, on the wall, while it is being adjusted.
##
## WHY ONE FROZEN FRAME FOR BOTH. The calibration is only true for the camera
## position it was solved from, and a hand moves between two exposures. Marking
## the markers and the surface on the SAME frame makes that impossible to get
## wrong: whatever the phone does after FREEZE no longer matters.
##
## WHY ORIENTATION DOES NOT MATTER HERE. The camera frame may arrive rotated or
## mirrored (the feed's orientation has never been polished). The homography is
## solved from correspondences and absorbs any of that — as long as the markers
## and the surface are marked on the same picture, which the frozen frame
## guarantees. The operator names corners by what the WALL looks like, not by
## where they sit on the phone.
##
## AUTO (from LIVE) does the MARKERS step by itself. It flashes discs on the
## wall ONE AT A TIME against a dark frame, lets CalibDetect find each one, and
## fits the calibration to them (fit_grid, below). If enough of them agree,
## AUTO goes straight to SURFACE; if not (too many missed, or a surface that is
## not flat), it lands in MARKERS, says why, and the taps are there instead.
## AUTO needs the phone STILL for the seconds it runs — every frame is compared
## with the others — and checks: it shows one disc a second time at the end, and
## if that has moved (MOVE_TOL) it refuses, and says the phone moved.
##
## SURFACE STARTS SQUARED UP. On arrival the four corners are already placed —
## auto_surface(): the largest rectangle of the output's shape that the
## projector can reach, as the camera sees it — and already applied, so the
## projection visibly corrects itself the moment the calibration is done and
## DONE keeps that. The corners are there to be dragged onto a real surface.
## (The first version waited for four taps. On its first complete wall run the
## operator pressed DONE the instant AUTO said OK, and nothing had moved.)
##
## AUTO reads a 3x3 GRID of discs (CalibPattern.grid_points), not the four
## numbered markers, and fits ONE calibration to all it can trust (fit_grid):
## four inset markers only reach the picture's corners by extrapolation, and
## nine fitted together can lose one — hidden, missed, or something else that
## happened to be round — without losing the calibration.
##
## TWO KINDS OF SQUARE, and SURFACE says which one is on the wall. "FROM HERE"
## is square as the phone sees it — right from that seat. "ON THE WALL" is a
## true level rectangle on the wall — right for people facing it, and a
## trapezoid from beside the projector (the first operator's reaction to a
## correct result was "it skews the output"). The second cell flips between
## them; see CalibWall for why they differ.
##
## WALL needs to know which way is level on the wall, and which way is down.
## Down is the phone's gravity sensor, read when the frame froze (not when the
## cell is pressed: by then the phone has been turned in the hand). Level it
## FINDS in the frozen frame (CalibLines): shelf edges, a ceiling line, a door
## head. It does so unasked on arriving at SURFACE, so AUTO then DONE leaves
## the wall's square up whenever there is one to be had (and the phone's, with
## the reason, when there is not). The lines it used are drawn on the picture, and LINES
## opens them for dragging, or for tapping others — two points along each of
## two level lines, then SENSOR, or two points along each of two vertical
## edges. That manual step is also where WALL lands when it finds no lines or
## the phone gave no gravity reading.
##
## This Control never touches the camera or the output itself. It asks for the
## picture through `camera_texture_provider`, asks for what should be on the
## wall through `pattern_requested`, and reports `step_changed`; the pipeline
## owns who holds the lens and what the output shows.

signal closed(applied: bool)
signal step_changed(step: int)
## AUTO wants this on the wall: a CalibPattern.Mode, and the SOLO index.
signal pattern_requested(mode: int, index: int)
## The check wants plain discs at these output px, all at once.
signal spots_requested(points: PackedVector2Array)
## AUTO wants the camera's exposure moved by this many EV (0 = back to normal).
## Honoured only where the camera can do it; see AUTO_EV.
signal exposure_requested(ev: float)

enum Step { LIVE, MARKERS, SURFACE, WALL }

const SAVE_PATH := "user://calibration.cfg"
const SECTION := "calibration"
const STRIP_H := 56.0
const HINT_H := 44.0
const GRAB_RADIUS := 70.0      ## logical px — a finger, not a stylus
## WALL's points are picked up only from this close. Its lines meet — a shelf
## runs into a door frame — and a finger's worth of reach would turn the first
## tap of one line into a drag of the last line's end. UNDO is the way back.
const WALL_GRAB_RADIUS := 30.0
const POINTS := 4
const LOUPE_SRC := 72.0        ## camera px across the loupe
const LOUPE_SIZE := 230.0      ## logical px on screen
const LOUPE_GAP := 150.0       ## how far from the point the loupe floats
const NO_POINTER := -2         ## (-1 is the desktop mouse)
## AUTO: how far a disc may sit from where the fitted calibration puts it and
## still count, camera px. Detection is good to well under a pixel; this is
## room for the camera's own distortion and for a wall that is nearly flat.
const INLIER_TOL := 5.0
## AUTO: the fewest grid discs a calibration may rest on — and they must reach
## both outer columns and both outer rows, or the fit is extrapolating again.
const MIN_GRID := 6
## WALL: two points on each of two level lines, then on each of two plumb lines.
const WALL_POINTS := 8
## AUTO: the disc it shows a second time at the end, to see whether the phone
## stayed put (the centre one: the likeliest to be on the surface and in shot)…
const MOVE_CHECK_DISC := 4
## …and how far that disc may have moved in the camera frame, px. ⚠️ A phone
## held in the hand does not pass this: the first wall run of the grid was
## hand-held, the scene slid 10-17 px across the eleven frames, six or seven of
## nine discs "agreed", and AUTO said OK over a calibration that was a blend of
## several poses. It has to rest on something.
const MOVE_TOL := 4.0
## THE CHECK, after AUTO has set the keystone: four discs are projected at the
## corrected picture's own corners (this far in, as a fraction of it) and
## photographed, and where they land is compared with where the picture was
## meant to be. It closes the loop on everything between "this is the
## rectangle" and the light on the wall — the calibration's fit, the warp, a
## lens that is not quite a pinhole. ⚠️ It cannot tell whether the RECTANGLE was
## the right one: a wrong idea of which way the wall faces moves the target and
## the result together.
const CHECK_INSET := 0.1
## Camera px. Closer than CHECK_OK: nothing to correct. Further than CHECK_MAX:
## not a small error to trim but something else (left alone, and said).
const CHECK_OK := 1.5
const CHECK_MAX := 30.0
const CHECK_MATCH := 45.0      ## how far from where it is expected a disc is still that disc
const AUTO_TRIES := 3          ## per marker, one settle apart — slow projectors
## AUTO underexposes while it reads the wall. Measured on the first wall run
## (a lit room, a white wall): auto-exposure put the wall at 235-248 of 255, so
## a projected disc could only add 5-20 levels before clipping — one of the
## four was lost outright. Two stops down the wall sits mid-scale and the disc
## has room to stand out. In a dark room it costs nothing: the discs are the
## only bright things either way.
const AUTO_EV := -2.0
## AUTO: how many candidates per disc to look at when the strongest ones do
## not give enough agreement (something round moved in one frame).
const AUTO_ALTERNATIVES := 3
## AUTO: once the calibration is solved it says how big each disc SHOULD look
## from the camera. A disc whose measured area falls this far under the others
## (relative to that prediction) is partly hidden: something stands between it
## and the phone. ⚠️ Position alone does not catch this — on the wall run that
## prompted it a lampshade cut a marker in half and its centroid slid only
## ~7 px: a half disc is still "disc-shaped". Such a disc is left out of the fit.
const HIDDEN_RATIO := 0.72
## AUTO writes every frame it captured here as PNG — but ONLY if the folder
## already exists (`adb shell run-as <pkg> mkdir files/calib_dump`). That is
## the whole switch: nothing in the app creates it, so it is inert in the
## field, and a failed detection on a real wall can be replayed on a desk.
const DUMP_DIR := "user://calib_dump"
const CORNER_NAMES: Array[String] = ["TOP-LEFT", "TOP-RIGHT", "BOTTOM-RIGHT", "BOTTOM-LEFT"]
const CORNER_TAGS: Array[String] = ["TL", "TR", "BR", "BL"]

const M8_GREEN := Color(0.0, 1.0, 0.255)   ## #00FF41 (matches pipeline M8 palette)
const M8_TEXT := Color(0.929, 0.929, 0.929)

var active: bool = false
var step: int = Step.LIVE
## -> Texture2D, the live camera picture. Asked for again on every RETAKE, so
## the pipeline may hand back a different engine's texture each time.
var camera_texture_provider: Callable = Callable()
var output_size_provider: Callable = Callable()   ## -> Vector2, output px
## True when nothing is driving a projector from OutputWorld. The flow still
## runs (it is how the UI gets tested on a desk), but it says so.
var dry_run: bool = false
## Seconds between changing what the wall shows and trusting the camera frame:
## projector lag + the camera's own pipeline (~0.2 s measured on the link).
var settle_sec: float = 0.5
## -> Image. Optional: what AUTO and FREEZE read instead of the camera
## texture's pixels. The headless verifier's seam (there is no readback there).
var frame_provider: Callable = Callable()
## -> Vector3, which way is DOWN in camera space (x right, y down, z into the
## scene), or ZERO when the phone cannot say. WALL's plumb, when no vertical
## edges are tapped.
var gravity_provider: Callable = Callable()
## The camera's focal length in px, or 0 to work it out from…
var focal_px: float = 0.0
## …the lens's focal length over its sensor's width (from Camera2, via
## AndroidProbe), or 0 for CalibWall's estimate.
var focal_per_width: float = 0.0
## -> int, Android's thermal status (3 = one step from the projector being cut),
## or -1. The hints say so while it is hot.
var heat_provider: Callable = Callable()

var _quad: QuadWarp
var _warp_snapshot: Dictionary = {}
var _applied: bool = false

var _view: TextureRect
var _overlay: Control
var _hint: Label
var _bar: HBoxContainer
var _btn_auto: Button
var _btn_shot: Button      ## FREEZE in LIVE, RETAKE after
var _btn_undo: Button
var _btn_next: Button      ## NEXT in MARKERS, MARKERS in SURFACE
var _btn_done: Button

var _frozen: ImageTexture
## AUTO only: the same view lit by a white projector. Shown in SURFACE, where
## the surface's edges matter and — in a dark room — the pattern frame is black.
var _flood: ImageTexture
var _busy: bool = false    ## AUTO is running
var _run: int = 0          ## bumped to cancel an AUTO in flight
var _auto_info: String = ""   ## "AUTO 9/9 · " prefix for the SURFACE hints
var _auto_placed: bool = false   ## the surface corners are still auto_surface()'s
var _cam_size: Vector2 = Vector2(1920, 1080)
var _markers: PackedVector2Array = PackedVector2Array()   ## camera px, pattern order
## True while the calibration is AUTO's fit of the grid and `_markers` are only
## where that fit puts the four numbered markers — shown for review. Touching
## one hands the calibration over to those four points.
var _markers_auto: bool = false
## WALL: level line 1 (2 points), level line 2, plumb line 1, plumb line 2.
var _wall: PackedVector2Array = PackedVector2Array()
var _wall_true: bool = false     ## the surface corners came from CalibWall
var _frozen_img: Image           ## the frozen frame's pixels, for CalibLines
## What WALL's level lines are, for the hints: "" (tapped), or CalibLines' own
## account ("3 LEVEL EDGES", "LEVEL FROM THE ROOM", …).
var _lines_info: String = ""
## Why the wall's square cannot be found by itself on this frozen frame ("" =
## not tried, or it can).
var _wall_why: String = ""
## True while SURFACE is being arrived at: the wall still shows the pattern and
## the lens is still borrowed (the step is MARKERS), so the wall's square can be
## found and the result checked before the deck comes back.
var _arriving: bool = false
## What the check found ("" = not checked): for the SURFACE hints.
var _checked: String = ""
## The calibration as the check corrected it — camera -> output, exact at the
## picture's own corners — or null. Used for the surface instead of the one
## fitted to the whole frame, until the surface is chosen afresh.
var _local: CalibHomography
## Where AUTO saw the disc it shows twice (its candidates): what "the phone has
## not moved" is measured against, then and at the check.
var _anchor: Array = []
var _frozen_gravity: Vector3 = Vector3.ZERO   ## gravity_provider, as the frame froze
var _fit: Dictionary = {}        ## AUTO's last fit_grid() result, for the log and the verifier
var _surface: PackedVector2Array = PackedVector2Array()   ## camera px, TL TR BR BL
var _cam_to_out: CalibHomography
var _out_to_cam: CalibHomography
var _note: String = ""     ## one-shot line that replaces the step's hint

var _grab_id: int = NO_POINTER
var _grab_index: int = -1
var _grab_offset: Vector2 = Vector2.ZERO   ## camera px: point minus finger
var _use_mouse: bool = true


func setup(quad: QuadWarp) -> void:
	_quad = quad
	_use_mouse = not OS.has_feature("mobile")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_view = TextureRect.new()
	_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view.stretch_mode = TextureRect.STRETCH_SCALE
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_view)

	# Markers, outlines and the loupe are drawn ABOVE the picture, so they live
	# on their own Control: a parent's _draw() renders under its children.
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	_hint = Label.new()
	_hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_hint.offset_bottom = HINT_H
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.clip_text = true
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.add_theme_color_override("font_color", M8_TEXT)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)

	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 0)
	_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_bar.offset_top = -STRIP_H
	add_child(_bar)
	_bar.add_child(_make_button("ESC", _esc_pressed))
	_btn_auto = _make_button("AUTO", _auto_pressed)
	_bar.add_child(_btn_auto)
	_btn_shot = _make_button("FREEZE", _shot_pressed)
	_bar.add_child(_btn_shot)
	_btn_undo = _make_button("UNDO", _undo_pressed)
	_bar.add_child(_btn_undo)
	_btn_next = _make_button("NEXT", _next_pressed)
	_bar.add_child(_btn_next)
	_btn_done = _make_button("DONE", _done_pressed)
	_btn_done.add_theme_color_override("font_color", M8_GREEN)
	_bar.add_child(_btn_done)

	resized.connect(_layout)


# --- activation ----------------------------------------------------------

func set_active(on: bool) -> void:
	active = on
	visible = on
	mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	_grab_id = NO_POINTER
	_grab_index = -1
	if _busy:
		exposure_requested.emit(0.0)   # an AUTO was cut short mid-sequence
	_run += 1        # an AUTO in flight stops at its next await
	_busy = false
	if on:
		# ESC must be able to put the wall back exactly as it was.
		_warp_snapshot = _quad.capture_state()
		_applied = false
		_go_live()
	else:
		# Drop the picture: a frozen 1080p frame is 8 MB nobody is looking at.
		_view.texture = null
		_arriving = false
		_frozen = null
		_frozen_img = null
		_flood = null
		_markers = PackedVector2Array()
		_markers_auto = false
		_surface = PackedVector2Array()
		_wall = PackedVector2Array()
		_cam_to_out = null
		_out_to_cam = null


## Camera -> output, from the last completed calibration, or null. For whatever
## consumes it next (masks traced on a camera frame). ⚠️ Only as true as the
## rig is still: it says nothing about whether the phone or projector moved.
static func load_calibration() -> CalibHomography:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return null
	return CalibHomography.load_from(cfg, SECTION)


# --- geometry ------------------------------------------------------------

## `content` aspect-fitted and centred inside `area`.
static func fit_rect(area: Rect2, content: Vector2) -> Rect2:
	if content.x <= 0.0 or content.y <= 0.0 or area.size.x <= 0.0 or area.size.y <= 0.0:
		return area
	var s := minf(area.size.x / content.x, area.size.y / content.y)
	var sz := content * s
	return Rect2(area.position + (area.size - sz) * 0.5, sz)


## The automatic surface: the largest rectangle with the OUTPUT'S aspect that
## fits inside the projector's frame as the camera sees it. Camera px, in
## TL TR BR BL order; empty when the frame has no usable image.
##
## "As the camera sees it" is the honest limit of this: the picture comes out
## rectangular FROM WHERE THE PHONE IS. With the phone roughly facing the wall
## that is ordinary keystone correction; from well off to one side it is
## correct for that seat and no other. Squaring it on the wall itself would
## need the wall's angle to the camera, which one view does not give.
##
## Its orientation follows the projection's own top edge, not the camera's
## axes — so a phone that is not level does not tilt the picture, and a camera
## frame that arrives rotated or mirrored gives the same answer.
static func auto_surface(out_to_cam: CalibHomography, out_size: Vector2) -> PackedVector2Array:
	var none := PackedVector2Array()
	if out_to_cam == null or out_size.x <= 0.0 or out_size.y <= 0.0:
		return none
	var q := PackedVector2Array()
	for c: Vector2 in [Vector2.ZERO, Vector2(out_size.x, 0), out_size, Vector2(0, out_size.y)]:
		var p := out_to_cam.apply(c)
		if not p.is_finite():
			return none
		q.append(p)
	# "Right" = the mean direction of the frame's top and bottom edges; "down"
	# = perpendicular to it, on the side the frame's own down is.
	var eu := ((q[1] - q[0]) + (q[2] - q[3])).normalized()
	var ev := Vector2(-eu.y, eu.x)
	if ev.dot((q[3] - q[0]) + (q[2] - q[1])) < 0.0:
		ev = -ev
	if eu == Vector2.ZERO:
		return none
	return inscribed_rect(q, eu, ev, out_size.x / out_size.y)


## The largest rectangle with sides along `eu` (its width) and `ev` (its
## height), width/height = `aspect`, inside the convex quad `q`. TL TR BR BL;
## empty when nothing fits. Works in whatever space `q` is given in — the
## camera frame for auto_surface(), a rectified wall for anything that knows
## the wall's true shape.
static func inscribed_rect(q: PackedVector2Array, eu: Vector2, ev: Vector2,
		aspect: float) -> PackedVector2Array:
	var none := PackedVector2Array()
	if q.size() != 4 or aspect <= 0.0:
		return none
	var centre := (q[0] + q[1] + q[2] + q[3]) * 0.25
	# The rectangle is fixed by its centre and one size. For any centre the
	# size comes from a bisection; the centre from a coarse-then-fine search
	# around the quad's middle, stepped along eu/ev so the result does not
	# depend on how the camera frame is turned.
	var span_u := maxf((q[1] - q[0]).length(), (q[2] - q[3]).length())
	var span_v := maxf((q[3] - q[0]).length(), (q[2] - q[1]).length())
	var best_c := centre
	var best_s := _fit_size(q, centre, eu, ev, aspect)
	var reach := 0.25
	for stage in 3:
		var from := best_c
		for j in range(-3, 4):
			for i in range(-3, 4):
				var c := from + eu * (span_u * reach * i / 3.0) + ev * (span_v * reach * j / 3.0)
				var sz := _fit_size(q, c, eu, ev, aspect)
				if sz > best_s:
					best_s = sz
					best_c = c
		reach *= 0.3
	if best_s <= 0.0:
		return none
	best_s *= 0.995   # a hair inside, so no corner lands past the frame
	return _rect_at(best_c, eu, ev, best_s * aspect, best_s)


## Half-height of the largest aspect-`aspect` rectangle centred on `c` inside
## the convex quad `q` (0 when `c` itself is outside).
static func _fit_size(q: PackedVector2Array, c: Vector2, eu: Vector2, ev: Vector2,
		aspect: float) -> float:
	if not _inside(q, c):
		return 0.0
	var lo := 0.0
	var hi := maxf((q[2] - q[0]).length(), (q[3] - q[1]).length())
	for it in 24:
		var mid := (lo + hi) * 0.5
		var ok := true
		for p in _rect_at(c, eu, ev, mid * aspect, mid):
			if not _inside(q, p):
				ok = false
				break
		if ok:
			lo = mid
		else:
			hi = mid
	return lo


static func _rect_at(c: Vector2, eu: Vector2, ev: Vector2, hw: float, hh: float) -> PackedVector2Array:
	return PackedVector2Array([
		c - eu * hw - ev * hh, c + eu * hw - ev * hh,
		c + eu * hw + ev * hh, c - eu * hw + ev * hh,
	])


## Inside a convex quad of either winding (a mirrored camera frame flips it).
static func _inside(q: PackedVector2Array, p: Vector2) -> bool:
	var pos := false
	var neg := false
	for i in 4:
		var cr := (q[(i + 1) % 4] - q[i]).cross(p - q[i])
		if cr > 0.0:
			pos = true
		elif cr < 0.0:
			neg = true
	return not (pos and neg)


## Fit ONE calibration to AUTO's grid of discs, and decide which to believe.
## `cands[i]` is grid point i's candidate list from CalibDetect.candidates():
## strongest first, or a single not-ok entry when the disc was not found.
##
##  1. Every set of four found discs proposes a calibration (their strongest
##     candidates); the proposal most of the grid agrees with wins. A disc
##     agrees when ANY of its candidates sits within INLIER_TOL of where the
##     proposal puts it — so a decoy that out-shone the real disc in one frame
##     is simply outvoted, and the real one is picked from the runners-up.
##  2. The winner is refitted through all the discs that agree (least squares).
##  3. Discs that look too small for where they are (hidden_discs) are dropped
##     and the fit redone: their centres have slid.
##  4. What is left must be at least MIN_GRID discs reaching both outer columns
##     and both outer rows. A projection across two walls fails here, by
##     agreeing on one wall only.
##
## -> { ok, h (camera->output), inv, used: PackedInt32Array (grid indices),
##      ranks: PackedInt32Array (which candidate of each used disc), rms (camera
##      px), seen, hidden: PackedInt32Array, reason }
static func fit_grid(cands: Array, out_size: Vector2) -> Dictionary:
	var grid := CalibPattern.grid_points(out_size)
	var n := mini(cands.size(), grid.size())
	var res := {"ok": false, "h": null, "inv": null, "used": PackedInt32Array(),
		"ranks": PackedInt32Array(), "rms": INF, "seen": 0,
		"hidden": PackedInt32Array(), "reason": ""}
	var seen := PackedInt32Array()
	for i in n:
		var list: Array = cands[i]
		if not list.is_empty() and list[0]["ok"]:
			seen.append(i)
	res["seen"] = seen.size()
	if seen.size() < MIN_GRID:
		res["reason"] = "ONLY %d OF %d MARKERS SEEN — ARE THEY ALL IN THE SHOT?" % [seen.size(), n]
		return res

	var best: Array = []      # [[grid index, candidate rank], ...]
	var best_err := INF
	var m := seen.size()
	for a in range(0, m - 3):
		for b in range(a + 1, m - 2):
			for c in range(b + 1, m - 1):
				for d in range(c + 1, m):
					var src := PackedVector2Array()
					var dst := PackedVector2Array()
					for k: int in [seen[a], seen[b], seen[c], seen[d]]:
						var list: Array = cands[k]
						src.append(list[0]["pos"])
						dst.append(grid[k])
					var h := CalibHomography.solve(src, dst)
					var inv: CalibHomography = h.inverse() if h != null else null
					if inv == null:
						continue
					var got := _agreeing(cands, grid, inv, n)
					var pairs: Array = got[0]
					var err: float = got[1]
					if pairs.size() > best.size() or (pairs.size() == best.size() and err < best_err):
						best = pairs
						best_err = err
	if best.size() < 4:
		res["reason"] = "THE MARKERS DO NOT AGREE WITH EACH OTHER — IS THE SURFACE FLAT?"
		return res

	var fit := _refit(cands, grid, best, n)
	var hidden := PackedInt32Array()
	if not fit.is_empty():
		var pairs: Array = fit["pairs"]
		hidden = hidden_discs(fit["inv"], out_size, pairs, cands)
		if not hidden.is_empty():
			var kept: Array = []
			for pr: Array in pairs:
				if not hidden.has(pr[0]):
					kept.append(pr)
			var again := _refit(cands, grid, kept, n, hidden)
			if not again.is_empty():
				fit = again
	res["hidden"] = hidden
	if fit.is_empty():
		res["reason"] = "THE MARKERS DO NOT AGREE WITH EACH OTHER — IS THE SURFACE FLAT?"
		return res

	var used := PackedInt32Array()
	var ranks := PackedInt32Array()
	var cols := {}
	var rows := {}
	var pairs2: Array = fit["pairs"]
	for pr: Array in pairs2:
		var gi: int = pr[0]
		used.append(gi)
		ranks.append(int(pr[1]))
		cols[gi % CalibPattern.GRID_COLS] = true
		@warning_ignore("integer_division")
		rows[gi / CalibPattern.GRID_COLS] = true
	res["h"] = fit["h"]
	res["inv"] = fit["inv"]
	res["used"] = used
	res["ranks"] = ranks
	res["rms"] = fit["rms"]
	var spans := cols.has(0) and cols.has(CalibPattern.GRID_COLS - 1) \
			and rows.has(0) and rows.has(CalibPattern.GRID_ROWS - 1)
	if used.size() < MIN_GRID or not spans:
		res["reason"] = "ONLY %d OF %d MARKERS AGREE — IS THE SURFACE FLAT? IS SOMETHING IN THE WAY?" % [used.size(), n]
		return res
	res["ok"] = true
	return res


## How far the same disc sits from itself between two looks at it — the camera
## movement in between. Each look is a candidate list from CalibDetect; the
## closest pair counts, so a decoy in either list cannot fake a movement.
## -1 when either look found nothing (then there is no telling).
static func moved_by(first: Array, again: Array) -> float:
	var best := INF
	for a: Dictionary in first:
		if not a["ok"]:
			continue
		for b: Dictionary in again:
			if not b["ok"]:
				continue
			var pa: Vector2 = a["pos"]
			var pb: Vector2 = b["pos"]
			best = minf(best, pa.distance_to(pb))
	return best if best < INF else -1.0


## Which discs agree with `inv` (output -> camera), each with its best
## candidate. -> [ [[grid index, rank], ...], summed squared error ]
static func _agreeing(cands: Array, grid: PackedVector2Array, inv: CalibHomography, n: int,
		skip: PackedInt32Array = PackedInt32Array()) -> Array:
	var pairs: Array = []
	var err := 0.0
	for i in n:
		if skip.has(i):
			continue
		var want := inv.apply(grid[i])
		if not want.is_finite():
			continue
		var list: Array = cands[i]
		var best_k := -1
		var best_e := INLIER_TOL
		for k in list.size():
			var c: Dictionary = list[k]
			if not c["ok"]:
				continue
			var pos: Vector2 = c["pos"]
			var e := want.distance_to(pos)
			if e <= best_e:
				best_e = e
				best_k = k
		if best_k >= 0:
			pairs.append([i, best_k])
			err += best_e * best_e
	return [pairs, err]


## Least squares through `pairs`, then once more through whatever agrees with
## that. -> { h, inv, pairs, rms } or {} when the points cannot carry a fit.
static func _refit(cands: Array, grid: PackedVector2Array, pairs: Array, n: int,
		skip: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var out := {}
	for _pass in 2:
		if pairs.size() < 4:
			return {}
		var src := PackedVector2Array()
		var dst := PackedVector2Array()
		for pr: Array in pairs:
			var list: Array = cands[pr[0]]
			src.append(list[pr[1]]["pos"])
			dst.append(grid[pr[0]])
		var h := CalibHomography.solve(src, dst)
		var inv: CalibHomography = h.inverse() if h != null else null
		if inv == null:
			return {}
		var got := _agreeing(cands, grid, inv, n, skip)
		pairs = got[0]
		var err: float = got[1]
		out = {"h": h, "inv": inv, "pairs": pairs, "rms": sqrt(err / float(maxi(pairs.size(), 1)))}
	return out


## Which of the fitted discs look too small for where they are. The expected
## area of each is the disc's output-px area times how much the calibration
## magnifies at that spot (the Jacobian of out_to_cam), so perspective — discs
## on the far side of a keystoned picture really are smaller — is not mistaken
## for occlusion. Judged against the MEDIAN ratio, because bloom and the
## half-peak threshold scale every disc alike. -> grid indices.
static func hidden_discs(out_to_cam: CalibHomography, out_size: Vector2, pairs: Array,
		cands: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	if out_to_cam == null or pairs.size() < 3:
		return out
	var ratios := PackedFloat64Array()
	for pr: Array in pairs:
		var p := CalibPattern.solo_point(out_size, pr[0])
		var o := out_to_cam.apply(p)
		var ex := out_to_cam.apply(p + Vector2(1, 0)) - o
		var ey := out_to_cam.apply(p + Vector2(0, 1)) - o
		var expected := PI * CalibPattern.SOLO_R * CalibPattern.SOLO_R * absf(ex.cross(ey))
		var list: Array = cands[pr[0]]
		ratios.append(float(list[pr[1]]["area"]) / maxf(expected, 1.0))
	var sorted := ratios.duplicate()
	sorted.sort()
	@warning_ignore("integer_division")
	var median := sorted[sorted.size() / 2]
	for i in ratios.size():
		if ratios[i] < HIDDEN_RATIO * median:
			var pr: Array = pairs[i]
			out.append(int(pr[0]))
	return out


## The output-px quad for four surface corners marked in camera px. Empty when
## a corner has no image (it sits on the calibration's horizon).
static func surface_to_corners(cam_to_out: CalibHomography,
		surface_cam: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	if cam_to_out == null:
		return out
	for p in surface_cam:
		var q := cam_to_out.apply(p)
		if not q.is_finite():
			return PackedVector2Array()
		out.append(q)
	return out


## Where the camera picture sits on screen: between the hint and the strip, so
## neither can ever cover a marker.
func _img_rect() -> Rect2:
	var area := Rect2(0.0, HINT_H, size.x, maxf(size.y - HINT_H - STRIP_H, 1.0))
	return fit_rect(area, _cam_size)


func _to_cam(screen: Vector2) -> Vector2:
	var r := _img_rect()
	return (screen - r.position) / r.size * _cam_size


func _to_screen(cam: Vector2) -> Vector2:
	var r := _img_rect()
	return r.position + cam / _cam_size * r.size


func _out_size() -> Vector2:
	return output_size_provider.call() if output_size_provider.is_valid() else Vector2(1920, 1080)


func _layout() -> void:
	var r := _img_rect()
	_view.position = r.position
	_view.size = r.size
	_overlay.queue_redraw()


# --- steps ---------------------------------------------------------------

func _go_live() -> void:
	if _busy:
		exposure_requested.emit(0.0)   # an AUTO was cut short mid-sequence
	_run += 1
	_busy = false
	_note = ""
	_auto_info = ""
	_auto_placed = false
	_frozen = null
	_frozen_img = null
	_lines_info = ""
	_wall_why = ""
	_arriving = false
	_checked = ""
	_local = null
	_anchor = []
	_flood = null
	pattern_requested.emit(CalibPattern.Mode.ALL, 0)
	_markers = PackedVector2Array()
	_markers_auto = false
	_surface = PackedVector2Array()
	_wall = PackedVector2Array()
	_wall_true = false
	_frozen_gravity = Vector3.ZERO
	_cam_to_out = null
	_out_to_cam = null
	# step_changed FIRST: the pipeline may need to take the lens back (it let go
	# of it at SURFACE) before there is a live texture to ask for.
	_set_step(Step.LIVE)
	var tex: Texture2D = camera_texture_provider.call() if camera_texture_provider.is_valid() else null
	_view.texture = tex
	if tex != null and tex.get_size().x > 0.0:
		_cam_size = tex.get_size()
	_layout()
	_refresh()


func _set_step(s: int) -> void:
	step = s
	if s != Step.LIVE:
		_view.texture = _shown_tex()
	step_changed.emit(s)


## The still the current step is marked on: the projector-lit frame for the
## surface when AUTO took one, the pattern frame otherwise.
func _shown_tex() -> ImageTexture:
	return _flood if step == Step.SURFACE and _flood != null else _frozen


## One camera frame as pixels, or null. Null also when the camera has not
## delivered a picture yet: its viewport clears to transparent, so alpha 0 in
## the middle means "no frame", which can last seconds while the feed comes up.
func _grab() -> Image:
	var img: Image = null
	if frame_provider.is_valid():
		img = frame_provider.call()
	else:
		var tex: Texture2D = camera_texture_provider.call() if camera_texture_provider.is_valid() else null
		img = tex.get_image() if tex != null else null
	if img == null or img.is_empty():
		return null
	if img.get_pixel(img.get_width() >> 1, img.get_height() >> 1).a <= 0.0:
		return null
	return img


func _shot_pressed() -> void:
	if step != Step.LIVE:
		_go_live()
		return
	if _busy:
		return
	var img := _grab()
	if img == null:
		_say("THE CAMERA HAS NO PICTURE YET — WAIT, THEN FREEZE AGAIN")
		return
	_note = ""
	_frozen = ImageTexture.create_from_image(img)
	_frozen_img = img
	_frozen_gravity = _read_gravity()
	_cam_size = Vector2(img.get_size())
	_layout()
	_set_step(Step.MARKERS)
	_refresh()


# --- AUTO ----------------------------------------------------------------

## The second cell is whatever the step's own extra action is: AUTO in LIVE;
## in SURFACE the OTHER kind of square (WALL, or FROM HERE once the wall's is
## on); BACK in WALL.
func _auto_pressed() -> void:
	if _busy:
		return
	if step == Step.LIVE:
		_run_auto()
	elif step == Step.SURFACE and _cam_to_out != null:
		if _wall_true and _auto_placed:
			_place_from_here()
		else:
			_wall_pressed()
	elif step == Step.WALL:
		_note = ""
		_set_step(Step.SURFACE)
		_refresh()


## Square as the phone sees it — what SURFACE arrives with, and what FROM HERE
## goes back to.
func _place_from_here() -> void:
	_surface = auto_surface(_out_to_cam, _out_size())
	_wall_true = false
	_local = null
	_checked = ""
	_auto_placed = _surface.size() == POINTS
	if _auto_placed:
		print("[calib] auto surface (camera px): %s" % [_surface])
	if _arriving:
		_apply_surface()
	else:
		_points_changed()


## WALL. Lines already in hand (found or tapped earlier on this frame) are
## simply applied again; otherwise look for them. Lands in the WALL step, with
## the reason, whenever that does not end with a picture on the wall.
func _wall_pressed() -> void:
	var by_taps := _wall.size() == WALL_POINTS
	if _wall.size() >= 4 and (by_taps or _gravity() != Vector3.ZERO):
		if _apply_wall(not by_taps):
			return
	if _gravity() == Vector3.ZERO:
		_wall_why = "NO GRAVITY READING"
	if _wall_why != "":
		# Already known not to work on this frame; looking again changes nothing.
		_open_lines(_wall_why)
		return
	_run += 1
	var run := _run
	_busy = true
	var found: bool = await _find_wall(run)
	if run != _run:
		return
	_busy = false
	if not found:
		_open_lines(_wall_why)


## Look for the wall's level lines in the frozen frame and, if they are there,
## put the wall's square on. False (with `_wall_why` saying why) when not; also
## false when `run` was cancelled meanwhile.
func _find_wall(run: int) -> bool:
	_say("LOOKING FOR LEVEL LINES IN THE PICTURE, TO SQUARE IT ON THE WALL")
	# Two frames, so the line above is on screen before the search holds the
	# main thread (~0.1 s on a desk, ~0.3 s on a Pixel 8).
	await get_tree().process_frame
	await get_tree().process_frame
	if run != _run:
		return false
	var frame := PackedVector2Array()
	var o := _out_size()
	for c: Vector2 in [Vector2.ZERO, Vector2(o.x, 0), o, Vector2(0, o.y)]:
		frame.append(_out_to_cam.apply(c))
	var t0 := Time.get_ticks_msec()
	var found := CalibLines.find(_frozen_img, _gravity(), _focal(), _cam_size * 0.5, frame)
	print("[calib] wall: lines in %d ms (focal %.0f px%s) -> %s" % [Time.get_ticks_msec() - t0, _focal(),
		"" if focal_px > 0.0 or focal_per_width > 0.0 else ", an estimate", found])
	_note = ""
	if found["ok"]:
		_wall = found["level"]
		if found["synthesized"]:
			_lines_info = "LEVEL FROM THE ROOM"
		else:
			_lines_info = "%d LEVEL EDGES" % int(found["found"])
		if found["ambiguous"]:
			_lines_info += " — CHECK LINES"
		if _apply_wall(true):
			return true
		_wall_why = _note
		_wall = PackedVector2Array()
		_lines_info = ""
	else:
		_wall_why = str(found["reason"])
	_note = ""
	return false


## The camera's focal length in px: given, from the lens, or CalibWall's
## estimate (0 lets it make one).
func _focal() -> float:
	if focal_px > 0.0:
		return focal_px
	return CalibWall.focal_for(_cam_size, focal_per_width * maxf(_cam_size.x, _cam_size.y))


## Into the WALL step to tap the lines by hand, saying why.
func _open_lines(why: String) -> void:
	_wall = PackedVector2Array()
	_lines_info = ""
	_set_step(Step.WALL)
	_say("%s%s — LEVEL 1 OF 2: TAP 2 POINTS, FAR APART, ON A LINE THAT IS LEVEL ON THE WALL" % [why,
		" (WAS THE PHONE UPRIGHT?)" if why == "NO GRAVITY READING" else ""])


## DARK, each grid disc SOLO, DARK again, then FLOOD and ALL for the two
## stills. Every await is followed by a `run` check: ESC, RETAKE or closing
## the editor bumps _run, and a stale coroutine must not write into the new
## state.
##
## Nothing is located until every frame is in: CalibDetect finds each disc as
## what was bright in its own frame and in NO other, which needs the frames
## that come after it as much as the ones before (see calib_detect.gd for the
## wall run that made that necessary).
func _run_auto() -> void:
	_run += 1
	var run := _run
	_busy = true
	var det := CalibDetect.new()
	var fail := ""
	var solo_frame := PackedInt32Array()   # solo i -> its frame index in det
	var check: CalibDetect = null          # [dark, MOVE_CHECK_DISC again]
	var dump: Array[Image] = []
	var dumping := DirAccess.dir_exists_absolute(DUMP_DIR)

	_say("AUTO — PHONE STILL, NOTHING MOVING IN THE SHOT · READING THE WALL")
	exposure_requested.emit(AUTO_EV)
	pattern_requested.emit(CalibPattern.Mode.DARK, 0)
	# Twice the settle: markers left over in this frame would cancel every disc.
	await get_tree().create_timer(settle_sec * 2.0).timeout
	if run != _run:
		return
	var dark := _grab()
	if dark == null:
		fail = "NO CAMERA FRAME"
	else:
		det.add_frame(dark)
		if dumping:
			dump.append(dark)

	if fail == "":
		var count := CalibPattern.GRID_COLS * CalibPattern.GRID_ROWS
		for i in count:
			pattern_requested.emit(CalibPattern.Mode.SOLO, i)
			_say("AUTO — PHONE STILL, NOTHING MOVING IN THE SHOT · MARKER %d OF %d" % [i + 1, count])
			var img: Image = null
			for attempt in AUTO_TRIES:
				# Shorter than a full settle: a frame taken too early shows the
				# PREVIOUS disc, is_news() says so, and the loop looks again.
				await get_tree().create_timer(settle_sec * 0.7).timeout
				if run != _run:
					return
				img = _grab()
				# Nothing new in the frame = the camera has not caught up with the
				# projector yet (or the disc is not in view). Look again; after
				# the last try keep the frame anyway and let locate() say why.
				if img != null and det.is_news(img):
					break
				print("[calib] auto: disc %d not in the frame yet (try %d)" % [i + 1, attempt + 1])
			if img == null or det.add_frame(img) < 0:
				fail = "NO CAMERA FRAME"
				break
			solo_frame.append(det.frame_count() - 1)
			if dumping:
				dump.append(img)

	if fail == "":
		pattern_requested.emit(CalibPattern.Mode.DARK, 0)
		await get_tree().create_timer(settle_sec).timeout
		if run != _run:
			return
		var dark2 := _grab()
		if dark2 != null:
			det.add_frame(dark2)
			if dumping:
				dump.append(dark2)
		# One disc again, against the dark frame just taken: a detector of its
		# own, so the main one still sees every disc in exactly one frame.
		if dark2 != null and solo_frame.size() > MOVE_CHECK_DISC:
			check = CalibDetect.new()
			check.add_frame(dark2)
			pattern_requested.emit(CalibPattern.Mode.SOLO, MOVE_CHECK_DISC)
			var back: Image = null
			for attempt in AUTO_TRIES:
				await get_tree().create_timer(settle_sec * 0.7).timeout
				if run != _run:
					return
				back = _grab()
				if back != null and check.is_news(back):
					break
			if back == null or check.add_frame(back) < 0:
				check = null
			elif dumping:
				back.save_png("%s/check.png" % DUMP_DIR)

	# The two stills, at the camera's normal exposure — they are for eyes.
	# FLOOD only when the sequence completed: it is for SURFACE, and a failed
	# AUTO is not going there.
	exposure_requested.emit(0.0)
	if fail == "":
		pattern_requested.emit(CalibPattern.Mode.FLOOD, 0)
		await get_tree().create_timer(settle_sec * 2.0).timeout   # exposure has to follow
		if run != _run:
			return
		var lit := _grab()
		_flood = ImageTexture.create_from_image(lit) if lit != null else null
	pattern_requested.emit(CalibPattern.Mode.ALL, 0)
	_say("AUTO — WORKING OUT WHERE THEY LANDED")
	await get_tree().create_timer(settle_sec * 1.5).timeout
	if run != _run:
		return
	var still := _grab()
	var still_gravity := _read_gravity()
	if still == null:
		_busy = false
		_say("AUTO: THE CAMERA HAS NO PICTURE — FREEZE BY HAND WHEN IT DOES")
		return

	# After the last capture, so writing PNGs cannot disturb the timing.
	for d in dump.size():
		dump[d].save_png("%s/frame_%d.png" % [DUMP_DIR, d])
	if dumping:
		still.save_png("%s/still.png" % DUMP_DIR)
		print("[calib] auto: dumped %d frames to %s" % [dump.size(), DUMP_DIR])

	# Locate. Here rather than frame by frame: each disc is judged against the
	# whole sequence. It is a few hundred ms of GDScript, with the readable
	# pattern already back on the wall.
	var fit: Dictionary = {}
	if fail == "":
		var cands: Array = []   # per disc: Array[Dictionary], strongest first
		for i in solo_frame.size():
			cands.append(det.candidates(solo_frame[i], 1))
			print("[calib] auto: disc %d -> %s" % [i + 1, cands[i][0]])
		fit = fit_grid(cands, _out_size())
		var full := solo_frame.size()
		var got: PackedInt32Array = fit["used"]
		if not fit["ok"] or got.size() < full:
			# Some disc's strongest blob was not the disc (something round
			# moved), or the fit fell short. Ask every frame for its runners-up
			# and let the geometry choose again.
			cands.clear()
			for i in solo_frame.size():
				cands.append(det.candidates(solo_frame[i], AUTO_ALTERNATIVES))
			var again := fit_grid(cands, _out_size())
			var got2: PackedInt32Array = again["used"]
			if again["ok"] and (not fit["ok"] or got2.size() > got.size()):
				print("[calib] auto: runners-up help — %d discs agree instead of %d" % [got2.size(), got.size()])
				fit = again
		if not fit["ok"]:
			fail = str(fit["reason"])
		# Movement outranks whatever the fit said: discs that do not agree are
		# what a moving phone looks like, and "is the surface flat?" would send
		# the operator looking at the wrong thing.
		var moved := -1.0
		if check != null:
			_anchor = det.candidates(solo_frame[MOVE_CHECK_DISC], AUTO_ALTERNATIVES)
			moved = moved_by(_anchor, check.candidates(1, AUTO_ALTERNATIVES))
			print("[calib] auto: disc %d shown again sits %.1f camera px from where it was" % [MOVE_CHECK_DISC + 1, moved])
		if moved > MOVE_TOL:
			fail = "THE PHONE MOVED %d PX WHILE AUTO READ THE WALL — REST IT ON SOMETHING" % roundi(moved)
			fit["ok"] = false
	_fit = fit

	_busy = false
	_frozen = ImageTexture.create_from_image(still)
	_frozen_img = still
	_frozen_gravity = still_gravity
	_cam_size = Vector2(still.get_size())
	_layout()

	if fail != "":
		print("[calib] auto failed: %s" % fail)
		_set_step(Step.MARKERS)
		_say("AUTO FAILED — %s — RETAKE, OR TAP THE 4 NUMBERED MARKERS" % fail)
		return

	if dumping:
		# What a replay needs beside the frames (tools/replay_lines.gd).
		var meta := ConfigFile.new()
		var corners := PackedVector2Array()
		var o := _out_size()
		var inv: CalibHomography = fit["inv"]
		for c: Vector2 in [Vector2.ZERO, Vector2(o.x, 0), o, Vector2(0, o.y)]:
			corners.append(inv.apply(c))
		meta.set_value("meta", "gravity", still_gravity)
		meta.set_value("meta", "frame", corners)
		meta.save("%s/meta.cfg" % DUMP_DIR)
	var used: PackedInt32Array = fit["used"]
	var hidden: PackedInt32Array = fit["hidden"]
	var rms: float = fit["rms"]
	print("[calib] auto: %d of %d discs fitted %s (ranks %s), rms %.2f camera px, hidden %s" % [used.size(),
		solo_frame.size(), used, fit["ranks"], rms, hidden])
	_cam_to_out = fit["h"]
	_out_to_cam = fit["inv"]
	# For MARKERS, should the operator go back to look: where the fit puts the
	# four numbered markers of the pattern in the still.
	_markers = PackedVector2Array()
	for p in CalibPattern.marker_points(_out_size()):
		_markers.append(_out_to_cam.apply(p))
	_markers_auto = true
	_set_step(Step.MARKERS)
	_auto_info = "AUTO %d/%d · " % [used.size(), solo_frame.size()]   # the fit's px are in the log
	_next_pressed()   # MARKERS -> SURFACE, saving the calibration on the way


func _next_pressed() -> void:
	if _busy:
		return
	if step == Step.MARKERS:
		if _cam_to_out == null:
			return
		_save_calibration()
		# Arrive squared up (see the header). Corners already marked — a trip
		# back to MARKERS and forward again — are kept and simply re-applied.
		if _surface.is_empty():
			_arrive()
		else:
			_set_step(Step.SURFACE)
			_points_changed()
	elif step == Step.SURFACE:
		# LINES while the wall's square is on: look at (and fix) what it rests
		# on. Otherwise back to the markers.
		_note = ""
		_set_step(Step.WALL if _wall_true and _auto_placed else Step.MARKERS)
		_refresh()
	elif step == Step.WALL:
		# SENSOR: the level lines are in; take plumb from gravity.
		if _wall.size() >= 4 and _gravity() != Vector3.ZERO:
			_apply_wall(true)


## MARKERS -> SURFACE for the first time on this frame. Everything that needs
## the wall to show the pattern and the lens to be ours happens BEFORE the step
## changes (the pipeline gives the deck its picture and its source back on
## SURFACE): the phone's square goes on, the wall's square is looked for — so
## that AUTO, DONE gives it whenever it can be had; it used to take a press of
## WALL, and "AUTO then DONE" on the second wall run left the phone's square
## up: "it doesn't apply the auto" — and, after an AUTO, the result is checked
## on the wall itself.
func _arrive() -> void:
	_run += 1
	var run := _run
	_busy = true
	_arriving = true
	_place_from_here()
	if _gravity() == Vector3.ZERO:
		_wall_why = "NO GRAVITY READING"
	elif _wall_why == "" and _auto_placed:
		await _find_wall(run)
		if run != _run:
			return
	# Only after an AUTO: the phone is resting somewhere then. After a FREEZE
	# it is in a hand, and has moved since.
	if _markers_auto and _auto_placed and not dry_run:
		await _check_on_wall(run)
		if run != _run:
			return
	_arriving = false
	_busy = false
	_note = ""
	_set_step(Step.SURFACE)
	_points_changed()


## Project four discs at the corrected picture's corners, photograph them, and
## compare with where the picture was meant to be (see CHECK_INSET). A small
## miss is corrected and looked at once more; the verdict goes in `_checked`.
func _check_on_wall(run: int) -> void:
	_say("CHECKING THE RESULT ON THE WALL — KEEP THE PHONE WHERE IT IS")
	exposure_requested.emit(AUTO_EV)
	pattern_requested.emit(CalibPattern.Mode.DARK, 0)
	await get_tree().create_timer(settle_sec * 2.0).timeout
	if run != _run:
		return
	var dark := _grab()
	var verdict := "UNCHECKED"
	var first_miss := -1.0
	var before := _local
	for pass_no in 2:
		if dark == null:
			break
		# Where the four discs go — the picture's own corners, a little way in,
		# through the warp exactly as it is set now — and where the camera
		# should see them: the same places in the rectangle that was asked for.
		var unit := PackedVector2Array([Vector2.ZERO, Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		var rect_to_cam := CalibHomography.solve(unit, _surface)
		if rect_to_cam == null:
			break
		var lo := CHECK_INSET
		var hi := 1.0 - CHECK_INSET
		var spots := PackedVector2Array()
		var want := PackedVector2Array()
		for uv: Vector2 in [Vector2(lo, lo), Vector2(hi, lo), Vector2(hi, hi), Vector2(lo, hi)]:
			spots.append(_quad.surface_point(uv.x, uv.y))
			want.append(rect_to_cam.apply(uv))
		# A fifth where AUTO showed the disc it shows twice: if the phone has
		# moved since, THAT one has moved, and nothing here means anything.
		var middle := CalibPattern.solo_point(_out_size(), MOVE_CHECK_DISC)
		var all := spots.duplicate()
		all.append(middle)
		spots_requested.emit(all)
		var det := CalibDetect.new()
		det.add_frame(dark)
		var img: Image = null
		for attempt in AUTO_TRIES:
			await get_tree().create_timer(settle_sec * 0.7).timeout
			if run != _run:
				return
			img = _grab()
			if img != null and det.is_news(img):
				break
		if img == null or det.add_frame(img) < 0:
			break
		if DirAccess.dir_exists_absolute(DUMP_DIR):
			img.save_png("%s/verify_%d.png" % [DUMP_DIR, pass_no])
		var blobs := det.candidates(1, all.size() + 3)
		var moved := moved_by(_anchor, blobs)
		if moved < 0.0 or moved > MOVE_TOL:
			verdict = "UNCHECKED: PHONE MOVED"
			print("[calib] check: the centre disc is %.1f camera px from where AUTO saw it — the phone moved" % moved)
			break
		var seen := PackedVector2Array()
		var miss := 0.0
		for p in want:
			var at := _nearest(blobs, p)
			if at.is_finite():
				seen.append(at)
				miss = maxf(miss, at.distance_to(p))
		if seen.size() != POINTS:
			verdict = "UNCHECKED: %d OF 4 DISCS SEEN" % seen.size()
			break
		print("[calib] check %d: corner discs land %.2f camera px from where the picture was meant to be" % [pass_no, miss])
		if pass_no == 0:
			first_miss = miss
			if miss <= CHECK_OK:
				verdict = "CHECKED %.1f PX" % miss
				break
			if miss > CHECK_MAX:
				verdict = "CHECK: %d PX OFF" % roundi(miss)
				break
			# Correct: the calibration that is exact at these four — where the
			# picture's corners are, which is where it has to be exact — and
			# the surface through it again.
			var local := CalibHomography.solve(seen, spots)
			if local == null:
				verdict = "CHECK: %.1f PX OFF" % miss
				break
			_local = local
			_apply_surface()
			verdict = "CHECK: %.1f PX OFF" % miss   # unless the second look says better
		else:
			if miss < first_miss:
				verdict = "CHECKED %.1f PX (WAS %.1f)" % [miss, first_miss]
			else:
				_local = before   # no better: put it back as it was
				_apply_surface()
				verdict = "CHECK: %.1f PX OFF" % first_miss
	exposure_requested.emit(0.0)
	pattern_requested.emit(CalibPattern.Mode.ALL, 0)
	_checked = verdict
	print("[calib] check: %s" % verdict)


## The disc among `blobs` (CalibDetect candidates) nearest to `p`, if one is
## within CHECK_MATCH; Vector2.INF if not.
func _nearest(blobs: Array, p: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_d := CHECK_MATCH
	for b: Dictionary in blobs:
		if not b["ok"]:
			continue
		var at: Vector2 = b["pos"]
		var d := at.distance_to(p)
		if d < best_d:
			best_d = d
			best = at
	return best


func _undo_pressed() -> void:
	if _busy:
		return
	if step == Step.MARKERS and _markers.size() > 0:
		_markers.remove_at(_markers.size() - 1)
		_markers_auto = false
	elif step == Step.SURFACE and _surface.size() > 0:
		_surface.remove_at(_surface.size() - 1)
		_auto_placed = false
	elif step == Step.WALL and _wall.size() > 0:
		_wall.remove_at(_wall.size() - 1)
		_lines_info = ""
	else:
		return
	_points_changed()


## DONE = leave, keeping whatever is on the wall. Same rule as the warp editor:
## it does NOT write a warp slot — SAVE there is the explicit slot write.
func _done_pressed() -> void:
	var applied := _applied
	set_active(false)
	closed.emit(applied)


## ESC = the wall goes back to the warp it had on entry.
func _esc_pressed() -> void:
	if not _warp_snapshot.is_empty():
		_quad.restore_state(_warp_snapshot)
	set_active(false)
	closed.emit(false)


## Android BACK. DONE, never ESC — a stray BACK must not throw away a keystone
## that is already on the wall (the warp editor's rule, for the same reason).
func handle_back() -> void:
	_done_pressed()


## The camera went away underneath us. Nothing sensible is left to do here.
func abort() -> void:
	if active:
		_esc_pressed()


# --- points --------------------------------------------------------------

func _pts() -> PackedVector2Array:
	match step:
		Step.MARKERS:
			return _markers
		Step.WALL:
			return _wall
	return _surface


func _set_pts(p: PackedVector2Array) -> void:
	match step:
		Step.MARKERS:
			_markers = p
		Step.WALL:
			_wall = p
		_:
			_surface = p


func _max_points() -> int:
	return WALL_POINTS if step == Step.WALL else POINTS


func _points_changed() -> void:
	_note = ""
	if step == Step.MARKERS:
		_solve()
	elif step == Step.SURFACE:
		_apply_surface()
	elif step == Step.WALL and _wall.size() == WALL_POINTS and _grab_id == NO_POINTER:
		if _apply_wall(false):
			return
	_refresh()


## Which way was down when the frame on screen was taken (camera space), or
## ZERO. NOT the sensor now — see the header.
func _gravity() -> Vector3:
	return _frozen_gravity


func _read_gravity() -> Vector3:
	if not gravity_provider.is_valid():
		return Vector3.ZERO
	var g: Vector3 = gravity_provider.call()
	return g.normalized() if g.length() > 0.001 else Vector3.ZERO


## Square the picture up ON THE WALL from the lines in hand (CalibWall), and
## go to SURFACE with it applied. Plumb is the two tapped vertical edges, or
## gravity when `use_gravity`. False, with the reason as the note, when the
## lines do not make a wall.
func _apply_wall(use_gravity: bool) -> bool:
	if _out_to_cam == null or _wall.size() < 4:
		return false
	var level := _wall.slice(0, 4)
	var plumb := PackedVector2Array() if use_gravity else _wall.slice(4, 8)
	var g := _gravity()
	var wall := CalibWall.solve(level, plumb, g if use_gravity else Vector3.ZERO, _cam_size, _focal())
	if wall == null:
		_say("THOSE LINES DO NOT GIVE A LEVEL AND A PLUMB — UNDO AND TAP THEM AGAIN")
		return false
	var rect := wall.surface(_out_to_cam, _out_size())
	if rect.size() != POINTS:
		_say("NO RECTANGLE FITS ON THAT WALL — CHECK THE LINES")
		return false
	print("[calib] wall: plumb from %s (gravity %s), level/plumb %.1f deg off square, keystone on the wall %.2fx"
			% ["gravity" if use_gravity else "taps", g, wall.skew_deg, wall.keystone(_out_to_cam, _out_size())])
	if not use_gravity and g != Vector3.ZERO:
		# Both answers are in hand: say how far the sensor is from the taps.
		# This line is how the sensor's axes get checked on a real phone.
		var by_g := CalibWall.solve(level, PackedVector2Array(), g, _cam_size, _focal())
		if by_g != null:
			print("[calib] wall: gravity plumb is %.2f deg from the tapped plumb"
					% rad_to_deg(acos(clampf(absf(by_g.down.dot(wall.down)), 0.0, 1.0))))
	if use_gravity and _wall.size() > 4:
		_wall = level   # plumb lines half-tapped and then abandoned for SENSOR
	_surface = rect
	_auto_placed = true
	_wall_true = true
	_local = null
	_checked = ""
	_note = ""
	if _arriving:
		_apply_surface()   # the step comes later, with the pattern still up
	else:
		_set_step(Step.SURFACE)
		_points_changed()
	return true


func _solve() -> void:
	if _markers_auto:
		return   # the calibration is AUTO's fit; these four are only its picture
	_cam_to_out = null
	_out_to_cam = null
	if _markers.size() != POINTS:
		return
	var h := CalibHomography.solve(_markers, CalibPattern.marker_points(_out_size()))
	var inv: CalibHomography = h.inverse() if h != null else null
	if h == null or inv == null:
		_note = "THOSE 4 POINTS DO NOT MAKE A USABLE QUAD — UNDO AND RETAP"
		return
	_cam_to_out = h
	_out_to_cam = inv


func _apply_surface() -> void:
	if _surface.size() != POINTS or _cam_to_out == null:
		return
	var corners := surface_to_corners(_local if _local != null else _cam_to_out, _surface)
	if corners.size() != POINTS:
		_note = "A CORNER IS OUTSIDE WHAT THE CALIBRATION CAN REACH — MOVE IT"
		return
	for i in POINTS:
		_quad.set_corner(i, corners[i])
	_applied = true
	# Corners beyond the output are legitimate (the picture is simply cropped by
	# the projector's own frame) but the operator should know why it is cut.
	var frame := Rect2(Vector2.ZERO, _out_size()).grow(2.0)
	for c in corners:
		if not frame.has_point(c):
			_note = "THE SURFACE REACHES PAST THE PROJECTOR'S FRAME — IT WILL BE CROPPED THERE"
			break


func _save_calibration() -> void:
	var cfg := ConfigFile.new()
	_cam_to_out.save_to(cfg, SECTION)
	cfg.set_value(SECTION, "cam_size", _cam_size)
	cfg.set_value(SECTION, "out_size", _out_size())
	cfg.set_value(SECTION, "markers_cam", _markers)
	cfg.set_value(SECTION, "unix_time", int(Time.get_unix_time_from_system()))
	cfg.save(SAVE_PATH)


# --- input ---------------------------------------------------------------
# RAW touch, one pointer at a time, like the warp editor: the mouse is a
# desktop-only fallback so touch emulation cannot land every tap twice.

func _gui_input(event: InputEvent) -> void:
	if not active or step == Step.LIVE or _busy:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_press(event.index, event.position)
		else:
			_release(event.index)
	elif event is InputEventScreenDrag:
		_drag(event.index, event.position)
	elif _use_mouse:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press(-1, event.position)
			else:
				_release(-1)
		elif event is InputEventMouseMotion:
			_drag(-1, event.position)


func _press(id: int, pos: Vector2) -> void:
	# Guarded here as well as in _gui_input: a point dropped in LIVE, or while
	# AUTO is reading the wall, would sit in the list as a phantom first corner.
	if _grab_id != NO_POINTER or _busy or step == Step.LIVE:
		return
	if not _img_rect().grow(GRAB_RADIUS * 0.5).has_point(pos):
		return
	if step == Step.SURFACE:
		_auto_placed = false   # from here on the corners are the operator's
	elif step == Step.MARKERS:
		_markers_auto = false  # ...and so is the calibration
	elif step == Step.WALL:
		_lines_info = ""       # ...and so are the lines
	var pts := _pts()
	# An existing point near the finger is picked up RELATIVE, so it does not
	# jump; otherwise the press drops the next point and keeps hold of it, so
	# press-slide-release places it under the loupe in one gesture.
	var best := -1
	var best_d := WALL_GRAB_RADIUS if step == Step.WALL else GRAB_RADIUS
	for i in pts.size():
		var d := _to_screen(pts[i]).distance_to(pos)
		if d < best_d:
			best_d = d
			best = i
	var cam := _clamp_cam(_to_cam(pos))
	if best == -1:
		if pts.size() >= _max_points():
			return
		pts.append(cam)
		_set_pts(pts)
		best = pts.size() - 1
	_grab_id = id
	_grab_index = best
	_grab_offset = _pts()[best] - cam
	_points_changed()
	accept_event()


func _drag(id: int, pos: Vector2) -> void:
	if id != _grab_id or _grab_index < 0:
		return
	var pts := _pts()
	if _grab_index >= pts.size():
		return
	pts[_grab_index] = _clamp_cam(_to_cam(pos) + _grab_offset)
	_set_pts(pts)
	_points_changed()
	accept_event()


func _release(id: int) -> void:
	if id != _grab_id:
		return
	_grab_id = NO_POINTER
	_grab_index = -1
	if step == Step.WALL:
		_points_changed()   # the eighth point is only acted on once it is let go
	else:
		_refresh()
	accept_event()


func _clamp_cam(p: Vector2) -> Vector2:
	return p.clamp(Vector2.ZERO, _cam_size)


# --- chrome --------------------------------------------------------------

func _say(text: String) -> void:
	_note = text
	_refresh()


func _refresh() -> void:
	var n := _pts().size()
	match step:
		Step.SURFACE:
			_btn_auto.text = "FROM HERE" if _wall_true and _auto_placed else "WALL"
			_btn_auto.disabled = _busy or _cam_to_out == null
		Step.WALL:
			_btn_auto.text = "BACK"
			_btn_auto.disabled = _busy
		_:
			_btn_auto.text = "AUTO"
			_btn_auto.disabled = step != Step.LIVE or _busy
	_btn_shot.text = "FREEZE" if step == Step.LIVE else "RETAKE"
	_btn_shot.disabled = _busy
	_btn_undo.disabled = step == Step.LIVE or n == 0 or _busy
	var sensor := _gravity() != Vector3.ZERO
	match step:
		Step.SURFACE:
			_btn_next.text = "LINES" if _wall_true and _auto_placed else "MARKERS"
			_btn_next.disabled = _busy
		Step.WALL:
			_btn_next.text = "SENSOR"
			_btn_next.disabled = _busy or n < 4 or not sensor
		_:
			_btn_next.text = "NEXT"
			_btn_next.disabled = _busy or step == Step.LIVE or _cam_to_out == null
	_btn_done.disabled = _busy   # ESC stays live: it is the way out of an AUTO
	var text := _note
	var checked := (_checked + " · ") if _checked != "" else ""
	if text == "":
		match step:
			Step.LIVE:
				text = "FRAME THE WHOLE PROJECTION — REST THE PHONE ON SOMETHING, NOT IN THE HAND — AUTO, OR FREEZE TO TAP THE 4 MARKERS"
			Step.MARKERS:
				if n < POINTS:
					text = "TAP THE CENTRE OF MARKER %d" % (n + 1)
				else:
					text = "THE RING SHOULD SIT ON THE CENTRE CROSS — DRAG TO FIX, THEN NEXT"
			Step.SURFACE:
				if n < POINTS:
					text = "%sTAP THE SURFACE'S %s CORNER (AS THE WALL LOOKS)" % [_auto_info, CORNER_NAMES[n]]
				# These three say a lot in one clipped line of ~125 characters, so
				# each keeps only what that square needs said.
				elif _auto_placed and _wall_true:
					text = "SQUARE ON THE WALL · %s · %sRIGHT FACING IT, SKEWED FROM THE SIDE — FROM HERE FLIPS" \
						% [_lines_info if _lines_info != "" else "YOUR LINES", checked]
				elif _auto_placed and _wall_why != "" and _wall.size() < 4:
					text = "%s%sSQUARE AS SEEN FROM THE PHONE ONLY · %s · WALL: TAP LINES" % [_auto_info, checked, _wall_why]
				elif _auto_placed:
					text = "%s%sSQUARE AS SEEN FROM THE PHONE — WALL SQUARES IT FOR PEOPLE FACING IT" % [_auto_info, checked]
				else:
					text = "THE PICTURE IS ON THE WALL — DRAG A CORNER TO ADJUST — DONE KEEPS IT"
			Step.WALL:
				if n < 2:
					text = "LEVEL 1 OF 2 — TAP 2 POINTS, FAR APART, ON A LINE THAT IS LEVEL ON THE WALL (SHELF, SKIRTING, CEILING)"
				elif n < 4:
					text = "LEVEL 2 OF 2 — AND ON ANOTHER, AS FAR ABOVE OR BELOW THE FIRST AS YOU CAN"
				elif n == 4 and _lines_info != "":
					text = "THE LEVEL LINES IT FOUND — DRAG AN END TO FIX ONE, UNDO TO TAP YOUR OWN — THEN SENSOR (BACK LEAVES IT)"
				elif n < 6:
					text = "PLUMB — %sTAP 2 POINTS, FAR APART, ON A VERTICAL EDGE (DOOR FRAME, CORNER)" \
						% ("SENSOR USES THE PHONE'S GRAVITY, OR " if sensor else "")
				else:
					text = "PLUMB 2 OF 2 — AND ON ANOTHER, ON THE OTHER SIDE OF THE PICTURE IF YOU CAN"
	if dry_run:
		text = "NO PROJECTOR LINK · " + text
	if heat_provider.is_valid() and int(heat_provider.call()) >= 3:
		text = "PHONE HOT — BE QUICK · " + text
	_hint.text = text
	_overlay.queue_redraw()


## The hint again — for when something outside the editor changed what it
## should say (the phone's heat).
func refresh_hint() -> void:
	if active:
		_refresh()


func _make_button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, STRIP_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # even M8 cells
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(on_press)
	return b


# --- drawing -------------------------------------------------------------

func _draw_overlay() -> void:
	if not active or step == Step.LIVE:
		return
	var font := get_theme_default_font()
	# Where the projector's own frame lands in the camera picture — the limit
	# of what the keystone can reach, and a second look at the calibration.
	if _out_to_cam != null:
		var o := _out_size()
		var frame := PackedVector2Array()
		for c: Vector2 in [Vector2.ZERO, Vector2(o.x, 0), o, Vector2(0, o.y)]:
			var p := _out_to_cam.apply(c)
			if p.is_finite():
				frame.append(_to_screen(p))
		if frame.size() == POINTS:
			frame.append(frame[0])
			_overlay.draw_polyline(frame, Color(M8_GREEN, 0.45), 1.5)
		if step == Step.MARKERS:
			var ring := _out_to_cam.apply(CalibPattern.centre_point(o))
			if ring.is_finite():
				_overlay.draw_arc(_to_screen(ring), 16.0, 0.0, TAU, 48, M8_GREEN, 2.0)

	var pts := _pts()
	if step == Step.WALL or (step == Step.SURFACE and _wall_true and _auto_placed):
		# Each finished pair as the line it stands for, run across the picture:
		# a line that is visibly not along its edge is wrong. In SURFACE they
		# are fainter — there to show what the wall's square rests on.
		var shade := 0.6 if step == Step.WALL else 0.3
		for i in range(0, _wall.size() - 1, 2):
			var a := _to_screen(_wall[i])
			var b := _to_screen(_wall[i + 1])
			var dir := (b - a).normalized()
			if dir != Vector2.ZERO:
				_overlay.draw_line(a - dir * 3000.0, b + dir * 3000.0, Color(M8_GREEN, shade), 1.5)
	if step == Step.SURFACE and pts.size() >= 2:
		var outline := PackedVector2Array()
		for p in pts:
			outline.append(_to_screen(p))
		if pts.size() == POINTS:
			outline.append(outline[0])
		_overlay.draw_polyline(outline, M8_GREEN, 2.0)
	for i in pts.size():
		var s := _to_screen(pts[i])
		var held := i == _grab_index
		_overlay.draw_line(s - Vector2(18, 0), s + Vector2(18, 0), M8_GREEN, 2.0)
		_overlay.draw_line(s - Vector2(0, 18), s + Vector2(0, 18), M8_GREEN, 2.0)
		_overlay.draw_arc(s, 26.0, 0.0, TAU, 40, M8_GREEN, 3.0 if held else 1.5)
		var tag := CORNER_TAGS[i % 4]
		if step == Step.MARKERS:
			tag = str(i + 1)
		elif step == Step.WALL:
			@warning_ignore("integer_division")
			tag = ("L%d" if i < 4 else "P%d") % ((i % 4) / 2 + 1)
		_overlay.draw_string(font, s + Vector2(30, -14), tag,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 22, M8_TEXT)
	_draw_loupe(pts)


## A magnified view of the frozen frame around the held point. The finger is on
## top of exactly the pixels that matter; this is what makes a tap accurate.
func _draw_loupe(pts: PackedVector2Array) -> void:
	var still := _shown_tex()
	if still == null or _grab_index < 0 or _grab_index >= pts.size():
		return
	var p := pts[_grab_index]
	var s := _to_screen(p)
	# Float above the finger; below it when there is no room above.
	var centre := s + Vector2(0, -LOUPE_GAP)
	if centre.y - LOUPE_SIZE * 0.5 < 0.0:
		centre = s + Vector2(0, LOUPE_GAP)
	centre.x = clampf(centre.x, LOUPE_SIZE * 0.5, maxf(size.x - LOUPE_SIZE * 0.5, LOUPE_SIZE * 0.5))
	var dest := Rect2(centre - Vector2.ONE * LOUPE_SIZE * 0.5, Vector2.ONE * LOUPE_SIZE)
	var src := Rect2(p - Vector2.ONE * LOUPE_SRC * 0.5, Vector2.ONE * LOUPE_SRC)
	_overlay.draw_rect(dest, Color.BLACK)
	_overlay.draw_texture_rect_region(still, dest, src)
	_overlay.draw_rect(dest, M8_GREEN, false, 2.0)
	_overlay.draw_line(centre - Vector2(LOUPE_SIZE * 0.5, 0), centre + Vector2(LOUPE_SIZE * 0.5, 0),
		Color(M8_GREEN, 0.7), 1.0)
	_overlay.draw_line(centre - Vector2(0, LOUPE_SIZE * 0.5), centre + Vector2(0, LOUPE_SIZE * 0.5),
		Color(M8_GREEN, 0.7), 1.0)
