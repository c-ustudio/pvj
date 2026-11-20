extends SceneTree
## Headless check of the mask editor's NUDGE PAD and the masks' CHECKER
## against the real RegionCompositor + RegionEditor + MaskGuides.
##
##   godot --headless --path <project> --script tools/verify_mask_nudge.gd
##
## Checks:
##   1. EDIT shows the pad and selects a point; leaving EDIT hides it.
##   2. An arrow moves ONLY the selected point, 10 output px (1 on fine),
##      whatever the phone's preview scale.
##   3. Grabbing a point selects it; the centre cell cycles; ADD PT selects the
##      new point; DEL PT keeps the same point selected.
##   4. ESC rolls a nudge back.
##   6. FIT: a 4-point mask's warp corners are its points (any drawing order);
##      a triangle gets the upright parallelogram on its flattest edge.
##   5. CHECKER: the region draws the board through an identity UV (the warp
##      parameter square), with square-ish cells; off restores the clip mapping
##      and the effect.
## (Shader COMPILATION is not provable headless — see tools/shader_probe.gd.)

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


func _uv0(comp: RegionCompositor) -> Vector2:
	var mesh := (comp._regions[0]["mesh_node"] as MeshInstance2D).mesh as ArrayMesh
	var arrays := mesh.surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	return uvs[uvs.size() - 1]   # the (1,1) corner of the parameter square


