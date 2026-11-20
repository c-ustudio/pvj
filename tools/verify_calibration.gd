extends SceneTree
## Headless check of the CAMERA KEYSTONE, run against the real classes —
## CalibHomography, CalibPattern, CalibEditor, QuadWarp/WarpSurface.
##
##   godot --headless --path <project> --script tools/verify_calibration.gd
##
## WHY THIS EXISTS. Whether a calibrated keystone is RIGHT is a geometric fact,
## and it can be settled without a projector: build a synthetic rig (a wall, a
## projector throwing onto it at an angle, a camera looking at it from somewhere
## else), run the real code on what that camera would see, and ask where the
## picture lands on the wall. Ground truth is known by construction, which no
## photograph of a real wall can offer.
##
## What it cannot settle, and a wall session still owes: whether a finger can
## place the taps well enough (check 6 puts a number on how much that matters),
## whether the markers are readable through the camera's auto-exposure, and
## whether the surface is flat enough for a homography to be the right model.
##
## Checks:
##   1. The 4-point solve is exact, and its inverse round-trips.
##   2. N > 4 points with noise: least squares beats the 4-point answer.
##   3. Degenerate input is REFUSED (null), not answered with a wild matrix.
##   4. Save/load round-trips the matrix through the .cfg text.
##   5. THE RIG: corners from the calibration put the picture on the target
##      surface — corners AND interior (perspective-correct, through the real
##      WarpSurface), from a camera that is rotated and mirrored.
##   6. Tap noise -> error on the wall, in output px (reported, loosely gated).
##   7. The real CalibEditor, driven by touches, sets the real QuadWarp to the
##      same corners — and arrives at SURFACE already squared up.
##  7b. auto_surface(): the automatic rectangle is a rectangle, of the right
##      shape, inside what the projector reaches, as big as it can be, and the
##      same whichever way up the camera frame arrives.
##   8. THE DECK: the real Main scene. CAM borrows the camera source and puts
##      the pattern on the output; SURFACE hands both back; ESC, DONE and a
##      dead camera all leave the deck as they found it.
##   9. DETECTION: CalibDetect finds synthetic discs to a fraction of a pixel
##      in a lit room and in a dark one, ignores a lamp AND A PERSON MOVING
##      THROUGH THE SEQUENCE (the failure of the first wall run), and refuses a
##      disc that is missing, cut off, or not a disc.
##  9b. fit_grid(): one calibration fitted to the 3x3 grid. Nine points beat
##      four at the picture's corners; a decoy, a missed disc and a half-hidden
##      one are each outvoted; a surface that is not flat, or too little of the
##      grid, is refused.
##  10. AUTO: the real editor runs its whole sequence against a synthetic
##      camera that answers each pattern the way the rig would — including a
##      camera that lags, a disc that never shows, one behind a lampshade, and
##      a surface that is not flat.
##  11. WALL: CalibWall on a 3D pinhole rig — a wall turned away from a camera
##      that stands beside the projector. The picture comes out a true 16:9
##      rectangle ON THE WALL, from tapped plumb lines and from gravity, where
##      "squared up as seen from the phone" does not; a wrong focal length
##      changes its proportions only; and the editor's WALL step drives it.
##  12. LINES: CalibLines finds the wall's level direction in a rendered room
##      (shelves, a door on the next wall, a lamp, a picture hung crooked) —
##      from the wall's own edges, from the next wall's alone, not at all in an
##      empty picture — and the editor's WALL is then one press, FROM HERE
##      flips back, and LINES opens what it rests on.
##  13. THE CHECK, HEAT, THE SAVE PROMPT: after AUTO four discs at the
##      picture's corners are looked at — nothing to correct on a perfect rig,
##      corrected and confirmed where the wall has a dent, skipped when the
##      phone moved or nothing is projecting; thermal status 3 eases the frame
##      rate and says so; DONE with a keystone asks whether to save it.

const OUT := Vector2(1920, 1080)
const CAM := Vector2(1920, 1080)

var _fails: int = 0
var _checks: int = 0
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	_rng.seed = 20260930
	_check_exact_and_inverse()
	_check_least_squares()
	_check_degenerate()
	_check_persistence()
	_check_rig()
	_check_tap_noise()
	_check_editor()
	_check_auto_surface()
	_check_detect()
	_check_fit_grid()
	_check_wall()
	_check_lines()
	# Checks 8 and 10 need real frames and timers, which cannot happen inside
	# _initialize — the loop has not started yet.
	_run_async.call_deferred()


