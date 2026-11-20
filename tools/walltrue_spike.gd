extends SceneTree
## SPIKE — "square on the WALL", not "square as the phone sees it".
##
##   godot --headless --path <project> --script tools/walltrue_spike.gd -- <cfg>
##   (tools/walltrue_spike.cfg is the 2026-09-30 wall run it was written for)
##
## WHY. CalibEditor.auto_surface() squares the picture up FROM WHERE THE PHONE
## IS, and the phone is on the HDMI cable — beside the projector, where every
## projection looks rectangular. On the run in the .cfg the camera saw the raw
## frame's sides as 511 vs 481 px (no keystone) while the wall had 27%.
##
## HOW. Two or more LEVEL lines on the wall meet at its horizontal vanishing
## point; two or more PLUMB lines anywhere meet at the vertical one. Those two
## points fix the wall's orientation to the camera, so the frozen frame can be
## un-projected onto the wall. The largest level 16:9 rectangle inside what the
## projector reaches is found THERE (CalibEditor.inscribed_rect) and brought
## back through the calibration to warp corners.
##
## WHAT IT SHOWED (the user judged both on the wall):
##  - "A lot better" than the as-seen-from-phone result.
##  - The vanishing points alone make it a true rectangle; the focal length
##    (an estimate, ~1386 px for the Pixel 8 main camera at 1080p) only moves
##    its proportions: +-12% focal is about +-2% of the width.
##  - ⚠️ THE PLUMB LINES MUST BRACKET THE PICTURE. The first pass took plumb
##    from two door-frame edges 300 px apart on one side (one of them a
##    moulding, not an edge) and left a 0.8 deg lean on the far side — "still a
##    bit skewed". Refitting with a line on the other side too (least squares:
##    vx - b*vy = a for each x = a + b*y) fixed it; that point is `vv` in the
##    cfg. `plumb` in the cfg is the bad pair, kept so the difference can be
##    re-run (delete the `vv` line).
##  - Self-calibrating the focal from the two vanishing points does not work
##    when the camera is level: the plumb point is at infinity and the formula
##    divides noise by noise.
##
## NOT IN THE APP. The lines were measured off the dumped frame by hand (a
## sub-pixel gradient fit along each edge, 0.1 px rms on the shelf boards).
## Building this in means giving the app those lines: taps, a reference
## rectangle, or the gravity sensor for plumb.
##
## cfg: [in] markers=PackedVector2Array(4 camera px, pattern order)
##           level=PackedVector2Array(p,q, p,q, …)  two points per LEVEL line on the wall
##           plumb=PackedVector2Array(p,q, p,q, …)  two points per PLUMB line anywhere
##           vv=Vector2(…)            optional: the plumb vanishing point, if fitted elsewhere
##           focals=PackedFloat32Array(…)   focal lengths to try, px
##           cam=Vector2(1920,1080)  out=Vector2(1920,1080)

func _cross3(a: Vector3, b: Vector3) -> Vector3:
	return a.cross(b)


func _line(p: Vector2, q: Vector2) -> Vector3:
	return Vector3(p.x, p.y, 1.0).cross(Vector3(q.x, q.y, 1.0))


