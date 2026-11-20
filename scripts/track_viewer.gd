class_name TrackViewer
extends Control

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

## The tracker's eyes, on the phone (M2 — docs/MEDIAPIPE_MODULE.md).
##
## A PiP panel showing what MediaPipe actually sees: the camera frame, the
## chosen subject's landmark dots, a reticle on the FILTERED head point, a
## z-bar against the acquisition baseline, and the presence state. Phone-side
## only — the wall never carries debug chrome.
##
## Pull-model: while hidden this node does NOTHING (and tells the plugin so —
## setViewer(false) stops the Kotlin-side frame copies too). While visible it
## polls ~15 Hz worth of frames for one stride-packed copy each.

const PANEL_W := 480.0           ## on-screen width, px (height follows aspect)
const MARGIN := 12.0
const DOT := Color("#00FF41")    ## M8 green — the ONE accent
const DOT_DIM := Color(0.0, 1.0, 0.255, 0.35)
const RETICLE := Color("#EDEDED")
const BAR_BG := Color(1.0, 1.0, 1.0, 0.15)

var engine: TrackingEngine = null   ## injected by pipeline

var _tex_rect: TextureRect
var _overlay: Control
var _state_lbl: Label
var _texture: ImageTexture = null
var _last_seq := -1
var _img_w := 0
var _img_h := 0
var _landmarks: PackedFloat32Array = PackedFloat32Array()
var _hand: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	# Pro module (Features.MEDIAPIPE). pipeline never builds it in the public
	# build; this is the backstop if anything ever does.
	if not FeaturesS.is_pro():
		push_warning("[track_viewer] pro-only module in a public build — freed")
		queue_free()
		return
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color.BLACK
	style.border_color = Color(0.0, 1.0, 0.255, 0.5)
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)
	# Top-CENTER by default — clear of the left menu stack and the right
	# fader column — and DRAGGABLE (screen-touch events; the emulated-mouse
	# stream is dropped app-wide since S15).
	panel.position = Vector2((get_viewport_rect().size.x - PANEL_W) * 0.5, 140.0)
	panel.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventScreenDrag:
			panel.position += ev.relative
			var vp := get_viewport_rect().size
			panel.position = panel.position.clamp(Vector2.ZERO, vp - panel.size))
	add_child(panel)
	_panel = panel

	var stack := Control.new()
	stack.custom_minimum_size = Vector2(PANEL_W, PANEL_W * 0.75)  # resized per frame aspect
	panel.add_child(stack)

	# ⚠️ Every child is input-TRANSPARENT: touches must fall through to the
	# PanelContainer or its drag handler never fires (device-found — the
	# TextureRect ate the drags).
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_tex_rect = TextureRect.new()
	_tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_tex_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_tex_rect)

	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	stack.add_child(_overlay)

	_state_lbl = Label.new()
	_state_lbl.position = Vector2(6, 4)
	_state_lbl.add_theme_font_size_override("font_size", 13)
	_state_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_state_lbl)

	_stack = stack


var _stack: Control = null
var _panel: PanelContainer = null
var _rot_logged: int = -1


## Pipeline's toggle. Tells Kotlin, so hidden == zero cost end to end.
func set_open(on: bool) -> void:
	visible = on
	if engine != null:
		engine.set_viewer(on)
	_last_seq = -1


