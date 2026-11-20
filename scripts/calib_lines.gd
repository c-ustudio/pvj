class_name CalibLines
extends RefCounted
## Find the wall's LEVEL direction in a camera frame by itself — so CalibEditor's
## WALL step is one press instead of four careful taps.
##
## WHY THIS EXISTS. On the first wall run of the WALL step (2026-09-30,
## CAMERA_PROCEDURAL_MASKS_SPEC.md §1c) the operator did not get on with
## tapping "two lines that are level on the wall" at all, and every good result
## of that day came from edges fitted in the dumped frame on a desk and tapped
## in over adb. The edges were there in the picture the whole time: three
## shelves, each good to a tenth of a pixel. This is that desk work, in the app.
##
## HOW.
##  1. SEGMENTS. Find the picture's long straight edges — all of them, whatever
##     they are: a coarse search for lines many edge pixels lie on (a Hough
##     transform), then each candidate re-measured at full resolution, where
##     it has to PROVE it is an edge: a brightness step tracked along it, a
##     straight line through those to under a pixel, there for most of its own
##     length, and long. A shelf edge passes; a row of book spines, a keyboard
##     and a chair's mesh do not.
##  2. DIRECTIONS. Gravity is known (the phone's sensor, read when the frame
##     froze), so each segment, IF it is level, runs in one particular compass
##     direction: the plane through the camera and the segment, cut by the
##     horizontal. Verticals, and segments lying along the horizon (where
##     every direction looks the same), say nothing and are left out.
##  3. THE ROOM'S GRID. Rooms are square: walls meet at right angles, so the
##     level edges of a room point in two directions 90 degrees apart. The
##     segments' directions, folded onto a quarter turn, pile up at the grid;
##     what does not belong to it (a picture hung crooked) is left behind.
##  4. WHICH WALL. Of the grid's two directions, the projection wall's is the
##     one the camera faces more squarely. (The phone is pointed at the picture.)
##  5. THE ANSWER. The wall's own segments vote on exactly where they meet,
##     gravity has its say, and two level LINES come back — four points,
##     exactly what four taps would have been — so the rest of the WALL step is
##     unchanged and the operator can look at them, drag them, or tap others.
##     With nothing usable on the wall itself (a bare wall, but a door on the
##     wall next to it) two lines are drawn in the direction the rest of the
##     room implies.
##
## ⚠️ SEGMENTS FIRST, and proven one at a time. Two earlier versions tried to
## find the direction straight from edge PIXELS, and both are why this file is
## shaped as it is:
##   - a vote per pixel (which way does your own edge point?) came out 7 and 9
##     degrees wrong on real frames: one pixel's edge direction is good to a
##     few degrees, and turning it into a compass bearing multiplies that;
##   - scoring each candidate direction by how well the pixels line up along
##     its lines got two real frames right and the third 55 degrees wrong. A
##     lived-in room is full of edge pixels; they line up well enough along
##     ANY direction, and the score barely moved (750 against a median of 620).
## A handful of segments that have each been measured to a tenth of a pixel is
## a different kind of evidence from thousands of pixels that might be anything.
##
## WHAT IT CANNOT DO. A dark room has no edges. A room that is not square to
## itself, or a wall seen at close to 45 degrees (`ambiguous`), can pick the
## neighbouring wall's direction. The lines are drawn on the frozen frame for
## that reason: a line that visibly does not run along the shelves is wrong,
## and the taps are still there.
##
## Pure image maths: no camera, no timing, no scene.