## Least-squares meeting point of several lines (homogeneous), via the two
## most separated when there are only two.
func _vanish(pts: PackedVector2Array) -> Vector3:
	var lines: Array[Vector3] = []
	for i in range(0, pts.size() - 1, 2):
		lines.append(_line(pts[i], pts[i + 1]).normalized())
	if lines.size() == 2:
		return lines[0].cross(lines[1])
	# Smallest eigenvector of sum(l l^T) by power iteration on the inverse is
	# overkill for a spike: average the pairwise intersections instead.
	var acc := Vector3.ZERO
	var n := 0
	for i in lines.size():
		for j in i:
			var v := lines[i].cross(lines[j])
			if absf(v.z) > 1e-12:
				v /= v.z
				acc += v
				n += 1
	return acc / float(maxi(n, 1))


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var cfg := ConfigFile.new()
	if args.is_empty() or cfg.load(args[0]) != OK:
		printerr("cannot read cfg")
		quit(2)
		return
	var markers: PackedVector2Array = cfg.get_value("in", "markers")
	var level: PackedVector2Array = cfg.get_value("in", "level")
	var plumb: PackedVector2Array = cfg.get_value("in", "plumb")
	var cam: Vector2 = cfg.get_value("in", "cam", Vector2(1920, 1080))
	var out: Vector2 = cfg.get_value("in", "out", Vector2(1920, 1080))
	var c := cam * 0.5

	var cam_to_out := CalibHomography.solve(markers, CalibPattern.marker_points(out))
	var out_to_cam := cam_to_out.inverse()
	var frame := PackedVector2Array()
	for p: Vector2 in [Vector2.ZERO, Vector2(out.x, 0), out, Vector2(0, out.y)]:
		frame.append(out_to_cam.apply(p))
	print("projector frame in camera: %s" % [frame])
	print("as-seen-from-phone corners: %s" % [CalibEditor.surface_to_corners(cam_to_out, CalibEditor.auto_surface(out_to_cam, out))])

	var vh := _vanish(level)
	var vv := _vanish(plumb)
	if cfg.has_section_key("in", "vv"):   # a least-squares plumb point worked out elsewhere
		var given: Vector2 = cfg.get_value("in", "vv")
		vv = Vector3(given.x, given.y, 1.0)
	var vh2 := Vector2(vh.x / vh.z, vh.y / vh.z) if absf(vh.z) > 1e-12 else Vector2.INF
	var vv2 := Vector2(vv.x / vv.z, vv.y / vv.z) if absf(vv.z) > 1e-12 else Vector2.INF
	print("vanishing points: level %s  plumb %s" % [vh2, vv2])
	# Orthogonal directions: (vh - c).(vv - c) + f^2 = 0
	var f2 := -(vh2 - c).dot(vv2 - c) if vh2.is_finite() and vv2.is_finite() else -1.0
	var f_self := sqrt(f2) if f2 > 0.0 else 0.0
	print("self-calibrated focal: %.0f px (hfov %.1f deg)" % [f_self, rad_to_deg(2.0 * atan(c.x / maxf(f_self, 1.0)))])

	var focals: Array[float] = []
	for v: float in cfg.get_value("in", "focals", PackedFloat32Array([1386.0])):
		focals.append(v)
	if f_self > 600.0 and f_self < 4000.0:
		focals.push_front(f_self)
	for f in focals:
		# K^-1 of a homogeneous image point.
		var dh := Vector3((vh.x - c.x * vh.z) / f, (vh.y - c.y * vh.z) / f, vh.z).normalized()
		var dv := Vector3((vv.x - c.x * vv.z) / f, (vv.y - c.y * vv.z) / f, vv.z).normalized()
		# Signs: "right" and "down" as the frame's own edges run in the image.
		var right := Vector3(frame[1].x - frame[0].x, frame[1].y - frame[0].y, 0.0)
		var down := Vector3(frame[3].x - frame[0].x, frame[3].y - frame[0].y, 0.0)
		if dh.dot(right) < 0.0:
			dh = -dh
		if dv.dot(down) < 0.0:
			dv = -dv
		var n := dh.cross(dv).normalized()
		dv = n.cross(dh).normalized()   # exactly orthogonal; level is trusted over plumb
		if n.z < 0.0:
			n = -n
		var wall := PackedVector2Array()
		for p in frame:
			var r := Vector3((p.x - c.x) / f, (p.y - c.y) / f, 1.0)
			var x3 := r / n.dot(r)
			wall.append(Vector2(x3.dot(dh), x3.dot(dv)))
		var top := wall[0].distance_to(wall[1])
		var bottom := wall[3].distance_to(wall[2])
		var left := wall[0].distance_to(wall[3])
		var rightl := wall[1].distance_to(wall[2])
		print("f=%.0f  angle(level,plumb before fix)=%.1f deg  frame ON THE WALL: top %.3f bottom %.3f left %.3f right %.3f  (top/bottom %.2f, left/right %.2f)"
			% [f, rad_to_deg(acos(clampf(absf(dh.dot((Vector3((vv.x - c.x * vv.z) / f, (vv.y - c.y * vv.z) / f, vv.z)).normalized())), 0.0, 1.0))),
				top, bottom, left, rightl, top / bottom, left / rightl])
		var rect := CalibEditor.inscribed_rect(wall, Vector2(1, 0), Vector2(0, 1), out.x / out.y)
		if rect.size() != 4:
			print("   no rectangle fits")
			continue
		var cam_pts := PackedVector2Array()
		for w in rect:
			# The wall point: along dh and dv, at distance 1/|n| along the normal.
			var x3 := dh * w.x + dv * w.y + n
			cam_pts.append(Vector2(f * x3.x / x3.z + c.x, f * x3.y / x3.z + c.y))
		var corners := CalibEditor.surface_to_corners(cam_to_out, cam_pts)
		print("   wall-true rect in camera: %s" % [cam_pts])
		print("   WALL-TRUE warp corners:   %s" % [corners])
		var norm := PackedVector2Array()
		for q in corners:
			norm.append(q / out)
		print("   normalized: %s" % [norm])
	quit(0)
