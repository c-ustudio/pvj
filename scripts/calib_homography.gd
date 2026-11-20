class_name CalibHomography
extends RefCounted
## A plane-to-plane homography between two PIXEL spaces, solved from point
## correspondences — the camera<->projector calibration
## (CAMERA_PROCEDURAL_MASKS_SPEC.md §1).
##
## WHY NOT WarpSurface._homography(). That one is the closed form for the unit
## square -> a quad, which is all a warp needs. Calibration maps one ARBITRARY
## quad (where the camera saw the markers) onto another (where the app drew
## them), and wants to accept more than four pairs once markers are detected
## instead of tapped. So this is the general solve:
##
##     [x']   [m0 m1 m2] [x]
##     [y'] ~ [m3 m4 m5] [y]        m8 is fixed at 1
##     [w ]   [m6 m7 m8] [1]
##
##  - exactly 4 pairs  -> the 8x8 system, solved directly (exact);
##  - more than 4      -> least squares through the normal equations.
##
## Both run on HARTLEY-NORMALIZED points (centroid at the origin, mean distance
## sqrt 2). Without that the matrix mixes terms of order 1 with terms of order
## 1920*1080 and the 8x8 is badly conditioned; with it, fixing m8 = 1 is also
## safe, because the normalized origin is the centroid of the points and a
## centroid never maps to infinity in a usable setup.
##
## The solve runs in float64 (GDScript's native float). PackedFloat32Array —
## what WarpSurface uses for its coefficients — would throw away the precision
## the normalization just bought. Points go in and out as Vector2, which is
## float32: about 1e-4 px at 1080p, far below anything a tap can resolve.
##
## LIMITS, which are physics and not this file: exact for a PLANAR surface, and
## valid only for the camera + projector positions it was solved from. Move
## either and it is stale.

const PIVOT_EPS := 1e-10
const W_EPS := 1e-9

## Row-major 3x3, m[8] == 1.
var m: PackedFloat64Array = PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1])


## Solve src[i] -> dst[i]. Returns null when no usable homography exists: fewer
## than four pairs, mismatched counts, collinear/coincident points, or a result
## that sends one of the source points through the projection horizon.
static func solve(src: PackedVector2Array, dst: PackedVector2Array) -> CalibHomography:
	var n := src.size()
	if n < 4 or dst.size() != n:
		return null
	var ts := _normalizer(src)
	var td := _normalizer(dst)
	if ts.is_empty() or td.is_empty():
		return null

	# Two rows per pair:
	#   x*m0 + y*m1 + m2                   - x*x'*m6 - y*x'*m7 = x'
	#                    x*m3 + y*m4 + m5  - x*y'*m6 - y*y'*m7 = y'
	var rows: Array[PackedFloat64Array] = []
	var rhs := PackedFloat64Array()
	# The normalized coordinates stay plain floats: a Vector2 is float32 and
	# would round them before the solve ever saw them.
	for i in n:
		var sx := ts[0] * src[i].x + ts[2]
		var sy := ts[4] * src[i].y + ts[5]
		var dx := td[0] * dst[i].x + td[2]
		var dy := td[4] * dst[i].y + td[5]
		rows.append(PackedFloat64Array([sx, sy, 1.0, 0.0, 0.0, 0.0, -sx * dx, -sy * dx]))
		rhs.append(dx)
		rows.append(PackedFloat64Array([0.0, 0.0, 0.0, sx, sy, 1.0, -sx * dy, -sy * dy]))
		rhs.append(dy)

	var a: Array[PackedFloat64Array] = []
	var b := PackedFloat64Array()
	if n == 4:
		a = rows
		b = rhs
	else:
		# Normal equations: (A^T A) h = A^T b.
		for r in 8:
			var line := PackedFloat64Array()
			line.resize(8)
			for c in 8:
				var acc := 0.0
				for k in rows.size():
					acc += rows[k][r] * rows[k][c]
				line[c] = acc
			a.append(line)
			var bacc := 0.0
			for k in rows.size():
				bacc += rows[k][r] * rhs[k]
			b.append(bacc)

	var h := _gauss(a, b)
	if h.is_empty():
		return null

	# Denormalize: H = Td^-1 * Hn * Ts.
	var hn := PackedFloat64Array([h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1.0])
	var full := _mul(_mul(_inv3(td), hn), ts)
	if absf(full[8]) < W_EPS:
		return null
	for i in 9:
		full[i] /= full[8]
	var out := CalibHomography.new()
	out.m = full
	# A homography fitted to real points keeps them all on ONE side of its
	# horizon. If it does not, the correspondences were crossed (two markers
	# tapped in the wrong order make a bow-tie) or degenerate. Which side is
	# not the test: m8 = 1 only fixes the sign at the origin, and a steep view
	# can put the horizon between the origin and the points.
	var side := signf(out._w(src[0]))
	for p in src:
		var w := out._w(p)
		if absf(w) < W_EPS or signf(w) != side:
			return null
	return out


