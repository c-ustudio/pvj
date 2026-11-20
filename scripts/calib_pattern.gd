class_name CalibPattern
extends Node2D
## The projected CALIBRATION PATTERN — four numbered markers at known output
## pixels, plus a centre mark, on black.
##
## The whole point of camera calibration is that the app DREW the pattern, so
## where each marker sits in projector space is known exactly; the camera only
## has to say where it landed (CAMERA_PROCEDURAL_MASKS_SPEC.md §1).
##
## ⚠️ TOPMOST child of OutputWorld, drawn AFTER QuadWarp — never inside
## ShaderSlot like the test grid. The grid is there to be warped with the
## footage. This must NOT be warped: its positions have to be raw output px,
## the space the projector's own pixels live in, or the solved homography would
## have the current keystone baked into it and correct for it twice.
##
## Black everywhere else, deliberately: it hides the deck (whose source is the
## camera while calibrating, so an uncovered output would be a feedback loop)
## and it gives the camera four bright things on a dark wall to expose for.
##
## MODES. ALL is the pattern a person reads. The other three exist for AUTO
## detection (CalibDetect), which never looks at ALL:
##   DARK   nothing — the reference frame everything else is subtracted from.
##   SOLO   ONE plain disc (a point of grid_points()), no ring and no number.
##          One disc at a time is what makes detection unambiguous: the only thing that
##          changed between DARK and this frame is that disc, so its identity
##          is known (it is the one that was asked for) however the camera is
##          rotated or mirrored, and its centroid is its centre.
##   FLOOD  white. Lights the surface with the projector itself so its edges
##          can be seen in a dark room — the frame the corners are tapped on.

## Marker inset from each edge, as a fraction of the output. Wide enough to be
## a well-conditioned quad, far enough in that the markers still land on the
## surface when the projector overshoots it.
const INSET := 0.18
const DISC_R := 22.0
const RING_R := 46.0
const CENTRE_R := 14.0
const LABEL_SIZE := 96
## SOLO disc radius. Bigger than the ALL disc: it has to survive distance and a
## camera that is exposing for a black wall. A disc's centroid does not care
## how much it blooms, as long as it blooms evenly.
const SOLO_R := 34.0
const WHITE := Color(1, 1, 1, 1)

enum Mode { ALL, DARK, SOLO, FLOOD, SPOTS }
## AUTO's points: a GRID_COLS x GRID_ROWS lattice, row-major (index = row *
## GRID_COLS + col), shown one disc at a time. NOT the four numbered markers a
## person taps: nine points fitted together pin the picture's corners, where
## four inset ones only reach them by extrapolation (about twice the error),
## and one of nine can be hidden or missed without losing the calibration.
const GRID_COLS := 3
const GRID_ROWS := 3
## How far in from the edges the grid's outer points sit. Closer to the edge
## than INSET because these no longer have to be tapped, and the fit can lose
## one that falls off the surface.
const GRID_INSET := 0.1

var mode: int = Mode.ALL
var solo_index: int = 0
## SPOTS: plain discs at these OUTPUT px, all at once. For the check after the
## keystone is set — the editor works out where the corrected picture's
## corners are and asks for discs exactly there.
var spots: PackedVector2Array = PackedVector2Array()

var out_size: Vector2 = Vector2(1920, 1080):
	set(v):
		out_size = v
		queue_redraw()


func _ready() -> void:
	visible = false
	z_index = RenderingServer.CANVAS_ITEM_Z_MAX   # above every OutputWorld sibling


## The four marker centres in OUTPUT px, in the corner order the rest of the
## app uses: TL, TR, BR, BL.
static func marker_points(size: Vector2) -> PackedVector2Array:
	var lo := size * INSET
	var hi := size * (1.0 - INSET)
	return PackedVector2Array([
		lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y),
	])


func show_mode(m: int, index: int = 0) -> void:
	mode = m
	solo_index = index
	queue_redraw()


func show_spots(points: PackedVector2Array) -> void:
	mode = Mode.SPOTS
	spots = points
	queue_redraw()


## AUTO's lattice in OUTPUT px, row-major.
static func grid_points(size: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for j in GRID_ROWS:
		for i in GRID_COLS:
			var u := lerpf(GRID_INSET, 1.0 - GRID_INSET, float(i) / float(GRID_COLS - 1))
			var v := lerpf(GRID_INSET, 1.0 - GRID_INSET, float(j) / float(GRID_ROWS - 1))
			out.append(Vector2(size.x * u, size.y * v))
	return out


## Where SOLO `index` is drawn, in output px: the grid point of that index.
static func solo_point(size: Vector2, index: int) -> Vector2:
	var pts := grid_points(size)
	return pts[clampi(index, 0, pts.size() - 1)]


## The centre mark. Not used by the solve — it is the free CHECK: once four
## markers are tapped, the calibration predicts where this one sits in the
## camera frame, and the operator can see whether the prediction lands on it.
static func centre_point(size: Vector2) -> Vector2:
	return size * 0.5


func _draw() -> void:
	if mode == Mode.FLOOD:
		draw_rect(Rect2(Vector2.ZERO, out_size), WHITE)
		return
	draw_rect(Rect2(Vector2.ZERO, out_size), Color.BLACK)
	if mode == Mode.DARK:
		return
	if mode == Mode.SOLO:
		draw_circle(solo_point(out_size, solo_index), SOLO_R, WHITE)
		return
	if mode == Mode.SPOTS:
		for p in spots:
			draw_circle(p, SOLO_R, WHITE)
		return
	var pts := marker_points(out_size)
	var font := ThemeDB.fallback_font
	var centre := centre_point(out_size)
	for i in pts.size():
		var p := pts[i]
		draw_circle(p, DISC_R, WHITE)
		draw_arc(p, RING_R, 0.0, TAU, 64, WHITE, 3.0)
		# The number sits on the side AWAY from the centre, so it can never be
		# mistaken for part of a neighbouring marker.
		var away := (p - centre).normalized()
		var label_at := p + away * (RING_R + LABEL_SIZE * 0.55)
		draw_string(font, label_at + Vector2(-LABEL_SIZE * 0.3, LABEL_SIZE * 0.35),
			str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1.0, LABEL_SIZE, WHITE)
	# A cross, not a disc — it must not be confusable with the four.
	draw_line(centre - Vector2(CENTRE_R * 3.0, 0), centre + Vector2(CENTRE_R * 3.0, 0), WHITE, 4.0)
	draw_line(centre - Vector2(0, CENTRE_R * 3.0), centre + Vector2(0, CENTRE_R * 3.0), WHITE, 4.0)
	draw_arc(centre, CENTRE_R, 0.0, TAU, 48, WHITE, 3.0)