const SHRINKS := 2              ## the coarse search runs at 1/4 size, box-averaged
const EDGE_MIN := 18            ## coarse gradient (levels across 2 px) that counts as an edge
const MAX_EDGES := 9000         ## edge pixels that vote; more are thinned (a bookshelf is thousands)
const HOUGH_RHO_PX := 4.0       ## the coarse search's resolution across a line, full-size px…
const HOUGH_SPREAD_DEG := 8     ## …and how far either side of its own edge direction a pixel votes
const HOUGH_MIN := 14           ## coarse edge pixels a line needs to be looked at
const CANDIDATES := 60          ## lines re-measured
## |plane normal x gravity| below this: the segment lies along the horizon,
## where every compass direction looks the same.
const MIN_TILT := 0.15
## |plane normal . gravity| below this: the segment is (nearly) a vertical.
const MAX_UPRIGHT := 0.35
const REFINE_REACH := 7         ## full-resolution search either side of the predicted line, px
const REFINE_STEP := 2
const REFINE_GRAD := 24
const RUN_GAP := 40.0           ## px; a wider hole in a line's edge ends the stretch
const MIN_LINE_PX := 120.0      ## a re-measured line shorter than this is not trusted
const MAX_LINE_RMS := 0.7
## A re-measured line must be there for at least this much of its own length —
## a real edge is, a chance alignment of clutter is not.
const MIN_FILL := 0.6
## How far a segment's direction may be from the room's grid and still belong.
const GRID_TOL_DEG := 4.0
## Two lines of the wall's own direction must be this far apart (the angle
## between their planes) to fix the direction between them; closer, and the
## direction comes from gravity and everything found instead.
const MIN_SPREAD_DEG := 6.0
## A line agrees with a proposed direction when its plane holds that direction
## to within this. Clean shelf edges agree to a few hundredths of a degree.
const AGREE_DEG := 0.25
## A proposed level direction further than this from level (by the gravity
## sensor, itself good to about half a degree) is not one.
const MAX_OFF_LEVEL_DEG := 2.0
## How well a measured edge is taken to say "level, along this wall", before
## its own measurement noise: shelves are hung by eye or by a spirit level, and
## a lens bends straight lines a little. Far worse than the tenth of a pixel
## the edge itself is measured to.
const LINE_SIGMA_DEG := 0.15
## How well the gravity reading is taken to be known. On the first wall run it
## agreed with hand-measured shelf edges to 0.0-0.3 degrees.
const GRAVITY_SIGMA_DEG := 0.4
## A wall within this of 45 degrees to the camera: either direction could be it.
const AMBIGUOUS := 0.12


