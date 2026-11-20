class_name MaskOverlay
extends ColorRect
## Raster (image) alpha mask over the composited output — the LAST stage inside
## OutputWorld, so it reaches the projector through DUAL·TEX like everything
## else. A greyscale PNG/JPG multiplies the frame: white = keep, black = masked
## out, feathered edges become soft edges on the wall (see raster_mask.gdshader
## for why a black overlay IS the multiply).
##
## Composes with the polygon masks rather than replacing them: RegionCompositor
## (or QuadWarp) produces the frame below; this node multiplies over whichever
## of them owns the output. pipeline builds it as the last OutputWorld child and
## full-rect anchors track HDMI-negotiated resolutions automatically.
##
## ⚠️ The black-overlay trick only equals a multiply because everything below
## sits on OutputWorld's BLACK clear color. Phase 2 dual-deck compositing
## (Deck B blended OVER Deck A) breaks that assumption — this stage must then
## become a real multiply (hint_screen_texture / BackBufferCopy) or mask each
## deck before the blend.
##
## Settings persist in user://regions.cfg ([raster_mask], alongside the polygon
## masks) — RegionEditor._save() loads-then-merges so the two never clobber
## each other.

const SAVE_PATH := "user://regions.cfg"
const FIT_NAMES: Array[String] = ["STRETCH", "FIT", "FILL"]
const IMAGE_EXTS: Array[String] = ["png", "jpg", "jpeg", "webp", "bmp"]

var mask_path: String = ""
var invert: bool = false
var opacity: float = 1.0
var fit_mode: int = 0          ## index into FIT_NAMES

var _save_pending: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color(1, 1, 1, 1)   # the shader owns the output; keep the rect neutral
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/raster_mask.gdshader")
	material = mat
	visible = false             # nothing masked until an image is set


## Load a greyscale image and start masking with it. Returns false (and keeps
## the previous state) if the file can't be read as an image.
func set_mask(path: String) -> bool:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return false
	# ⚠️ A single-channel PNG (the usual export for a matte) loads as L8, and an
	# L8 texture samples as BLACK on the phones' GLES driver — the whole output
	# went black on the Pixel 8 (2026-10-01). RGBA8 always samples as authored.
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()      # the mask is usually minified to the output res
	var tex := ImageTexture.create_from_image(img)
	(material as ShaderMaterial).set_shader_parameter("mask_tex", tex)
	mask_path = path
	visible = true
	_push_params()
	return true


func clear_mask() -> void:
	mask_path = ""
	visible = false


func set_invert(on: bool) -> void:
	invert = on
	_push_params()


func set_opacity(v: float) -> void:
	opacity = clampf(v, 0.0, 1.0)
	_push_params()


func set_fit(mode: int) -> void:
	fit_mode = clampi(mode, 0, FIT_NAMES.size() - 1)
	_push_params()


func cycle_fit() -> int:
	set_fit((fit_mode + 1) % FIT_NAMES.size())
	return fit_mode


func fit_name() -> String:
	return FIT_NAMES[fit_mode]


func _push_params() -> void:
	var mat := material as ShaderMaterial
	mat.set_shader_parameter("invert", invert)
	mat.set_shader_parameter("opacity", opacity)
	mat.set_shader_parameter("fit_mode", fit_mode)


# --- persistence (merged into the polygon-mask config) --------------------

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)         # keep the region_N sections; ignore "file missing"
	cfg.set_value("raster_mask", "path", mask_path)
	cfg.set_value("raster_mask", "invert", invert)
	cfg.set_value("raster_mask", "opacity", opacity)
	cfg.set_value("raster_mask", "fit", fit_mode)
	cfg.save(SAVE_PATH)


## Debounced save for slider-driven changes (opacity emits on every step).
func save_debounced() -> void:
	if _save_pending:
		return
	_save_pending = true
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		_save_pending = false
		save())


func load_saved() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	invert = bool(cfg.get_value("raster_mask", "invert", false))
	opacity = float(cfg.get_value("raster_mask", "opacity", 1.0))
	fit_mode = clampi(int(cfg.get_value("raster_mask", "fit", 0)), 0, FIT_NAMES.size() - 1)
	_push_params()
	var path := str(cfg.get_value("raster_mask", "path", ""))
	if path != "" and FileAccess.file_exists(path):
		set_mask(path)
