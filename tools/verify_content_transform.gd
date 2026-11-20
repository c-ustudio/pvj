extends SceneTree
## Headless check of the CONTENT TRANSFORM's invariants, run against the real
## RegionCompositor — not a re-derivation of it.
##
##   godot --headless --path <project> --script tools/verify_content_transform.gd
##
## WHY THIS EXISTS. The spec (PER_REGION_WARP_CONTENT_FIT.md §5/§6) requires a
## pre-transform regions.cfg to render PIXEL-IDENTICAL after the transform lands.
## That cannot be proved from device captures: the deck is playing, so two
## captures are of different video frames, and comparing covered-pixel counts
## between them is the invalid method PROJECT_STATE records burning hours on.
##
## But the UVs decide every pixel. If the mapping is identical, the render is —
## so this compares the MAPPING, exactly, on the real fixture, which is a
## stronger claim than any screenshot diff and needs no display attached.
##
## Checks:
##   1. DEFAULTS == the pre-transform expression, to float precision, on
##      fixtures/s21_two_region_warp/regions.cfg (both hand-authored regions).
##   2. A move is 1:1 in OUTPUT PX at any scale and rotation (what makes the
##      nudge pad and NUM entry honest).
##   3. Rotation is isotropic — a circle stays a circle on a non-square bbox.
##   4. The pivot stays ON THE REGION under FULL_FRAME (§2 item 1).
##   5. Toggling the fit mode does not change what the offset MEANS (§2 item 2).

const FIXTURE := "res://fixtures/s21_two_region_warp/regions.cfg"
const OUT_SIZE := Vector2(1920, 1080)   ## the S13 output basis
const EPS := 0.0000005

var _fails: int = 0
var _checks: int = 0


func _initialize() -> void:
	var comp := RegionCompositor.new()
	comp.output_size = OUT_SIZE
	root.add_child(comp)

	var pts := _fixture_points()
	if pts.is_empty():
		printerr("FIXTURE MISSING: %s" % FIXTURE)
		quit(1)
		return
	print("fixture: %d regions from %s" % [pts.size(), FIXTURE])

	for i in pts.size():
		var idx := comp.add_region(pts[i])
		_check_defaults_match_legacy(comp, idx)
	_check_move_is_1to1(comp, 0)
	_check_rotation_is_isotropic(comp, 0)
	_check_pivot_stays_on_region(comp, 0)
	_check_fit_toggle_keeps_offset_meaning(comp, 0)
	_check_editor_overlay(comp, 0)

	print("\n%d checks, %d failed" % [_checks, _fails])
	# The regions hold Polygon2D/MeshInstance2D children, so drop them explicitly.
	# ⚠️ The run still ends on "ObjectDB instances leaked at exit" — that is the
	# project's AUTOLOADS (GlobalBus and friends load even under --script) and not
	# this tool. Read the check tally, not the warning.
	comp.clear()
	root.remove_child(comp)
	comp.free()
	quit(1 if _fails > 0 else 0)


## The mask polygons as the app loads them: normalized in the file, scaled by the
## output basis.
func _fixture_points() -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var cfg := ConfigFile.new()
	if cfg.load(FIXTURE) != OK:
		return out
	for i in int(cfg.get_value("regions", "count", 0)):
		var key := "region_%d" % i
		if not cfg.has_section_key(key, "points"):
			continue
		var norm: PackedVector2Array = cfg.get_value(key, "points")
		var pts := PackedVector2Array()
		for n in norm:
			pts.append(Vector2(n.x * OUT_SIZE.x, n.y * OUT_SIZE.y))
		out.append(pts)
	return out


## THE PRE-TRANSFORM EXPRESSION, verbatim from region_compositor.gd before this
## increment (S20). Kept here as the reference the new code must reproduce.
##
##   fit  := _bounds_of(pts);  dom := warp domain (the same rect)
##   nrm  := (ident - fit.position) / fit.size
##   uv   := 0.5 + (nrm - 0.5).rotated(-ang) / s + off
func _legacy_uv(pts: PackedVector2Array, u: float, v: float,
		s: float, off: Vector2, ang: float) -> Vector2:
	var fit := _bounds(pts)
	var ident := fit.position + Vector2(u, v) * fit.size
	var nrm := (ident - fit.position) / fit.size
	var centered := nrm - Vector2(0.5, 0.5)
	if ang != 0.0:
		centered = centered.rotated(-ang)
	return Vector2(0.5, 0.5) + centered / s + off


func _bounds(pts: PackedVector2Array) -> Rect2:
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	r.size.x = maxf(r.size.x, 1.0)
	r.size.y = maxf(r.size.y, 1.0)
	return r


