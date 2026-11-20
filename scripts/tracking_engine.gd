class_name TrackingEngine
extends Node

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

## The tracking module's GDScript face (docs/MEDIAPIPE_MODULE.md §3, M1).
##
## Owns the PocketVJTracking singleton: start/stop policy, the per-frame
## snapshot poll, and the typed surface everything else reads. NOBODY else
## touches the plugin — pipeline and (later) osc_output read this node.
##
## ⚠️ THE CAMERA GATE (§2.1, made law by Session 33): CameraServer
## (CameraEngine) and CameraX sharing a lens WEDGES Godot's main loop on a
## source switch. start() therefore REFUSES while the deck's camera runs,
## and pipeline refuses SRC→CAMERA while tracking runs. Loud, never silent.

signal started(mode: String)
signal failed(reason: String)
signal stopped
signal subject_acquired
signal subject_lost
signal values_updated            ## once per NEW inference (seq advanced)

## Snapshot layout — doc §4; must mirror TrackingPlugin.kt's IDX_ constants.
const IDX_SEQ := 0
const IDX_PRESENCE := 2
const IDX_HEAD_X := 5
const IDX_HEAD_Y := 6
const IDX_HEAD_Z := 7
const IDX_HEAD_SIZE := 8
const IDX_CROWDED := 12
const IDX_N_FACES := 13
const IDX_HAND_X := 14
const IDX_HAND_Y := 15
const IDX_HAND_PRESENT := 16

var _plugin: Object = null
var _running: bool = false
var _mode: String = "off"
var _lens: String = "rear"
var _last_seq: float = -1.0
var _frame: PackedFloat32Array = PackedFloat32Array()
var _use_str_fallback: bool = false   ## doc §10 #3: FloatArray marshalling probe

## The deck's camera engine, injected by pipeline for the gate check.
var camera_engine: CameraEngine = null


func _ready() -> void:
	# Pro module (Features.MEDIAPIPE). pipeline never builds it in the public
	# build; this is the backstop if anything ever does.
	if not FeaturesS.is_pro():
		push_warning("[tracking_engine] pro-only module in a public build — freed")
		queue_free()
		return
	if not Engine.has_singleton("PocketVJTracking"):
		return
	_plugin = Engine.get_singleton("PocketVJTracking")
	_plugin.connect("tracking_started", func(m: String) -> void:
		_running = true
		_mode = m
		started.emit(m))
	_plugin.connect("tracking_failed", func(reason: String) -> void:
		_running = false
		_mode = "off"
		_drop_lanes()
		failed.emit(reason))
	_plugin.connect("tracking_stopped", func() -> void:
		_running = false
		_mode = "off"
		_drop_lanes()
		stopped.emit())
	_plugin.connect("subject_acquired", func() -> void: subject_acquired.emit())
	_plugin.connect("subject_lost", func() -> void: subject_lost.emit())


func available() -> bool:
	return _plugin != null


func is_running() -> bool:
	return _running


func mode() -> String:
	return _mode


## Start landmark tracking. Returns "" on success-in-flight or a reason token
## the caller flashes. The CAMERA GATE lives here: never two clients, §2.1.
## mode: "landmark" | "crowd" | "camera". "camera" publishes the lens to the
## deck over CameraX with NO inference — the way to get zoom/exposure/AE-lock
## on the deck's CAMERA source, none of which Godot's CameraServer can offer.
func start(lens: String, mode: String = "landmark") -> String:
	if _plugin == null:
		return "no-plugin"
	if _running:
		return ""
	if camera_engine != null and camera_engine.is_running():
		return "camera-busy"       # the deck's CAMERA source holds the lens
	if not OS.get_granted_permissions().has("android.permission.CAMERA"):
		OS.request_permission("android.permission.CAMERA")
		return "no-permission"     # grant lands async; user re-taps
	_lens = lens
	# mode: "landmark" (v1) | "crowd" (the M8a spike — logcat only, no snapshot).
	var ans := str(_plugin.call("start", mode, lens))
	return "" if ans == "ok" else ans


func lens_front() -> bool:
	return _lens == "front"


func stop() -> void:
	if _plugin != null and _running:
		_plugin.call("stop")
	_running = false
	_mode = "off"


## "cpu" | "gpu" — baked into the task options at graph build, so it applies
## on the NEXT start(). doc §8 keeps GPU available for phone-only rigs, which
## is exactly the M8a case; it was never wired from GDScript until now.
func set_delegate(d: String) -> void:
	if _plugin != null:
		_plugin.call("setDelegate", "gpu" if d == "gpu" else "cpu")


## M8b: the slot tracker. Fed once per NEW inference in crowd mode, from the
## plugin's raw boxes. Lives here (not in Kotlin) so tools/verify_crowd_tracker
## .gd can prove it with synthetic time — see the file's own header.
var crowd := CrowdTracker.new()