## `img`: the frozen frame. `gravity`: down, in camera space (x right, y down,
## z into the scene). `focal`, `centre`: the camera, in px. `skip`: a quad in
## camera px whose inside is ignored — the projection itself, whose markers and
## edges are not the room's.
## -> { ok, level: PackedVector2Array (two lines, two points each), reason,
##      found: int (segments the wall's direction rests on),
##      other: int (…in the direction square to it), synthesized: bool,
##      ambiguous: bool, azimuth: float (deg, for the log) }
static func find(img: Image, gravity: Vector3, focal: float, centre: Vector2,
		skip: PackedVector2Array = PackedVector2Array(), debug: bool = false) -> Dictionary:
	var res := {"ok": false, "level": PackedVector2Array(), "reason": "", "found": 0, "other": 0,
		"synthesized": false, "ambiguous": false, "azimuth": 0.0}
	if img == null or img.is_empty() or focal <= 0.0:
		res["reason"] = "NO PICTURE TO LOOK AT"
		return res
	if gravity.length() < 0.5:
		res["reason"] = "NO GRAVITY READING"
		return res
	var g := gravity.normalized()
	var l := CalibDetect._luma(img)
	var w := l.get_width()
	var h := l.get_height()
	var full := l.get_data()

	# The horizontal plane's own axes: e1 is "to the right" flattened (or "into
	# the scene", for a frame that arrives on its side), e2 square to it.
	var axis := Vector3.RIGHT if absf(g.x) < 0.9 else Vector3.BACK
	var e1 := (axis - g * g.dot(axis)).normalized()
	var e2 := g.cross(e1)

	# 1 + 2. The segments, and which way each would run if it were level.
	var segments := _segments(l, full, w, h, focal, centre, g, skip, debug)
	var level_like: Array = []
	for seg: Dictionary in segments:
		var sm: Vector3 = seg["m"]
		var sd := sm.cross(g)
		if absf(sm.dot(g)) < MAX_UPRIGHT or sd.length() < MIN_TILT:
			continue
		seg["runs"] = fposmod(rad_to_deg(atan2(sd.dot(e2), sd.dot(e1))), 180.0)
		seg["weight"] = float(seg["len"]) * sd.length() / maxf(seg["rms"], 0.05)
		level_like.append(seg)
	if debug:
		print("[lines] %d segments measured, %d of them could be level" % [segments.size(), level_like.size()])
		for seg: Dictionary in segments:
			print("[lines]   %s  %s -> %s  len %.0f rms %.2f" % ["runs %5.1f" % seg["runs"] if seg.has("runs") else "  (not level)",
				seg["a"], seg["b"], seg["len"], seg["rms"]])
	if level_like.is_empty():
		res["reason"] = "NO LEVEL EDGES IN THE PICTURE"
		return res

	# 3. The room's grid: where the directions pile up, folded onto a quarter turn.
	var hist := PackedFloat32Array()
	hist.resize(90)
	hist.fill(0.0)
	for seg: Dictionary in level_like:
		hist[int(fposmod(seg["runs"], 90.0)) % 90] += seg["weight"]
	var theta := 0.0
	var best := -1.0
	for b in 90:
		var v := 0.0
		for k in range(-2, 3):
			v += hist[(b + k + 90) % 90] * (3.0 - absf(k))
		if v > best:
			best = v
			theta = float(b) + 0.5
	var lines: Array = [[], []]
	for pass_no in 2:
		lines = [[], []]
		for seg: Dictionary in level_like:
			var dev := fposmod(float(seg["runs"]) - theta + 45.0, 90.0) - 45.0
			if absf(dev) > GRID_TOL_DEG:
				continue
			var side_of := int(round((float(seg["runs"]) - theta - dev) / 90.0))
			lines[posmod(side_of, 2)].append(seg)
		theta += _room_turn(lines, g, e1, e2, theta)
	if debug:
		print("[lines] the room's grid runs %.2f deg: %d + %d segments" % [theta, lines[0].size(), lines[1].size()])
	var dirs: Array[Vector3] = []
	for f in 2:
		var ang := deg_to_rad(theta + 90.0 * f)
		dirs.append(e1 * cos(ang) + e2 * sin(ang))

	# 4. Which of the two is the projection wall's: the one faced more squarely.
	var wall := 0 if absf(dirs[0].z) <= absf(dirs[1].z) else 1
	res["ambiguous"] = absf(absf(dirs[0].z) - absf(dirs[1].z)) < AMBIGUOUS
	var own: Array = lines[wall]
	var side: Array = lines[1 - wall]
	res["found"] = own.size()
	res["other"] = side.size()
	# One thing is not a room: it may be the one thing in the picture that is
	# hung crooked. So the grid must rest on two edges that are not just the
	# two sides of one board.
	var apart := 0.0
	var every: Array = own + side
	for i in every.size():
		for j in i:
			var pi: Vector3 = every[i]["m"]
			var pj: Vector3 = every[j]["m"]
			apart = maxf(apart, rad_to_deg(asin(clampf(pi.cross(pj).length(), 0.0, 1.0))))
	if apart < MIN_SPREAD_DEG * 0.5:
		res["reason"] = "NOT ENOUGH LEVEL EDGES IN THE PICTURE"
		return res

	# Two of the wall's own edges, well apart, fix its direction between them
	# exactly as two tapped lines would (where they meet; gravity not needed).
	# But a direction also catches things that merely point nearly that way —
	# a keyboard propped against the wall — so every such pair PROPOSES a
	# direction, the proposal the most edge agrees with wins (it must also be
	# level, give or take the sensor), and only the edges that agree are kept.
	var weights := PackedFloat32Array()
	for line: Dictionary in own:
		# Long and clean: an edge with books standing on it is several times
		# worse than the bare underside of the same shelf.
		weights.append(float(line["len"]) / maxf(line["rms"], 0.05))
	var agreed := PackedInt32Array()
	var agreed_w := 0.0
	for i in own.size():
		for j in i:
			var mi: Vector3 = own[i]["m"]
			var mj: Vector3 = own[j]["m"]
			var across := mi.cross(mj)
			if rad_to_deg(asin(clampf(across.length(), 0.0, 1.0))) < MIN_SPREAD_DEG:
				continue
			var prop := across.normalized()
			if absf(prop.dot(g)) > sin(deg_to_rad(MAX_OFF_LEVEL_DEG)):
				continue
			var with := PackedInt32Array()
			var total := 0.0
			for k in own.size():
				var mk: Vector3 = own[k]["m"]
				if absf(mk.dot(prop)) <= sin(deg_to_rad(AGREE_DEG)):
					with.append(k)
					total += weights[k]
			if total > agreed_w:
				agreed_w = total
				agreed = with
	var pair_score := 0.0
	var first := -1
	var second := -1
	var meet := Vector3.ZERO
	for i in agreed:
		for j in agreed:
			if j >= i:
				continue
			var mi: Vector3 = own[i]["m"]
			var mj: Vector3 = own[j]["m"]
			var across := mi.cross(mj)
			var spread := rad_to_deg(asin(clampf(across.length(), 0.0, 1.0)))
			if spread < MIN_SPREAD_DEG:
				continue
			if meet.dot(across) < 0.0:
				across = -across
			meet += across * (weights[i] * weights[j])
			var sc := spread * minf(weights[i], weights[j])
			if sc > pair_score:
				pair_score = sc
				first = i
				second = j
	if debug:
		print("[lines] the wall's direction rests on lines %s of %d" % [agreed, own.size()])
	res["found"] = agreed.size()
	var level := PackedVector2Array()
	if first >= 0:
		# Where shelf edges meet is sharp ACROSS them and vague ALONG them: they
		# are nearly parallel, so a tenth of a pixel moves the meeting point a
		# long way down the line (about a degree of wall angle on the real
		# frames). Gravity says the meeting point is also on the horizon, which
		# cuts across exactly that vague direction. So: one least-squares step
		# from the pairs' answer, every agreeing edge and gravity each weighted
		# by how well it is known.
		meet = meet.normalized()
		var p := meet.cross(g).normalized()
		var q := meet.cross(p)
		var spp := 0.0
		var spq := 0.0
		var sqq := 0.0
		var sp := 0.0
		var sq := 0.0
		for k in range(-1, agreed.size()):
			var cvec := g
			var sigma := GRAVITY_SIGMA_DEG
			if k >= 0:
				cvec = own[agreed[k]]["m"]
				sigma = LINE_SIGMA_DEG + 20.0 * maxf(own[agreed[k]]["rms"], 0.05) / float(own[agreed[k]]["len"])
			var wk := 1.0 / (sigma * sigma)
			var c0 := cvec.dot(meet)
			var cp := cvec.dot(p)
			var cq := cvec.dot(q)
			spp += wk * cp * cp
			spq += wk * cp * cq
			sqq += wk * cq * cq
			sp += wk * cp * c0
			sq += wk * cq * c0
		var det := spp * sqq - spq * spq
		if absf(det) > 1e-12:
			meet = (meet - p * ((sp * sqq - sq * spq) / det) - q * ((sq * spp - sp * spq) / det)).normalized()
		# Hand back the two best edges, each turned about its own middle (by a
		# fraction of a pixel) so that the two meet where it all agrees.
		for idx: int in [first, second]:
			var ea: Vector2 = own[idx]["a"]
			var eb: Vector2 = own[idx]["b"]
			var mid := (ea + eb) * 0.5
			var ray := Vector2((mid.x - centre.x) / focal, (mid.y - centre.y) / focal)
			var run_dir := Vector2(meet.x - ray.x * meet.z, meet.y - ray.y * meet.z).normalized()
			if run_dir.dot(eb - ea) < 0.0:
				run_dir = -run_dir
			var half := ea.distance_to(eb) * 0.5
			level.append(mid - run_dir * half)
			level.append(mid + run_dir * half)
	var az := theta + 90.0 * wall
	if level.is_empty():
		# Not enough on the wall itself. Every measured line still says which
		# way the room runs (given gravity — `theta` already is their answer);
		# draw two lines in that direction, a third of the way in from the top
		# and the bottom.
		var level_dir := e1 * cos(deg_to_rad(az)) + e2 * sin(deg_to_rad(az))
		for fy: float in [0.3, 0.7]:
			var through := Vector3(0.0, (h * fy - centre.y) / focal, 1.0)
			var pm := level_dir.cross(through)
			for fx: float in [0.12, 0.88]:
				var px := w * fx
				# pm . ((x - cx)/f, (y - cy)/f, 1) = 0, solved for y
				if absf(pm.y) < 1e-9:
					res["reason"] = "THE LEVEL DIRECTION RUNS STRAIGHT UP THE PICTURE"
					return res
				level.append(Vector2(px, centre.y - focal * (pm.x * (px - centre.x) / focal + pm.z) / pm.y))
		res["synthesized"] = true
	res["azimuth"] = az
	res["level"] = level
	res["ok"] = true
	return res



