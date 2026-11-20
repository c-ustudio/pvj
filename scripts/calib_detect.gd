class_name CalibDetect
extends RefCounted
## Finds projected discs in camera frames, one disc per frame, by asking which
## pixels were bright in THAT frame and in no other.
##
## The projector shows DARK, then one SOLO disc at a time, then DARK again;
## the camera takes a frame of each (CalibEditor owns the timing and calls
## add_frame()). A disc's pixels are then the ones that are brighter in its own
## frame than in EVERY other frame of the sequence.
##
## ⚠️ WHY "EVERY OTHER FRAME" AND NOT JUST THE DARK ONE. The first version
## subtracted one dark frame, and the first run on a real wall (2026-09-30)
## locked onto the operator's head instead of the markers: he moved between
## frames, and hair uncovering a white wall is a bigger, brighter difference
## than any projected disc in a lit room. Subtracting one reference cannot tell
## "lit by the projector" from "something moved". But a pixel uncovered by
## movement is usually still uncovered in the frames that follow, while a disc
## is lit for exactly one frame — so demanding that a pixel beat ALL the other
## frames cancels movement and keeps the disc. What survives (something that
## happened to move in and out within one frame) is then rejected by SHAPE: a
## disc seen at any angle fills ~78% of its bounding box, a sliver of moving
## hair does not. Anything that still gets through has to agree with the other
## discs on one calibration (CalibEditor.fit_grid).
##
## WHY ONE DISC AT A TIME. It removes the two hard parts of marker detection:
## telling markers apart (the one lit in frame N is the one that was asked for
## in frame N, whatever way up the camera is) and telling a marker from its
## neighbour.
##
## The position is the INTENSITY-WEIGHTED CENTROID of that exclusive brightness
## above half its peak, at full resolution. Bloom and defocus spread a disc
## evenly, so they barely move its centroid.
##
## Pure image maths: no camera, no timing, no scene.

const COARSE_SHRINKS := 3       ## the coarse search runs at 1/8 size, box-averaged
## A disc must beat every other frame by this many levels (of 255), after the
## box averaging and after the frame's own drift is taken out (see locate()).
## ⚠️ LOW ON PURPOSE. On a lit white wall the camera exposes the wall at
## 235-248, and a disc clips after adding very little: the wall runs measured
## discs worth 9, 15 and 21 levels beside others worth 40-50 in the same frame.
## At 12 a perfectly visible marker was refused. What keeps a floor this low
## honest is everything downstream of it — exclusivity, the shape test, and
## the discs having to agree with each other on one calibration.
const MIN_CONTRAST := 5
const WINDOW := 48              ## half-size of the first refinement window, px
const MAX_WINDOW := 384
const THRESH := 0.5             ## of the window's peak
const MIN_AREA := 9             ## px above threshold — below this it is noise
const EDGE := 2                 ## a blob this close to the frame edge is cut off
## A disc under any perspective is an ellipse: it fills pi/4 of its bounding
## box, and the box is not far from square unless the view is nearly edge-on.
const MIN_FILL := 0.5
const MAX_ASPECT := 3.0
## The brightest exclusive blob is not always the disc: something that moved
## in and out within one frame can beat it. So the search walks down the
## candidates, strongest first, until one has a disc's shape.
const MAX_CANDIDATES := 10

## The contrast floor in use. A var so the replay tool can sweep it against
## real frames; the app leaves it at MIN_CONTRAST.
var min_contrast: int = MIN_CONTRAST

var _w: int = 0
var _h: int = 0
var _cw: int = 0
var _ch: int = 0
var _full: Array[PackedByteArray] = []
var _coarse: Array[PackedByteArray] = []
var _cmax: PackedByteArray      ## coarse per-pixel max of every frame added so far


func frame_count() -> int:
	return _full.size()


## Add one frame of the sequence. -> its index, or -1 when the frame's size does
## not match the ones before it.
func add_frame(img: Image) -> int:
	var l := _luma(img)
	if _full.is_empty():
		_w = l.get_width()
		_h = l.get_height()
	elif l.get_width() != _w or l.get_height() != _h:
		return -1
	var c := _shrink(l)
	var cdata := c.get_data()
	if _full.is_empty():
		_cw = c.get_width()
		_ch = c.get_height()
		_cmax = cdata.duplicate()
	else:
		for i in cdata.size():
			if cdata[i] > _cmax[i]:
				_cmax[i] = cdata[i]
	_full.append(l.get_data())
	_coarse.append(cdata)
	return _full.size() - 1


