class_name CameraEngine
extends SubViewport
## Stage 0 (alternative) of the PocketVJ pipeline — the LIVE CAMERA source.
##
## A SubViewport that grabs the rear camera via Godot's CameraServer/CameraFeed
## API and renders it as an RGB frame, so it is a drop-in alternative to the
## ClipEngine video source: feed get_texture() into the ShaderSlot exactly the
## same way and every existing effect shader works on the camera identically.
##
## Android delivers the frame as a SEPARATED YCbCr pair (FEED_YCBCR_SEP): a
## full-res luma plane + a half-res chroma plane. We sample both via CameraTexture
## resources and convert to RGB in camera_ycbcr.gdshader (BT.601). RGB feeds
## (some desktops) fall back to a straight pass-through.
##
## start()/stop() are idle by default — the camera is only powered while the
## pipeline's source is set to CAMERA (saves battery + the permission prompt only
## fires when the user actually picks the camera).

const YCBCR_SHADER := preload("res://shaders/camera_ycbcr.gdshader")
const PASSTHROUGH := preload("res://shaders/passthrough.gdshader")

signal camera_started(feed_name: String)
signal camera_failed(reason: String)

var display: TextureRect
var _material: ShaderMaterial
var _feed: CameraFeed
var _tex_y: CameraTexture       ## luma plane (also reused as the RGBA plane for RGB feeds)
var _tex_cbcr: CameraTexture    ## chroma plane (YCbCr feeds only)
# Whether the active feed is planar YUV (needs the YCbCr→RGB shader). Decided from
# the SELECTED FORMAT, not get_datatype(): on Android the datatype still reports RGB
# right after activate (before the first frame), which would wrongly pick passthrough
# and tint the image red. Android camera2 is always planar YUV, so default true there.
var _fmt_is_yuv: bool = (OS.get_name() == "Android")
var _running: bool = false
var _retries: int = 0
const MAX_RETRIES := 10         ## ~5 s of polling while the OS spins the camera up


func _ready() -> void:
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	transparent_bg = true

	_material = ShaderMaterial.new()
	_material.shader = YCBCR_SHADER

	display = TextureRect.new()
	display.material = _material
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	display.visible = false   # nothing to show until a feed is live
	add_child(display)


func is_running() -> bool:
	return _running


## Power up the rear camera and start rendering its frames. Idempotent.
func start() -> void:
	if _running:
		return
	if OS.get_name() == "Android" and not _has_camera_permission():
		# Asked HERE, in context (never at launch). The dialog is async and a
		# person reading it takes seconds — so wait for the ANSWER, instead of
		# burning the feed-discovery retries on it (that is what made the first
		# CAMERA selection on a fresh install fail with "reported none").
		var tree := get_tree()
		if not tree.on_request_permissions_result.is_connected(_on_permission_result):
			tree.on_request_permissions_result.connect(_on_permission_result)
		OS.request_permission("android.permission.CAMERA")
		return
	_retries = 0
	_attempt_start()


func _on_permission_result(permission: String, granted: bool) -> void:
	if permission != "android.permission.CAMERA":
		return
	get_tree().on_request_permissions_result.disconnect(_on_permission_result)
	if granted:
		_retries = 0
		_attempt_start()
	else:
		camera_failed.emit("camera permission denied — allow it in Android settings ▸ apps ▸ permissions")


func stop() -> void:
	_running = false
	display.visible = false
	if _tex_y != null:
		_tex_y.camera_is_active = false
	if _tex_cbcr != null:
		_tex_cbcr.camera_is_active = false
	if _feed != null:
		_feed.feed_is_active = false
	_feed = null


func _retry_start() -> void:
	if _retries >= MAX_RETRIES:
		camera_failed.emit("no camera feed (CameraServer reported none)")
		return
	_retries += 1
	get_tree().create_timer(0.5).timeout.connect(_attempt_start)