## The picture's long straight edges, each measured: a coarse Hough search for
## lines that many edge pixels lie on, then every candidate re-measured at full
## resolution (_measure), which is where most of them turn out not to be edges.
## Edge pixels of verticals are left out before the search even starts: a room
## is mostly verticals (door frames, book spines, corners), they can say
## nothing about level, and they would take every place among the candidates.
## -> [{ a, b, m, len, rms }]
static func _segments(l: Image, full: PackedByteArray, w: int, h: int, focal: float,
		centre: Vector2, g: Vector3, skip: PackedVector2Array, debug: bool) -> Array:
	var c: Image = l.duplicate()
	for i in SHRINKS:
		c.shrink_x2()
	var cw := c.get_width()
	var ch := c.get_height()
	var cd := c.get_data()
	var scale := float(w) / float(cw)

	# Edge pixels: where (relative to the picture's middle, full-size px), and
	# the angle of the edge's normal, 0..179.
	var ex := PackedFloat32Array()
	var ey := PackedFloat32Array()
	var ea := PackedInt32Array()
	var quad := _scaled(skip, 1.0 / scale)
	var min2 := EDGE_MIN * EDGE_MIN
	var mid := Vector2(w, h) * 0.5
	for y in range(1, ch - 1):
		var span := _row_span(quad, float(y) + 0.5)
		var row := y * cw
		for x in range(1, cw - 1):
			if x >= span.x and x <= span.y:
				continue
			var i := row + x
			var gx: int = cd[i + 1] - cd[i - 1]
			var gy: int = cd[i + cw] - cd[i - cw]
			var m2 := gx * gx + gy * gy
			if m2 < min2:
				continue
			var fx := (x + 0.5) * scale
			var fy := (y + 0.5) * scale
			# The plane through the camera and this pixel's edge: upright?
			var inv := 0.05 / sqrt(float(m2))
			var r0 := Vector3((fx - centre.x) / focal, (fy - centre.y) / focal, 1.0)
			var pm := r0.cross(Vector3(r0.x - gy * inv, r0.y + gx * inv, 1.0)).normalized()
			if absf(pm.dot(g)) < MAX_UPRIGHT:
				continue
			ex.append(fx - mid.x)
			ey.append(fy - mid.y)
			ea.append(posmod(int(round(rad_to_deg(atan2(float(gy), float(gx))))), 180))
	if ex.size() < HOUGH_MIN:
		return []
	var stride := maxf(float(ex.size()) / float(MAX_EDGES), 1.0)

	# The vote: every edge pixel, for every line through it within
	# HOUGH_SPREAD_DEG of its own edge direction.
	var reach := mid.length() + HOUGH_RHO_PX
	var rhos := int(2.0 * reach / HOUGH_RHO_PX) + 1
	var acc := PackedInt32Array()
	acc.resize(180 * rhos)
	acc.fill(0)
	var cosv := PackedFloat32Array()
	var sinv := PackedFloat32Array()
	for a in 180:
		cosv.append(cos(deg_to_rad(float(a))))
		sinv.append(sin(deg_to_rad(float(a))))
	var at := 0.0
	while int(at) < ex.size():
		var k := int(at)
		at += stride
		var px := ex[k]
		var py := ey[k]
		for da in range(-HOUGH_SPREAD_DEG, HOUGH_SPREAD_DEG + 1):
			var a := posmod(ea[k] + da, 180)
			acc[a * rhos + int((px * cosv[a] + py * sinv[a] + reach) / HOUGH_RHO_PX)] += 1

	# The strongest lines, none of them a near-copy of a stronger one.
	var floor_v := maxi(int(HOUGH_MIN / stride), 5)
	var cells: Array = []
	for i in acc.size():
		if acc[i] >= floor_v:
			cells.append([acc[i], i])
	cells.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0])
	var picked: Array[Vector2i] = []
	var out: Array = []
	for cell: Array in cells:
		if picked.size() >= CANDIDATES:
			break
		var idx: int = cell[1]
		@warning_ignore("integer_division")
		var a := idx / rhos
		var r := idx % rhos
		var clear := true
		for prev in picked:
			var da := absi(prev.x - a)
			if mini(da, 180 - da) <= 3 and absi(prev.y - r) <= 3:
				clear = false
				break
		if not clear:
			continue
		picked.append(Vector2i(a, r))
		# The line n . p = rho (p from the picture's middle), as the plane
		# through the camera that holds it.
		var n := Vector2(cosv[a], sinv[a])
		var rho := (float(r) + 0.5) * HOUGH_RHO_PX - reach
		var offset := n.dot(mid - centre) + rho     # n . (p - centre) = offset
		var plane := Vector3(n.x * focal, n.y * focal, -offset).normalized()
		var seg := _measure(full, w, h, plane, focal, centre)
		if seg.is_empty():
			continue
		var twin := false
		for prev: Dictionary in out:
			var pa: Vector2 = prev["a"]
			var pb: Vector2 = prev["b"]
			var sa: Vector2 = seg["a"]
			var sb: Vector2 = seg["b"]
			var along := (pb - pa).normalized()
			if absf(along.cross(sa - pa)) < 3.0 and absf(along.cross(sb - pa)) < 3.0:
				twin = true   # the same edge, reached from the cell next door
		if not twin:
			out.append(seg)
	if debug:
		print("[lines] %d edge px, %d Hough cells over %d, %d candidates -> %d segments" % [ex.size(),
			cells.size(), floor_v, picked.size(), out.size()])
	return out