## Feed the tracker one inference's worth of raw boxes. Called from _poll on a
## seq advance; separate so the headless proof can drive it directly.
func _feed_crowd(now_ms: int) -> void:
	if _plugin == null:
		return
	var v: Variant = _plugin.call("getCrowdRaw")
	if v == null:
		return
	var f := PackedFloat32Array(v)
	if f.size() < 1:
		return
	var n := int(f[0])
	var dets: Array = []
	for i in n:
		var b := 1 + i * 4
		if b + 3 >= f.size():
			break
		dets.append({"x": f[b], "y": f[b + 1], "size": f[b + 2], "conf": f[b + 3]})
	crowd.mirror_output = lens_front()      # §4.2 — OUTPUT only
	crowd.feed(dets, now_ms)


## Crowd mode's live count: {n, max, conf}. Empty dict outside crowd mode.
func crowd_count() -> Dictionary:
	var out := {"n": 0, "max": 0, "conf": 0.0}
	if _plugin == null:
		return out
	var v: Variant = _plugin.call("getCrowdCount")
	if v == null or str(v) == "":
		return out
	var p := str(v).split("|")
	if p.size() == 3:
		out["n"] = int(p[0]); out["max"] = int(p[1]); out["conf"] = float(p[2])
	return out


## Exposure compensation in the device's own EV steps. Live.
func set_exposure(index: int) -> void:
	if _plugin != null:
		_plugin.call("setExposure", index)


## {index, min, max, step_ev} — device-specific; a slider built on guesses
## would be a knob that does nothing on half the phones.
func exposure_range() -> Dictionary:
	var out := {"index": 0, "min": 0, "max": 0, "step": 0.0}
	if _plugin == null:
		return out
	var v: Variant = _plugin.call("getExposureRange")
	if v == null:
		return out
	var p := str(v).split("|")
	if p.size() == 4:
		out["index"] = int(p[0]); out["min"] = int(p[1])
		out["max"] = int(p[2]); out["step"] = float(p[3])
	return out


## ⚠️ AE/AWB LOCK — the one that matters on a wall. Auto-exposure hunts as
## people move through frame, so a projected camera image pulses and shifts
## colour. Locking holds the look for a set.
func set_ae_lock(on: bool) -> bool:
	if _plugin == null:
		return false
	var r: Variant = _plugin.call("setAeLock", on)
	return r != null and bool(r)


## Torch — a venue light that is already in the rig.
func set_torch(on: bool) -> void:
	if _plugin != null:
		_plugin.call("setTorch", on)


## Zoom ratio — THE range control, and the only one that applies LIVE (no
## session rebuild, so no teardown and no wedge risk). Trades field of view
## for reach: a win for one performer, a tension for crowd coverage.
func set_zoom(ratio: float) -> void:
	if _plugin != null:
		_plugin.call("setZoom", ratio)


## What the camera GRANTED: {applied, min, max}. A requested ratio is not a
## granted one — devices clamp silently.
func zoom_state() -> Dictionary:
	var out := {"applied": 1.0, "min": 1.0, "max": 1.0}
	if _plugin == null:
		return out
	var v: Variant = _plugin.call("getZoom")
	if v == null:
		return out
	var p := str(v).split("|")
	if p.size() == 3:
		out["applied"] = float(p[0]); out["min"] = float(p[1]); out["max"] = float(p[2])
	return out


## Analysis stream height: 480 | 720 | 1080. §8 assumed 720; nothing ever
## asked CameraX for it, so every measurement to date — including the M3
## range figure — was taken at the ~640x480 default.
func set_analysis_res(h: int) -> void:
	if _plugin != null:
		_plugin.call("setAnalysisRes", h)


## Detector confidence floor (crowd mode). Lower = more distant people, more
## false boxes. The recall knob for the §13.7 range gate.
func set_crowd_score(v: float) -> void:
	if _plugin != null:
		_plugin.call("setCrowdScore", v)


## M8a variant sweep: "edl0_int8" | "edl0_fp16" | "edl0_fp32" | "ssd".
func set_crowd_model(name: String) -> void:
	if _plugin != null:
		_plugin.call("setCrowdModel", name)


func set_filter(min_cutoff: float, beta: float) -> void:
	if _plugin != null:
		_plugin.call("setFilter", min_cutoff, beta)


func rebaseline() -> void:
	if _plugin != null:
		_plugin.call("rebaseline")


func set_inference_rate(hz: int) -> void:
	if _plugin != null:
		_plugin.call("setInferenceRate", hz)


func set_input_path(p: String) -> void:
	if _plugin != null:
		_plugin.call("setInputPath", p)