func _run() -> void:
	var comp := RegionCompositor.new()
	comp.output_size = OUT
	root.add_child(comp)
	var fx_shader := Shader.new()
	fx_shader.code = "shader_type canvas_item;\nvoid fragment() {}\n"
	comp.setup([{"name": "Off", "shader": null}, {"name": "Fx", "shader": fx_shader}])
	var ed := RegionEditor.new()
	root.add_child(ed)
	ed.setup(comp, PackedStringArray(["Off", "Fx"]), "")
	# Output shown at half size, offset — so screen px and output px differ.
	var xf := Transform2D(0.0, Vector2(0.5, 0.5), 0.0, Vector2(100, 40))
	ed.xform_provider = func() -> Transform2D: return xf
	ed.output_size_provider = func() -> Vector2: return OUT
	var guides := MaskGuides.new()
	guides.editor = ed
	root.add_child(guides)
	ed.set_active(true)

	var quad := PackedVector2Array([Vector2(400, 200), Vector2(1200, 250),
		Vector2(1100, 800), Vector2(450, 700)])
	comp.add_region(quad.duplicate())   # packed arrays are shared by reference
	ed._selected = 0
	ed._sync_selected()

	# 1. EDIT shows the pad with a point selected.
	ed._radio_edit()
	_ok(ed._pad.visible and ed._sel_vert == 0 and ed._btn_point.text == "P1",
		"EDIT shows the pad with point 1 selected", "sel %d '%s'" % [ed._sel_vert, ed._btn_point.text])

	# 2. One arrow press = 10 output px on that point, nothing else moves.
	ed._start_nudge(Vector2(1, 0))
	ed._stop_nudge()
	var p := comp.get_points(0)
	_ok(p[0].distance_to(quad[0] + Vector2(10, 0)) < 0.001, "► moves the point 10 output px", str(p[0]))
	var others := true
	for i in range(1, 4):
		others = others and p[i].distance_to(quad[i]) < 0.001
	_ok(others, "the other points stay put")
	ed._toggle_step()
	ed._start_nudge(Vector2(0, -1))
	ed._stop_nudge()
	p = comp.get_points(0)
	_ok(p[0].distance_to(quad[0] + Vector2(10, -1)) < 0.001, "fine step: ▲ moves it 1 px", str(p[0]))
	_ok(not ed.cursor_on, "the projector crosshair goes when the arrow is let go")
	# Hold-to-repeat: nothing until REPEAT_DELAY, then one step per REPEAT_SEC.
	ed._start_nudge(Vector2(0, 1))
	ed._process(RegionEditor.REPEAT_DELAY - 0.01)
	var held_once := comp.get_points(0)[0]
	ed._process(0.01 + RegionEditor.REPEAT_SEC * 2.0 + 0.001)
	ed._stop_nudge()
	var held := comp.get_points(0)[0]
	_ok(held_once.distance_to(quad[0] + Vector2(10, 0)) < 0.001
		and held.distance_to(quad[0] + Vector2(10, 3)) < 0.001,
		"holding repeats after the delay", "%s then %s" % [held_once, held])
	ed._toggle_step()

	# 3. Selection: grab, cycle, add, delete.
	ed._press(xf * quad[2])
	ed._release(xf * quad[2])
	_ok(ed._sel_vert == 2 and ed._btn_point.text == "P3", "grabbing a point selects it")
	ed._cycle_vert()
	_ok(ed._sel_vert == 3, "the centre cell cycles to the next point")
	ed._cycle_vert()
	_ok(ed._sel_vert == 0, "…and wraps round")
	ed._set_mode("addpt")
	var mid := (quad[1] + quad[2]) * 0.5 + Vector2(5, 0)
	ed._press(xf * mid)
	ed._release(xf * mid)
	_ok(comp.get_points(0).size() == 5 and ed._sel_vert == 2, "ADD PT selects the new point",
		"sel %d" % ed._sel_vert)
	ed._set_mode("addpt")   # back to reshape
	ed._select_vert(3)
	var kept := comp.get_points(0)[3]
	ed._set_mode("delpt")
	ed._press(xf * comp.get_points(0)[1])
	ed._release(xf * comp.get_points(0)[1])
	_ok(comp.get_points(0).size() == 4 and ed._sel_vert == 2
		and comp.get_points(0)[2].distance_to(kept) < 0.001,
		"DEL PT before the selection keeps the same point selected", "sel %d" % ed._sel_vert)
	ed._set_mode("delpt")
	guides._draw_check()

	# 4. ESC rolls everything since EDIT back, nudges included.
	ed._exit_fullscreen(true)
	p = comp.get_points(0)
	var same := p.size() == 4
	for i in mini(p.size(), 4):
		same = same and p[i].distance_to(quad[i]) < 0.001
	_ok(same and not ed._pad.visible, "ESC rolls the nudges back and hides the pad", str(p))

	# 5. CHECKER.
	comp.set_effect(0, 1)
	comp.set_content_scale(0, Vector2(2.0, 2.0))   # so the clip's UVs are NOT the parameter square
	var clip_uv := _uv0(comp)
	ed._toggle_checker()
	var mat := (comp._regions[0]["mesh_node"] as MeshInstance2D).material as ShaderMaterial
	_ok(comp.checker and mat != null and mat.shader == RegionCompositor.CHECKER_SHADER,
		"CHECKER puts the board on the mask")
	_ok(_uv0(comp).distance_to(Vector2.ONE) < 0.0001, "the board spans the warp's parameter square",
		str(_uv0(comp)))
	var cells: Vector2 = mat.get_shader_parameter("cells")
	var dom := comp.warp_domain(0)
	var cw := dom.size.x / cells.x
	var ch := dom.size.y / cells.y
	_ok(cells.x == RegionCompositor.CHECKER_CELLS and absf(cw / ch - 1.0) < 0.15,
		"cells are near square on the mask's box", "%s → %.1f x %.1f px" % [cells, cw, ch])
	comp.add_region(PackedVector2Array([Vector2(1300, 100), Vector2(1800, 100), Vector2(1550, 600)]))
	var mat2 := (comp._regions[1]["mesh_node"] as MeshInstance2D).material as ShaderMaterial
	_ok(mat2 != null and mat2.shader == RegionCompositor.CHECKER_SHADER, "a mask added with it on gets it too")
	ed._toggle_checker()
	mat = (comp._regions[0]["mesh_node"] as MeshInstance2D).material as ShaderMaterial
	_ok(not comp.checker and mat != null and mat.shader == fx_shader
		and _uv0(comp).distance_to(clip_uv) < 0.0001,
		"CHECKER off brings back the effect and the clip mapping", str(_uv0(comp)))

	# 6. FIT: the warp from the mask's own corners.
	var tilted := PackedVector2Array([Vector2(300, 900), Vector2(1000, 950),
		Vector2(1050, 400), Vector2(350, 300)])   # drawn counter-clockwise, from the bottom-left
	var qi := comp.add_region(tilted)
	_ok(comp.warp_is_plain(qi), "a new mask's warp is plain")
	_ok(comp.fit_warp_to_mask(qi), "FIT works on a 4-point mask")
	var w := comp.get_warp(qi)
	var want := [Vector2(350, 300), Vector2(1050, 400), Vector2(1000, 950), Vector2(300, 900)]
	var fit_ok := true
	for k in 4:
		fit_ok = fit_ok and w.corners[k].distance_to(want[k]) < 0.001
	_ok(fit_ok, "the warp's TL/TR/BR/BL are the mask's corners, whatever order they were drawn in",
		str(w.corners))
	# Corners only: in a true perspective map the parameter midpoint is NOT the
	# edge midpoint — that foreshortening is the point of FIT.
	_ok(w.surface_point(0.0, 0.0).distance_to(want[0]) < 0.001
		and w.surface_point(1.0, 1.0).distance_to(want[2]) < 0.001,
		"the rendered surface spans the face", str(w.surface_point(1.0, 1.0)))
	_ok(not comp.warp_is_plain(qi), "a fitted warp is no longer plain (FIT asks before replacing it)")
	var up := RegionCompositor.fit_quad(PackedVector2Array([Vector2(500, 800), Vector2(700, 300), Vector2(900, 800)]))
	_ok(up.size() == 4 and up[0].distance_to(Vector2(500, 300)) < 0.001 and up[1].distance_to(Vector2(900, 300)) < 0.001
		and up[2].distance_to(Vector2(900, 800)) < 0.001 and up[3].distance_to(Vector2(500, 800)) < 0.001,
		"a triangle pointing up: base at the bottom, apex at the top middle", str(up))
	var down := RegionCompositor.fit_quad(PackedVector2Array([Vector2(900, 200), Vector2(500, 200), Vector2(720, 700)]))
	_ok(down.size() == 4 and down[0].distance_to(Vector2(500, 200)) < 0.001 and down[1].distance_to(Vector2(900, 200)) < 0.001
		and down[2].distance_to(Vector2(920, 700)) < 0.001 and down[3].distance_to(Vector2(520, 700)) < 0.001,
		"a triangle pointing down: base on top, the quad leans with the apex", str(down))
	_ok(RegionCompositor.fit_quad(PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10),
		Vector2(5, 15), Vector2(0, 10)])).is_empty(), "5 points: no fit")

	ed.set_active(false)
	print("\n%d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
