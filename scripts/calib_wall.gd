class_name CalibWall
extends RefCounted
## Where the WALL is, as the camera sees it — so a picture can be made square
## on the wall itself, not merely square from where the phone stands.
##
## WHY THIS EXISTS. CalibEditor.auto_surface() squares the picture up as the
## camera sees it, and the camera is on the HDMI cable: beside the projector,
## where every projection looks rectangular. On the wall run that prompted this
## (2026-09-30, CAMERA_PROCEDURAL_MASKS_SPEC.md §1b) the camera saw the raw
## frame's sides as 511 vs 481 px while on the wall they differed by 27%.
## tools/walltrue_spike.gd proved the fix by hand; this is that maths as a
## class.
##
## THE IDEA. Lines that are LEVEL on the wall are parallel in the world, so in
## the picture they meet at one vanishing point; so do lines that are PLUMB.
## Those two directions are the wall's own axes as seen from the camera. With
## them the frozen frame can be un-projected onto the wall in true proportions
## (to_wall), a rectangle chosen there, and brought back (to_cam).
##
##  - LEVEL comes from two lines on the wall: shelf edges, a skirting board,
##    the ceiling line.
##  - PLUMB comes from two vertical lines anywhere in the room, or from the
##    phone's gravity sensor — a plumb line is plumb on every wall.
##
## WHAT THE FOCAL LENGTH DOES AND DOES NOT DO. It is an estimate (no camera API
## here reports it). With both directions TAPPED, the result's sides run through
## the two vanishing points whatever the focal length is, so it is a rectangle
## with level and plumb sides regardless, and the focal length only sets its
## PROPORTIONS (on the wall run, +-12% of focal moved the width by about +-2%).
## That is why wall coordinates here run along the two measured directions even
## when the estimate makes them come out not quite square to each other
## (`skew_deg`), instead of being squared up first.
##
## GRAVITY IS THE WEAKER MEASUREMENT, and is used for less. A phone's gravity
## reading is good to about half a degree, and the lens is not exactly square
## to the sensor that produces it. Level (tapped on the wall itself) already
## says which way the wall's horizontal runs; the only thing it cannot say is
## how the wall tips about that line, and that one number is all gravity is
## asked for: its reading is squared up against level first. On the verifier's
## rig a sensor 0.5 deg out then leans the worst side 0.3 deg instead of 0.5.
## The price is that the focal length matters again on this route — +12% leans
## the worst side 0.5 deg with the phone tipped 6 deg (0.2 unsquared) — which
## is the argument for feeding `focal_px` from the camera's real intrinsics.
## Tapped plumb lines that bracket the picture remain the accurate route.
##
## ⚠️ LINES MUST BRACKET THE PICTURE. Two plumb lines close together on one
## side of it leave the far side leaning (0.8 deg on the wall run, which the
## operator saw at once). The taps cannot enforce that; the hint asks for it.
##
## Works in normalized camera coordinates — (x - cx) / f, (y - cy) / f, 1 — so
## a line through two picture points is the plane through the camera that
## contains it, and the direction shared by two such planes is simply the
## cross product of their normals.

## No camera API here gives intrinsics, so: horizontal field of view ~69 deg,
## the usual main camera of a phone. focal = width * this.
const FOCAL_PER_WIDTH := 0.722
## Level and plumb must come out within this of a right angle, or the lines
## were not what they were tapped as.
const MAX_SKEW_DEG := 20.0
## A wall seen closer to edge-on than this cannot be un-projected usefully.
const MIN_FACING := 0.15

var focal: float = 1386.0
var centre: Vector2 = Vector2(960, 540)
## The wall's level and plumb directions and its normal, in camera space, unit
## length. `right` and `down` lie in the wall; `normal` points away from the
## camera. With tapped plumb lines `right` and `down` are as measured and need
## not be exactly square to each other — see `skew_deg`.
var right: Vector3 = Vector3.RIGHT
var down: Vector3 = Vector3.UP
var normal: Vector3 = Vector3.BACK
## How far from a right angle the two directions came out, as measured (before
## a gravity reading is squared up). Zero with the true focal length and
## perfect lines; a large number means a line was not what it was tapped as.
var skew_deg: float = 0.0


## `level`: two points per LEVEL line on the wall, at least two lines.
## `plumb`: two points per PLUMB line, at least two lines — or empty, and then
##          `gravity` (camera space: x right, y down, z into the scene) is used.
## Null when the lines do not describe a usable wall.
static func solve(level: PackedVector2Array, plumb: PackedVector2Array, gravity: Vector3,
		cam_size: Vector2, focal_px: float = 0.0) -> CalibWall:
	var w := CalibWall.new()
	w.centre = cam_size * 0.5
	w.focal = focal_for(cam_size, focal_px)
	var dh := w._direction(level)
	var dv := w._direction(plumb) if plumb.size() >= 4 else gravity
	if dh.length() < 1e-9 or dv.length() < 1e-9:
		return null
	dh = dh.normalized()
	dv = dv.normalized()
	w.skew_deg = absf(90.0 - rad_to_deg(acos(clampf(absf(dh.dot(dv)), 0.0, 1.0))))
	if w.skew_deg > MAX_SKEW_DEG:
		return null
	if plumb.size() < 4:
		# Gravity: keep only what level cannot say (see the header).
		dv = (dv - dh * dv.dot(dh)).normalized()
	var n := dh.cross(dv).normalized()
	if n.z < 0.0:
		n = -n
	if n.z < MIN_FACING:
		return null
	w.normal = n
	w.right = dh
	w.down = dv
	return w