## Did `img` light up anything the frames so far had not? Cheap, and only for
## the capture loop: a frame taken before the camera caught up with the
## projector shows the PREVIOUS disc, which is already in the running max, so
## nothing is new and the answer is no. (Movement also answers yes. That is
## fine — this only decides whether to wait and look again; locate() decides
## where the disc is.)
func is_news(img: Image) -> bool:
	if _full.is_empty():
		return true
	var l := _luma(img)
	if l.get_width() != _w or l.get_height() != _h:
		return false
	var c := _shrink(l).get_data()
	for i in c.size():
		if c[i] - _cmax[i] >= min_contrast:
			return true
	return false


## Where is the disc of frame `index`?
## -> { ok, pos: Vector2 (camera px), contrast: int, area: int, reason: String }
func locate(index: int) -> Dictionary:
	var found := candidates(index, 1)
	return found[0]


## Up to `want` disc-shaped candidates for frame `index`, strongest first. When
## there is none, ONE entry with ok == false saying why — so the result is never
## empty and [0] is always what locate() would have answered.
##
## More than one matters when something else was bright for exactly one frame
## and happens to be round (a face turning, a reflection). The strongest blob
## is then not the marker, and only geometry can tell — which is the caller's
## job (CalibEditor.fit_grid), not this file's.
func candidates(index: int, want: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if index < 0 or index >= _full.size() or _full.size() < 2:
		out.append(_fail("NOT ENOUGH FRAMES"))
		return out
	var mine := _coarse[index]
	var others: Array[PackedByteArray] = []
	for j in _coarse.size():
		if j != index:
			others.append(_coarse[j])

	# Coarse: how much each pixel beats every other frame by.
	var score := PackedByteArray()
	score.resize(mine.size())
	var hist := PackedInt32Array()
	hist.resize(256)
	hist.fill(0)
	for i in mine.size():
		var ref := 0
		for o in others:
			if o[i] > ref:
				ref = o[i]
		var d := maxi(mine[i] - ref, 0)
		score[i] = d
		hist[d] += 1
	# DRIFT. Auto-exposure moves between frames, and when this frame happens to
	# be the brightest of the sequence the WHOLE wall "beats every other frame"
	# by a level or two. That is not a disc; it is the frame's baseline. The
	# median of the score is that baseline (a disc covers a sliver of the
	# frame), and it comes off everything below.
	var baseline := 0
	var seen := 0
	@warning_ignore("integer_division")
	var half_count := mine.size() / 2
	for v in 256:
		seen += hist[v]
		if seen > half_count:
			baseline = v
			break
	if baseline > 0:
		for i in score.size():
			score[i] = maxi(score[i] - baseline, 0)

	var scale := float(_w) / float(_cw)
	var rejected := 0
	var cut_off: Dictionary = {}
	for attempt in MAX_CANDIDATES:
		var best := 0
		var best_i := -1
		for i in score.size():
			if score[i] > best:
				best = score[i]
				best_i = i
		if best < min_contrast:
			break
		@warning_ignore("integer_division")
		var cy := int((float(best_i / _cw) + 0.5) * scale)
		var cx := int((float(best_i % _cw) + 0.5) * scale)
		var res := _refine(index, cx, cy, baseline)
		# This coarse cell is spent whatever happens next: the refinement can
		# settle on a blob NEXT to the cell it started from, and blanking only
		# that blob would leave this cell to be picked again, forever.
		score[best_i] = 0
		if res["ok"]:
			var fresh := true
			var pos: Vector2 = res["pos"]
			for prev in out:
				var was: Vector2 = prev["pos"]
				if was.distance_to(pos) < 4.0:
					fresh = false   # the same blob, reached from a neighbouring cell
			if fresh:
				out.append(res)
				if out.size() >= want:
					return out
		else:
			rejected += 1
			if cut_off.is_empty() and str(res["reason"]).begins_with("CUT OFF"):
				cut_off = res
		# Blank what was just looked at and take the next strongest.
		var box: Rect2i = res["box"]
		var gx0 := maxi(int(box.position.x / scale) - 1, 0)
		var gy0 := maxi(int(box.position.y / scale) - 1, 0)
		var gx1 := mini(int(box.end.x / scale) + 2, _cw)
		var gy1 := mini(int(box.end.y / scale) + 2, _ch)
		for gy in range(gy0, gy1):
			for gx in range(gx0, gx1):
				score[gy * _cw + gx] = 0
	# No disc. Say the most useful true thing: a blob on the frame edge is
	# probably the disc itself, half out of shot; anything else that lit up
	# was movement; nothing at all means it is not in view (or too faint).
	if not out.is_empty():
		return out
	if not cut_off.is_empty():
		out.append(cut_off)
	elif rejected > 0:
		out.append(_fail("NOT FOUND — IS IT IN THE SHOT? (ONLY MOVEMENT SEEN)"))
	else:
		out.append(_fail("NOT SEEN — IS IT IN THE SHOT?"))
	return out


## The exclusive blob around (cx, cy), at full resolution. A failure carries
## "box" (what it looked at) and "pos" (where it was) so the caller can move on
## and the log can say what was rejected.
func _refine(index: int, cx: int, cy: int, baseline: int) -> Dictionary:
	var lit := _full[index]
	var refs: Array[PackedByteArray] = []
	for j in _full.size():
		if j != index:
			refs.append(_full[j])

	# A disc bigger than the window (a close camera, heavy bloom) gets a bigger
	# window rather than a clipped centroid.
	var half := WINDOW
	while true:
		var x0 := maxi(cx - half, 0)
		var y0 := maxi(cy - half, 0)
		var x1 := mini(cx + half, _w)
		var y1 := mini(cy + half, _h)
		var window := Rect2i(x0, y0, x1 - x0, y1 - y0)
		# The exclusive brightness of every pixel in the window, once.
		var ex := PackedByteArray()
		ex.resize(window.size.x * window.size.y)
		var peak := 0
		var k := 0
		for y in range(y0, y1):
			var row := y * _w
			for x in range(x0, x1):
				var v := lit[row + x]
				var ref := 0
				for o in refs:
					if o[row + x] > ref:
						ref = o[row + x]
				var d := maxi(v - ref - baseline, 0)
				ex[k] = d          # written even when 0: resize() does not promise zeros
				if d > peak:
					peak = d
				k += 1
		var t := maxi(int(float(peak) * THRESH), 1)
		var sum := 0.0
		var sx := 0.0
		var sy := 0.0
		var area := 0
		var bx0 := x1
		var by0 := y1
		var bx1 := x0
		var by1 := y0
		k = 0
		for y in range(y0, y1):
			for x in range(x0, x1):
				var d := ex[k]
				k += 1
				if d >= t:
					sum += d
					sx += d * x
					sy += d * y
					area += 1
					bx0 = mini(bx0, x)
					by0 = mini(by0, y)
					bx1 = maxi(bx1, x)
					by1 = maxi(by1, y)
		if area < MIN_AREA:
			return _fail("TOO SMALL TO TRUST", peak, area, window)
		var pos := Vector2(sx / sum + 0.5, sy / sum + 0.5)   # +0.5: pixel centres
		var box := Rect2i(bx0, by0, bx1 - bx0 + 1, by1 - by0 + 1)
		if bx0 < EDGE or by0 < EDGE or bx1 >= _w - EDGE or by1 >= _h - EDGE:
			return _fail("CUT OFF BY THE EDGE OF THE CAMERA FRAME", peak, area, box, pos)
		var clipped := bx0 <= x0 or by0 <= y0 or bx1 >= x1 - 1 or by1 >= y1 - 1
		if clipped and half < MAX_WINDOW:
			half *= 2
			# Re-centre on what was found so far; the coarse peak of a big
			# blob need not be its middle.
			cx = int(sx / sum)
			cy = int(sy / sum)
			continue
		var bw := float(box.size.x)
		var bh := float(box.size.y)
		if float(area) / (bw * bh) < MIN_FILL or maxf(bw / bh, bh / bw) > MAX_ASPECT:
			return _fail("NOT A DISC (SOMETHING MOVED?)", peak, area, box, pos)
		return {"ok": true, "pos": pos, "contrast": peak, "area": area, "reason": "", "box": box}
	return _fail("NOT SEEN")   # unreachable; keeps the analyzer's return check happy


static func _fail(reason: String, contrast: int = 0, area: int = 0,
		box: Rect2i = Rect2i(), pos: Vector2 = Vector2.ZERO) -> Dictionary:
	return {"ok": false, "pos": pos, "contrast": contrast, "area": area, "reason": reason, "box": box}


## A luminance copy — the caller's image is left alone.
static func _luma(img: Image) -> Image:
	var l: Image = img.duplicate()
	if l.is_compressed():
		l.decompress()
	if l.get_format() != Image.FORMAT_L8:
		l.convert(Image.FORMAT_L8)
	return l


## Box-averaged downsample. shrink_x2 averages 2x2 blocks, which is the point:
## Image.resize() would SAMPLE, and let a lone hot pixel through.
static func _shrink(l: Image) -> Image:
	var c: Image = l.duplicate()
	for i in COARSE_SHRINKS:
		c.shrink_x2()
	return c