func _run_async() -> void:
	await _check_auto()
	await _check_wall_step()
	await _check_deck()
	print("\n%d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)


func _ok(cond: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
	print("%s  %s%s" % ["ok  " if cond else "FAIL", what, ("  — " + detail) if detail != "" else ""])


func _rect_corners(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end,
		Vector2(r.position.x, r.end.y)])


## A convex quad: a rectangle with every corner pushed by up to `jitter`.
func _random_quad(r: Rect2, jitter: float) -> PackedVector2Array:
	var q := _rect_corners(r)
	for i in q.size():
		q[i] += Vector2(_rng.randf_range(-jitter, jitter), _rng.randf_range(-jitter, jitter))
	return q


func _max_err(h: CalibHomography, src: PackedVector2Array, dst: PackedVector2Array) -> float:
	var worst := 0.0
	for i in src.size():
		worst = maxf(worst, h.apply(src[i]).distance_to(dst[i]))
	return worst


# --- 1 -------------------------------------------------------------------

func _check_exact_and_inverse() -> void:
	var worst := 0.0
	var worst_rt := 0.0
	for trial in 200:
		var src := _random_quad(Rect2(300, 200, 1200, 650), 180.0)
		var dst := _random_quad(Rect2(346, 194, 1228, 692), 160.0)
		var h := CalibHomography.solve(src, dst)
		if h == null:
			_ok(false, "4-point solve returned null on a convex quad (trial %d)" % trial)
			return
		worst = maxf(worst, _max_err(h, src, dst))
		var inv := h.inverse()
		for k in 20:
			var p := Vector2(_rng.randf_range(0, CAM.x), _rng.randf_range(0, CAM.y))
			var q := h.apply(p)
			if q.is_finite():
				worst_rt = maxf(worst_rt, inv.apply(q).distance_to(p))
	_ok(worst < 0.002, "4-point solve reproduces its correspondences", "worst %.6f px over 200 quads" % worst)
	_ok(worst_rt < 0.02, "inverse round-trips", "worst %.6f px" % worst_rt)


# --- 2 -------------------------------------------------------------------

func _check_least_squares() -> void:
	var truth := CalibHomography.solve(
		_rect_corners(Rect2(0, 0, CAM.x, CAM.y)),
		PackedVector2Array([Vector2(210, 95), Vector2(1730, 40), Vector2(1835, 1010), Vector2(90, 930)]))
	var sum4 := 0.0
	var sum25 := 0.0
	var probes := PackedVector2Array()
	for k in 50:
		probes.append(Vector2(_rng.randf_range(100, 1820), _rng.randf_range(100, 980)))
	var probe_truth := PackedVector2Array()
	for p in probes:
		probe_truth.append(truth.apply(p))
	for trial in 60:
		var src := PackedVector2Array()
		var dst := PackedVector2Array()
		for j in 5:
			for i in 5:
				var p := Vector2(250.0 + 355.0 * i, 150.0 + 195.0 * j)
				src.append(p + Vector2(_rng.randfn(0.0, 1.0), _rng.randfn(0.0, 1.0)))
				dst.append(truth.apply(p))
		var h25 := CalibHomography.solve(src, dst)
		var corner_idx := [0, 4, 24, 20]
		var s4 := PackedVector2Array()
		var d4 := PackedVector2Array()
		for ci: int in corner_idx:
			s4.append(src[ci])
			d4.append(dst[ci])
		var h4 := CalibHomography.solve(s4, d4)
		if h25 == null or h4 == null:
			_ok(false, "least-squares solve returned null")
			return
		sum25 += h25.rms_error(probes, probe_truth)
		sum4 += h4.rms_error(probes, probe_truth)
	_ok(sum25 < sum4 * 0.6, "25 noisy points beat 4 noisy points",
		"mean rms %.3f px vs %.3f px (1 px tap noise)" % [sum25 / 60.0, sum4 / 60.0])


# --- 3 -------------------------------------------------------------------

func _check_degenerate() -> void:
	var dst := CalibPattern.marker_points(OUT)
	var collinear := PackedVector2Array([Vector2(100, 100), Vector2(400, 400), Vector2(700, 700), Vector2(900, 900)])
	_ok(CalibHomography.solve(collinear, dst) == null, "collinear points are refused")
	var repeated := PackedVector2Array([Vector2(100, 100), Vector2(100, 100), Vector2(700, 700), Vector2(200, 900)])
	_ok(CalibHomography.solve(repeated, dst) == null, "a repeated point is refused")
	var three := PackedVector2Array([Vector2(100, 100), Vector2(900, 120), Vector2(800, 700)])
	_ok(CalibHomography.solve(three, dst) == null, "three points are refused")
	# Two markers tapped in the wrong order: a bow-tie. It maps the four points,
	# but through the horizon — which the solve must catch.
	var crossed := PackedVector2Array([Vector2(400, 300), Vector2(1500, 320), Vector2(380, 800), Vector2(1520, 790)])
	_ok(CalibHomography.solve(crossed, dst) == null, "a crossed (bow-tie) tap order is refused")


# --- 4 -------------------------------------------------------------------

func _check_persistence() -> void:
	var h := CalibHomography.solve(_random_quad(Rect2(300, 200, 1200, 650), 150.0),
		CalibPattern.marker_points(OUT))
	var cfg := ConfigFile.new()
	h.save_to(cfg, "calibration")
	var text := cfg.encode_to_text()
	var cfg2 := ConfigFile.new()
	cfg2.parse(text)
	var back := CalibHomography.load_from(cfg2, "calibration")
	var diff := INF
	if back != null:
		diff = 0.0
		for i in 9:
			diff = maxf(diff, absf(back.m[i] - h.m[i]))
	_ok(diff < 1e-9, "save/load round-trips the matrix through the .cfg text", "max element diff %.12f" % diff)
	_ok(CalibHomography.load_from(ConfigFile.new(), "calibration") == null, "a missing calibration loads as null")


# --- 5 -------------------------------------------------------------------

## The synthetic rig. Wall coordinates are millimetres on the wall plane.
##   proj_to_wall: where each projector pixel lands (a keystoned throw)
##   wall_to_cam:  where the camera sees each wall point
func _rig(cam_quad: PackedVector2Array) -> Dictionary:
	# The projector's frame lands on the wall as a trapezoid: aimed up and from
	# the left, so it is wider at the top and leans.
	var throw_quad := PackedVector2Array([
		Vector2(-260, -140), Vector2(3480, 60), Vector2(3150, 2080), Vector2(140, 1960)])
	var proj_to_wall := CalibHomography.solve(_rect_corners(Rect2(Vector2.ZERO, OUT)), throw_quad)
	# The camera sees the wall's 3200x1800 reference rectangle as `cam_quad`.
	var wall_to_cam := CalibHomography.solve(_rect_corners(Rect2(0, 0, 3200, 1800)), cam_quad)
	return {"p2w": proj_to_wall, "w2c": wall_to_cam}


## Run the calibration on what the rig's camera would see. Returns the output
## quad for `target` (a rectangle on the wall), with optional tap noise.
func _calibrate(rig: Dictionary, target: Rect2, noise: float) -> PackedVector2Array:
	var p2w: CalibHomography = rig["p2w"]
	var w2c: CalibHomography = rig["w2c"]
	var markers_cam := PackedVector2Array()
	for m in CalibPattern.marker_points(OUT):
		markers_cam.append(w2c.apply(p2w.apply(m)) + _jit(noise))
	var cam_to_out := CalibHomography.solve(markers_cam, CalibPattern.marker_points(OUT))
	var surface_cam := PackedVector2Array()
	for c in _rect_corners(target):
		surface_cam.append(w2c.apply(c) + _jit(noise))
	return CalibEditor.surface_to_corners(cam_to_out, surface_cam)


func _jit(noise: float) -> Vector2:
	if noise <= 0.0:
		return Vector2.ZERO
	return Vector2(_rng.randfn(0.0, noise), _rng.randfn(0.0, noise))


func _check_rig() -> void:
	var target := Rect2(620, 420, 1920, 1080)   # a 16:9 surface on the wall, mm
	# Three cameras: a plain oblique view, the same view delivered rotated 90°
	# (an unrotated sensor buffer), and mirrored. The answer must not care.
	var plain := PackedVector2Array([Vector2(310, 250), Vector2(1580, 180), Vector2(1690, 930), Vector2(240, 860)])
	var rotated := PackedVector2Array()
	var mirrored := PackedVector2Array()
	for p in plain:
		rotated.append(Vector2(CAM.y - p.y, p.x))
		mirrored.append(Vector2(CAM.x - p.x, p.y))
	var names := ["oblique camera", "camera frame rotated 90°", "camera frame mirrored"]
	var quads: Array[PackedVector2Array] = [plain, rotated, mirrored]
	var reference := PackedVector2Array()
	for qi in quads.size():
		var rig := _rig(quads[qi])
		var p2w: CalibHomography = rig["p2w"]
		var corners := _calibrate(rig, target, 0.0)
		if corners.size() != 4:
			_ok(false, "%s: calibration produced no corners" % names[qi])
			continue
		# Truth: the projector pixels that land on the target's corners.
		var truth := PackedVector2Array()
		var w2p := p2w.inverse()
		for c in _rect_corners(target):
			truth.append(w2p.apply(c))
		var worst := 0.0
		for i in 4:
			worst = maxf(worst, corners[i].distance_to(truth[i]))
		_ok(worst < 0.01, "%s: warp corners land on the surface corners" % names[qi],
			"worst %.5f output px" % worst)
		if qi == 0:
			reference = corners
		else:
			var drift := 0.0
			for i in 4:
				drift = maxf(drift, corners[i].distance_to(reference[i]))
			_ok(drift < 0.01, "%s: same corners as the oblique camera" % names[qi],
				"differs by %.5f px" % drift)
		# Interior: push the real WarpSurface through the throw and compare with
		# where an undistorted picture would sit on the target.
		var surf := WarpSurface.new()
		surf.fill_rect(OUT)
		for i in 4:
			surf.set_corner(i, corners[i])
		var worst_mm := 0.0
		for j in 9:
			for i in 9:
				var u := float(i) / 8.0
				var v := float(j) / 8.0
				var on_wall := p2w.apply(surf.surface_point(u, v))
				var want := target.position + Vector2(u, v) * target.size
				worst_mm = maxf(worst_mm, on_wall.distance_to(want))
		_ok(worst_mm < 0.5, "%s: the picture is undistorted across the surface" % names[qi],
			"worst %.4f mm on a %d mm wide surface" % [worst_mm, int(target.size.x)])


# --- 6 -------------------------------------------------------------------

func _check_tap_noise() -> void:
	var rig := _rig(PackedVector2Array([Vector2(310, 250), Vector2(1580, 180), Vector2(1690, 930), Vector2(240, 860)]))
	var target := Rect2(620, 420, 1920, 1080)
	var clean := _calibrate(rig, target, 0.0)
	for noise: float in [1.0, 3.0]:
		var sum := 0.0
		var worst := 0.0
		var n := 0
		for trial in 400:
			var c := _calibrate(rig, target, noise)
			if c.size() != 4:
				continue
			for i in 4:
				var e := c[i].distance_to(clean[i])
				sum += e
				worst = maxf(worst, e)
				n += 1
		var mean := sum / float(maxi(n, 1))
		# Loose on purpose: this is a regression tripwire on error AMPLIFICATION,
		# not a claim about how well a finger taps.
		_ok(mean < noise * 4.0, "tap noise sigma %.0f camera px" % noise,
			"corner error mean %.2f / worst %.2f output px" % [mean, worst])


# --- 7 -------------------------------------------------------------------

func _check_editor() -> void:
	var rig := _rig(PackedVector2Array([Vector2(310, 250), Vector2(1580, 180), Vector2(1690, 930), Vector2(240, 860)]))
	var p2w: CalibHomography = rig["p2w"]
	var w2c: CalibHomography = rig["w2c"]
	var target := Rect2(620, 420, 1920, 1080)
	var want := _calibrate(rig, target, 0.0)

	var quad := QuadWarp.new()
	root.add_child(quad)
	quad.fill_rect(OUT)
	var before := quad.corners.duplicate()

	var ed := CalibEditor.new()
	root.add_child(ed)
	ed.setup(quad)
	# setup() anchors it full-rect to the (headless) window; pin it to the
	# phone's logical UI size instead so the numbers below mean something.
	ed.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ed.size = Vector2(1454, 648)
	ed.output_size_provider = func() -> Vector2: return OUT
	var steps: Array[int] = []
	ed.step_changed.connect(func(s: int) -> void: steps.append(s))
	var closes: Array[bool] = []
	ed.closed.connect(func(applied: bool) -> void: closes.append(applied))
	ed.set_active(true)
	_ok(ed.step == CalibEditor.Step.LIVE, "editor opens on LIVE")

	# No camera frame headless: step past FREEZE the way a frozen frame would.
	ed._cam_size = CAM
	ed._set_step(CalibEditor.Step.MARKERS)
	var img := ed._img_rect()
	_ok(absf(img.size.x / img.size.y - CAM.x / CAM.y) < 0.001 and img.position.y >= CalibEditor.HINT_H - 0.01
		and img.end.y <= 648.0 - CalibEditor.STRIP_H + 0.01,
		"the camera picture is aspect-true and clear of the hint and the strip",
		"%dx%d at %d,%d" % [int(img.size.x), int(img.size.y), int(img.position.x), int(img.position.y)])

	# Tap the four markers where the rig's camera sees them.
	for m in CalibPattern.marker_points(OUT):
		_tap(ed, w2c.apply(p2w.apply(m)))
	_ok(ed._cam_to_out != null, "four marker taps solve the calibration")
	_ok(quad.corners == before, "marking the markers does not move the warp")
	var ring := ed._out_to_cam.apply(CalibPattern.centre_point(OUT))
	var ring_truth := w2c.apply(p2w.apply(CalibPattern.centre_point(OUT)))
	_ok(ring.distance_to(ring_truth) < 2.0, "the check ring predicts the centre cross",
		"%.3f camera px off" % ring.distance_to(ring_truth))

	ed._next_pressed()
	_ok(ed.step == CalibEditor.Step.SURFACE, "NEXT moves to SURFACE")
	_ok(ed._surface.size() == 4 and quad.corners != before and ed._hint.text.contains("SQUARE AS SEEN FROM THE PHONE"),
		"SURFACE arrives squared up: four corners placed and already on the warp", ed._hint.text)
	_mark_surface(ed, _cam_corners(w2c, target))
	var worst := 0.0
	for i in 4:
		worst = maxf(worst, quad.corners[i].distance_to(want[i]))
	# Through the editor the taps go camera -> screen -> camera in float32, so
	# this is looser than check 5 — it proves the glue, not the maths.
	_ok(worst < 0.05, "four surface taps set the QuadWarp corners", "worst %.4f output px from the exact answer" % worst)

	# A press on an existing point picks it up instead of adding a fifth.
	ed._press(0, ed._to_screen(ed._surface[2]) + Vector2(12, -9))
	ed._drag(0, ed._to_screen(ed._surface[2]) + Vector2(12, -9))
	ed._release(0)
	_ok(ed._surface.size() == 4, "pressing near a point grabs it (no fifth point)")

	# ESC restores the warp the wall had on entry.
	ed._esc_pressed()
	_ok(quad.corners == before, "ESC restores the warp from before the calibration")
	_ok(closes == [false], "ESC reports not-applied")

	# DONE keeps it.
	ed.set_active(true)
	ed._cam_size = CAM
	ed._set_step(CalibEditor.Step.MARKERS)
	for m in CalibPattern.marker_points(OUT):
		_tap(ed, w2c.apply(p2w.apply(m)))
	ed._next_pressed()
	_mark_surface(ed, _cam_corners(w2c, target))
	ed.handle_back()
	_ok(quad.corners != before and closes == [false, true], "BACK/DONE keeps the keystone and reports applied")
	_ok(steps.has(CalibEditor.Step.SURFACE) and steps[0] == CalibEditor.Step.LIVE,
		"step_changed reports LIVE first and SURFACE later")

	root.remove_child(ed)
	ed.free()
	root.remove_child(quad)
	quad.free()


## Replace whatever surface corners are there (SURFACE arrives with the
## automatic four) with taps at these camera-space points.
func _mark_surface(ed: CalibEditor, cam_points: PackedVector2Array) -> void:
	for i in 4:
		ed._undo_pressed()
	for p in cam_points:
		_tap(ed, p)


func _cam_corners(w2c: CalibHomography, target: Rect2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for c in _rect_corners(target):
		out.append(w2c.apply(c))
	return out


## One finger: down, up, at the screen position of a camera-space point.
func _tap(ed: CalibEditor, cam: Vector2) -> void:
	var s := ed._to_screen(cam)
	ed._press(0, s)
	ed._release(0)


# --- 8 -------------------------------------------------------------------

func _check_deck() -> void:
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 12:
		await process_frame   # boot's deferred loads (warp slot, regions, routing)

	var video: int = main.ClipSource.VIDEO
	var camera: int = main.ClipSource.CAMERA
	if main._source != video:   # whatever this machine's settings.cfg says
		main._source = video
		main._apply_source()
	var calib: CalibEditor = main._calib
	var pattern: CalibPattern = main._calib_pattern
	var warp: WarpEditor = main._warp
	var quad: QuadWarp = main.quad_warp
	var before := quad.corners.duplicate()

	main._enter_warp()
	_ok(warp.active and not calib.active, "WRP opens the warp editor, calibration idle")
	warp.camera_requested.emit()   # the CAM cell
	_ok(calib.active and not warp.active, "CAM hands over from the warp editor to the calibration")
	_ok(pattern.visible and pattern.get_parent() == main.output_world
		and pattern.z_index == RenderingServer.CANVAS_ITEM_Z_MAX,
		"the pattern is on the output, above everything in OutputWorld")
	_ok(main._source == camera and main._calib_prev_source == video,
		"LIVE borrows the camera source and remembers the deck's own")
	_ok(calib.get_index() == calib.get_parent().get_child_count() - 1, "the editor is the topmost chrome")

	# FREEZE cannot read a frame headless; step the way a frozen frame would.
	calib._cam_size = CAM
	calib._set_step(CalibEditor.Step.MARKERS)
	_ok(pattern.visible and main._source == camera, "MARKERS keeps the pattern up and the lens held")
	var cam_quad := PackedVector2Array([Vector2(420, 260), Vector2(1510, 230), Vector2(1560, 850), Vector2(380, 820)])
	for p in cam_quad:
		_tap(calib, p)
	calib._next_pressed()
	_ok(calib.step == CalibEditor.Step.SURFACE and not pattern.visible and main._source == video,
		"SURFACE takes the pattern down and gives the deck its source back")
	var saved := CalibEditor.load_calibration()
	_ok(saved != null and saved.apply(cam_quad[0]).distance_to(CalibPattern.marker_points(OUT)[0]) < 0.01,
		"NEXT saved the calibration to user://calibration.cfg")
	_ok(quad.corners != before and calib._surface.size() == 4,
		"…and the deck's real global warp is already squared up")
	var squared := quad.corners.duplicate()
	_mark_surface(calib, PackedVector2Array([Vector2(600, 400), Vector2(1300, 380), Vector2(1320, 760), Vector2(590, 770)]))
	_ok(quad.corners != before and quad.corners != squared, "surface taps move it again")
	calib._auto_pressed()   # the WALL cell
	_ok(calib.step == CalibEditor.Step.WALL and not pattern.visible and main._source == video,
		"WALL keeps the deck on the wall: no pattern, the deck's own source")
	calib._auto_pressed()   # BACK
	_ok(calib.step == CalibEditor.Step.SURFACE, "BACK returns from WALL to SURFACE")
	_ok(calib.gravity_provider.is_valid() and ProjectSettings.get_setting("input_devices/sensors/enable_gravity", false),
		"the deck offers the editor a gravity reading, and the project has the sensor switched on")

	calib._shot_pressed()   # RETAKE
	_ok(calib.step == CalibEditor.Step.LIVE and pattern.visible and main._source == camera,
		"RETAKE goes back to LIVE: pattern up, lens borrowed again")

	calib._esc_pressed()
	_ok(not calib.active and warp.active and not pattern.visible, "ESC returns to the warp editor, pattern down")
	_ok(main._source == video and main._calib_prev_source == -1, "ESC gives the source back")
	_ok(quad.corners == before, "ESC restores the deck's warp")

	# A camera that cannot start ends the calibration and leaves the deck alone.
	warp.camera_requested.emit()
	main.camera_engine.camera_failed.emit("verify_calibration: simulated failure")
	_ok(not calib.active and main._source == video and not pattern.visible,
		"a dead camera aborts the calibration and the deck stays on its own source")
	var dlg: Node = main._topmost_dialog()
	_ok(dlg != null, "…and says so in a dialog")
	if dlg != null:
		dlg.dismiss()

	# MIRROR / DUAL·PLAYER cannot carry the pattern. Only reachable with the
	# HDMI plugin present, so fake its presence for the one call.
	main._warp.set_active(true)
	main._hdmi = RefCounted.new()
	main._display_mode = main.DisplayMode.MIRROR
	main._enter_calibration()
	_ok(not calib.active and warp.active, "MIRROR refuses the calibration and stays in the warp editor")
	main._hdmi = null
	main._display_mode = main.DisplayMode.DUAL

	# AUTO's requests reach the pattern on the output, and LIVE resets them.
	warp.camera_requested.emit()
	calib.pattern_requested.emit(CalibPattern.Mode.SOLO, 2)
	_ok(pattern.mode == CalibPattern.Mode.SOLO and pattern.solo_index == 2,
		"pattern_requested drives the pattern on the output")
	calib.spots_requested.emit(PackedVector2Array([Vector2(300, 200), Vector2(1600, 880)]))
	_ok(pattern.mode == CalibPattern.Mode.SPOTS and pattern.spots.size() == 2,
		"spots_requested puts the check's discs on the output")
	calib._go_live()
	_ok(pattern.mode == CalibPattern.Mode.ALL, "LIVE puts the readable pattern back")

	# HEAT. One step before Android cuts the projector: say so, ease off, and
	# tell the calibration (which has the camera on top of everything else).
	var fps_before := Engine.max_fps
	main._on_heat(3)
	_ok(Engine.max_fps == main.HEAT_FPS and main.status.text.contains("PHONE HOT") and calib._hint.text.begins_with("PHONE HOT"),
		"thermal status 3: the frame rate is held at %d, the deck says why, the calibration's hint says so" % main.HEAT_FPS,
		main.status.text)
	main._on_heat(2)
	_ok(Engine.max_fps == main.HEAT_FPS and main._heat_capped and not calib._hint.text.begins_with("PHONE HOT"),
		"status 2: still eased off (it has to cool further), the hint is back to normal")
	main._on_heat(4)
	var hot: Node = main._topmost_dialog()
	_ok(hot != null, "status 4: a dialog that stays — Android has cut the projector")
	if hot != null:
		hot.dismiss()
	main._on_heat(1)
	_ok(Engine.max_fps == fps_before and main.status.text.contains("FULL FRAME RATE"),
		"status 1: the frame rate is given back")
	Engine.max_fps = fps_before
	calib._esc_pressed()

	# DONE with a keystone on the wall asks whether to keep it — DONE writes no
	# slot, and an unsaved keystone is gone at the next start.
	warp.camera_requested.emit()
	calib._cam_size = CAM
	calib._set_step(CalibEditor.Step.MARKERS)
	for p in cam_quad:
		_tap(calib, p)
	calib._next_pressed()
	calib._done_pressed()
	var ask: Node = main._topmost_dialog()
	_ok(not calib.active and warp.active and ask != null, "DONE with a keystone applied asks whether to save it to the armed slot")
	if ask != null:
		ask.dismiss()   # NOT NOW — and the verifier must not write a slot on this machine
	await process_frame
	_ok(main._topmost_dialog() == null and warp.active, "NOT NOW leaves the keystone on, unsaved, in the warp editor")
	quad.restore_state(main._warp._snapshot)
	warp._esc_pressed()
	root.remove_child(main)
	main.queue_free()


# --- 9 -------------------------------------------------------------------

## A camera frame of a textured wall: blocky noise around `level`, plus a lamp
## far brighter than any marker. L8, the camera's size.
func _wall(level: int, noise: int) -> Image:
	var small := PackedByteArray()
	small.resize(480 * 270)
	for i in small.size():
		small[i] = clampi(level + _rng.randi_range(-noise, noise), 0, 255)
	var img := Image.create_from_data(480, 270, false, Image.FORMAT_L8, small)
	img.resize(int(CAM.x), int(CAM.y), Image.INTERPOLATE_NEAREST)
	_stamp(img, Vector2(1500, 200), 60.0, 255, 0.0)   # the lamp
	return img


## Add an anti-aliased disc (and, with `bloom`, a soft halo 2.5 radii wide).
func _stamp(img: Image, centre: Vector2, radius: float, gain: int, bloom: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var reach := radius * (2.5 if bloom > 0.0 else 1.0) + 2.0
	for y in range(maxi(int(centre.y - reach), 0), mini(int(centre.y + reach) + 1, h)):
		for x in range(maxi(int(centre.x - reach), 0), mini(int(centre.x + reach) + 1, w)):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(centre)
			var cover := clampf(radius + 0.5 - d, 0.0, 1.0)
			if bloom > 0.0:
				cover = maxf(cover, bloom * clampf(1.0 - d / (radius * 2.5), 0.0, 1.0))
			if cover > 0.0:
				var i := y * w + x
				data[i] = clampi(data[i] + int(gain * cover), 0, 255)
	img.set_data(w, h, false, Image.FORMAT_L8, data)


## DARK, one frame per disc, DARK — the sequence AUTO captures. `head` (if not
## INF) is where a dark head starts; it drifts 30 px per frame, uncovering wall.
func _sequence(base: Image, discs: PackedVector2Array, radius: float, gain: int,
		bloom: float, head: Vector2 = Vector2.INF) -> CalibDetect:
	var det := CalibDetect.new()
	for f in discs.size() + 2:
		var img := base.duplicate() as Image
		if head.is_finite():
			_stamp(img, head + Vector2(30.0 * f, 0.0), 110.0, -200, 0.0)
		if f >= 1 and f <= discs.size():
			_stamp(img, discs[f - 1], radius, gain, bloom)
		det.add_frame(img)
	return det


## Worst distance between what locate() says and the truth; INF if any failed.
func _worst(det: CalibDetect, discs: PackedVector2Array) -> float:
	var worst := 0.0
	for i in discs.size():
		var res := det.locate(i + 1)
		if not res["ok"]:
			print("      disc %d: %s" % [i + 1, res])
			return INF
		worst = maxf(worst, discs[i].distance_to(res["pos"]))
	return worst


func _check_detect() -> void:
	var five := PackedVector2Array([Vector2(463.52, 349.74), Vector2(1399.34, 358.20),
		Vector2(1388.54, 893.96), Vector2(490.09, 820.33), Vector2(904.99, 609.46)])

	# A lit room: a bright wall and a disc that adds little to it.
	var day := _wall(110, 4)
	var err := _worst(_sequence(day, five, 13.0, 30, 0.0), five)
	_ok(err < 0.3, "lit room, faint discs (30 levels over a bright wall)", "worst %.3f px" % err)

	# A dark room: black wall, the discs saturate and bloom.
	var night := _wall(6, 3)
	err = _worst(_sequence(night, five, 16.0, 600, 0.45), five)
	_ok(err < 0.3, "dark room, saturated discs with bloom", "worst %.3f px" % err)

	# THE WALL RUN. A head moves through the sequence, uncovering bright wall —
	# a difference of 100 levels, against discs worth 40. Subtracting one dark
	# frame picks the head every time; this must not.
	err = _worst(_sequence(day, five, 13.0, 40, 0.0, Vector2(760, 160)), five)
	_ok(err < 0.3, "a person moving through the sequence is not mistaken for a disc", "worst %.3f px" % err)

	# A disc bigger than the refinement window (a very close camera).
	var one := PackedVector2Array([Vector2(900.4, 520.7)])
	err = _worst(_sequence(night, one, 150.0, 600, 0.0), one)
	_ok(err < 0.5, "a disc larger than the search window", "%.3f px off" % err)

	# Refusals.
	var blank := CalibDetect.new()
	for f in 3:
		blank.add_frame(night)
	var res := blank.locate(1)
	_ok(not res["ok"], "no disc -> refused", str(res["reason"]))

	var edge := PackedVector2Array([Vector2(6.0, 300.0)])
	res = _sequence(night, edge, 16.0, 600, 0.0).locate(1)
	_ok(not res["ok"], "a disc cut off by the frame edge -> refused", str(res["reason"]))

	# Something thin that was bright for exactly one frame: passes every test of
	# brightness, fails the one of shape.
	var streak := CalibDetect.new()
	streak.add_frame(night)
	var slash := night.duplicate() as Image
	for k in 90:
		_stamp(slash, Vector2(700.0 + k, 400.0 + k), 2.0, 600, 0.0)
	streak.add_frame(slash)
	streak.add_frame(night)
	res = streak.locate(1)
	_ok(not res["ok"], "a bright streak is not a disc -> refused", str(res["reason"]))

	# is_news(): the capture loop's "has the camera caught up?" question.
	var seq := CalibDetect.new()
	seq.add_frame(night)
	var first := night.duplicate() as Image
	_stamp(first, five[0], 16.0, 600, 0.0)
	_ok(seq.is_news(first), "a frame with a new disc is news")
	seq.add_frame(first)
	_ok(not seq.is_news(first), "the same disc again is not (the camera is lagging)")
	var second := night.duplicate() as Image
	_stamp(second, five[1], 16.0, 600, 0.0)
	_ok(seq.is_news(second), "the next disc is news")


# --- 10 ------------------------------------------------------------------

## What the rig's camera would see for whatever the editor last asked the wall
## to show. `quirk` bends the truth:
##   "lag"     replays the previous disc once
##   "missing" never shows disc 3 (a corner of the grid)
##   "blind"   never shows four of the nine
##   "bump"    moves the centre disc 25 px (one spot that is not on the plane)
##   "bent"    moves the whole right-hand column 25 px (a second wall)
##   "person"  walks a head across the top of every frame
##   "lamp"    hides the left half of disc 2 behind something
##   "decoy"   adds a brighter round blob elsewhere to disc 2's frame only (a
##             face turning)
##   "handheld" the camera drifts: every frame sits 1.6 px further along
##   "nudged"  the camera is knocked 7 px after the last disc, before the
##             disc AUTO shows a second time
##   "dent"    near the picture's top-left corner everything sits up to 6 px
##             from where a flat wall and a perfect lens would put it
##   "late"    the camera is knocked 8 px after AUTO is done, before the check
func _camera_frame(rig: Dictionary, base: Image, wall: Dictionary, quirk: String) -> Image:
	var p2w: CalibHomography = rig["p2w"]
	var w2c: CalibHomography = rig["w2c"]
	var img := base.duplicate() as Image
	var mode: int = wall["mode"]
	wall["frames"] = int(wall.get("frames", 0)) + 1
	if quirk == "person":
		_stamp(img, Vector2(640.0 + 30.0 * int(wall["frames"]), 150.0), 110.0, -200, 0.0)
	if mode == CalibPattern.Mode.ALL:
		for m in CalibPattern.marker_points(OUT):
			_stamp(img, _through_lens(w2c.apply(p2w.apply(m)), quirk), 8.0, 120, 0.0)
	elif mode == CalibPattern.Mode.SPOTS:
		# The check: discs wherever the editor asked for them.
		wall["checks"] = int(wall.get("checks", 0)) + 1
		var spots: PackedVector2Array = wall["spots"]
		for p in spots:
			var at := _through_lens(w2c.apply(p2w.apply(p)), quirk)
			if quirk == "late":
				at += Vector2(7, 4)
			if quirk == "bump" and p.distance_to(OUT * 0.5) < 1.0:
				at += Vector2(25, 0)   # the same spot off the plane as in AUTO
			_stamp(img, at, 18.0, 120, 0.0)
	elif mode == CalibPattern.Mode.SOLO:
		var index: int = wall["index"]
		if quirk == "lag" and index == 1 and not wall.has("lagged"):
			wall["lagged"] = true
			index = 0
		if quirk == "missing" and index == 2:
			return img
		if quirk == "blind" and [2, 5, 7, 8].has(index):
			return img
		var spot := CalibPattern.solo_point(OUT, index)
		var at := w2c.apply(p2w.apply(spot))
		# As big as the rig says the disc looks from here: further away, smaller.
		var ex := w2c.apply(p2w.apply(spot + Vector2(1, 0))) - at
		var ey := w2c.apply(p2w.apply(spot + Vector2(0, 1))) - at
		var radius := CalibPattern.SOLO_R * sqrt(absf(ex.cross(ey)))
		at = _through_lens(at, quirk)
		if quirk == "bump" and index == 4:
			at += Vector2(25, 0)
		if quirk == "bent" and index % CalibPattern.GRID_COLS == CalibPattern.GRID_COLS - 1:
			at += Vector2(25, 0)
		if quirk == "handheld":
			at += Vector2(1.6, 0.5) * float(wall["frames"])
		var shown: Array = wall.get("shown", [])
		if quirk == "nudged" and shown.has(index) and shown.size() > index + 1:
			at += Vector2(6, 3.6)   # asked for a second time, after later discs
		if not shown.has(index):
			shown.append(index)
			wall["shown"] = shown
		_stamp(img, at, radius, 40 if quirk == "person" else 120, 0.0)
		if quirk == "decoy" and index == 1:
			_stamp(img, Vector2(1700, 900), 9.0, 200, 0.0)
		if quirk == "lamp" and index == 1:
			# Put the wall back over everything left of the disc's centre.
			var reach := int(radius) + 4
			var x0 := int(at.x) - reach
			img.blit_rect(base, Rect2i(x0, int(at.y) - reach, reach, reach * 2), Vector2i(x0, int(at.y) - reach))
	return img


## The "dent" quirk: what the camera sees is pushed aside near one spot — by
## 6 px at the spot, fading over ~120 px. Too local for nine discs over the
## whole frame to fit; exactly where the picture's top-left corner is.
const DENT_AT := Vector2(556, 294)
func _through_lens(p: Vector2, quirk: String) -> Vector2:
	if quirk != "dent":
		return p
	return p + Vector2(5.0, -3.3) * exp(-p.distance_squared_to(DENT_AT) / (2.0 * 120.0 * 120.0))


## A fresh editor wired to the synthetic camera. -> [editor, quad, wall]
func _auto_editor(rig: Dictionary, base: Image, quirk: String) -> Array:
	var quad := QuadWarp.new()
	root.add_child(quad)
	quad.fill_rect(OUT)
	var ed := CalibEditor.new()
	root.add_child(ed)
	ed.setup(quad)
	ed.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ed.size = Vector2(1454, 648)
	ed.output_size_provider = func() -> Vector2: return OUT
	ed.settle_sec = 0.01
	var wall := {"mode": CalibPattern.Mode.ALL, "index": 0}
	ed.pattern_requested.connect(func(m: int, i: int) -> void:
		wall["mode"] = m
		wall["index"] = i)
	ed.spots_requested.connect(func(points: PackedVector2Array) -> void:
		wall["mode"] = CalibPattern.Mode.SPOTS
		wall["spots"] = points)
	ed.frame_provider = func() -> Image: return _camera_frame(rig, base, wall, quirk)
	ed.set_active(true)
	return [ed, quad, wall]


func _await_auto(ed: CalibEditor) -> void:
	for i in 900:
		await process_frame
		if not ed._busy:
			return


func _drop(pair: Array) -> void:
	for n: Node in [pair[0], pair[1]]:
		root.remove_child(n)
		n.free()


func _check_auto() -> void:
	var rig := _rig(PackedVector2Array([Vector2(310, 250), Vector2(1580, 180), Vector2(1690, 930), Vector2(240, 860)]))
	var p2w: CalibHomography = rig["p2w"]
	var w2c: CalibHomography = rig["w2c"]
	var target := Rect2(620, 420, 1920, 1080)
	var want := _calibrate(rig, target, 0.0)
	var base := _wall(70, 4)

	# The clean run.
	var pair := _auto_editor(rig, base, "")
	var ed: CalibEditor = pair[0]
	var quad: QuadWarp = pair[1]
	var before_auto := quad.corners.duplicate()
	ed._auto_pressed()
	_ok(ed._busy, "AUTO starts and holds the editor busy")
	ed._press(0, Vector2(700, 300))
	_ok(ed._markers.size() == 0 and ed._surface.size() == 0, "touches are ignored while AUTO runs")
	await _await_auto(ed)
	var worst := 0.0
	var truth := CalibPattern.marker_points(OUT)
	for i in mini(ed._markers.size(), 4):
		worst = maxf(worst, ed._markers[i].distance_to(w2c.apply(p2w.apply(truth[i]))))
	_ok(ed._markers.size() == 4 and worst < 0.3, "AUTO's fit puts the four numbered markers where they are",
		"worst %.3f camera px" % worst)
	var used: PackedInt32Array = ed._fit["used"]
	_ok(ed.step == CalibEditor.Step.SURFACE and ed._hint.text.contains("AUTO 9/9") and used.size() == 9,
		"all nine discs agree and AUTO goes straight to SURFACE", ed._hint.text)
	_ok(ed._flood != null and ed._view.texture == ed._flood, "SURFACE is marked on the projector-lit frame")
	_ok(ed._checked.begins_with("CHECKED") and ed._hint.text.contains("CHECKED") and int(pair[2].get("checks", 0)) == 1
		and ed._local == null,
		"the result was checked on the wall: four discs at the picture's corners, one look, nothing to correct", ed._checked)
	_ok(ed._surface.size() == 4 and quad.corners != before_auto and ed._applied,
		"AUTO alone already corrected the projection — DONE would keep it")
	_mark_surface(ed, _cam_corners(w2c, target))
	worst = 0.0
	for i in 4:
		worst = maxf(worst, quad.corners[i].distance_to(want[i]))
	_ok(worst < 1.5, "AUTO + four surface taps give the right keystone",
		"worst %.3f output px from the exact answer" % worst)
	ed._next_pressed()   # SURFACE -> MARKERS: review what AUTO found
	_ok(ed.step == CalibEditor.Step.MARKERS and ed._view.texture == ed._frozen and ed._markers.size() == 4,
		"MARKERS shows the pattern frame with the four markers marked")
	# Looking is free; touching one makes the calibration the four points'.
	var fitted := ed._cam_to_out
	ed._solve()
	_ok(ed._cam_to_out == fitted, "looking at MARKERS keeps the nine-disc fit")
	ed._press(0, ed._to_screen(ed._markers[0]))
	ed._drag(0, ed._to_screen(ed._markers[0]) + Vector2(6, 4))
	ed._release(0)
	_ok(ed._cam_to_out != fitted and ed._cam_to_out != null, "dragging a marker hands the calibration to the four points")
	ed._esc_pressed()
	_drop(pair)

	# Someone walks through the shot for the whole sequence.
	pair = _auto_editor(rig, base, "person")
	ed = pair[0]
	ed._auto_pressed()
	await _await_auto(ed)
	worst = 0.0
	for i in mini(ed._markers.size(), 4):
		worst = maxf(worst, ed._markers[i].distance_to(w2c.apply(p2w.apply(truth[i]))))
	_ok(ed.step == CalibEditor.Step.SURFACE and ed._markers.size() == 4 and worst < 0.3,
		"AUTO with a person moving in the shot still fits the grid", "%s, worst %.3f camera px" % [ed._fit.get("used"), worst])
	ed._esc_pressed()
	_drop(pair)

	# Something round and brighter than the disc shows up in disc 2's frame
	# only. It wins on brightness; the geometry has to overrule it — and then
	# find the real disc among the runners-up.
	pair = _auto_editor(rig, base, "decoy")
	ed = pair[0]
	ed._auto_pressed()
	await _await_auto(ed)
	used = ed._fit.get("used", PackedInt32Array())
	var ranks: PackedInt32Array = ed._fit.get("ranks", PackedInt32Array())
	_ok(ed.step == CalibEditor.Step.SURFACE and used.size() == 9 and ranks.size() == 9 and ranks[1] > 0,
		"a brighter round decoy in one frame is overruled, and the real disc found behind it",
		"ranks %s" % [ranks])
	ed._esc_pressed()
	_drop(pair)

	# A lampshade in front of half of disc 2. It is bright, exclusive and
	# disc-shaped, and its centre has only slid a little. It must not steer the
	# fit — and one lost disc must not stop the calibration any more.
	pair = _auto_editor(rig, base, "lamp")
	ed = pair[0]
	ed._auto_pressed()
	await _await_auto(ed)
	used = ed._fit.get("used", PackedInt32Array())
	worst = 0.0
	for i in mini(ed._markers.size(), 4):
		worst = maxf(worst, ed._markers[i].distance_to(w2c.apply(p2w.apply(truth[i]))))
	_ok(ed.step == CalibEditor.Step.SURFACE and used.size() == 8 and not used.has(1) and worst < 0.3
		and ed._hint.text.contains("AUTO 8/9"),
		"a half-hidden disc is left out and the other eight carry the calibration",
		"%s · hidden %s · worst %.3f camera px" % [ed._hint.text.left(22), ed._fit.get("hidden"), worst])
	ed._esc_pressed()
	_drop(pair)

	# The camera shows disc 1 again when disc 2 is asked for, once.
	pair = _auto_editor(rig, base, "lag")
	ed = pair[0]
	ed._auto_pressed()
	await _await_auto(ed)
	used = ed._fit.get("used", PackedInt32Array())
	_ok(ed.step == CalibEditor.Step.SURFACE and pair[2].has("lagged") and used.size() == 9,
		"a lagging camera is noticed and retried, not believed")
	ed._esc_pressed()
	_drop(pair)

	# Disc 3 never appears (it fell off the surface, say).
	pair = _auto_editor(rig, base, "missing")
	ed = pair[0]
	ed._auto_pressed()
	await _await_auto(ed)
	used = ed._fit.get("used", PackedInt32Array())
	_ok(ed.step == CalibEditor.Step.SURFACE and used.size() == 8 and not used.has(2),
		"a disc that never shows is done without", ed._hint.text.left(22))
	ed._esc_pressed()
	_drop(pair)

	# One disc lands on something that is not the wall. It is also the disc
	# AUTO shows twice to check for movement — and it has not moved.
	pair = _auto_editor(rig, base, "bump")
	ed = pair[0]
	ed._auto_pressed()
	await _await_auto(ed)
	used = ed._fit.get("used", PackedInt32Array())
	_ok(ed.step == CalibEditor.Step.SURFACE and used.size() == 8 and not used.has(4),
		"one disc 25 px off the plane is outvoted (and is not mistaken for movement)", ed._hint.text.left(22))
	ed._esc_pressed()
	_drop(pair)

	# THE FIRST WALL RUN OF THE GRID: a phone held in the hand. Enough discs
	# still agree for a fit; it must be refused anyway, and for the right reason.
	pair = _auto_editor(rig, base, "handheld")
	ed = pair[0]
	quad = pair[1]
	var still_warp := quad.corners.duplicate()
	ed._auto_pressed()
	await _await_auto(ed)
	_ok(ed.step == CalibEditor.Step.MARKERS and ed._cam_to_out == null and ed._hint.text.contains("THE PHONE MOVED")
		and quad.corners == still_warp,
		"a phone drifting in the hand is refused, and named as the reason", ed._hint.text)
	ed._esc_pressed()
	_drop(pair)

	# Every disc agrees, and then the phone is knocked.
	pair = _auto_editor(rig, base, "nudged")
	ed = pair[0]
	ed._auto_pressed()
	await _await_auto(ed)
	_ok(ed.step == CalibEditor.Step.MARKERS and ed._hint.text.contains("THE PHONE MOVED 7 PX"),
		"a knock after the last disc is caught by the disc shown twice", ed._hint.text)
	ed._esc_pressed()
	_drop(pair)

	# Four of the nine never appear.
	pair = _auto_editor(rig, base, "blind")
	ed = pair[0]
	ed._auto_pressed()
	await _await_auto(ed)
	_ok(ed.step == CalibEditor.Step.MARKERS and ed._markers.size() == 0 and ed._cam_to_out == null
		and ed._hint.text.contains("ONLY 5 OF 9") and ed._frozen != null,
		"too few discs falls back to tapping, and says how many it saw", ed._hint.text)
	ed._esc_pressed()
	_drop(pair)

	# A whole column is 25 px from where a flat surface would put it.
	pair = _auto_editor(rig, base, "bent")
	ed = pair[0]
	quad = pair[1]
	var before := quad.corners.duplicate()
	ed._auto_pressed()
	await _await_auto(ed)
	_ok(ed.step == CalibEditor.Step.MARKERS and ed._markers.size() == 0 and ed._hint.text.contains("IS THE SURFACE FLAT")
		and quad.corners == before,
		"a surface that is not flat stops at MARKERS with the reason, the warp untouched", ed._hint.text)
	ed._esc_pressed()
	_drop(pair)

	# A wall (or a lens) that is not quite what a homography assumes, right
	# where a corner of the picture is. The check sees by how much, corrects,
	# and looks again.
	pair = _auto_editor(rig, base, "dent")
	ed = pair[0]
	quad = pair[1]
	ed._auto_pressed()
	await _await_auto(ed)
	var rough := CalibEditor.surface_to_corners(ed._cam_to_out, ed._surface)
	var trimmed := 0.0
	for i in mini(rough.size(), 4):
		trimmed = maxf(trimmed, rough[i].distance_to(quad.corners[i]))
	_ok(ed.step == CalibEditor.Step.SURFACE and ed._checked.contains("(WAS") and ed._local != null
		and int(pair[2].get("checks", 0)) == 2 and trimmed > 0.3 and trimmed < 12.0,
		"a dent at one corner of the picture: the check corrects the corners and confirms it",
		"%s, corners moved by up to %.1f output px" % [ed._checked, trimmed])
	ed._auto_pressed()   # WALL -> the taps (no gravity here): the correction belonged to that square
	ed._auto_pressed()   # BACK
	ed._esc_pressed()
	_drop(pair)

	# The phone is knocked after AUTO has finished, before the check.
	pair = _auto_editor(rig, base, "late")
	ed = pair[0]
	quad = pair[1]
	ed._auto_pressed()
	await _await_auto(ed)
	var unchecked := CalibEditor.surface_to_corners(ed._cam_to_out, ed._surface)
	_ok(ed.step == CalibEditor.Step.SURFACE and ed._checked.contains("PHONE MOVED") and ed._local == null
		and unchecked.size() == 4 and quad.corners[0].distance_to(unchecked[0]) < 0.001 and ed._hint.text.contains("UNCHECKED: PHONE MOVED"),
		"a phone knocked before the check: nothing is corrected, and SURFACE says it was not checked", ed._hint.text)
	ed._esc_pressed()
	_drop(pair)

	# No projector link: nothing to check against.
	pair = _auto_editor(rig, base, "")
	ed = pair[0]
	ed.dry_run = true
	ed._auto_pressed()
	await _await_auto(ed)
	_ok(ed.step == CalibEditor.Step.SURFACE and ed._checked == "" and int(pair[2].get("checks", 0)) == 0,
		"with no projector link there is no check")
	ed._esc_pressed()
	_drop(pair)

	# ESC in the middle of a run.
	pair = _auto_editor(rig, base, "")
	ed = pair[0]
	quad = pair[1]
	before = quad.corners.duplicate()
	ed._auto_pressed()
	for i in 4:
		await process_frame
	ed._esc_pressed()
	for i in 60:
		await process_frame
	_ok(not ed.active and not ed._busy and ed._frozen == null and quad.corners == before,
		"ESC mid-AUTO stops the sequence and leaves nothing behind")
	_drop(pair)


# --- 7b ------------------------------------------------------------------

func _check_auto_surface() -> void:
	var aspect := OUT.x / OUT.y
	# A camera square-on to the wall (a similarity: scale + shift). Here "as the
	# camera sees it" IS "on the wall", so the result can be judged on the wall.
	var frontal := PackedVector2Array([Vector2(300, 150), Vector2(1580, 150), Vector2(1580, 870), Vector2(300, 870)])
	var rig := _rig(frontal)
	var p2w: CalibHomography = rig["p2w"]
	var w2c: CalibHomography = rig["w2c"]
	var out_to_cam := CalibHomography.solve(_rect_corners(Rect2(Vector2.ZERO, OUT)),
		PackedVector2Array([w2c.apply(p2w.apply(Vector2.ZERO)), w2c.apply(p2w.apply(Vector2(OUT.x, 0))),
			w2c.apply(p2w.apply(OUT)), w2c.apply(p2w.apply(Vector2(0, OUT.y)))]))
	var rect := CalibEditor.auto_surface(out_to_cam, OUT)
	_ok(rect.size() == 4, "auto_surface returns four corners")
	if rect.size() != 4:
		return
	var corners := CalibEditor.surface_to_corners(out_to_cam.inverse(), rect)
	var wall := PackedVector2Array()
	for c in corners:
		wall.append(p2w.apply(c))
	var top := wall[1] - wall[0]
	var left := wall[3] - wall[0]
	var skew := absf(top.normalized().dot(left.normalized()))
	var shape := top.length() / left.length()
	_ok(skew < 0.001 and absf(shape / aspect - 1.0) < 0.002,
		"square-on camera: the picture is a true 16:9 rectangle ON THE WALL",
		"skew %.5f, aspect %.4f (want %.4f)" % [skew, shape, aspect])
	var inside := true
	for c in corners:
		if not Rect2(Vector2.ZERO, OUT).grow(0.01).has_point(c):
			inside = false
	_ok(inside, "every warp corner is inside the projector's frame")
	# As big as it can be: 3% bigger about its own centre no longer fits.
	var mid := (rect[0] + rect[2]) * 0.5
	var grown := PackedVector2Array()
	for p in rect:
		grown.append(mid + (p - mid) * 1.03)
	var spills := false
	for c in CalibEditor.surface_to_corners(out_to_cam.inverse(), grown):
		if not Rect2(Vector2.ZERO, OUT).has_point(c):
			spills = true
	var used := (rect[1] - rect[0]).length() * (rect[3] - rect[0]).length()
	var quad_cam := PackedVector2Array()
	for c in _rect_corners(Rect2(Vector2.ZERO, OUT)):
		quad_cam.append(out_to_cam.apply(c))
	var avail := absf((quad_cam[2] - quad_cam[0]).cross(quad_cam[3] - quad_cam[1])) * 0.5
	_ok(spills, "it is as large as the projector's frame allows", "uses %.0f%% of the frame's area" % (100.0 * used / avail))

	# hidden_discs() must not mistake PERSPECTIVE for occlusion: under a steep
	# view the far discs really are smaller. Areas here are exactly what the
	# geometry predicts, so none is "hidden" — until one is halved.
	var steep := CalibHomography.solve(_rect_corners(Rect2(Vector2.ZERO, OUT)),
		PackedVector2Array([Vector2(200, 300), Vector2(1700, 80), Vector2(1750, 1000), Vector2(220, 760)]))
	var honest: Array = []
	var pairs: Array = []
	var lo := INF
	var hi := 0.0
	for i in CalibPattern.GRID_COLS * CalibPattern.GRID_ROWS:
		var at := CalibPattern.solo_point(OUT, i)
		var o := steep.apply(at)
		var jac := absf((steep.apply(at + Vector2(1, 0)) - o).cross(steep.apply(at + Vector2(0, 1)) - o))
		var area := int(PI * CalibPattern.SOLO_R * CalibPattern.SOLO_R * jac)
		honest.append([{"ok": true, "pos": o, "area": area}])
		pairs.append([i, 0])
		lo = minf(lo, area)
		hi = maxf(hi, area)
	_ok(CalibEditor.hidden_discs(steep, OUT, pairs, honest).is_empty(),
		"discs that are smaller only because they are further away are not 'hidden'",
		"largest %.1fx the smallest" % (hi / lo))
	honest[3][0]["area"] = int(honest[3][0]["area"] * 0.55)
	_ok(CalibEditor.hidden_discs(steep, OUT, pairs, honest) == PackedInt32Array([3]),
		"…and a disc at 55% of its expected area is")

	# The same rig seen by cameras whose frames arrive rotated and mirrored.
	var reference := corners
	for kind: String in ["rotated 90°", "mirrored"]:
		var turned := PackedVector2Array()
		for p in frontal:
			turned.append(Vector2(CAM.y - p.y, p.x) if kind == "rotated 90°" else Vector2(CAM.x - p.x, p.y))
		var rig2 := _rig(turned)
		var w2c2: CalibHomography = rig2["w2c"]
		var o2c := CalibHomography.solve(_rect_corners(Rect2(Vector2.ZERO, OUT)),
			PackedVector2Array([w2c2.apply(p2w.apply(Vector2.ZERO)), w2c2.apply(p2w.apply(Vector2(OUT.x, 0))),
				w2c2.apply(p2w.apply(OUT)), w2c2.apply(p2w.apply(Vector2(0, OUT.y)))]))
		var c2 := CalibEditor.surface_to_corners(o2c.inverse(), CalibEditor.auto_surface(o2c, OUT))
		var drift := INF
		if c2.size() == 4:
			drift = 0.0
			for i in 4:
				drift = maxf(drift, c2[i].distance_to(reference[i]))
		_ok(drift < 0.5, "camera frame %s: the same warp corners" % kind, "differs by %.3f output px" % drift)


# --- 9b ------------------------------------------------------------------

## What CalibDetect would hand fit_grid() for the rig: one candidate per grid
## disc, where the rig's camera sees it (plus `noise`), with the area the
## geometry predicts.
func _grid_cands(rig: Dictionary, noise: float) -> Array:
	var p2w: CalibHomography = rig["p2w"]
	var w2c: CalibHomography = rig["w2c"]
	var cands: Array = []
	for g in CalibPattern.grid_points(OUT):
		var at := w2c.apply(p2w.apply(g))
		var ex := w2c.apply(p2w.apply(g + Vector2(1, 0))) - at
		var ey := w2c.apply(p2w.apply(g + Vector2(0, 1))) - at
		cands.append([{"ok": true, "pos": at + _jit(noise),
			"area": int(PI * CalibPattern.SOLO_R * CalibPattern.SOLO_R * absf(ex.cross(ey)))}])
	return cands


func _check_fit_grid() -> void:
	var rig := _rig(PackedVector2Array([Vector2(310, 250), Vector2(1580, 180), Vector2(1690, 930), Vector2(240, 860)]))
	var p2w: CalibHomography = rig["p2w"]
	var w2c: CalibHomography = rig["w2c"]
	var frame := _rect_corners(Rect2(Vector2.ZERO, OUT))

	var fit := CalibEditor.fit_grid(_grid_cands(rig, 0.0), OUT)
	var used: PackedInt32Array = fit["used"]
	var rms: float = fit["rms"]
	_ok(fit["ok"] and used.size() == 9 and rms < 0.01, "nine exact discs: all used", "rms %.5f camera px" % rms)

	# WHY NINE. The same detection noise, read at the picture's own corners in
	# output px — where the keystone is set — for the old four inset markers
	# and for the grid.
	var sum4 := 0.0
	var sum9 := 0.0
	var n := 0
	for trial in 300:
		var m_cam := PackedVector2Array()
		for m in CalibPattern.marker_points(OUT):
			m_cam.append(w2c.apply(p2w.apply(m)) + _jit(1.0))
		var h4 := CalibHomography.solve(m_cam, CalibPattern.marker_points(OUT))
		var f9 := CalibEditor.fit_grid(_grid_cands(rig, 1.0), OUT)
		if h4 == null or not f9["ok"]:
			continue
		var h9: CalibHomography = f9["h"]
		for c in frame:
			var seen := w2c.apply(p2w.apply(c))
			sum4 += h4.apply(seen).distance_to(c)
			sum9 += h9.apply(seen).distance_to(c)
		n += 1
	_ok(n == 300 and sum9 < sum4 * 0.75, "the grid pins the picture's corners better than four markers did",
		"mean corner error at 1 px of detection noise: %.2f output px (four) vs %.2f (grid)" % [sum4 / (4.0 * n), sum9 / (4.0 * n)])

	# A decoy is the STRONGEST candidate of disc 6, the real disc the runner-up.
	var cands := _grid_cands(rig, 0.3)
	var real: Dictionary = cands[5][0]
	cands[5] = [{"ok": true, "pos": Vector2(1500, 300), "area": 900}, real]
	fit = CalibEditor.fit_grid(cands, OUT)
	used = fit["used"]
	var ranks: PackedInt32Array = fit["ranks"]
	_ok(fit["ok"] and used.size() == 9 and ranks[used.find(5)] == 1,
		"a decoy that out-shone its disc is outvoted and the runner-up taken", "ranks %s" % [ranks])

	# The decoy is ALL that was found for that disc.
	cands = _grid_cands(rig, 0.3)
	cands[5] = [{"ok": true, "pos": Vector2(1500, 300), "area": 900}]
	fit = CalibEditor.fit_grid(cands, OUT)
	used = fit["used"]
	_ok(fit["ok"] and used.size() == 8 and not used.has(5), "…or the disc is done without")

	# Two discs not found at all.
	cands = _grid_cands(rig, 0.3)
	cands[0] = [{"ok": false, "pos": Vector2.ZERO, "area": 0, "reason": "NOT SEEN"}]
	cands[7] = [{"ok": false, "pos": Vector2.ZERO, "area": 0, "reason": "NOT SEEN"}]
	fit = CalibEditor.fit_grid(cands, OUT)
	used = fit["used"]
	_ok(fit["ok"] and used.size() == 7 and fit["seen"] == 7, "seven of nine are enough")

	# A disc whose centre slid only 3 px — inside the tolerance — but which
	# shows half the area it should: hidden, and left out.
	cands = _grid_cands(rig, 0.0)
	cands[2][0]["pos"] += Vector2(3, 0)
	cands[2][0]["area"] = int(cands[2][0]["area"] * 0.5)
	fit = CalibEditor.fit_grid(cands, OUT)
	used = fit["used"]
	rms = fit["rms"]
	_ok(fit["ok"] and fit["hidden"] == PackedInt32Array([2]) and not used.has(2) and rms < 0.01,
		"a half-hidden disc inside the tolerance is caught by its size and left out of the fit",
		"rms %.5f without it" % rms)

	# Refusals. Only five seen; and six that agree, all on one side (the right
	# column is on another wall).
	cands = _grid_cands(rig, 0.3)
	for i: int in [1, 3, 5, 7]:
		cands[i] = [{"ok": false, "pos": Vector2.ZERO, "area": 0, "reason": "NOT SEEN"}]
	fit = CalibEditor.fit_grid(cands, OUT)
	_ok(not fit["ok"] and str(fit["reason"]).contains("ONLY 5 OF 9 MARKERS SEEN"), "five discs are refused", str(fit["reason"]))
	cands = _grid_cands(rig, 0.3)
	for i: int in [2, 5, 8]:
		cands[i][0]["pos"] += Vector2(25, 6)
	fit = CalibEditor.fit_grid(cands, OUT)
	_ok(not fit["ok"] and str(fit["reason"]).contains("IS THE SURFACE FLAT"),
		"a fit that holds on one side only is refused", str(fit["reason"]))


# --- 11 ------------------------------------------------------------------

const FOCAL := 1386.0

## A rig in 3D, for CalibWall. The camera is at the origin looking down +z (x
## right, y down). The wall is turned away from it by `yaw`, and the camera is
## tipped by `pitch` and rolled by `roll` against it. The PROJECTOR stands
## 35 cm beside the camera and looks the same way — the real arrangement, with
## the phone on the HDMI cable — so from the camera the throw looks almost
## rectangular however keystoned it is on the wall. Wall coordinates: metres.
func _wall_rig(yaw: float, pitch: float, roll: float) -> Dictionary:
	var b := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), deg_to_rad(roll)))
	var rig := {"r": b.x, "d": b.y, "n": b.z, "p0": Vector3(0.1, -0.05, 3.0)}
	var lens := Vector3(0.35, 0.08, 0.0)
	var throw_f := OUT.x * 1.4
	var throw := PackedVector2Array()
	var seen := PackedVector2Array()
	for c in _rect_corners(Rect2(Vector2.ZERO, OUT)):
		var ray := Vector3((c.x - OUT.x * 0.5) / throw_f, (c.y - OUT.y * 0.5) / throw_f, 1.0)
		var t: float = (rig["p0"] - lens).dot(rig["n"]) / ray.dot(rig["n"])
		var hit: Vector3 = lens + ray * t - rig["p0"]
		var on_wall := Vector2(hit.dot(rig["r"]), hit.dot(rig["d"]))
		throw.append(on_wall)
		seen.append(_wall_to_cam(rig, on_wall))
	rig["throw"] = throw
	rig["o2w"] = CalibHomography.solve(_rect_corners(Rect2(Vector2.ZERO, OUT)), throw)
	rig["o2c"] = CalibHomography.solve(_rect_corners(Rect2(Vector2.ZERO, OUT)), seen)
	return rig


