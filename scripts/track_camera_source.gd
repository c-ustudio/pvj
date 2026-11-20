class_name TrackCameraSource
extends SubViewport
## M6 — THE LENS ON THE WALL (docs/MEDIAPIPE_MODULE.md §2.1's resolution).
##
## The deck's CAMERA source, backed by the TRACKING module's camera instead of
## Godot's CameraServer. TrackingPlugin binds a CameraX Preview beside the
## analyzer MediaPipe already eats, renders it into a SurfaceTexture latched
## onto this node's ExternalTexture, and the wall shows exactly what the
## tracker sees — one camera client, two consumers. That retires the §2.1
## mutual exclusion: SRC▸CAMERA no longer has to refuse while tracking runs.
##
## ── WHY A SUBVIEWPORT (the whole trick) ─────────────────────────────────
## An ExternalTexture may reach the canvas ONLY through a samplerExternalOES
## uniform — assigned as a CanvasItem texture, GLES3 binds the OES name to
## GL_TEXTURE_2D and the layer is silently black (pipeline.LINK_OES_SHADER
## says the same thing for the link layer). But the deck's whole chain —
## ShaderSlot, masks, regions, MixWorld, the DUAL·TEX blit — wants an ordinary
## 2D texture. So the OES texture is sampled ONCE here, through the material,
## into this SubViewport's render target; get_texture() then hands out a plain
## ViewportTexture and every downstream consumer stays untouched. The same
## shape as CameraEngine (SubViewport + TextureRect + ShaderMaterial), and
## deliberately the same public API — start/stop/is_running/get_texture plus
## the two signals — so pipeline routes between the two by swapping one
## reference.
##
## ── LIFECYCLE ────────────────────────────────────────────────────────────
## This node never starts the camera: TrackingEngine owns it. start() means
## "publish what tracking already has"; if tracking is not running, start()
## fails loudly through camera_failed and pipeline falls back exactly as it
## does for a dead CameraServer feed. The ExternalTexture is created ONCE and
## never replaced (recreating it would orphan the plugin's SurfaceTexture and
## every consumer's held reference — NetSource's law, same reason).
##
## ⚠️ GL context recreation kills the ExternalTexture's GL name; the plugin's
## SurfaceTexture is then latched onto nothing. _process notices (no frames
## while armed) and re-arms with the fresh name — NetSource's rearm tick,
## camera edition.

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

signal camera_started(feed_name: String)
signal camera_failed(reason: String)

## Sampled through the OES uniform. ⚠️ CORRECTED (Session 36): the
## SurfaceTexture matrix carries ONLY the buffer's own crop/flip — NOT the
## sensor rotation and NOT the front-lens mirror. M6 shipped believing it
## carried all three and put the front lens on the wall sideways. The real
## rotation/crop come from CameraX's TransformationInfo (publish_transform()).
##
## Sampling runs in UPRIGHT, audience-facing space and walks backwards:
##   fit (never distort) → mirror (§4.2) → un-rotate into buffer space →
##   CameraX crop rect → the SurfaceTexture matrix.
## ⚠️ Android's matrix wants GL's bottom-left UV origin; Godot's canvas UV is
## top-left, so V flips into Android's space FIRST and everything below is in
## that space.
##
## `cam_rot` is CameraX's own convention: degrees the BUFFER must turn
## CLOCKWISE to sit upright. To sample we invert it — rotate the upright
## coordinate COUNTER-clockwise by the same amount.
const OES_SHADER := """
shader_type canvas_item;
uniform samplerExternalOES cam_tex : filter_linear, repeat_disable;
uniform mat4 cam_xform;
uniform int cam_rot = 0;                            // 0 | 90 | 180 | 270
uniform bool cam_mirror = false;                    // front lens
uniform vec4 cam_crop = vec4(0.0, 0.0, 1.0, 1.0);   // x,y,w,h — buffer space
uniform float cam_fit = 1.0;                        // img aspect / view aspect
void fragment() {
	vec2 uv = vec2(UV.x, 1.0 - UV.y);
	// Cover: crop the long axis, never squash the picture.
	if (cam_fit > 1.0) uv.x = (uv.x - 0.5) / cam_fit + 0.5;
	else               uv.y = (uv.y - 0.5) * cam_fit + 0.5;
	// §4.2 audience view — mirrored in UPRIGHT space, exactly where the
	// landmarks are mirrored, so the wall and the dots can never disagree.
	if (cam_mirror) uv.x = 1.0 - uv.x;
	// Invert the sensor rotation (CCW by cam_rot).
	vec2 b = uv;
	if (cam_rot == 90)       b = vec2(1.0 - uv.y, uv.x);
	else if (cam_rot == 180) b = vec2(1.0 - uv.x, 1.0 - uv.y);
	else if (cam_rot == 270) b = vec2(uv.y, 1.0 - uv.x);
	b = cam_crop.xy + b * cam_crop.zw;
	COLOR *= texture(cam_tex, (cam_xform * vec4(b, 0.0, 1.0)).xy);
}
"""