## How far the room's grid is from `theta`, by the measured lines themselves:
## each says (given gravity) which way it runs; the weighted MEDIAN of those,
## so that one propped-up keyboard does not move it. Degrees; 0 with no lines.
static func _room_turn(lines: Array, g: Vector3, e1: Vector3, e2: Vector3, theta: float) -> float:
	var said: Array = []
	var total := 0.0
	for f in 2:
		for line: Dictionary in lines[f]:
			var lm: Vector3 = line["m"]
			var ld := lm.cross(g)
			var runs := rad_to_deg(atan2(ld.dot(e2), ld.dot(e1))) - 90.0 * f
			var wgt: float = line["len"] * ld.length() / maxf(line["rms"], 0.05)
			said.append([fposmod(runs - theta + 90.0, 180.0) - 90.0, wgt])
			total += wgt
	if said.is_empty():
		return 0.0
	said.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
	var seen := 0.0
	for entry: Array in said:
		seen += entry[1]
		if seen >= total * 0.5:
			return entry[0]
	return 0.0


## Re-measure one line at full resolution: step along it right across the
## picture, find the sharpest brightness step within REFINE_REACH of where it is
## expected, take the longest unbroken stretch of those, and fit a straight
## line through it — dropping what does not belong, as the books on a shelf do
## not belong to the shelf's edge. `m` is the plane through the camera that the
## line lies in. {} unless what comes out is long, straight and mostly there.
## -> { a, b: Vector2 (the ends), m: Vector3, len, rms }
static func _measure(full: PackedByteArray, w: int, h: int, m: Vector3, focal: float,
		centre: Vector2) -> Dictionary:
	# a*x + b*y + c = 0 in px.
	var a := m.x / focal
	var b := m.y / focal
	var c := m.z - (m.x * centre.x + m.y * centre.y) / focal
	var flat := absf(b) >= absf(a)      # runs more across the picture than up it
	# Work in (u, v): u along the line's long axis, v across it.
	var slope := -a / b if flat else -b / a
	var offset := -c / b if flat else -c / a
	var un := w if flat else h
	var vn := h if flat else w
	var ustride := 1 if flat else w
	var vstride := w if flat else 1
	var up: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]   # u, per sign
	var vp: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]   # v
	var u := REFINE_STEP + 2
	while u <= un - REFINE_STEP - 3:
		var vc := int(round(offset + slope * u))
		if vc - REFINE_REACH - 3 >= 0 and vc + REFINE_REACH + 3 < vn:
			var base := u * ustride
			var hi_g := REFINE_GRAD - 1
			var lo_g := -(REFINE_GRAD - 1)
			var hi_v := 0
			var lo_v := 0
			for v in range(vc - REFINE_REACH, vc + REFINE_REACH + 1):
				var at := base + v * vstride
				var gr: int = (full[at + vstride] + full[at + 2 * vstride]) \
						- (full[at - vstride] + full[at - 2 * vstride])
				if gr > hi_g:
					hi_g = gr
					hi_v = v
				elif gr < lo_g:
					lo_g = gr
					lo_v = v
			for s in 2:
				var v := hi_v if s == 0 else lo_v
				if (hi_g if s == 0 else -lo_g) < REFINE_GRAD:
					continue
				# Sub-pixel: the peak of a parabola through the step's strength
				# here and either side.
				var at := base + v * vstride
				var g0 := float((full[at] + full[at + vstride]) - (full[at - 2 * vstride] + full[at - 3 * vstride]))
				var g1 := float((full[at + vstride] + full[at + 2 * vstride]) - (full[at - vstride] + full[at - 2 * vstride]))
				var g2 := float((full[at + 2 * vstride] + full[at + 3 * vstride]) - (full[at] + full[at - vstride]))
				var den := g0 - 2.0 * g1 + g2
				var sub := 0.5 * (g0 - g2) / den if absf(den) > 1e-6 else 0.0
				up[s].append(float(u))
				vp[s].append(float(v) + clampf(sub, -1.0, 1.0))
		u += REFINE_STEP
	var best := {}
	for s in 2:
		# The longest unbroken stretch of this sign — a line across a room
		# crosses many things; the edge is the part that does not stop.
		var from := 0
		var run_from := 0
		var run_to := -1
		for i in range(1, up[s].size() + 1):
			if i == up[s].size() or up[s][i] - up[s][i - 1] > RUN_GAP:
				if i - from > run_to - run_from + 1:
					run_from = from
					run_to = i - 1
				from = i
		if run_to - run_from + 1 < 8:
			continue
		var fit := _fit(up[s].slice(run_from, run_to + 1), vp[s].slice(run_from, run_to + 1))
		if fit.is_empty():
			continue
		var length: float = (fit["u1"] - fit["u0"]) * sqrt(1.0 + fit["k"] * fit["k"])
		if length < MIN_LINE_PX or fit["rms"] > MAX_LINE_RMS \
				or fit["n"] * REFINE_STEP < MIN_FILL * (fit["u1"] - fit["u0"]):
			continue
		if best.is_empty() or fit["n"] > best["n"]:
			best = fit
			best["len"] = length
	if best.is_empty():
		return {}
	var ua: float = best["u0"]
	var ub: float = best["u1"]
	var va: float = best["o"] + best["k"] * ua
	var vb: float = best["o"] + best["k"] * ub
	var pa := Vector2(ua, va) if flat else Vector2(va, ua)
	var pb := Vector2(ub, vb) if flat else Vector2(vb, ub)
	var ra := Vector3((pa.x - centre.x) / focal, (pa.y - centre.y) / focal, 1.0)
	var rb := Vector3((pb.x - centre.x) / focal, (pb.y - centre.y) / focal, 1.0)
	return {"a": pa, "b": pb, "m": ra.cross(rb).normalized(), "len": best["len"], "rms": best["rms"]}


