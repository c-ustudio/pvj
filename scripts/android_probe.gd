class_name AndroidProbe
extends RefCounted
## Two things only Android knows, asked for straight from GDScript: how hot the
## phone is, and what lens the camera has.
##
## No Kotlin plugin behind this. Godot 4.4+ can call Java by reflection —
## `Engine.get_singleton("AndroidRuntime")` hands over the app's Context and
## `JavaClassWrapper` wraps any class — so two read-only questions do not need
## an AAR rebuilt for them.
##
## ⚠️ EVERY CALL HERE CAN FAIL, AND GDSCRIPT CANNOT CATCH. A Java method that is
## not there (an older Android), or a value that comes back as a different type
## than expected, is a script error that ends the function it happened in. So:
##   - each probe sets its own "broken" latch BEFORE the first risky call and
##     clears it only after the last — a probe that dies half-way stays
##     switched off instead of erroring again on every poll;
##   - results live in static vars with harmless defaults, and callers read
##     those — never the return value of a call that may not have returned;
##   - the pipeline calls the probes deferred, from their own call stack, so a
##     failure in here cannot take a caller's function down with it.
## Off Android every probe is a no-op and the defaults stand.
##
## RUN ON A PIXEL 8 / ANDROID 17 (2026-09-30), both first time:
##   [heat] thermal status -1 -> 0 (headroom 0.63)
##   camera 0 of [0:1 1:0]: focal [6.9] mm, sensor 9.792x7.3728 mm -> 0.705
## and `adb shell cmd thermalservice override-status 3` (then `reset`) is how
## the heat path is exercised without cooking a phone.
##
## WHY HEAT. A Pixel 8 driving a projector over HDMI cannot charge (one port)
## and heats up; at PowerManager's THERMAL_STATUS_CRITICAL (4) Android DISABLES
## the external display — a black projector mid-set, and a replug to get it
## back. Status 3 (SEVERE) is the last warning. See
## CAMERA_PROCEDURAL_MASKS_SPEC.md §1a (it happened three times in one day).
##
## WHY THE LENS. CalibWall needs the camera's focal length in pixels and used
## to guess it (0.722 x the frame's long side, right for a Pixel 8 main camera).
## Camera2 publishes the lens's focal length and the sensor's size.

## PowerManager.THERMAL_STATUS_*: 0 none, 1 light, 2 moderate, 3 severe,
## 4 critical, 5 emergency, 6 shutdown. -1: not known.
static var thermal_status: int = -1
## PowerManager.getThermalHeadroom(10): a forecast, 1.0 = SEVERE in ten
## seconds' time. NAN when Android will not say.
static var thermal_headroom: float = NAN

## The back camera's lens: focal length over sensor width — multiply by the
## frame's long side for the focal length in px. 0: not known.
static var focal_per_width: float = 0.0
## What was read, for the log.
static var camera_note: String = "not asked"

static var _thermal_broken: bool = false
static var _camera_asked: bool = false
static var _power: Variant = null


static func available() -> bool:
	return OS.get_name() == "Android" and Engine.has_singleton("AndroidRuntime")


## Ask Android how hot it is. Cheap; meant to be called every few seconds.
## Leaves `thermal_status` at -1 for good if the question cannot be asked.
static func poll_thermal() -> void:
	if _thermal_broken or not available():
		return
	_thermal_broken = true   # until proven otherwise — see the header
	if _power == null:
		var ctx: Variant = Engine.get_singleton("AndroidRuntime").getApplicationContext()
		if ctx == null:
			return
		_power = ctx.getSystemService("power")
		if _power == null:
			return
	var status: Variant = _power.getCurrentThermalStatus()   # API 29
	if status == null:
		return
	thermal_status = int(status)
	_thermal_broken = false
	# The forecast is newer (API 30) and rate-limited by Android; never let it
	# take the status reading down with it.
	if OS.get_version().to_int() >= 11:
		_thermal_broken = true
		var ahead: Variant = _power.getThermalHeadroom(10)
		if ahead != null:
			thermal_headroom = float(ahead)
		_thermal_broken = false