# --- checks ---------------------------------------------------------------

## 1. At the defaults the new mapping must equal the old one EXACTLY. This is the
## §5 "existing presets load unchanged, pixel-identical" requirement.
func _check_defaults_match_legacy(comp: RegionCompositor, i: int) -> void:
	var pts := comp.get_points(i)
	var worst := 0.0
	for a in 21:
		for b in 21:
			var u := float(a) / 20.0
			var v := float(b) / 20.0
			var got := _uv(comp, i, u, v)
			var want := _legacy_uv(pts, u, v, 1.0, Vector2.ZERO, 0.0)
			worst = maxf(worst, (got - want).length())
	_assert(worst <= EPS, "region %d: defaults == pre-transform mapping" % i,
		"max UV deviation %.9f" % worst)


## 2. Moving the content by N output px must move it by exactly N output px, at
## any scale and rotation — otherwise the pad's "10 PX" and NUM's px entry lie.
func _check_move_is_1to1(comp: RegionCompositor, i: int) -> void:
	var dom := comp.warp_domain(i)
	for sc in [Vector2.ONE, Vector2(2.0, 2.0), Vector2(0.5, 3.0)]:
		for ang in [0.0, 0.7, -2.1]:
			comp.set_content_scale(i, sc)
			comp.set_content_rotation(i, ang)
			comp.set_content_offset(i, Vector2.ZERO)
			# Where does the texture centre land, before and after a move?
			var before := _content_point(comp, i, Vector2(0.5, 0.5))
			var move_px := Vector2(120.0, -75.0)
			comp.set_content_offset(i, move_px / dom.size)
			var after := _content_point(comp, i, Vector2(0.5, 0.5))
			var err := ((after - before) - move_px).length()
			_assert(err <= 0.001,
				"move is 1:1 in output px (scale %s, rot %.1f)" % [sc, ang],
				"off by %.4f px" % err)
	comp.reset_transform(i)


## 3. A rotation must be a RIGID rotation of the fitted content in output space:
## the content that was there, turned. The test is therefore not "are the axes
## equal and perpendicular" — the fit itself stretches the source onto a
## non-square box (784x490 and 628x482 here), so they are legitimately neither.
## It is "does rotating by A rotate every output-space vector by exactly A".
##
## The old normalized form failed this: it rotated in bbox-normalized space, so a
## non-square box sheared the content as it turned.
func _check_rotation_is_isotropic(comp: RegionCompositor, i: int) -> void:
	var ang := PI / 3.0
	comp.reset_transform(i)
	var o0 := _content_point(comp, i, Vector2(0.5, 0.5))
	var ax0 := _content_point(comp, i, Vector2(0.6, 0.5)) - o0
	var ay0 := _content_point(comp, i, Vector2(0.5, 0.6)) - o0
	comp.set_content_rotation(i, ang)
	var o1 := _content_point(comp, i, Vector2(0.5, 0.5))
	var ax1 := _content_point(comp, i, Vector2(0.6, 0.5)) - o1
	var ay1 := _content_point(comp, i, Vector2(0.5, 0.6)) - o1
	_assert((ax1 - ax0.rotated(ang)).length() <= 0.001,
		"rotation is rigid along the content's x axis",
		"got %s, want %s" % [ax1, ax0.rotated(ang)])
	_assert((ay1 - ay0.rotated(ang)).length() <= 0.001,
		"rotation is rigid along the content's y axis",
		"got %s, want %s" % [ay1, ay0.rotated(ang)])
	comp.reset_transform(i)


## 4. §2 item 1: under FULL_FRAME the pivot must stay on the REGION. Zooming must
## not swing a small region's content across the screen, which is exactly what a
## hardcoded 0.5,0.5 in frame-normalized space would do.
func _check_pivot_stays_on_region(comp: RegionCompositor, i: int) -> void:
	var dom := comp.warp_domain(i)
	var want := dom.get_center()
	for mode in [RegionCompositor.ContentFit.MANUAL,
			RegionCompositor.ContentFit.FULL_FRAME]:
		comp.reset_transform(i)
		comp.set_content_fit(i, mode)
		# The pivot is the one point a pure scale leaves alone: find it by
		# scaling and asking which output point did not move.
		var fixed_before := _fixed_point_of_scale(comp, i)
		_assert((fixed_before - want).length() <= 1.0,
			"fit mode %d: scaling pivots on the region centre" % mode,
			"pivot at %s, region centre %s" % [fixed_before, want])
	comp.set_content_fit(i, RegionCompositor.ContentFit.MANUAL)
	comp.reset_transform(i)