func stats() -> String:
	if _plugin == null:
		return ""
	return str(_plugin.call("getStats"))


# ── tracker viewer taps (M2) — pull-model, zero cost while the panel is shut ──

func set_viewer(on: bool) -> void:
	if _plugin != null:
		_plugin.call("setViewer", on)


func preview_info() -> String:
	if _plugin == null:
		return ""
	return str(_plugin.call("getPreviewInfo"))


func preview_rgba() -> PackedByteArray:
	if _plugin == null:
		return PackedByteArray()
	var v: Variant = _plugin.call("getPreviewRgba")
	return v if v is PackedByteArray else PackedByteArray()


func debug_landmarks() -> PackedFloat32Array:
	if _plugin == null:
		return PackedFloat32Array()
	var v: Variant = _plugin.call("getDebugLandmarks")
	return v if v is PackedFloat32Array else PackedFloat32Array()


func presence() -> float:
	return value_at(IDX_PRESENCE)


func head() -> Vector3:
	return Vector3(value_at(IDX_HEAD_X), value_at(IDX_HEAD_Y), value_at(IDX_HEAD_Z))


func hand() -> Vector2:
	return Vector2(value_at(IDX_HAND_X), value_at(IDX_HAND_Y))


func hand_present() -> bool:
	return value_at(IDX_HAND_PRESENT) >= 0.5


# --- M6: the camera publish path (doc §2.1's resolution) --------------------
# Thin pass-throughs; TrackCameraSource owns the ExternalTexture and the rearm
# policy, this node owns the plugin handle. ⚠️ Every call here MUST come from
# the render thread (GDScript's own thread) — see TrackingPlugin's threading
# note: a SurfaceTexture belongs to the GL context that creates it.

## Arm publishing over an ExternalTexture's GL name. False = not armed (dead
## name, no plugin, or the plugin refused); the caller retries.
func preview_arm(tex_id: int, w: int, h: int) -> bool:
	if _plugin == null:
		return false
	var r: Variant = _plugin.call("setPreviewTexture", tex_id, w, h)
	# The has_method lesson (jni-plugin-returns): null = the method is missing
	# on this APK, which is a pre-M6 build, not a refusal.
	if r == null:
		return false
	return bool(r)


## Latch the newest camera frame. Call once per frame BEFORE rendering.
func preview_pump() -> bool:
	if _plugin == null:
		return false
	var r: Variant = _plugin.call("pumpPreview")
	return r != null and bool(r)


## The SurfaceTexture UV transform as a Projection. ⚠️ This carries the
## buffer's own crop/flip ONLY — NOT sensor orientation and NOT the front-lens
## mirror, whatever the M6 comments claimed. Those come from
## publish_transform() below, and both are needed to sample correctly.
func preview_transform() -> Projection:
	if _plugin == null:
		return Projection()
	var v: Variant = _plugin.call("getPreviewTransform")
	if v == null:
		return Projection()
	var f := PackedFloat32Array(v)
	if f.size() < 16:
		return Projection()
	# Android hands back a column-major 4x4; Projection's constructor takes
	# columns, so the mapping is direct.
	return Projection(
		Vector4(f[0], f[1], f[2], f[3]),
		Vector4(f[4], f[5], f[6], f[7]),
		Vector4(f[8], f[9], f[10], f[11]),
		Vector4(f[12], f[13], f[14], f[15]))


## CameraX's REAL publish transform, as a typed dictionary:
##   rot    — degrees the buffer must turn to sit upright (0/90/180/270)
##   mirror — true on the front lens (§4.2 audience view)
##   crop   — Rect2 in BUFFER PIXELS, the region CameraX wants shown
##   buf    — Vector2i, the buffer CameraX actually chose (often NOT our hint)
## Missing plugin or a pre-fix APK returns rot 0 / no mirror / empty crop,
## which samples the full frame exactly as before — the old behaviour, so an
## older APK degrades instead of breaking.
func publish_transform() -> Dictionary:
	var out := {"rot": 0, "mirror": false, "crop": Rect2(), "buf": Vector2i()}
	if _plugin == null:
		return out
	var v: Variant = _plugin.call("getPublishTransform")
	if v == null:
		return out                     # pre-fix APK: no such method
	var parts := str(v).split("|")
	if parts.size() < 8:
		return out
	out["rot"] = int(parts[0]) % 360
	out["mirror"] = int(parts[1]) == 1
	var l := int(parts[2]); var t := int(parts[3])
	var r := int(parts[4]); var b := int(parts[5])
	if r > l and b > t:
		out["crop"] = Rect2(l, t, r - l, b - t)
	out["buf"] = Vector2i(int(parts[6]), int(parts[7]))
	return out