func _wall_to_cam(rig: Dictionary, w: Vector2) -> Vector2:
	var x: Vector3 = rig["p0"] + rig["r"] * w.x + rig["d"] * w.y
	return CAM * 0.5 + Vector2(x.x, x.y) * (FOCAL / x.z)


## Two points on each of two level lines, then on each of two plumb lines —
## the eight taps of the WALL step, as the rig's camera sees those lines.
func _wall_taps(rig: Dictionary, noise: float) -> PackedVector2Array:
	var taps := PackedVector2Array()
	for seg: Array in [[Vector2(-1.2, -0.72), Vector2(1.1, -0.72)], [Vector2(-1.1, 0.7), Vector2(1.2, 0.7)],
			[Vector2(-1.3, -0.52), Vector2(-1.3, 0.55)], [Vector2(1.3, -0.5), Vector2(1.3, 0.6)]]:
		for w: Vector2 in seg:
			taps.append(_wall_to_cam(rig, w) + _jit(noise))
	return taps


## What a picture with these surface corners (camera px) looks like ON THE
## WALL: { lean: the worst angle of a side from level/plumb, in degrees,
## aspect: width / height, quad: the corners in metres }.
func _on_wall(rig: Dictionary, surface_cam: PackedVector2Array) -> Dictionary:
	var o2c: CalibHomography = rig["o2c"]
	var o2w: CalibHomography = rig["o2w"]
	var q := PackedVector2Array()
	for c in CalibEditor.surface_to_corners(o2c.inverse(), surface_cam):
		q.append(o2w.apply(c))
	if q.size() != 4:
		return {"lean": INF, "aspect": 0.0, "quad": q}
	var lean := 0.0
	for e: Vector2 in [q[1] - q[0], q[2] - q[3]]:
		lean = maxf(lean, absf(rad_to_deg(atan2(e.y, e.x))))
	for e: Vector2 in [q[3] - q[0], q[2] - q[1]]:
		lean = maxf(lean, absf(rad_to_deg(atan2(e.x, e.y))))
	var width := ((q[1] - q[0]).length() + (q[2] - q[3]).length()) * 0.5
	var height := ((q[3] - q[0]).length() + (q[2] - q[1]).length()) * 0.5
	return {"lean": lean, "aspect": width / height, "quad": q}


