extends Control
## Compiles every effect shader against a REAL GL driver and quits.
##
## ⚠️ NEITHER `--headless --import` NOR A HEADLESS RUN COMPILES SHADERS — the
## importer does not, and the dummy renderer never runs them. A shader that fails
## to compile is then a SILENT no-op at runtime: Godot draws the material's
## texture unchanged, so the deck looks healthy while the effect does nothing.
## That cost a full session (slit-scan shipped with `return` inside fragment(),
## which Godot rejects, and it took a device log to find).
##
## Running the whole app as a compile check does not work on every dev box — on
## this one the mic init floods WASAPI errors and startup never completes — so
## this scene loads the shaders and nothing else.
##
##     Godot_v4.6.3-stable_win64_console.exe --path . \
##       --rendering-driver opengl3 --resolution 320x200 res://tools/shader_probe.tscn
##
## Then grep the output for "SHADER ERROR". Silence means they all compiled.
## This proves COMPILATION only — it says nothing about whether an effect looks
## right, and nothing about GL Compatibility on Mali specifically.

const SHADERS := [
	"res://shaders/slit_scan.gdshader",
	"res://shaders/slice_write.gdshader",
	"res://shaders/trails.gdshader",
	"res://shaders/displace.gdshader",
	"res://shaders/bloom.gdshader",
	"res://shaders/glitch.gdshader",
	"res://shaders/ascii.gdshader",
	"res://shaders/pixelate.gdshader",
	"res://shaders/kaleidoscope.gdshader",
	"res://shaders/rgb_shift.gdshader",
	"res://shaders/chromatic_aberration.gdshader",
	"res://shaders/feedback.gdshader",
	"res://shaders/solarize.gdshader",
	"res://shaders/passthrough.gdshader",
	"res://shaders/raster_mask.gdshader",
	"res://shaders/mask_checker.gdshader",
]


func _ready() -> void:
	var x := 0.0
	for path in SHADERS:
		var sh: Shader = load(path)
		if sh == null:
			print("[probe] MISSING %s" % path)
			continue
		var mat := ShaderMaterial.new()
		mat.shader = sh
		# A ColorRect big enough to actually rasterize — a zero-size control can
		# be culled before the material is ever bound, which would make this pass
		# vacuously.
		var r := ColorRect.new()
		r.material = mat
		r.position = Vector2(x, 0.0)
		r.size = Vector2(16, 16)
		add_child(r)
		x += 18.0
		print("[probe] loaded %s" % path)
	# Let the frames actually draw before quitting, or nothing gets compiled.
	for i in 5:
		await get_tree().process_frame
	print("[probe] done — any SHADER ERROR above is a real failure")
	get_tree().quit()