## The ExternalTexture's own size is metadata only (OES sampling is
## normalized) — the real buffer size is whatever CameraX picks and tells the
## plugin. This is just the decoder-hint equivalent.
const TEX_W := 1280
const TEX_H := 720
const REARM_MS := 1000        ## how often a dead arm retries
const STALL_MS := 2000        ## armed but no frames this long = re-arm
const PUB_POLL_MS := 500      ## how often TransformationInfo is re-read

var engine: TrackingEngine = null     ## injected by pipeline; owns the plugin

var _display: TextureRect = null
var _material: ShaderMaterial = null
var _ext_tex: ExternalTexture = null
var _running: bool = false            ## publish INTENT (not the camera's state)
var _armed: bool = false              ## the plugin currently holds our GL name
var _last_arm_ms: int = -1
var _last_frame_ms: int = -1
var _frames: int = 0
## The cover-fit actually applied, published so consumers can map INTO
## this viewport's UV. <1 crops height, >1 crops width (§13.5).
var last_fit: float = 1.0
var _pub_rot: int = -1                ## last applied, -1 = never
var _pub_mirror: bool = false
var _pub_poll_ms: int = -1            ## TransformationInfo is a string call
## Added to whatever CameraX reports. CameraX computes rotation against the
## TARGET ROTATION we pin (ROTATION_90), which is the app's forced landscape
## — not necessarily the space this SubViewport samples in. Settings-driven
## so the four candidates can be tried with an app restart, not a rebuild.
var rot_offset: int = 270
## [tracking] publish_mirror: -1 auto (measured) | 0 never | 1 always
var mirror_override: int = 0


func _ready() -> void:
	# Pro module (Features.MEDIAPIPE). pipeline never builds it in the public
	# build; this is the backstop if anything ever does.
	if not FeaturesS.is_pro():
		push_warning("[track_camera_source] pro-only module in a public build — freed")
		queue_free()
		return
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	transparent_bg = true

	# 1x1 WHITE placeholder: geometry for the material to run over, and white
	# so the vertex COLOR the shader multiplies is exactly modulate. The
	# camera arrives through the uniform, never through .texture.
	var img := Image.create(1, 1, false, Image.FORMAT_RGB8)
	img.fill(Color.WHITE)

	var sh := Shader.new()
	sh.code = OES_SHADER
	_material = ShaderMaterial.new()
	_material.shader = sh

	_display = TextureRect.new()
	_display.name = "CamOES"
	_display.texture = ImageTexture.create_from_image(img)
	_display.material = _material
	_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_display.stretch_mode = TextureRect.STRETCH_SCALE
	_display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_display.visible = false        # nothing to show until the first latch
	add_child(_display)


func is_running() -> bool:
	return _running