func _check_wall() -> void:
	var aspect := OUT.x / OUT.y
	var rig := _wall_rig(24.0, 6.0, 2.0)
	var o2c: CalibHomography = rig["o2c"]
	var throw: PackedVector2Array = rig["throw"]
	var taps := _wall_taps(rig, 0.0)
	var level := taps.slice(0, 4)
	var plumb := taps.slice(4, 8)
	var in_shot := true
	for p in taps:
		if not Rect2(Vector2.ZERO, CAM).grow(-20.0).has_point(p):
			in_shot = false
	_ok(in_shot, "the rig's level and plumb lines are in the shot (a tap cannot be anywhere else)", "%s" % [taps])

	# The premise: beside the projector the throw LOOKS square, and is not.
	var seen := PackedVector2Array()
	for c in _rect_corners(Rect2(Vector2.ZERO, OUT)):
		seen.append(o2c.apply(c))
	var seen_ratio := seen[0].distance_to(seen[3]) / seen[1].distance_to(seen[2])
	var wall_ratio := throw[0].distance_to(throw[3]) / throw[1].distance_to(throw[2])
	var phone := _on_wall(rig, CalibEditor.auto_surface(o2c, OUT))
	_ok(absf(seen_ratio - 1.0) < 0.05 and absf(wall_ratio - 1.0) > 0.15 and phone["lean"] > 1.0,
		"the rig: a throw that looks square from the phone and is keystoned on the wall",
		"left/right sides %.2f as seen, %.2f on the wall; 'squared up from the phone' leans %.1f deg there"
			% [seen_ratio, wall_ratio, phone["lean"]])

	var wall := CalibWall.solve(level, plumb, Vector3.ZERO, CAM, FOCAL)
	_ok(wall != null and wall.normal.dot(rig["n"]) > 0.99999 and wall.skew_deg < 0.05,
		"CalibWall finds the wall from two level and two plumb lines",
		"normal %.2f deg off" % rad_to_deg(acos(clampf(wall.normal.dot(rig["n"]), -1.0, 1.0))) if wall != null else "null")
	if wall == null:
		return
	var rect := wall.surface(o2c, OUT)
	var got := _on_wall(rig, rect)
	_ok(rect.size() == 4 and got["lean"] < 0.02 and absf(got["aspect"] / aspect - 1.0) < 0.002,
		"the picture is a true 16:9 rectangle ON THE WALL, level and plumb",
		"worst side %.4f deg off, aspect %.4f (want %.4f)" % [got["lean"], got["aspect"], aspect])
	var corners := CalibEditor.surface_to_corners(o2c.inverse(), rect)
	var inside := corners.size() == 4
	for c in corners:
		if not Rect2(Vector2.ZERO, OUT).grow(0.01).has_point(c):
			inside = false
	_ok(inside and corners[0].x < corners[1].x and corners[0].y < corners[3].y,
		"…inside the projector's frame, and the right way round", "%s" % [corners])
	var q: PackedVector2Array = got["quad"]
	var mid := (q[0] + q[2]) * 0.5
	var spills := false
	for p in q:
		if not Geometry2D.is_point_in_polygon(mid + (p - mid) * 1.03, throw):
			spills = true
	var area := (q[1] - q[0]).length() * (q[3] - q[0]).length()
	var avail := absf((throw[2] - throw[0]).cross(throw[3] - throw[1])) * 0.5
	_ok(spills, "…and as large as the throw allows", "uses %.0f%% of the throw's area" % (100.0 * area / avail))

	# Plumb from the gravity sensor instead of two tapped lines.
	var by_g := CalibWall.solve(level, PackedVector2Array(), rig["d"], CAM, FOCAL)
	var drift := INF
	if by_g != null:
		var rect_g := by_g.surface(o2c, OUT)
		if rect_g.size() == 4:
			drift = 0.0
			for i in 4:
				drift = maxf(drift, rect_g[i].distance_to(rect[i]))
	_ok(drift < 0.05, "plumb from gravity gives the same picture as tapped plumb lines", "differs by %.4f camera px" % drift)

	# The focal length is a guess. With tapped lines a wrong guess must change
	# the picture's proportions and nothing else.
	for scale: float in [0.88, 1.12]:
		var off := CalibWall.solve(level, plumb, Vector3.ZERO, CAM, FOCAL * scale)
		var res := _on_wall(rig, off.surface(o2c, OUT)) if off != null else {"lean": INF, "aspect": 0.0}
		_ok(res["lean"] < 0.02 and absf(res["aspect"] / aspect - 1.0) < 0.08,
			"focal length %+d%% wrong: still level and plumb, only the proportions move" % roundi((scale - 1.0) * 100.0),
			"worst side %.4f deg off, aspect %+.1f%%" % [res["lean"], (res["aspect"] / aspect - 1.0) * 100.0])
	# With gravity the same wrong guess does lean the sides (the camera is
	# tipped 6 deg here): gravity is squared up against level, and level's
	# direction in space depends on the focal length. Reported, loosely gated —
	# the number calib_wall.gd's header quotes.
	var off_g := CalibWall.solve(level, PackedVector2Array(), rig["d"], CAM, FOCAL * 1.12)
	var res_g := _on_wall(rig, off_g.surface(o2c, OUT)) if off_g != null else {"lean": INF}
	_ok(res_g["lean"] < 1.0, "focal length +12% wrong with gravity plumb, phone tipped 6 deg",
		"worst side %.2f deg off" % res_g["lean"])

	# Fingers. 1.5 px of tap noise on all eight points.
	var sum := 0.0
	var worst := 0.0
	var n := 0
	for trial in 200:
		var noisy := _wall_taps(rig, 1.5)
		var w := CalibWall.solve(noisy.slice(0, 4), noisy.slice(4, 8), Vector3.ZERO, CAM, FOCAL)
		if w == null:
			continue
		var res := _on_wall(rig, w.surface(o2c, OUT))
		sum += res["lean"]
		worst = maxf(worst, res["lean"])
		n += 1
	_ok(n == 200 and sum / float(maxi(n, 1)) < 0.5, "tap noise sigma 1.5 camera px on the eight points",
		"worst side leans %.2f deg on average, %.2f at worst" % [sum / float(maxi(n, 1)), worst])
	# …and on the four level points only, plumb from a gravity reading that is
	# itself half a degree out (the sensor, and the lens not quite square to it).
	sum = 0.0
	worst = 0.0
	n = 0
	for trial in 200:
		var noisy := _wall_taps(rig, 1.5)
		var g: Vector3 = rig["d"]
		g = g.rotated(Vector3(0, 0, 1), deg_to_rad(_rng.randfn(0.0, 0.5))).rotated(Vector3(1, 0, 0), deg_to_rad(_rng.randfn(0.0, 0.5)))
		var w := CalibWall.solve(noisy.slice(0, 4), PackedVector2Array(), g, CAM, FOCAL)
		if w == null:
			continue
		var res := _on_wall(rig, w.surface(o2c, OUT))
		sum += res["lean"]
		worst = maxf(worst, res["lean"])
		n += 1
	_ok(n == 200 and sum / float(maxi(n, 1)) < 0.8, "the same taps on the level lines, plumb from a sensor 0.5 deg out",
		"worst side leans %.2f deg on average, %.2f at worst" % [sum / float(maxi(n, 1)), worst])

	# The camera frame arrives rotated 90 deg: the taps turn with it, nothing
	# else is told, and the warp corners must not change.
	var turned_o2c := CalibHomography.solve(_rect_corners(Rect2(Vector2.ZERO, OUT)),
		PackedVector2Array([_turn(seen[0]), _turn(seen[1]), _turn(seen[2]), _turn(seen[3])]))
	var turned := PackedVector2Array()
	for p in taps:
		turned.append(_turn(p))
	var wt := CalibWall.solve(turned.slice(0, 4), turned.slice(4, 8), Vector3.ZERO, Vector2(CAM.y, CAM.x), FOCAL)
	drift = INF
	if wt != null:
		var ct := CalibEditor.surface_to_corners(turned_o2c.inverse(), wt.surface(turned_o2c, OUT))
		if ct.size() == 4:
			drift = 0.0
			for i in 4:
				drift = maxf(drift, ct[i].distance_to(corners[i]))
	_ok(drift < 0.5, "camera frame rotated 90 deg: the same warp corners", "differs by %.3f output px" % drift)

	# Refusals: "level" lines that are really plumb, and the same line twice.
	_ok(CalibWall.solve(plumb, plumb, Vector3.ZERO, CAM, FOCAL) == null, "level and plumb along the same direction -> refused")
	var twice := PackedVector2Array([level[0], level[1], level[0], level[1]])
	_ok(CalibWall.solve(twice, plumb, Vector3.ZERO, CAM, FOCAL) == null, "the same level line tapped twice -> refused")