## Ask Camera2 about the back camera, once. `prefer_id`: the camera the feed is
## actually using, when known ("0"); otherwise the first back-facing one.
static func ask_camera(prefer_id: String = "") -> void:
	if _camera_asked or not available():
		return
	_camera_asked = true
	camera_note = "failed part-way (see the log above)"
	var ctx: Variant = Engine.get_singleton("AndroidRuntime").getApplicationContext()
	if ctx == null:
		camera_note = "no Android context"
		return
	var manager: Variant = ctx.getSystemService("camera")
	if manager == null:
		camera_note = "no camera service"
		return
	# The characteristics are looked up by Key objects, which are static fields
	# of CameraCharacteristics — reached by Java reflection, since the wrapper
	# only exposes integer constants.
	var klass: Variant = JavaClassWrapper.wrap("java.lang.Class").forName(
		"android.hardware.camera2.CameraCharacteristics")
	if klass == null:
		camera_note = "no CameraCharacteristics class"
		return
	# ⚠️ .call("get", …), never .get(…): every Godot Object has a get() of its
	# own (property access), and that is what a plain .get() would reach.
	var key_facing: Variant = klass.getField("LENS_FACING").call("get", null)
	var key_focal: Variant = klass.getField("LENS_INFO_AVAILABLE_FOCAL_LENGTHS").call("get", null)
	var key_size: Variant = klass.getField("SENSOR_INFO_PHYSICAL_SIZE").call("get", null)
	if key_facing == null or key_focal == null or key_size == null:
		camera_note = "no characteristic keys"
		return
	var ids: Variant = manager.getCameraIdList()
	if ids == null:
		camera_note = "no camera list"
		return
	var chosen := ""
	var seen := ""
	for id: Variant in ids:
		var chars: Variant = manager.getCameraCharacteristics(str(id))
		if chars == null:
			continue
		var facing := _to_int(chars.call("get", key_facing))
		seen += "%s:%d " % [str(id), facing]
		# LENS_FACING_BACK = 1.
		if facing == 1 and (chosen == "" or str(id) == prefer_id):
			chosen = str(id)
	if chosen == "":
		camera_note = "no back camera among [%s]" % seen.strip_edges()
		return
	var back: Variant = manager.getCameraCharacteristics(chosen)
	var focals := _to_floats(back.call("get", key_focal))
	# SizeF prints as "9.8x7.35" — read it from that rather than trust how a
	# SizeF would come across the bridge.
	var size: Variant = back.call("get", key_size)
	var size_text := str(size.toString()) if size != null else ""
	var parts := size_text.split("x")
	var sensor_w := maxf(parts[0].to_float(), parts[1].to_float() if parts.size() > 1 else 0.0)
	if focals.is_empty() or sensor_w <= 0.0:
		camera_note = "camera %s: focal lengths %s, sensor '%s' — not usable" % [chosen, focals, size_text]
		return
	# A logical camera lists every lens behind it (main, ultra-wide). The one a
	# 1x preview uses is the main: the ratio nearest a normal phone camera's.
	var best := 0.0
	for f in focals:
		var ratio := f / sensor_w
		if best == 0.0 or absf(ratio - 0.72) < absf(best - 0.72):
			best = ratio
	camera_note = "camera %s of [%s]: focal %s mm, sensor %s mm" % [chosen, seen.strip_edges(), focals, size_text]
	# 45 to 100 degrees across; anything else is a number from the wrong place.
	if best < 0.42 or best > 1.2:
		camera_note += " — ratio %.3f out of range, not used" % best
		return
	focal_per_width = best
	camera_note += " -> %.3f x the frame's long side" % best


## A java.lang.Integer, however it crossed the bridge. -1 if it did not.
static func _to_int(v: Variant) -> int:
	if v == null:
		return -1
	if v is int or v is float:
		return int(v)
	return str(v.toString()).to_int()


## A float[] (or Float[]), however it crossed the bridge.
static func _to_floats(v: Variant) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if v == null:
		return out
	if v is PackedFloat32Array or v is PackedFloat64Array or v is Array:
		for f: Variant in v:
			out.append(float(f))
		return out
	# Still a Java object: read it element by element.
	var arrays: Variant = JavaClassWrapper.wrap("java.lang.reflect.Array")
	var n := int(arrays.getLength(v))
	for i in n:
		out.append(float(arrays.getFloat(v, i)))
	return out