## "frames|age_ms|armed" — age is milliseconds SINCE the last latch, or -1.
func preview_stats() -> String:
	if _plugin == null:
		return ""
	var v: Variant = _plugin.call("getPreviewStats")
	return "" if v == null else str(v)


func preview_clear() -> void:
	if _plugin != null:
		_plugin.call("clearPreviewTexture")


## M3 economy mode: the hand graph alone — no face landmarker, subject
## machine idle, HAND still modulates. Applies at the next start().
func set_hands_only(on: bool) -> void:
	if _plugin != null:
		_plugin.call("setHandsOnly", on)


func set_hands(on: bool) -> void:
	if _plugin != null:
		_plugin.call("setHands", on)


func debug_hand_landmarks() -> PackedFloat32Array:
	if _plugin == null:
		return PackedFloat32Array()
	var v: Variant = _plugin.call("getDebugHandLandmarks")
	return v if v is PackedFloat32Array else PackedFloat32Array()


func value_at(idx: int) -> float:
	if idx >= 0 and idx < _frame.size():
		return _frame[idx]
	return 0.0


func _process(_delta: float) -> void:
	if _plugin == null or not _running:
		return
	# doc §10 #3 answered at runtime: prefer the typed array; if the JNI
	# marshalling hands back anything else, fall to the string form once
	# and log it — same values, one parse.
	if not _use_str_fallback:
		var v: Variant = _plugin.call("getFrame")
		if v is PackedFloat32Array:
			_take(v)
			return
		if v is PackedFloat64Array or v is Array:
			_take(PackedFloat32Array(v))
			return
		_use_str_fallback = true
		print("[track] getFrame() marshalled as %s — using string fallback" % type_string(typeof(v)))
	var s := str(_plugin.call("getFrameStr"))
	if s.is_empty():
		return
	var parts := s.split("|")
	var out := PackedFloat32Array()
	out.resize(parts.size())
	for i in parts.size():
		out[i] = float(parts[i])
	_take(out)


func _take(f: PackedFloat32Array) -> void:
	if f.is_empty():
		return
	_frame = f
	if f[IDX_SEQ] != _last_seq:
		_last_seq = f[IDX_SEQ]
		# M8b: the tracker eats the same inference the lanes do, and BEFORE
		# them — a crowd trigger lane reading crowd_count on values_updated
		# must see this frame's slots, not last frame's.
		if _mode == "crowd":
			_feed_crowd(Time.get_ticks_msec())
		_feed_lanes()
		values_updated.emit()


# --- §5.4 trigger lanes ------------------------------------------------------
# name -> TriggerLane, fed once per NEW inference (before values_updated, so
# a consumer reading lane state on that signal sees this frame's verdicts).

var _lanes: Dictionary = {}


func add_lane(lane_name: String, lane: TriggerLane) -> void:
	_lanes[lane_name] = lane


func remove_lane(lane_name: String) -> void:
	if _lanes.has(lane_name):
		_lanes[lane_name].reset()
		_lanes.erase(lane_name)


func lanes() -> Dictionary:
	return _lanes


func _drop_lanes() -> void:
	for lane_name: String in _lanes:
		_lanes[lane_name].drop()


func _feed_lanes() -> void:
	if _lanes.is_empty():
		return
	var now := Time.get_ticks_msec()
	for lane_name: String in _lanes:
		var lane: TriggerLane = _lanes[lane_name]
		lane.feed(_lane_value(lane), now)


## The lane's channel value, PRESENCE-GATED: when the subject (or hand) is
## gone the lane is fed the released-direction extreme instead of the frozen
## hold — doc §5.2 freezes values for VISUAL consumers, but a trigger left
## live by a frozen head_z would hold an audio gate open forever. The dwell
## still debounces the synthetic release like any real one.
func _lane_value(lane: TriggerLane) -> float:
	var ch := lane.channel
	var gated := false
	if ch.begins_with("head") and value_at(IDX_PRESENCE) < 0.5:
		gated = true
	elif ch.begins_with("hand") and ch != "hand_present" \
			and value_at(IDX_HAND_PRESENT) < 0.5:
		gated = true
	if gated:
		return 1.0 if lane.invert else 0.0
	match ch:
		"head_x": return value_at(IDX_HEAD_X)
		"head_y": return value_at(IDX_HEAD_Y)
		"head_z": return value_at(IDX_HEAD_Z)
		"head_size": return value_at(IDX_HEAD_SIZE)
		"presence": return value_at(IDX_PRESENCE)
		"crowded": return value_at(IDX_CROWDED)
		"hand_x": return value_at(IDX_HAND_X)
		"hand_y": return value_at(IDX_HAND_Y)
		"hand_present": return value_at(IDX_HAND_PRESENT)
	return 0.0