## v = o + k*u through the points, least squares, thrown-out points trimmed
## until none is further than twice the median miss (or 0.6 px).
## -> { o, k, n, rms, u0, u1 } or {}.
static func _fit(us: PackedFloat32Array, vs: PackedFloat32Array) -> Dictionary:
	var keep := PackedInt32Array()
	for i in us.size():
		keep.append(i)
	var o := 0.0
	var k := 0.0
	for pass_no in 6:
		var n := keep.size()
		if n < 8:
			return {}
		var su := 0.0
		var sv := 0.0
		var suu := 0.0
		var suv := 0.0
		for i in keep:
			su += us[i]
			sv += vs[i]
			suu += us[i] * us[i]
			suv += us[i] * vs[i]
		var den := n * suu - su * su
		if absf(den) < 1e-9:
			return {}
		k = (n * suv - su * sv) / den
		o = (sv - k * su) / n
		var miss := PackedFloat32Array()
		for i in keep:
			miss.append(absf(vs[i] - (o + k * us[i])))
		var sorted := miss.duplicate()
		sorted.sort()
		@warning_ignore("integer_division")
		var limit := maxf(0.6, 2.0 * sorted[n / 2])
		var next := PackedInt32Array()
		for j in n:
			if miss[j] <= limit:
				next.append(keep[j])
		if next.size() == n:
			break
		keep = next
	var sq := 0.0
	var u0 := INF
	var u1 := -INF
	for i in keep:
		var e := vs[i] - (o + k * us[i])
		sq += e * e
		u0 = minf(u0, us[i])
		u1 = maxf(u1, us[i])
	return {"o": o, "k": k, "n": keep.size(), "rms": sqrt(sq / float(keep.size())), "u0": u0, "u1": u1}


## The quad, grown a little about its middle and scaled (to coarse pixels).
static func _scaled(quad: PackedVector2Array, by: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if quad.size() != 4:
		return out
	var mid := (quad[0] + quad[1] + quad[2] + quad[3]) * 0.25
	for p in quad:
		out.append((mid + (p - mid) * 1.08) * by)
	return out


## The x range a convex quad covers on row `y` — (1, 0), an empty range, when
## it does not reach the row (or there is no quad).
static func _row_span(quad: PackedVector2Array, y: float) -> Vector2:
	var lo := INF
	var hi := -INF
	for i in quad.size():
		var p := quad[i]
		var q := quad[(i + 1) % quad.size()]
		if (p.y <= y and q.y > y) or (q.y <= y and p.y > y):
			var x := p.x + (q.x - p.x) * (y - p.y) / (q.y - p.y)
			lo = minf(lo, x)
			hi = maxf(hi, x)
	return Vector2(lo, hi) if lo <= hi else Vector2(1.0, 0.0)