func _attempt_start() -> void:
	if _running:
		return
	if OS.get_name() == "Android" and not _has_camera_permission():
		_retry_start()   # still waiting on the permission grant
		return

	# Some platforms only populate feeds once monitoring is on.
	if CameraServer.has_method("set_monitoring_feeds"):
		CameraServer.set_monitoring_feeds(true)

	var feed := _find_rear_feed()
	if feed == null:
		_retry_start()
		return

	_feed = feed
	# Android requires a capture format to be chosen BEFORE the feed is activated
	# (otherwise CameraServer errors "format needs to be set before activating").
	_select_format(_feed)
	_feed.feed_is_active = true
	_wire_textures(_feed)
	_running = true
	_retries = 0
	_log("started feed '%s' (datatype %d, pos %d)" % [
		_feed.get_name(), _feed.get_datatype(), _feed.get_position()])
	camera_started.emit(_feed.get_name())


# Pick a capture format and select it. Android exposes many formats and leaves the
# selection at -1; without this the feed cannot activate. We prefer the largest
# ~16:9 format no taller than 1080p (so we don't grab a heavy multi-MP still size),
# falling back to whatever has the most pixels. No-op where no formats are exposed.
func _select_format(feed: CameraFeed) -> void:
	if not feed.has_method("get_formats"):
		return
	var formats: Array = feed.get_formats()
	if formats.is_empty():
		return
	var best: int = -1
	var best_score: float = -1.0
	for i: int in formats.size():
		var f: Dictionary = formats[i]
		var w: int = int(f.get("width", 0))
		var h: int = int(f.get("height", 0))
		if w <= 0 or h <= 0:
			continue
		var score: float = float(w * h)
		if absf(float(w) / float(h) - 16.0 / 9.0) > 0.06:
			score *= 0.5            # de-prioritise non-16:9 formats
		if h > 1080:
			score *= 0.2            # de-prioritise oversized (still-photo) formats
		if score > best_score:
			best_score = score
			best = i
	if best < 0:
		best = 0
	var chosen: Dictionary = formats[best]
	var fmt_str: String = str(chosen.get("format", "")).to_upper()
	if fmt_str != "":
		_fmt_is_yuv = fmt_str.contains("YUV") or fmt_str.contains("420") or fmt_str.contains("YCBCR")
	_log("formats=%d, chose #%d = %sx%s %s (yuv=%s)" % [formats.size(), best,
		str(chosen.get("width", "?")), str(chosen.get("height", "?")), fmt_str, str(_fmt_is_yuv)])
	feed.set_format(best, {})


# Prefer a back-facing camera; fall back to the first feed of any position so the
# camera still works on devices/desktops that report FEED_UNSPECIFIED.
func _find_rear_feed() -> CameraFeed:
	var first: CameraFeed = null
	for i: int in CameraServer.get_feed_count():
		var f := CameraServer.get_feed(i)
		if f == null:
			continue
		if first == null:
			first = f
		if f.get_position() == CameraFeed.FEED_BACK:
			return f
	return first


# Build the CameraTexture(s) for this feed and point the display TextureRect at
# them. Separated YCbCr (Android) → Y plane as TEXTURE + CbCr plane as a uniform,
# converted by the YCbCr shader. RGB feeds → single RGBA plane, pass-through.
func _wire_textures(feed: CameraFeed) -> void:
	var fid := feed.get_id()
	# Use the selected-format decision (reliable) over get_datatype() (still RGB
	# here on Android, before the first frame) so YUV feeds get the conversion.
	var sep := _fmt_is_yuv or feed.get_datatype() == CameraFeed.FEED_YCBCR_SEP

	_tex_y = CameraTexture.new()
	_tex_y.camera_feed_id = fid
	_tex_y.camera_is_active = true

	if sep:
		_tex_y.which_feed = CameraServer.FEED_Y_IMAGE
		_tex_cbcr = CameraTexture.new()
		_tex_cbcr.camera_feed_id = fid
		_tex_cbcr.which_feed = CameraServer.FEED_CBCR_IMAGE
		_tex_cbcr.camera_is_active = true
		_material.shader = YCBCR_SHADER
		_material.set_shader_parameter("cbcr_tex", _tex_cbcr)
	else:
		# RGB(A) feed — no conversion needed.
		_tex_y.which_feed = CameraServer.FEED_RGBA_IMAGE
		_material.shader = PASSTHROUGH

	display.texture = _tex_y
	display.visible = true


func _has_camera_permission() -> bool:
	return OS.get_granted_permissions().has("android.permission.CAMERA")


func _log(msg: String) -> void:
	print("[CameraEngine] %s" % msg)