## Publish tracking's camera onto this viewport. Idempotent. Refuses (loudly,
## through camera_failed) when tracking is not holding the lens — the caller
## falls back to CameraEngine or to the video source, its choice.
func start() -> void:
	if _running:
		return
	if engine == null or not engine.available():
		camera_failed.emit("no tracking plugin (desktop or pre-M6 APK)")
		return
	if not engine.is_running():
		camera_failed.emit("tracking is not running — TRK ON first")
		return
	_running = true
	_frames = 0
	_last_frame_ms = -1
	if not _arm():
		# Not fatal: the arm tick retries every REARM_MS. The wall stays black
		# until a frame lands, which is honest — and the status row says why.
		_log("arm deferred — retrying")


func stop() -> void:
	if not _running:
		return
	_running = false
	_display.visible = false
	if _armed and engine != null:
		engine.preview_clear()
	_armed = false


## True once real camera frames are landing — the row's LIVE tell, and what
## pipeline waits for before believing the wall.
func has_frames() -> bool:
	return _frames > 0


func stats() -> String:
	if engine == null:
		return ""
	return engine.preview_stats()


# ── the arm / rearm machinery ────────────────────────────────────────────

## Hand the plugin our GL name. The name is fetched FRESH every time: the
## first call materializes it, and after a GL context recreation the old one
## is dead — this is the line that revives the path.
func _arm() -> bool:
	_last_arm_ms = Time.get_ticks_msec()
	_ensure_texture()
	var tex_id := _ext_tex.get_external_texture_id()
	if tex_id <= 0:
		_armed = false
		return false        # renderer hasn't materialized the name yet
	if not engine.preview_arm(tex_id, TEX_W, TEX_H):
		_armed = false
		return false
	_armed = true
	_material.set_shader_parameter("cam_tex", _ext_tex)
	_log("armed on GL name %d" % tex_id)
	return true


func _ensure_texture() -> void:
	if _ext_tex != null:
		return
	_ext_tex = ExternalTexture.new()
	_ext_tex.size = Vector2(TEX_W, TEX_H)


func _process(_delta: float) -> void:
	if not _running:
		return
	var now := Time.get_ticks_msec()

	if not _armed:
		if now - _last_arm_ms >= REARM_MS:
			_arm()
		return

	# Latch BEFORE this frame renders, every frame — the plugin drops nothing
	# and returns false when there is simply no new camera frame yet.
	if engine.preview_pump():
		_material.set_shader_parameter("cam_xform", engine.preview_transform())
		# CameraX can re-issue TransformationInfo at any time (a rotation or a
		# resolution change re-fires the listener), so this is polled, not
		# latched once. It is a string call, hence PUB_POLL_MS rather than
		# every frame.
		if _pub_poll_ms < 0 or now - _pub_poll_ms >= PUB_POLL_MS:
			_pub_poll_ms = now
			_apply_publish_transform()
		_last_frame_ms = now
		_frames += 1
		if _frames == 1:
			_display.visible = true
			camera_started.emit("tracking camera")
			_log("first frame — the lens is on the wall")
	elif _last_frame_ms >= 0 and now - _last_frame_ms >= STALL_MS:
		# Frames stopped with the arm still nominally good: a GL context
		# recreation (dead name) or a session rebuild underneath us. Re-arm
		# rather than sit on a frozen frame forever.
		_log("stalled %d ms — re-arming" % (now - _last_frame_ms))
		_armed = false
		_last_frame_ms = -1
		engine.preview_clear()
	elif _last_frame_ms < 0 and now - _last_arm_ms >= STALL_MS:
		# Armed but the first frame never came (tracking stopped between the
		# gate check and the arm, or CameraX refused the surface).
		_armed = false
		engine.preview_clear()