## Map a point. A point on the horizon (w ~ 0) has no image; it comes back as
## Vector2.INF so a caller can tell rather than receive a huge finite number.
func apply(p: Vector2) -> Vector2:
	var w := _w(p)
	if absf(w) < W_EPS:
		return Vector2.INF
	return Vector2(
		(m[0] * p.x + m[1] * p.y + m[2]) / w,
		(m[3] * p.x + m[4] * p.y + m[5]) / w)


## The reverse mapping, or null when this one is singular.
func inverse() -> CalibHomography:
	var inv := _inv3(m)
	if inv.is_empty() or absf(inv[8]) < W_EPS:
		return null
	for i in 9:
		inv[i] /= inv[8]
	var out := CalibHomography.new()
	out.m = inv
	return out


## RMS distance, in dst px, between apply(src[i]) and dst[i].
func rms_error(src: PackedVector2Array, dst: PackedVector2Array) -> float:
	var n := mini(src.size(), dst.size())
	if n == 0:
		return 0.0
	var acc := 0.0
	for i in n:
		acc += apply(src[i]).distance_squared_to(dst[i])
	return sqrt(acc / float(n))


func save_to(cfg: ConfigFile, section: String) -> void:
	cfg.set_value(section, "m", m)


static func load_from(cfg: ConfigFile, section: String) -> CalibHomography:
	# has_section_key first: get_value treats a null default as "none given"
	# and logs an error for the ordinary case of no calibration saved yet.
	if not cfg.has_section_key(section, "m"):
		return null
	var v: Variant = cfg.get_value(section, "m")
	if not (v is PackedFloat64Array):
		return null
	var arr: PackedFloat64Array = v
	if arr.size() != 9 or absf(arr[8]) < W_EPS:
		return null
	var out := CalibHomography.new()
	out.m = arr.duplicate()
	return out


func _w(p: Vector2) -> float:
	return m[6] * p.x + m[7] * p.y + m[8]


# --- linear algebra ------------------------------------------------------

## The similarity that moves the centroid to the origin and scales the mean
## distance from it to sqrt 2. Empty when every point coincides.
static func _normalizer(pts: PackedVector2Array) -> PackedFloat64Array:
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= float(pts.size())
	var mean := 0.0
	for p in pts:
		mean += p.distance_to(c)
	mean /= float(pts.size())
	if mean < PIVOT_EPS:
		return PackedFloat64Array()
	var s := sqrt(2.0) / mean
	return PackedFloat64Array([s, 0.0, -s * c.x, 0.0, s, -s * c.y, 0.0, 0.0, 1.0])


static func _mul(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(9)
	for r in 3:
		for c in 3:
			out[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]
	return out


## Inverse by the adjugate. Empty when the determinant vanishes.
static func _inv3(a: PackedFloat64Array) -> PackedFloat64Array:
	var c0 := a[4] * a[8] - a[5] * a[7]
	var c1 := a[5] * a[6] - a[3] * a[8]
	var c2 := a[3] * a[7] - a[4] * a[6]
	var det := a[0] * c0 + a[1] * c1 + a[2] * c2
	if absf(det) < 1e-300:
		return PackedFloat64Array()
	return PackedFloat64Array([
		c0 / det, (a[2] * a[7] - a[1] * a[8]) / det, (a[1] * a[5] - a[2] * a[4]) / det,
		c1 / det, (a[0] * a[8] - a[2] * a[6]) / det, (a[2] * a[3] - a[0] * a[5]) / det,
		c2 / det, (a[1] * a[6] - a[0] * a[7]) / det, (a[0] * a[4] - a[1] * a[3]) / det,
	])


## Gaussian elimination with partial pivoting on an 8x8. Works on copies. Empty
## when a pivot vanishes — collinear or repeated points leave the system rank
## deficient, and that must read as "no calibration", not as a wild matrix.
static func _gauss(a_in: Array[PackedFloat64Array], b_in: PackedFloat64Array) -> PackedFloat64Array:
	var n := b_in.size()
	var a: Array[PackedFloat64Array] = []
	for row in a_in:
		a.append(row.duplicate())
	var b := b_in.duplicate()
	for col in n:
		var piv := col
		var best := absf(a[col][col])
		for r in range(col + 1, n):
			if absf(a[r][col]) > best:
				best = absf(a[r][col])
				piv = r
		if best < PIVOT_EPS:
			return PackedFloat64Array()
		if piv != col:
			var tmp_row := a[col]
			a[col] = a[piv]
			a[piv] = tmp_row
			var tmp_b := b[col]
			b[col] = b[piv]
			b[piv] = tmp_b
		for r in range(col + 1, n):
			var f := a[r][col] / a[col][col]
			if f == 0.0:
				continue
			for c in range(col, n):
				a[r][c] -= f * a[col][c]
			b[r] -= f * b[col]
	var x := PackedFloat64Array()
	x.resize(n)
	for i in range(n - 1, -1, -1):
		var acc := b[i]
		for c in range(i + 1, n):
			acc -= a[i][c] * x[c]
		x[i] = acc / a[i][i]
	return x
