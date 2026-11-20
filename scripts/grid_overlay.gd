class_name GridOverlay
extends Control
## Toggleable projection TEST GRID.
##
## Lives INSIDE the active pre-warp viewport — ShaderSlot on the no-mask path,
## MaskWorld while polygon masks own the output (pipeline's
## _refresh_output_source reparents it on every routing change) — so the grid
## is always baked into the texture QuadWarp samples: it warps with the footage
## and reaches the projector through DUAL·TEX on BOTH paths. That is the point:
## straight grid lines on the WALL are only straight if the warp is right; a
## UI-layer grid (like the editor's striped background) would always look
## straight on the phone and prove nothing.
##
## Drawn topmost in its viewport and NOT run through any effect material (the
## effect sits on ShaderSlot's display TextureRect; mask FX sit on the region
## polygons — the grid is a sibling drawn after either).
##
## 16x9 cells on a 16:9 output = square cells; the dimmed backing keeps the
## lines legible over bright footage. Full-rect anchors track the QUALITY
## resize of the shader stage.

const COLS := 16
const ROWS := 9
const M8_GREEN := Color(0.0, 1.0, 0.255)   ## #00FF41 (matches pipeline M8 palette)
const BACKING := Color(0.0, 0.0, 0.0, 0.45)
const LINE := Color(0.0, 1.0, 0.255, 0.8)
const FAINT := Color(0.0, 1.0, 0.255, 0.4)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	resized.connect(queue_redraw)


func _draw() -> void:
	var sz := size
	if sz.x <= 1.0 or sz.y <= 1.0:
		return
	draw_rect(Rect2(Vector2.ZERO, sz), BACKING)
	# Corner-to-corner diagonals: the fastest keystone tell.
	draw_line(Vector2.ZERO, sz, FAINT, 2.0)
	draw_line(Vector2(sz.x, 0), Vector2(0, sz.y), FAINT, 2.0)
	for i in COLS + 1:
		var x := sz.x * float(i) / float(COLS)
		draw_line(Vector2(x, 0), Vector2(x, sz.y), LINE, 2.0)
	for j in ROWS + 1:
		var y := sz.y * float(j) / float(ROWS)
		draw_line(Vector2(0, y), Vector2(sz.x, y), LINE, 2.0)
	# Centre cross drawn explicitly — with an odd ROW count the horizontal
	# centreline falls BETWEEN grid rows, so it can't ride a loop line.
	draw_line(Vector2(sz.x * 0.5, 0), Vector2(sz.x * 0.5, sz.y), M8_GREEN, 4.0)
	draw_line(Vector2(0, sz.y * 0.5), Vector2(sz.x, sz.y * 0.5), M8_GREEN, 4.0)
	# Centre circle: circles read scale/aspect errors that straight lines hide.
	draw_arc(sz * 0.5, sz.y * 0.25, 0.0, TAU, 96, LINE, 2.0)
	draw_rect(Rect2(Vector2.ZERO, sz), M8_GREEN, false, 4.0)