## Push CameraX's real rotation/crop/mirror into the shader. Cheap and
## idempotent; logs only when the ORIENTATION actually changes, so the device
## log carries one honest line per state instead of a stream.
func _apply_publish_transform() -> void:
	var pub := engine.publish_transform()
	var rot := (int(pub.get("rot", 0)) + rot_offset) % 360
	# ⚠️ INVERTED, and measured rather than guessed. Composing the shader chain
	# for the device's rot=270 and its ST matrix ((u,v)->(v,1-u)) gives:
	#     mirror=true  -> samples (U, V)    raw buffer, NOT mirrored
	#     mirror=false -> samples (1-U, V)  mirrored
	# i.e. the rotation compensation and the ST matrix ALREADY contribute one
	# horizontal flip between them, so applying the lens-facing flag directly
	# left the FRONT deck un-mirrored (disagreeing with the viewer, which does
	# flip_h) and the REAR deck mirrored (a rear camera must show the scene as
	# it is). Inverting fixes BOTH at once. Overridable because this is a
	# composition result, not a law: -1 auto, 0 never, 1 always.
	var mirror := not bool(pub.get("mirror", false))
	if mirror_override == 0:
		mirror = false
	elif mirror_override == 1:
		mirror = true
	var crop: Rect2 = pub.get("crop", Rect2())
	var buf: Vector2i = pub.get("buf", Vector2i())

	# Crop arrives in BUFFER PIXELS with a TOP-LEFT origin (android.graphics
	# .Rect); the shader samples bottom-left. Flip Y here so the shader stays
	# in one space. No crop (or a pre-fix APK) = the whole frame.
	var c := Vector4(0.0, 0.0, 1.0, 1.0)
	var cw := float(buf.x)
	var ch := float(buf.y)
	if crop.size.x > 0.0 and crop.size.y > 0.0 and cw > 0.0 and ch > 0.0:
		c = Vector4(
			crop.position.x / cw,
			(ch - crop.end.y) / ch,
			crop.size.x / cw,
			crop.size.y / ch)
		cw = crop.size.x
		ch = crop.size.y

	# ⚠️ A quarter turn swaps which buffer axis is the image's width — but the
	# SurfaceTexture matrix ALREADY applies a quarter turn of its own (measured
	# on device: x=(0,-1) y=(1,0), i.e. (u,v) -> (v,1-u)). The displayed aspect
	# therefore follows the NET of the two, not ours alone. Reading only `rot`
	# here inverted the test and over-cropped the wall by 1.78x.
	var m := engine.preview_transform()
	var mat_swaps := absf(m.x.y) > absf(m.x.x)      # u drives the OUTPUT y axis
	var our_swap := rot == 90 or rot == 270
	if mat_swaps != our_swap:                        # XOR — net quarter turn
		var t := cw
		cw = ch
		ch = t
	var fit := 1.0
	if cw > 0.0 and ch > 0.0 and size.x > 0 and size.y > 0:
		fit = (cw / ch) / (float(size.x) / float(size.y))

	_material.set_shader_parameter("cam_rot", rot)
	_material.set_shader_parameter("cam_mirror", mirror)
	_material.set_shader_parameter("cam_crop", c)
	_material.set_shader_parameter("cam_fit", fit)
	last_fit = fit

	if rot != _pub_rot or mirror != _pub_mirror:
		_pub_rot = rot
		_pub_mirror = mirror
		_log("xform rot=%d (cameraX %d + offset %d) mirror=%s buf=%dx%d fit=%.3f"
				% [rot, int(pub.get("rot", 0)), rot_offset, str(mirror),
				   buf.x, buf.y, fit])
		# ⚠️ THE decisive datum: if CameraX says rot=0 but the picture is a
		# quarter-turn out, the rotation is either riding in this matrix (and
		# the shader is mishandling it) or the matrix is identity and nothing
		# is carrying it at all. Printed once per orientation, never per frame.
		_log("  ST matrix x=%s y=%s w=%s swaps=%s" % [str(m.x), str(m.y), str(m.w), str(mat_swaps)])


func _log(msg: String) -> void:
	print("[trackcam] %s" % msg)