func _turn(p: Vector2) -> Vector2:
	return Vector2(CAM.y - p.y, p.x)


# --- 12 ------------------------------------------------------------------

## A quad on the rig's wall, from wall metres: (u0, v0) to (u1, v1), turned
## `lean` degrees about its own middle.
func _wall_quad(rig: Dictionary, u0: float, v0: float, u1: float, v1: float, lean: float = 0.0) -> Array:
	var mid := Vector2(u0 + u1, v0 + v1) * 0.5
	var out: Array = []
	for w: Vector2 in [Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1)]:
		var t := mid + (w - mid).rotated(deg_to_rad(lean))
		out.append(rig["p0"] + rig["r"] * t.x + rig["d"] * t.y)
	return out


## A quad on the NEXT wall — the one that meets the rig's wall at u = `at` and
## comes towards the camera: from `s0` to `s1` metres out from the corner.
## (On this rig the left-hand one is the one the camera can see.)
func _side_quad(rig: Dictionary, at: float, s0: float, v0: float, s1: float, v1: float) -> Array:
	var out: Array = []
	for w: Vector2 in [Vector2(s0, v0), Vector2(s1, v0), Vector2(s1, v1), Vector2(s0, v1)]:
		out.append(rig["p0"] + rig["r"] * at + rig["d"] * w.y - rig["n"] * w.x)
	return out


