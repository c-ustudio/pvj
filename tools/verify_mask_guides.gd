extends SceneTree
## Headless check of the mask editor's projector guides (scripts/mask_guides.gd)
## against the real RegionCompositor + RegionEditor.
##
##   godot --headless --path <project> --script tools/verify_mask_guides.gd
##
## Checks:
##   1. The guides show only while the editor is open.
##   2. A press reports the finger in OUTPUT px; a release clears it.
##   3. A point placed while drawing follows the finger until it lifts, and
##      the earlier points do not move.
##   4. A tap on the first point still closes the mask.
##   5. The GUIDES cell hides them with the editor open, and is saved.
##   6. MASK SETS: a saved set brings the mapping back exactly.

const OUT := Vector2(1920, 1080)

var _fails: int = 0
var _checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
	print("%s  %s%s" % ["ok  " if cond else "FAIL", what, ("  — " + detail) if detail != "" else ""])


func _run() -> void:
	var comp := RegionCompositor.new()
	comp.output_size = OUT
	root.add_child(comp)
	var ed := RegionEditor.new()
	root.add_child(ed)
	ed.setup(comp, PackedStringArray(["Off"]), "")
	# Output shown at half size, offset — so screen px and output px differ.
	var xf := Transform2D(0.0, Vector2(0.5, 0.5), 0.0, Vector2(100, 40))
	ed.xform_provider = func() -> Transform2D: return xf
	ed.output_size_provider = func() -> Vector2: return OUT
	var guides := MaskGuides.new()
	guides.editor = ed
	guides.visible = false
	root.add_child(guides)

	guides._process(0.0)
	_ok(not guides.visible, "guides are hidden while the editor is closed")
	ed.set_active(true)
	guides._process(0.0)
	_ok(guides.visible, "guides show when the editor opens")

	ed._start_draw()
	var a := Vector2(400, 300)
	ed._press(xf * a)
	_ok(ed.cursor_on and ed.cursor_out.distance_to(a) < 0.01, "a press reports the finger in output px",
		str(ed.cursor_out))
	_ok(ed._draft.size() == 1 and ed._op == "draft", "the press places a point that is still held")
	var a2 := Vector2(460, 340)
	ed._drag_to(xf * a2)
	_ok(ed._draft.size() == 1 and ed._draft[0].distance_to(a2) < 0.01, "the held point follows the finger",
		str(ed._draft))
	ed._release(xf * a2)
	_ok(not ed.cursor_on and ed._op == "", "a release clears the finger and the hold")

	var b := Vector2(1200, 320)
	ed._press(xf * b)
	ed._drag_to(xf * Vector2(1250, 300))
	ed._release(xf * Vector2(1250, 300))
	var c := Vector2(900, 800)
	ed._press(xf * c)
	ed._release(xf * c)
	_ok(ed._draft.size() == 3 and ed._draft[0].distance_to(a2) < 0.01
		and ed._draft[1].distance_to(Vector2(1250, 300)) < 0.01,
		"earlier points stay where they were left", str(ed._draft))

	ed._press(xf * a2)
	ed._release(xf * a2)
	_ok(comp.region_count() == 1 and not ed._drawing and comp.get_points(0).size() == 3,
		"a tap on the first point closes the mask", "regions %d" % comp.region_count())

	guides._draw_check()
	# The GUIDES cell: off hides them from the projector with the editor still
	# open, and the choice is written to regions.cfg.
	var was := ed.projector_guides
	ed._toggle_guides()
	guides._process(0.0)
	_ok(ed.projector_guides != was and guides.visible == ed.projector_guides and ed.active,
		"the GUIDES cell hides the guides with the editor still open")
	var cfg := ConfigFile.new()
	cfg.load(RegionEditor.SAVE_PATH)
	_ok(bool(cfg.get_value("guides", "projector", was)) == ed.projector_guides, "the choice is saved")
	ed._toggle_guides()   # leave the desktop's regions.cfg as it was found
	guides._process(0.0)
	_ok(ed.projector_guides == was and guides.visible == was, "and back again")
	# MASK SETS: the mapping goes into a slot, the screen is changed, and the
	# slot brings back exactly what was saved. Uses the LAST slot and removes
	# its file afterwards, so a desktop user's own sets are not touched.
	var slot := RegionEditor.SET_COUNT
	var had := FileAccess.file_exists(ed._set_path(slot))
	var keep := FileAccess.get_file_as_bytes(ed._set_path(slot)) if had else PackedByteArray()
	# duplicate(): a packed array is shared by reference, and the move below
	# would otherwise move this copy too.
	var before := comp.get_points(0).duplicate()
	_ok(ed.save_set(slot) and ed.set_count_of(slot) == 1, "a set saves the mapping on screen")
	comp.add_region(PackedVector2Array([Vector2(100, 100), Vector2(300, 100), Vector2(200, 300)]))
	var moved := comp.get_points(0)
	moved[0] += Vector2(50, 50)
	comp.set_points(0, moved)
	_ok(comp.region_count() == 2, "the screen was changed after the save")
	_ok(ed.load_set(slot) and comp.region_count() == 1, "loading the set replaces what is on screen",
		"regions %d" % comp.region_count())
	var after := comp.get_points(0)
	var worst := 0.0
	for i in before.size():
		worst = maxf(worst, before[i].distance_to(after[i]))
	_ok(after.size() == before.size() and worst < 0.01, "the mask comes back where it was saved",
		"worst %.4f px" % worst)
	_ok(not ed.load_set(0) and comp.region_count() == 1, "a slot that does not exist loads nothing")
	if had:
		var f := FileAccess.open(ed._set_path(slot), FileAccess.WRITE)
		f.store_buffer(keep)
		f.close()
	else:
		DirAccess.remove_absolute(ed._set_path(slot))

	ed.set_active(false)
	guides._process(0.0)
	_ok(not guides.visible and not ed.cursor_on, "closing the editor hides the guides")

	print("\n%d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