## 5. §2 item 2: the offset must MEAN the same thing in both fit modes. Toggling
## with a non-zero offset must not make content jump — the displacement the offset
## produces has to be the same number of output px either side of the toggle.
func _check_fit_toggle_keeps_offset_meaning(comp: RegionCompositor, i: int) -> void:
	var dom := comp.warp_domain(i)
	var move_px := Vector2(90.0, 40.0)
	var disp: Array[Vector2] = []
	for mode in [RegionCompositor.ContentFit.MANUAL,
			RegionCompositor.ContentFit.FULL_FRAME]:
		comp.reset_transform(i)
		comp.set_content_fit(i, mode)
		var a := _content_point(comp, i, Vector2(0.5, 0.5))
		comp.set_content_offset(i, move_px / dom.size)
		var b := _content_point(comp, i, Vector2(0.5, 0.5))
		disp.append(b - a)
	var err := (disp[0] - disp[1]).length()
	_assert(err <= 0.001, "a fit-mode toggle does not change what offset means",
		"MASK_BOUNDS %s vs FULL_FRAME %s" % [disp[0], disp[1]])
	comp.set_content_fit(i, RegionCompositor.ContentFit.MANUAL)
	comp.reset_transform(i)


## 6. What EDIT CONTENT actually draws. The solid content rect and the pivot cross
## come from content_quad()/content_pivot_px(), so those must agree with the
## mapping rather than re-deriving it — an overlay that lies about where the
## content is would be worse than no overlay.
func _check_editor_overlay(comp: RegionCompositor, i: int) -> void:
	comp.reset_transform(i)
	comp.set_content_fit(i, RegionCompositor.ContentFit.MANUAL)
	var dom := comp.warp_domain(i)
	# At the defaults the source exactly fills the region's box, so the SOLID rect
	# must coincide with the DASHED bounds. If these two ever disagree at rest, the
	# overlay is measuring something else.
	var q := comp.content_quad(i)
	var want := PackedVector2Array([dom.position, Vector2(dom.end.x, dom.position.y),
		dom.end, Vector2(dom.position.x, dom.end.y)])
	var worst := 0.0
	for k in 4:
		worst = maxf(worst, (q[k] - want[k]).length())
	_assert(worst <= 0.001, "at rest the content rect == the dashed bounds",
		"max corner error %.4f px" % worst)
	# The drawn pivot must be the point a scale actually turns about.
	var probe := comp.content_pivot_px(i)
	var empirical := _fixed_point_of_scale(comp, i)
	_assert((probe - empirical).length() <= 1.0,
		"the drawn pivot is the real pivot",
		"drawn %s, measured %s" % [probe, empirical])
	# And the rect must move with the content, exactly.
	var move_px := Vector2(-64.0, 128.0)
	comp.set_content_offset(i, move_px / dom.size)
	var q2 := comp.content_quad(i)
	worst = 0.0
	for k in 4:
		worst = maxf(worst, ((q2[k] - q[k]) - move_px).length())
	_assert(worst <= 0.001, "the content rect tracks a move 1:1",
		"max corner error %.4f px" % worst)
	comp.reset_transform(i)


# --- helpers --------------------------------------------------------------

## The compositor's own mapping: lattice parameter -> texture UV.
func _uv(comp: RegionCompositor, i: int, u: float, v: float) -> Vector2:
	return comp._uv_at(comp._regions[i], u, v)


## The inverse: where a given texture UV lands in OUTPUT px (undeformed domain
## space — the warp is a separate stage and is not what this file tests).
func _content_point(comp: RegionCompositor, i: int, uv: Vector2) -> Vector2:
	var dom := comp.warp_domain(i)
	var t: Transform2D = comp._uv_xform(comp._regions[i]).affine_inverse()
	return dom.position + (t * uv) * dom.size


## The one output point a pure scale leaves where it is — i.e. the pivot, found
## empirically rather than read out of the dictionary.
func _fixed_point_of_scale(comp: RegionCompositor, i: int) -> Vector2:
	var probe := Vector2(0.5, 0.5)
	comp.set_content_scale(i, Vector2.ONE)
	var p1 := _content_point(comp, i, probe)
	comp.set_content_scale(i, Vector2(2.0, 2.0))
	var p2 := _content_point(comp, i, probe)
	comp.set_content_scale(i, Vector2.ONE)
	# One texture point at two scales: p = pivot + k*(q - pivot), with p1 at k=1
	# (so p1 == q) and p2 at k=2. Hence pivot = 2*p1 - p2.
	return p1 * 2.0 - p2


func _assert(ok: bool, what: String, detail: String) -> void:
	_checks += 1
	if ok:
		print("  ok    %s" % what)
	else:
		_fails += 1
		printerr("  FAIL  %s  (%s)" % [what, detail])