## What the rig's camera sees of a room: a plain wall and `things`, each
## [four corners in space, brightness]. Drawn at twice the size and averaged
## down, so edges are anti-aliased the way a lens leaves them.
func _room(things: Array) -> Image:
	var w := int(CAM.x) * 2
	var h := int(CAM.y) * 2
	var data := PackedByteArray()
	data.resize(w * h)
	data.fill(205)
	for thing: Array in things:
		var quad := PackedVector2Array()
		for x3: Vector3 in thing[0]:
			quad.append((CAM * 0.5 + Vector2(x3.x, x3.y) * (FOCAL / x3.z)) * 2.0)
		var value: int = thing[1]
		var top := INF
		var bottom := -INF
		for p in quad:
			top = minf(top, p.y)
			bottom = maxf(bottom, p.y)
		for y in range(maxi(int(ceil(top)), 0), mini(int(bottom) + 1, h)):
			var span := CalibLines._row_span(quad, float(y))
			for x in range(maxi(int(ceil(span.x)), 0), mini(int(span.y) + 1, w)):
				data[y * w + x] = value
	var img := Image.create_from_data(w, h, false, Image.FORMAT_L8, data)
	img.shrink_x2()
	return img


## The rig's room. On the wall: a picture rail above the throw, three short
## shelves beside it and a low shelf under it (`shelves`). On the wall that
## meets it at the left and comes towards the camera: a door (`door`). And what
## must NOT be read as level: a standing lamp, a picture hung 14 degrees
## crooked.
func _furnish(rig: Dictionary, shelves: bool, door: bool) -> Array:
	var things: Array = []
	if shelves:
		things.append([_wall_quad(rig, -1.85, -0.93, 1.5, -0.9), 70])
		for v: float in [-0.62, -0.22, 0.2]:
			things.append([_wall_quad(rig, -1.78, v, -1.2, v + 0.05), 50])
		things.append([_wall_quad(rig, -1.8, 0.84, 1.0, 0.89), 50])
	if door:
		things.append([_side_quad(rig, -1.9, 0.15, -0.5, 0.75, 1.3), 120])
		things.append([_side_quad(rig, -1.9, 0.1, -0.85, 0.8, -0.8), 60])   # a shelf over it
	things.append([_wall_quad(rig, 1.3, -0.7, 1.34, 0.9), 80])
	things.append([_wall_quad(rig, -1.72, 0.45, -1.38, 0.69, 14.0), 110])
	return things


