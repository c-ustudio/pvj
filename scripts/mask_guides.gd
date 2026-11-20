class_name MaskGuides
extends Node2D
## The mask editor's guides ON THE PROJECTOR.
##
## RegionEditor draws its outlines, points and handles on the UI layer — the
## phone only. Mapping a real object is done looking at the OBJECT, not the
## phone: the performer has to see, on the thing being mapped, where the finger
## is and where the points have landed. This node draws that inside MaskWorld
## (above the compositor), so it is part of the picture QuadWarp samples and
## reaches the wall through the same path as the masks themselves.
##
## What it draws, in OUTPUT px, only while the editor is open and its GUIDES
## cell is ON (off = draw a mask mid-set without the audience seeing lines):
##   - every mask's outline (the selected one brighter, with its points, and
##     in EDIT the nudge pad's point boxed a second time);
##   - the mask being drawn: its points and edges, the edge back to the first
##     point once it can be closed, and the close target;
##   - a full-height / full-width CROSSHAIR through the finger while it is down
##     — the way to find a corner of the object before letting go.
##
## A view of the editor's state: it owns none. ⚠️ It IS in the output while the
## editor is open — a recording made then has the guides in it.

const GREEN := Color(0.0, 1.0, 0.255)
const YELLOW := Color(1.0, 0.867, 0.0)
const RED := Color(1.0, 0.267, 0.133)
const CURSOR := Color(1.0, 1.0, 1.0, 0.9)
const LINE_W := 3.0            ## output px: one projector pixel is too thin to find
const POINT_R := 9.0           ## half-size of a point's square
const CURSOR_GAP := 14.0       ## the crosshair leaves the spot itself uncovered

var editor: RegionEditor


func _process(_delta: float) -> void:
	var on := editor != null and is_instance_valid(editor) and editor.active \
		and editor.projector_guides
	if on != visible:
		visible = on
	if on:
		queue_redraw()   # a handful of lines; the editor's state changes under a finger


func _square(p: Vector2, r: float, col: Color) -> void:
	draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), col, false, LINE_W)


## For the headless check: run the draw path's READS (nothing can be drawn
## outside a draw pass) so a renamed editor field fails there, not on a wall.
func _draw_check() -> void:
	if editor == null or editor.comp == null:
		return
	for i in editor.comp.region_count():
		editor.comp.get_points(i)
	var _s := [editor._selected, editor._mode, editor._drawing, editor._draft,
		editor._edit, editor._sel_vert,
		editor.cursor_on, editor.cursor_out, editor._hit_r(RegionEditor.CLOSE_RADIUS),
		editor.comp.output_size]


func _draw() -> void:
	if editor == null or not is_instance_valid(editor) or not editor.active or editor.comp == null:
		return
	var comp := editor.comp
	for i in comp.region_count():
		var pts := comp.get_points(i)
		var n := pts.size()
		if n < 2:
			continue
		var sel := i == editor._selected
		var col := Color(GREEN, 1.0 if sel else 0.55)
		for k in n:
			draw_line(pts[k], pts[(k + 1) % n], col, LINE_W)
		if sel and editor._mode != "transform":
			var pcol := RED if editor._mode == "delpt" else GREEN
			for p in pts:
				_square(p, POINT_R, pcol)
			if editor._edit and editor._sel_vert >= 0 and editor._sel_vert < n:
				_square(pts[editor._sel_vert], POINT_R * 2.5, pcol)
	if editor._drawing and editor._draft.size() >= 1:
		var d := editor._draft
		for k in range(d.size() - 1):
			draw_line(d[k], d[k + 1], YELLOW, LINE_W)
		if d.size() >= 3:
			# Where the mask will close, and the target that closes it.
			draw_dashed_line(d[d.size() - 1], d[0], Color(YELLOW, 0.6), LINE_W, 16.0)
			_square(d[0], editor._hit_r(RegionEditor.CLOSE_RADIUS), YELLOW)
		for p in d:
			_square(p, POINT_R, YELLOW)
	if editor.cursor_on:
		var c := editor.cursor_out
		var sz := comp.output_size
		draw_line(Vector2(c.x, 0.0), Vector2(c.x, c.y - CURSOR_GAP), CURSOR, 2.0)
		draw_line(Vector2(c.x, c.y + CURSOR_GAP), Vector2(c.x, sz.y), CURSOR, 2.0)
		draw_line(Vector2(0.0, c.y), Vector2(c.x - CURSOR_GAP, c.y), CURSOR, 2.0)
		draw_line(Vector2(c.x + CURSOR_GAP, c.y), Vector2(sz.x, c.y), CURSOR, 2.0)
