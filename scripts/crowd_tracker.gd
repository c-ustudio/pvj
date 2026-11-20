class_name CrowdTracker
extends RefCounted
## M8b — SLOTS, NOT INDICES (docs/MEDIAPIPE_MODULE.md §13.3).
##
## The detector is the easy part. Keeping "person 3" the same human between
## frames is the whole job: MediaPipe's detection order is NOT identity, so
## anything bound to a raw index flickers and swaps people. This turns a bag
## of boxes per inference into `crowd_slots` STABLE identities.
##
## ── WHY GDSCRIPT AND NOT CrowdTracker.kt (a deliberate §13.9 deviation) ──
## §13.9 asks for `CrowdTracker.kt` AND a headless `verify_crowd_tracker.gd`
## in the verify_trigger_lane idiom. Those contradict: a GDScript harness
## cannot drive Kotlin. This is pure logic with no camera access — 8 slots at
## 12 Hz is nothing — so it lives here where synthetic time can prove the
## birth debounce, the grace release and the cooldown EXACTLY, before a phone
## is involved. Kotlin's job shrinks to handing over raw boxes.
##
## ── THE LAW THIS FILE EXISTS TO KEEP ────────────────────────────────────
## ⚠️ Matching happens in RAW CAMERA SPACE. The §4.2 audience-view mirror is
## applied at OUTPUT only. This is not style: it is verbatim the Session 34
## bug that made the single lock churn every ~2 s on the front lens, and a
## one-to-many tracker would reproduce it once per slot.

const K := 8                     ## floats per slot — see slot_channel()
const CH_PRESENT := 0
const CH_X := 1
const CH_Y := 2
const CH_SIZE := 3
const CH_VX := 4
const CH_VY := 5
const CH_AGE := 6
const CH_CONF := 7

## §13.6 defaults. All live except slots (a resize reallocates the bank).
var slots: int = 6               ## 1..8
var min_conf: float = 0.4        ## detector floor (measured: 0.25 is a trap)
var max_jump: float = 0.18       ## frame widths per inference — the gate
var acquire_frames: int = 4      ## consecutive hits before a slot is born
var grace_ms: int = 900          ## unmatched slot holds this long before release
var cooldown_ms: int = 1500      ## a freed slot is not reused this soon
var energy_gain: float = 6.0     ## crowd_energy scale
var mirror_output: bool = false  ## §4.2 — applied at OUTPUT, never to matching

## One Euro, per slot per channel. Reset on birth so a new person never
## inherits the previous occupant's filter state.
var filter_min_cutoff: float = 1.0
var filter_beta: float = 0.02

var _slots: Array[Dictionary] = []     ## held identities, index == slot id
var _cands: Array[Dictionary] = []     ## unmatched detections serving their debounce
var _last_ms: int = -1
var _overflow: bool = false
var _last_n: int = 0


func _init() -> void:
	_rebuild()


func _rebuild() -> void:
	_slots.clear()
	for i in slots:
		_slots.append(_empty_slot())
	_cands.clear()


func _empty_slot() -> Dictionary:
	return {
		"held": false,          # a person occupies this slot
		"x": 0.0, "y": 0.0,     # RAW camera space (matching lives here)
		"size": 0.0, "conf": 0.0,
		"vx": 0.0, "vy": 0.0,
		"born_ms": 0, "seen_ms": 0,
		"free_ms": -1,          # when it was released (cooldown starts)
		"present": false,       # debounced — survives grace
		"fx": null, "fy": null, "fs": null,   # One Euro state per channel
	}


## Resize the bank. Loses all identities, so callers do it on start(), never
## mid-set — §13.6 marks crowd_slots restart-only for exactly this reason.
func set_slots(n: int) -> void:
	slots = clampi(n, 1, 8)
	_rebuild()