## How far CalibLines' level lines are from the rig's true level direction,
## in degrees — as the wall's own axis, so it is the error that matters.
func _level_error(rig: Dictionary, level: PackedVector2Array) -> float:
	var wall := CalibWall.solve(level, PackedVector2Array(), rig["d"], CAM, FOCAL)
	if wall == null:
		return INF
	return rad_to_deg(acos(clampf(absf(wall.right.dot(rig["r"])), 0.0, 1.0)))


func _check_lines() -> void:
	var rig := _wall_rig(24.0, 6.0, 2.0)
	var o2c: CalibHomography = rig["o2c"]
	var frame := PackedVector2Array()
	for c in _rect_corners(Rect2(Vector2.ZERO, OUT)):
		frame.append(o2c.apply(c))
	var down: Vector3 = rig["d"]

	# The wall's own edges.
	var room := _room(_furnish(rig, true, true))
	var t0 := Time.get_ticks_msec()
	var res := CalibLines.find(room, down, FOCAL, CAM * 0.5, frame)
	var ms := Time.get_ticks_msec() - t0
	var err := _level_error(rig, res["level"]) if res["ok"] else INF
	_ok(res["ok"] and not res["synthesized"] and int(res["found"]) >= 3 and err < 0.15,
		"shelves beside the picture: the wall's level direction, from its own edges",
		"%d edges, %.3f deg off, %d ms" % [int(res["found"]), err, ms])
	if res["ok"]:
		var level: PackedVector2Array = res["level"]
		var in_shot := true
		for p in level:
			if not Rect2(Vector2.ZERO, CAM).has_point(p):
				in_shot = false
		_ok(in_shot and level.size() == 4, "…handed back as two lines inside the picture, as four taps would be", "%s" % [level])
		# The keystone that follows, against the one from exact taps.
		var exact := CalibWall.solve(_wall_taps(rig, 0.0).slice(0, 4), PackedVector2Array(), down, CAM, FOCAL)
		var found := CalibWall.solve(level, PackedVector2Array(), down, CAM, FOCAL)
		var worst := INF
		if exact != null and found != null:
			var a := CalibEditor.surface_to_corners(o2c.inverse(), exact.surface(o2c, OUT))
			var b := CalibEditor.surface_to_corners(o2c.inverse(), found.surface(o2c, OUT))
			if a.size() == 4 and b.size() == 4:
				worst = 0.0
				for i in 4:
					worst = maxf(worst, a[i].distance_to(b[i]))
		_ok(worst < 4.0, "…and the keystone from them is the one exact taps give", "worst corner %.2f output px apart" % worst)

	# A gravity reading half a degree out.
	var tipped := down.rotated(Vector3(0, 0, 1), deg_to_rad(0.35)).rotated(Vector3(1, 0, 0), deg_to_rad(-0.35))
	res = CalibLines.find(room, tipped, FOCAL, CAM * 0.5, frame)
	err = _level_error(rig, res["level"]) if res["ok"] else INF
	_ok(res["ok"] and err < 0.4, "the same room, gravity half a degree out", "%.3f deg off" % err)

	# A bare wall: only the door on the NEXT wall (and the lamp) to go by.
	res = CalibLines.find(_room(_furnish(rig, false, true)), down, FOCAL, CAM * 0.5, frame)
	err = _level_error(rig, res["level"]) if res["ok"] else INF
	_ok(res["ok"] and res["synthesized"] and int(res["found"]) == 0 and err < 0.3,
		"a bare wall: level from the door on the wall next to it", "%.3f deg off" % err)

	# Nothing but a lamp and a crooked picture: no answer, rather than theirs.
	res = CalibLines.find(_room(_furnish(rig, false, false)), down, FOCAL, CAM * 0.5, frame)
	_ok(not res["ok"], "a lamp and a crooked picture are not taken for level", str(res["reason"]))
	# …nor one board by itself (its two edges), which may be the one thing hung crooked.
	var lone: Array = [[_wall_quad(rig, -1.7, -0.92, 0.9, -0.87, 3.0), 50]]
	res = CalibLines.find(_room(lone), down, FOCAL, CAM * 0.5, PackedVector2Array())
	_ok(not res["ok"] and str(res["reason"]).contains("NOT ENOUGH"), "one board is not a room -> refused", str(res["reason"]))

	# An empty picture, and no gravity.
	res = CalibLines.find(_room([]), down, FOCAL, CAM * 0.5, frame)
	_ok(not res["ok"] and str(res["reason"]).contains("NO LEVEL EDGES"), "an empty picture -> refused", str(res["reason"]))
	res = CalibLines.find(room, Vector3.ZERO, FOCAL, CAM * 0.5, frame)
	_ok(not res["ok"] and str(res["reason"]).contains("GRAVITY"), "no gravity reading -> refused", str(res["reason"]))

	# The projection's own inside is not the room: shelves "inside the picture"
	# (a pattern, a previous frame) must not be read.
	var all := PackedVector2Array([Vector2.ZERO, Vector2(CAM.x, 0), CAM, Vector2(0, CAM.y)])
	res = CalibLines.find(room, down, FOCAL, CAM * 0.5, all)
	_ok(not res["ok"], "edges inside the projection are ignored", str(res["reason"]))