## The focal length in px to work with: the one given, or the estimate. From
## the frame's LONG side: a camera frame that arrives rotated is the same lens.
static func focal_for(cam_size: Vector2, focal_px: float = 0.0) -> float:
	return focal_px if focal_px > 0.0 else maxf(cam_size.x, cam_size.y) * FOCAL_PER_WIDTH


## Flip the axes so that "right" and "down" on the wall run the way the
## projector's own frame does. `frame_cam` is that frame in camera px,
## TL TR BR BL. (A direction has no sign until something says which end is
## which; the frame is what the picture has to match.)
func orient(frame_cam: PackedVector2Array) -> void:
	if frame_cam.size() != 4:
		return
	var q := PackedVector2Array()
	for p in frame_cam:
		q.append(to_wall(p))
	if ((q[1] - q[0]) + (q[2] - q[3])).x < 0.0:
		right = -right
	if ((q[3] - q[0]) + (q[2] - q[1])).y < 0.0:
		down = -down


## Camera px -> wall coordinates: how far along `right` and along `down` (an
## arbitrary unit; true proportions). Lines that are level on the wall have a
## constant y here and plumb lines a constant x — exactly, by construction.
func to_wall(p: Vector2) -> Vector2:
	var r := Vector3((p.x - centre.x) / focal, (p.y - centre.y) / focal, 1.0)
	var d := normal.dot(r)
	if absf(d) < 1e-9:
		return Vector2.INF
	var x3 := r / d
	# `right` and `down` need not be square to each other, so read the point
	# off against both at once (the dual basis) rather than one at a time.
	var xu := x3.dot(right)
	var xv := x3.dot(down)
	var k := right.dot(down)
	var det := 1.0 - k * k
	if det < 1e-6:
		return Vector2.INF
	return Vector2((xu - k * xv) / det, (xv - k * xu) / det)


## Wall coordinates -> camera px.
func to_cam(w: Vector2) -> Vector2:
	var x3 := right * w.x + down * w.y + normal
	if absf(x3.z) < 1e-9:
		return Vector2.INF
	return Vector2(centre.x + focal * x3.x / x3.z, centre.y + focal * x3.y / x3.z)


## The largest LEVEL rectangle with the output's aspect that the projector can
## reach, found on the wall. Camera px, TL TR BR BL — what CalibEditor takes as
## its surface corners. Empty when nothing fits.
func surface(out_to_cam: CalibHomography, out_size: Vector2) -> PackedVector2Array:
	var none := PackedVector2Array()
	if out_to_cam == null or out_size.x <= 0.0 or out_size.y <= 0.0:
		return none
	var frame := PackedVector2Array()
	for c: Vector2 in [Vector2.ZERO, Vector2(out_size.x, 0), out_size, Vector2(0, out_size.y)]:
		var p := out_to_cam.apply(c)
		if not p.is_finite():
			return none
		frame.append(p)
	orient(frame)
	var quad := PackedVector2Array()
	for p in frame:
		var q := to_wall(p)
		if not q.is_finite():
			return none
		quad.append(q)
	var rect := CalibEditor.inscribed_rect(quad, Vector2(1, 0), Vector2(0, 1), out_size.x / out_size.y)
	var out := PackedVector2Array()
	for q in rect:
		var p := to_cam(q)
		if not p.is_finite():
			return none
		out.append(p)
	return out


## How much taller the projector's frame is on one side of the wall than the
## other (always >= 1) — the keystone a viewer in front of the wall sees, and
## the number that says whether this step was worth taking.
func keystone(out_to_cam: CalibHomography, out_size: Vector2) -> float:
	var q := PackedVector2Array()
	for c: Vector2 in [Vector2.ZERO, Vector2(out_size.x, 0), out_size, Vector2(0, out_size.y)]:
		q.append(to_wall(out_to_cam.apply(c)))
	var l := q[0].distance_to(q[3])
	var r := q[1].distance_to(q[2])
	var t := q[0].distance_to(q[1])
	var b := q[3].distance_to(q[2])
	if minf(minf(l, r), minf(t, b)) < 1e-9:
		return 1.0
	return maxf(maxf(l / r, r / l), maxf(t / b, b / t))


## The 3D direction shared by the lines in `pts` (two points per line), in
## camera space; ZERO when there are fewer than two lines or they coincide.
## With more than two lines the pairwise answers are averaged, each weighted
## by how well-separated its pair is (the cross product's own length).
func _direction(pts: PackedVector2Array) -> Vector3:
	var planes: Array[Vector3] = []
	for i in range(0, pts.size() - 1, 2):
		var a := Vector3((pts[i].x - centre.x) / focal, (pts[i].y - centre.y) / focal, 1.0)
		var b := Vector3((pts[i + 1].x - centre.x) / focal, (pts[i + 1].y - centre.y) / focal, 1.0)
		var m := a.cross(b)
		if m.length() > 1e-12:
			planes.append(m.normalized())
	if planes.size() < 2:
		return Vector3.ZERO
	var acc := Vector3.ZERO
	for i in planes.size():
		for j in i:
			var d := planes[i].cross(planes[j])
			if acc.dot(d) < 0.0:
				d = -d
			acc += d
	return acc