## Feed one inference. `dets` is an Array of {x, y, size, conf} in RAW camera
## space, normalised 0..1. `now_ms` is injected so the headless proof can make
## dwell and cooldown windows exact — nothing here reads the clock itself.
func feed(dets: Array, now_ms: int) -> void:
	var dt := 0.0
	if _last_ms >= 0:
		dt = maxf(float(now_ms - _last_ms) / 1000.0, 0.0001)
	_last_ms = now_ms

	# ---- 1. drop everything under the confidence floor
	var live: Array = []
	for d in dets:
		if float(d.get("conf", 0.0)) >= min_conf:
			live.append(d)
	_last_n = live.size()
	_overflow = live.size() > slots

	# ---- 2. greedy nearest-centroid, held slots first, descending confidence.
	# Greedy rather than Hungarian: at N <= 8 the optimal assignment and the
	# greedy one differ vanishingly often, and greedy is auditable in a log.
	live.sort_custom(func(a, b): return float(a.get("conf", 0)) > float(b.get("conf", 0)))
	var taken := {}
	for si in _slots.size():
		var s: Dictionary = _slots[si]
		if not s["held"]:
			continue
		var best := -1
		var best_cost := INF
		for di in live.size():
			if taken.has(di):
				continue
			var d: Dictionary = live[di]
			var dist := Vector2(float(d["x"]) - s["x"], float(d["y"]) - s["y"]).length()
			if dist > max_jump:
				continue          # beyond the gate: a DIFFERENT person stood there
			# size mismatch breaks ties — two people at the same spot in the
			# image are separated by how near they are, not by luck.
			var cost := dist + absf(float(d.get("size", 0.0)) - s["size"]) * 0.5
			if cost < best_cost:
				best_cost = cost
				best = di
		if best >= 0:
			taken[best] = true
			_update_slot(si, live[best], now_ms, dt)
		else:
			_miss_slot(si, now_ms)

	# ---- 3. unmatched detections serve the birth debounce (§5.2's door, per slot)
	var unmatched: Array = []
	for di in live.size():
		if not taken.has(di):
			unmatched.append(live[di])
	_run_candidates(unmatched, now_ms)


func _update_slot(si: int, d: Dictionary, now_ms: int, dt: float) -> void:
	var s: Dictionary = _slots[si]
	var nx := float(d["x"])
	var ny := float(d["y"])
	var ns := float(d.get("size", 0.0))
	if dt > 0.0:
		s["vx"] = clampf((nx - s["x"]) / dt, -1.0, 1.0)
		s["vy"] = clampf((ny - s["y"]) / dt, -1.0, 1.0)
	s["x"] = _filt(s, "fx", nx, now_ms)
	s["y"] = _filt(s, "fy", ny, now_ms)
	s["size"] = _filt(s, "fs", ns, now_ms)
	s["conf"] = float(d.get("conf", 0.0))
	s["seen_ms"] = now_ms
	s["present"] = true


## Unmatched: FREEZE, do not decay. §5.2's reasoning applies unchanged — a
## slow slide toward centre reads as the person drifting, which is worse than
## a hold. present stays true through the grace window.
func _miss_slot(si: int, now_ms: int) -> void:
	var s: Dictionary = _slots[si]
	if now_ms - int(s["seen_ms"]) >= grace_ms:
		s["held"] = false
		s["present"] = false
		s["free_ms"] = now_ms
		s["fx"] = null; s["fy"] = null; s["fs"] = null
		s["vx"] = 0.0; s["vy"] = 0.0