func _await_idle(ed: CalibEditor) -> void:
	for i in 200:
		await process_frame
		if not ed._busy:
			return


## The editor's WALL: one press with a room to read, the flip back, LINES, and
## the taps when there is nothing to read.
func _check_wall_step() -> void:
	var rig := _wall_rig(24.0, 6.0, 2.0)
	var o2c: CalibHomography = rig["o2c"]
	var taps := _wall_taps(rig, 0.0)
	var exact := CalibWall.solve(taps.slice(0, 4), taps.slice(4, 8), Vector3.ZERO, CAM, FOCAL)
	var want := CalibEditor.surface_to_corners(o2c.inverse(), exact.surface(o2c, OUT))
	var quad := QuadWarp.new()
	root.add_child(quad)
	quad.fill_rect(OUT)
	var ed := CalibEditor.new()
	root.add_child(ed)
	ed.setup(quad)
	ed.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ed.size = Vector2(1454, 648)
	ed.output_size_provider = func() -> Vector2: return OUT
	ed.focal_px = FOCAL
	var held := {"g": rig["d"], "img": _room(_furnish(rig, true, true))}
	ed.gravity_provider = func() -> Vector3: return held["g"]
	ed.frame_provider = func() -> Image:
		var rgba: Image = held["img"].duplicate()
		rgba.convert(Image.FORMAT_RGBA8)
		return rgba
	ed.set_active(true)
	ed._shot_pressed()   # FREEZE — this is when gravity is read
	held["g"] = Vector3(0.6, 0.5, 0.62)   # …and the phone is turned in the hand afterwards
	for m in CalibPattern.marker_points(OUT):
		_tap(ed, o2c.apply(m))

	# Arriving at SURFACE it looks for the wall's square unasked.
	ed._next_pressed()
	_ok(ed.step == CalibEditor.Step.MARKERS and ed._busy and ed._hint.text.contains("LOOKING FOR LEVEL LINES"),
		"on the way to SURFACE it says it is looking for level lines (the pattern is still up)")
	await _await_idle(ed)
	var worst := 0.0
	for i in 4:
		worst = maxf(worst, quad.corners[i].distance_to(want[i]))
	_ok(ed.step == CalibEditor.Step.SURFACE and ed._wall_true and worst < 4.0,
		"…and lands on the wall's square: level found in the picture, plumb from gravity as it was at FREEZE",
		"worst %.2f output px from exact taps" % worst)
	_ok(ed._hint.text.contains("SQUARE ON THE WALL") and ed._hint.text.contains("LEVEL EDGES")
		and ed._hint.text.contains("SKEWED FROM THE SIDE") and ed._btn_auto.text == "FROM HERE" and ed._btn_next.text == "LINES",
		"SURFACE says it is the wall's square, what it rests on, and how it will look from the side", ed._hint.text)
	var on_wall := quad.corners.duplicate()

	# The flip, both ways.
	var here := CalibEditor.surface_to_corners(o2c.inverse(), CalibEditor.auto_surface(o2c, OUT))
	ed._auto_pressed()
	worst = 0.0
	for i in 4:
		worst = maxf(worst, quad.corners[i].distance_to(here[i]))
	_ok(worst < 0.1 and not ed._wall_true and ed._btn_auto.text == "WALL" and ed._btn_next.text == "MARKERS"
		and ed._hint.text.contains("AS SEEN FROM THE PHONE — WALL SQUARES IT"), "FROM HERE flips to the phone's square, and says so", ed._hint.text)
	ed._auto_pressed()
	_ok(not ed._busy and quad.corners == on_wall and ed._wall_true, "WALL flips back at once: the lines are already in hand")

	# LINES: what it rests on, open for fixing.
	ed._next_pressed()
	_ok(ed.step == CalibEditor.Step.WALL and ed._wall.size() == 4 and ed._hint.text.contains("LEVEL LINES IT FOUND")
		and not ed._btn_next.disabled and quad.corners == on_wall,
		"LINES opens the two level lines it found, nothing moved", ed._hint.text)
	ed._auto_pressed()   # BACK
	_ok(ed.step == CalibEditor.Step.SURFACE and quad.corners == on_wall and ed._wall_true, "BACK leaves the wall's square on")
	# …and with two vertical edges tapped after them, plumb comes from the taps.
	ed._next_pressed()
	for i in range(4, 7):
		_tap(ed, taps[i])
	var s := ed._to_screen(taps[7])
	ed._press(0, s + Vector2(40, 0))
	_ok(ed.step == CalibEditor.Step.WALL, "the eighth point waits for the finger to lift")
	ed._drag(0, s)
	ed._release(0)
	worst = 0.0
	for i in 4:
		worst = maxf(worst, quad.corners[i].distance_to(want[i]))
	_ok(ed.step == CalibEditor.Step.SURFACE and ed._wall_true and worst < 4.0 and ed._hint.text.contains("YOUR LINES"),
		"two vertical edges tapped after the found lines: plumb from the taps", "worst %.2f output px from exact taps" % worst)
	_drop([ed, quad])

	# A picture with nothing to read: WALL lands in the taps and says why.
	quad = QuadWarp.new()
	root.add_child(quad)
	quad.fill_rect(OUT)
	ed = CalibEditor.new()
	root.add_child(ed)
	ed.setup(quad)
	ed.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ed.size = Vector2(1454, 648)
	ed.output_size_provider = func() -> Vector2: return OUT
	ed.focal_px = FOCAL
	held = {"g": rig["d"]}
	ed.gravity_provider = func() -> Vector3: return held["g"]
	var blank := Image.create(int(CAM.x), int(CAM.y), false, Image.FORMAT_RGBA8)
	blank.fill(Color(0.2, 0.2, 0.2, 1.0))
	ed.frame_provider = func() -> Image: return blank
	ed.set_active(true)
	ed._shot_pressed()
	for m in CalibPattern.marker_points(OUT):
		_tap(ed, o2c.apply(m))
	ed._next_pressed()
	await _await_idle(ed)
	var squared := quad.corners.duplicate()
	_ok(ed.step == CalibEditor.Step.SURFACE and not ed._wall_true and ed._btn_auto.text == "WALL"
		and ed._hint.text.contains("AS SEEN FROM THE PHONE ONLY") and ed._hint.text.contains("NO LEVEL EDGES"),
		"nothing to read: SURFACE keeps the phone's square and says the wall's could not be found", ed._hint.text)
	ed._auto_pressed()
	_ok(not ed._busy and ed.step == CalibEditor.Step.WALL and ed._btn_next.text == "SENSOR" and ed._btn_next.disabled
		and ed._btn_auto.text == "BACK" and ed._hint.text.contains("NO LEVEL EDGES") and ed._hint.text.contains("LEVEL 1 OF 2"),
		"…and WALL then opens the taps at once, says why, and asks for the first level line", ed._hint.text)
	for i in 4:
		_tap(ed, taps[i])
	_ok(not ed._btn_next.disabled and quad.corners == squared and ed._hint.text.contains("SENSOR"),
		"two level lines in: SENSOR is offered, nothing has moved yet", ed._hint.text)
	ed._undo_pressed()
	_ok(ed._wall.size() == 3 and ed._btn_next.disabled, "UNDO takes a tap back, and SENSOR with it")
	_tap(ed, taps[3])
	ed._next_pressed()   # SENSOR
	worst = 0.0
	for i in 4:
		worst = maxf(worst, quad.corners[i].distance_to(want[i]))
	_ok(ed.step == CalibEditor.Step.SURFACE and ed._hint.text.contains("SQUARE ON THE WALL · YOUR LINES") and worst < 0.5,
		"tapped level lines + SENSOR square the picture on the wall", "worst %.3f output px from exact taps" % worst)
	var res := _on_wall(rig, ed._surface)
	_ok(res["lean"] < 0.05, "…and it is level and plumb there", "worst side %.4f deg off" % res["lean"])

	# A line that starts a finger's width from where another ends, and lines
	# that make no wall.
	var kept := quad.corners.duplicate()
	ed._next_pressed()   # LINES
	for i in 4:
		ed._undo_pressed()
	_tap(ed, taps[0])
	for i in range(4, 8):
		_tap(ed, taps[i])
	_ok(ed._wall.size() == 5 and ed._to_screen(taps[4]).distance_to(ed._to_screen(taps[0])) < CalibEditor.GRAB_RADIUS,
		"a line that starts close to another line's end is a new point, not a drag of the old one",
		"%.0f logical px apart" % ed._to_screen(taps[4]).distance_to(ed._to_screen(taps[0])))
	for i in 5:
		ed._undo_pressed()
	for i in range(4, 8):
		_tap(ed, taps[i])
	for i: int in [4, 6]:   # …the same two vertical edges again as "plumb", tapped elsewhere along them
		_tap(ed, taps[i].lerp(taps[i + 1], 0.27))
		_tap(ed, taps[i].lerp(taps[i + 1], 0.73))
	_ok(ed.step == CalibEditor.Step.WALL and quad.corners == kept and ed._hint.text.contains("DO NOT GIVE"),
		"plumb lines tapped as level are refused, and say so", ed._hint.text)
	ed._auto_pressed()   # BACK
	_ok(ed.step == CalibEditor.Step.SURFACE and quad.corners == kept, "BACK leaves the keystone as it was")

	# No gravity reading: straight to the taps, SENSOR off.
	ed._shot_pressed()   # RETAKE -> LIVE
	ed.gravity_provider = func() -> Vector3: return Vector3.ZERO
	ed._shot_pressed()   # FREEZE
	for m in CalibPattern.marker_points(OUT):
		_tap(ed, o2c.apply(m))
	ed._next_pressed()
	_ok(not ed._busy and ed.step == CalibEditor.Step.SURFACE and ed._hint.text.contains("NO GRAVITY READING"),
		"without a gravity reading SURFACE arrives on the phone's square, and says why", ed._hint.text)
	ed._auto_pressed()
	_ok(not ed._busy and ed.step == CalibEditor.Step.WALL and ed._hint.text.contains("NO GRAVITY READING"),
		"…and WALL goes straight to the taps", ed._hint.text)
	for i in 4:
		_tap(ed, taps[i])
	_ok(ed._btn_next.disabled and not ed._hint.text.contains("SENSOR"),
		"…SENSOR stays off and the hint asks for plumb lines", ed._hint.text)
	ed._esc_pressed()
	_drop([ed, quad])