func _process(_delta: float) -> void:
	if not visible or engine == null or not engine.is_running():
		if visible and _state_lbl != null:
			_state_lbl.text = "TRACKING OFF"
		return

	var info := engine.preview_info()      # "w|h|rot|seq"
	var parts := info.split("|")
	if parts.size() != 4:
		return
	var seq := int(parts[3])
	if seq != _last_seq and seq > 0:
		_last_seq = seq
		var w := int(parts[0])
		var h := int(parts[1])
		var rot := int(parts[2])
		var bytes: PackedByteArray = engine.preview_rgba()
		if bytes.size() == w * h * 4:
			var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)
			if rot != _rot_logged:
				_rot_logged = rot
				print("[trackview] frame %dx%d rot=%d front=%s" % [w, h, rot, engine.lens_front()])
			# The landmarks live in the ROTATION-APPLIED (upright) frame —
			# rotate the image into the same space so the dots land on the
			# face. ⚠️ The two sensors mount at OPPOSITE orientations: the
			# mapping that made the FRONT image upright showed the REAR
			# sideways (device-observed), so rear takes the inverse spin.
			var cw := not engine.lens_front()
			if rot == 90:
				img.rotate_90(COUNTERCLOCKWISE if cw else CLOCKWISE)
			elif rot == 270:
				img.rotate_90(CLOCKWISE if cw else COUNTERCLOCKWISE)
			elif rot == 180:
				img.rotate_180()
			if _texture == null or img.get_width() != _img_w or img.get_height() != _img_h:
				_texture = ImageTexture.create_from_image(img)
				_img_w = img.get_width()
				_img_h = img.get_height()
				# Panel keeps PANEL_W, height follows the upright aspect.
				_stack.custom_minimum_size = Vector2(PANEL_W, PANEL_W * float(_img_h) / float(_img_w))
			else:
				_texture.update(img)
			_tex_rect.texture = _texture
			# §4.2: front-lens LANDMARKS are mirrored into audience view, so
			# the IMAGE must mirror too or the dots run opposite the face —
			# and a selfie view reads naturally as a mirror anyway.
			_tex_rect.flip_h = engine.lens_front()
		_landmarks = engine.debug_landmarks()
		_hand = engine.debug_hand_landmarks()
		_overlay.queue_redraw()

	# Label at ~10 Hz and only on change: a 60 Hz text write relayouts the
	# panel and drags the whole dot overlay into redrawing every frame —
	# measured on device as the FPS-10 bug.
	if Engine.get_process_frames() % 6 == 0:
		var present := engine.presence() >= 0.5
		var txt := ""
		if engine.mode() == "crowd":
			# ⚠️ Crowd mode builds NO face landmarker, so presence/z are dead and
			# the old text sat on "SEARCHING · z 0.00" forever — which reads as a
			# malfunction rather than a mode. Report what this mode actually
			# knows: how many people it can see.
			var c := engine.crowd_count()
			txt = "CROWD · %d seen (max %d) · conf %.2f" % [c["n"], c["max"], c["conf"]]
			present = int(c["n"]) > 0
		elif engine.mode() == "camera":
			txt = "CAMERA ONLY · no tracking"
		else:
			txt = "%s · z %.2f" % [
				"LOCKED" if present else "SEARCHING", engine.head().z]
		if txt != _state_lbl.text:
			_state_lbl.text = txt
			_state_lbl.add_theme_color_override("font_color",
				DOT if present else Color(1, 1, 1, 0.5))


func _draw_overlay() -> void:
	var size := _overlay.size
	# Landmark dots — raw MediaPipe output for the chosen subject, every 3rd
	# point (478 circles per redraw was a real cost; 159 reads the same).
	var n := _landmarks.size() / 2
	for i in range(0, n, 3):
		var p := Vector2(_landmarks[i * 2] * size.x, _landmarks[i * 2 + 1] * size.y)
		_overlay.draw_circle(p, 1.5, DOT_DIM)
	# Hand landmarks — all 21, full accent (a hand is sparse enough to afford it).
	var hn := _hand.size() / 2
	for i in hn:
		var hp := Vector2(_hand[i * 2] * size.x, _hand[i * 2 + 1] * size.y)
		_overlay.draw_circle(hp, 2.5, DOT)
	# Reticle — the FILTERED head point the consumers actually receive. The
	# gap between reticle and dots IS the One Euro lag, made visible.
	if engine != null and engine.presence() >= 0.5:
		var h := engine.head()
		var c := Vector2(h.x * size.x, h.y * size.y)
		_overlay.draw_arc(c, 14.0, 0.0, TAU, 24, RETICLE, 1.5)
		_overlay.draw_line(c - Vector2(20, 0), c - Vector2(8, 0), RETICLE, 1.5)
		_overlay.draw_line(c + Vector2(8, 0), c + Vector2(20, 0), RETICLE, 1.5)
		# z-bar, right edge: marker at head_z, tick at 0.5 (= the baseline).
		var bx := size.x - 10.0
		_overlay.draw_rect(Rect2(bx, 8, 4, size.y - 16), BAR_BG)
		_overlay.draw_line(Vector2(bx - 2, size.y * 0.5), Vector2(bx + 6, size.y * 0.5), BAR_BG, 1.0)
		var zy := 8.0 + (size.y - 16.0) * h.z
		_overlay.draw_rect(Rect2(bx - 1, zy - 3, 6, 6), DOT)