func _run_candidates(unmatched: Array, now_ms: int) -> void:
	var still: Array[Dictionary] = []
	for d in unmatched:
		var dx := float(d["x"])
		var dy := float(d["y"])
		var matched := false
		for c in _cands:
			if c["used"]:
				continue
			if Vector2(dx - float(c["x"]), dy - float(c["y"])).length() <= max_jump:
				c["x"] = dx
				c["y"] = dy
				c["size"] = float(d.get("size", 0.0))
				c["conf"] = float(d.get("conf", 0.0))
				c["hits"] = int(c["hits"]) + 1
				c["used"] = true
				matched = true
				still.append(c)
				break
		if not matched:
			# a jump mid-debounce restarts the clock: a DIFFERENT person at the
			# doorway starts over rather than inheriting a stranger's progress
			still.append({
				"x": dx, "y": dy,
				"size": float(d.get("size", 0.0)),
				"conf": float(d.get("conf", 0.0)),
				"hits": 1, "used": true,
			})
	# a candidate that missed this inference is gone — one-frame phantoms must
	# never accumulate toward a birth
	_cands.clear()
	for c in still:
		c["used"] = false
		if int(c["hits"]) >= acquire_frames:
			if _birth(c, now_ms):
				continue          # promoted; stop tracking it as a candidate
		_cands.append(c)


## Lowest free slot, respecting the cooldown. Returns false when the room is
## fuller than the bank — the surplus is simply untracked, and held slots are
## NEVER re-shuffled to "fit better" (predictable beats optimal, §13.8).
func _birth(c: Dictionary, now_ms: int) -> bool:
	for si in _slots.size():
		var s: Dictionary = _slots[si]
		if s["held"]:
			continue
		if int(s["free_ms"]) >= 0 and now_ms - int(s["free_ms"]) < cooldown_ms:
			continue              # still cooling: an effect bound here must not
			                      # inherit a stranger the instant its owner is occluded
		s["held"] = true
		s["present"] = true
		s["x"] = float(c["x"]); s["y"] = float(c["y"])
		s["size"] = float(c["size"]); s["conf"] = float(c["conf"])
		s["vx"] = 0.0; s["vy"] = 0.0
		s["born_ms"] = now_ms
		s["seen_ms"] = now_ms
		s["free_ms"] = -1
		s["fx"] = null; s["fy"] = null; s["fs"] = null   # never inherit filter state
		return true
	return false


# --- One Euro (§5.1), per slot per channel -------------------------------

func _filt(s: Dictionary, key: String, v: float, now_ms: int) -> float:
	var st = s[key]
	if st == null:
		s[key] = {"x": v, "dx": 0.0, "t": now_ms}
		return v
	var dt := maxf(float(now_ms - int(st["t"])) / 1000.0, 0.0001)
	st["t"] = now_ms
	var dx := (v - float(st["x"])) / dt
	var ad := _alpha(dt, 1.0)
	st["dx"] = ad * dx + (1.0 - ad) * float(st["dx"])
	var cutoff := filter_min_cutoff + filter_beta * absf(float(st["dx"]))
	var a := _alpha(dt, cutoff)
	st["x"] = a * v + (1.0 - a) * float(st["x"])
	return float(st["x"])


func _alpha(dt: float, cutoff: float) -> float:
	var tau := 1.0 / (TAU * cutoff)
	return 1.0 / (1.0 + tau / dt)


# --- readers -------------------------------------------------------------

## Per-slot channel, §13.3's table. x is mirrored HERE and only here.
func slot_channel(si: int, ch: int) -> float:
	if si < 0 or si >= _slots.size():
		return 0.0
	var s: Dictionary = _slots[si]
	match ch:
		CH_PRESENT: return 1.0 if s["present"] else 0.0
		CH_X:
			var x := float(s["x"])
			return (1.0 - x) if mirror_output else x
		CH_Y: return float(s["y"])
		CH_SIZE: return float(s["size"])
		CH_VX:
			var vx := float(s["vx"])
			return -vx if mirror_output else vx
		CH_VY: return float(s["vy"])
		CH_AGE:
			if not s["present"]:
				return 0.0
			return clampf(float(_last_ms - int(s["born_ms"])) / 10000.0, 0.0, 1.0)
		CH_CONF: return float(s["conf"])
	return 0.0


## RAW slot position — no §4.2 mirror. The DECK needs camera-space values so
## it can apply the OES chain's own mapping; the mirrored slot_channel() is for
## OSC and the mod matrix, which speak audience view. Two consumers, two
## spaces, and conflating them put the box on the wrong side of the frame.
func slot_raw(si: int, ch: int) -> float:
	if si < 0 or si >= _slots.size():
		return 0.0
	var s: Dictionary = _slots[si]
	match ch:
		CH_PRESENT: return 1.0 if s["present"] else 0.0
		CH_X: return float(s["x"])
		CH_Y: return float(s["y"])
		CH_SIZE: return float(s["size"])
	return 0.0


func count() -> int:
	var n := 0
	for s in _slots:
		if s["present"]:
			n += 1
	return n


func overflow() -> bool:
	return _overflow


## §13.4 aggregates. Size-weighted so a near person counts for more than a
## distant one — the same instinct §5.2 uses to pick a subject.
func aggregates() -> Dictionary:
	var n := 0
	var wsum := 0.0
	var cx := 0.0
	var cy := 0.0
	var speed := 0.0
	var nearest := 0.0
	var left := 0.0
	var right := 0.0
	var xs: Array[float] = []
	var ys: Array[float] = []
	for si in _slots.size():
		var s: Dictionary = _slots[si]
		if not s["present"]:
			continue
		n += 1
		var w := maxf(float(s["size"]), 0.01)
		var x := slot_channel(si, CH_X)
		var y := float(s["y"])
		wsum += w
		cx += x * w
		cy += y * w
		speed += Vector2(float(s["vx"]), float(s["vy"])).length()
		nearest = maxf(nearest, float(s["size"]))
		if x < 0.5: left += w
		else: right += w
		xs.append(x)
		ys.append(y)
	if n == 0 or wsum <= 0.0:
		return {
			"count": 0, "centroid_x": 0.5, "centroid_y": 0.5,
			"spread": 0.0, "energy": 0.0, "nearest": 0.0,
			"balance": 0.5, "overflow": 1.0 if _overflow else 0.0,
		}
	cx /= wsum
	cy /= wsum
	# §4's variance normalisation, deliberately identical so field mode and
	# crowd mode are interchangeable on the wire (§13.4's free win)
	var vx := 0.0
	var vy := 0.0
	for i in xs.size():
		vx += pow(xs[i] - cx, 2.0)
		vy += pow(ys[i] - cy, 2.0)
	vx /= float(xs.size())
	vy /= float(ys.size())
	return {
		"count": n,
		"centroid_x": clampf(cx, 0.0, 1.0),
		"centroid_y": clampf(cy, 0.0, 1.0),
		"spread": clampf((vx + vy) * 6.0, 0.0, 1.0),
		"energy": clampf(speed / float(n) * energy_gain, 0.0, 1.0),
		"nearest": clampf(nearest, 0.0, 1.0),
		"balance": clampf(right / (left + right), 0.0, 1.0),
		"overflow": 1.0 if _overflow else 0.0,
	}


## §13.4's compatibility leg: the five FROZEN Kinect channels, synthesised
## from boxes. occupied_volume is summed box AREA, a different estimator from
## a segmentation mask's masked fraction — §13.10 #20 owns that calibration.
func field_channels() -> Dictionary:
	var a := aggregates()
	var area := 0.0
	for si in _slots.size():
		var s: Dictionary = _slots[si]
		if s["present"]:
			area += pow(float(s["size"]), 2.0) * 0.5
	return {
		"occupied_volume": clampf(area, 0.0, 1.0),
		"motion_energy": a["energy"],
		"centroid_x": a["centroid_x"],
		"centroid_y": a["centroid_y"],
		"spatial_variance": a["spread"],
	}


## Debug/status: "held/slots n=<detections> overflow"
func stats() -> String:
	return "%d/%d n=%d%s" % [count(), slots, _last_n, " OVF" if _overflow else ""]
