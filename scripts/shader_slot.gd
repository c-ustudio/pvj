class_name ShaderSlot
extends SubViewport
## Stage 2 of the PocketVJ pipeline.
##
## Runs a fragment shader over the ClipEngine output. Pass-through by default;
## call set_shader() to apply an effect. Output is read via get_texture().
##
## ── FEEDBACK HISTORY (frame-buffer effects) ──────────────────────────────
## Effects that need LAST frame's pixels (Trails and Slit-Scan today)
## call set_history_enabled(true). That switches on a second render target, a
## child SubViewport holding a 1-tap copy of this slot's own output, and binds
## it to the effect material as `prev_frame`:
##
##     ClipEngine ─► ShaderSlot (RT-A) ──texture──► QuadWarp (output)
##                      ▲   │
##           prev_frame │   │ samples
##                      │   ▼
##                 _history (RT-B) — a copy of RT-A
##
## ⚠️ THE TWO TARGETS SAMPLE EACH OTHER, AND THAT IS THE WHOLE TRICK. Neither
## is read and written in the same pass, so there is no read-write hazard —
## unlike sampling our own texture, which reads the BOUND render target and is
## undefined on the tile-based GPUs these phones use (it produces
## driver-dependent garbage on Mali rather than failing honestly). Whichever
## target renders second in a frame sees fresh data and the other sees a
## frame-old copy; either way a >=1 frame delay exists somewhere in the loop,
## which is all feedback needs.
##
## Fixed roles, not a per-frame ping-pong swap: the output texture stays the
## same object, so QuadWarp's source (and the mask-routing chooser that fights
## over it) never has to be re-pointed.
##
## ⚠️ THE HISTORY PASS IS A FULL-FRAME READ+WRITE — ~8 MB each way at 1080p.
## It is DISABLED unless an effect asks for it, so the other effects pay
## nothing. Do not switch it on globally "just in case".

## ── SLICE RING (multi-frame history) ────────────────────────────────────
## A SECOND, INDEPENDENT history mechanism, for effects that need genuinely OLD
## frames rather than just the last one. Effects declare "slices" in the bank and
## ShaderSlot builds a PING-PONGED PAIR of frame-sized atlases. Each frame,
## slice_write.gdshader rebuilds one of them from the other: the head band comes
## from this slot's INPUT, every other band is copied forward.
##
##     ClipEngine ─┬─► ShaderSlot (effect reads TEXTURE + slices) ─► output
##                 └─► atlas[dst] ← head band from input, rest copied from [src]
##                       (roles swap every frame; effect reads [dst])
##
## Band b holds band b's own rows as they were (write_index - b) mod bands frames
## ago, so the atlas is a stack of frozen moments that can be read straight out.
##
## ⚠️ COSTS ONE FULL-FRAME PASS PER FRAME — the same order as the feedback
## history above, which sustains 60 fps here. Still far cheaper than the
## alternatives: a chain of delay viewports is `bands` full passes, and Godot 4
## cannot render a SubViewport into a sampler2DArray layer at all.
##
## ⚠️ THE ORIGINAL DESIGN WAS CHEAPER AND DID NOT WORK. It wrote only the head
## band into a CLEAR_MODE_NEVER target and let retention carry the rest — 1/bands
## of a frame per frame. On the Pixel 8 (Mali G715, GL Compatibility) that atlas
## read BLACK everywhere the effect sampled it: 25-33% of the frame black against
## 0% for effect Off, including the band written that very frame. Tile-based
## renderers do not owe us a preserved target. Do not "optimise" this back.
##
## ⚠️ ONE ATLAS IS WRITTEN WHILE THE OTHER IS READ, AND THAT IS THE POINT.
## Sampling a surface while rendering into it is undefined on these GPUs, so the
## carry-forward copy is only legal because the pair alternates. It captures the
## INPUT rather than our output, so there is also no feedback loop.

const PASSTHROUGH := preload("res://shaders/passthrough.gdshader")
const SLICE_WRITE := preload("res://shaders/slice_write.gdshader")

var display: TextureRect
var _material: ShaderMaterial

# Feedback history — created lazily on the first set_history_enabled(true), so
# an install that never selects a feedback effect never allocates the target.
var _history: SubViewport
var _history_copy: TextureRect
var _history_on: bool = false

# Slice ring — see the class docs. Also built lazily, so an install that never
# selects a multi-frame effect never allocates the atlases.
# TWO of everything: the ring is ping-ponged, rendering into one while sampling
# the other, so it never reads the surface it is writing.
var _slice_vp: Array[SubViewport] = []
var _slice_rect: Array[TextureRect] = []
var _slice_mat: Array[ShaderMaterial] = []
var _slice_dst: int = 0        ## which atlas this frame renders INTO
var _slices_on: bool = false
var _slice_bands: int = 32
var _slice_axis: int = 0
var _slice_index: int = 0
## Forces one full-frame fill. Set on enable and on any `bands` change, because
## repartitioning the atlas leaves every strip boundary in the wrong place.
var _slice_prime: bool = true


func _ready() -> void:
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	transparent_bg = true

	_material = ShaderMaterial.new()
	_material.shader = PASSTHROUGH

	display = TextureRect.new()
	display.material = _material
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.stretch_mode = TextureRect.STRETCH_SCALE
	display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(display)

	# The history target tracks our resolution, which changes with the
	# FULL/HALF/FAST quality setting. Owned here so callers can resize this slot
	# without having to remember a second buffer exists.
	size_changed.connect(_sync_history_size)
	size_changed.connect(_sync_slice_size)


## Feed this slot's input (the previous stage's texture).
func set_input(tex: Texture2D) -> void:
	display.texture = tex
	# The ring captures the INPUT, so it has to follow the same swap — otherwise
	# it would keep filling bands from the previous clip's texture. BOTH atlases,
	# since either can be the destination on any given frame.
	for r in _slice_rect:
		r.texture = tex


## Swap the active effect shader.
func set_shader(shader: Shader) -> void:
	_material.shader = shader
	# A freshly-swapped material has no `prev_frame` bound. Re-bind when the new
	# effect wants history; harmless (the uniform just doesn't exist) when not.
	if _history_on:
		_bind_history()
	if _slices_on:
		_bind_slices()


## Access the material to set shader uniforms (e.g. audio-reactive params).
func get_shader_material() -> ShaderMaterial:
	return _material


## Turn the feedback history buffer on/off. Called from _apply_effect() with the
## effect's "history" flag — see the class docs for why this is gated.
func set_history_enabled(on: bool) -> void:
	if on == _history_on and (_history != null or not on):
		return
	_history_on = on
	if on:
		if _history == null:
			_build_history()
		_sync_history_size()
		_history.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_bind_history()
	elif _history != null:
		# DISABLED, not just hidden: an updating viewport costs its pass whether
		# or not anything samples the result.
		_history.render_target_update_mode = SubViewport.UPDATE_DISABLED
		# And say so, or an effect could keep sampling a FROZEN prev_frame and
		# hold a dead picture on screen. Harmless where the uniform doesn't exist.
		_material.set_shader_parameter("history_bound", false)


## Turn the multi-frame slice ring on/off. Called from _apply_effect() with the
## effect's "slices" flag — see the class docs for the mechanism and its risk.
func set_slice_history_enabled(on: bool) -> void:
	if on == _slices_on and (not _slice_vp.is_empty() or not on):
		return
	_slices_on = on
	if on:
		if _slice_vp.is_empty():
			_build_slices()
		_sync_slice_size()
		# The atlases hold whatever they held when we last switched off — which
		# may be a different clip, or undefined memory on the very first enable.
		_slice_prime = true
		_bind_slices()
	elif not _slice_vp.is_empty():
		for vp in _slice_vp:
			vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		# Say so, or an effect could keep sampling a FROZEN atlas and hold a dead
		# picture. Harmless where the uniform doesn't exist.
		_material.set_shader_parameter("slices_bound", false)


## Strip count, which is ALSO the depth in frames (the head advances one strip
## per frame). Repartitions the atlas, so it re-primes.
func set_slice_bands(n: int) -> void:
	var b := clampi(n, 2, 256)
	if b == _slice_bands:
		return
	_slice_bands = b
	_slice_index = 0
	# ⚠️ Every existing strip boundary is now in the wrong place, so the old
	# contents are not merely stale, they are misaligned. Repaint the lot.
	_slice_prime = true


## 0 = horizontal strips, 1 = vertical. Writer and effect must agree, so this
## sets both; a mismatch would write bands across one axis and read them on the
## other, which looks like the ring is broken rather than misconfigured.
func set_slice_axis(axis: int) -> void:
	var a := clampi(axis, 0, 1)
	if a == _slice_axis:
		return
	_slice_axis = a
	_slice_prime = true


func _process(_delta: float) -> void:
	if not _slices_on or _slice_vp.is_empty():
		return
	# One strip per frame — this IS the clock. Depth in frames therefore equals
	# the strip count, which is why `span` sets `bands`.
	_slice_index = (_slice_index + 1) % _slice_bands

	var dst := _slice_dst
	var src := 1 - _slice_dst
	var m := _slice_mat[dst]
	# ⚠️ SAMPLES THE OTHER ATLAS, NEVER ITS OWN TARGET. Reading a surface while
	# rendering into it is undefined on these tile-based GPUs; ping-ponging is
	# what makes the carry-forward copy legal.
	m.set_shader_parameter("prev_atlas", _slice_vp[src].get_texture())
	m.set_shader_parameter("band_index", _slice_index)
	m.set_shader_parameter("bands", _slice_bands)
	m.set_shader_parameter("axis", _slice_axis)
	m.set_shader_parameter("prime", _slice_prime)
	_slice_prime = false

	# UPDATE_ONCE, not ALWAYS: exactly one atlas is rebuilt per frame, so the
	# cost stays at ONE full-frame pass however many atlases exist.
	_slice_vp[dst].render_target_update_mode = SubViewport.UPDATE_ONCE
	_slice_vp[src].render_target_update_mode = SubViewport.UPDATE_DISABLED

	# Point the effect at the atlas being written THIS frame. Child SubViewports
	# render before their parent, so by the time the effect draws, dst is fresh.
	if _material != null and _material.shader != null:
		_material.set_shader_parameter("slices", _slice_vp[dst].get_texture())
		# The effect needs the head position to work out each strip's age. Pushed
		# every frame by definition — a stale write_index freezes the age ramp.
		_material.set_shader_parameter("write_index", _slice_index)
		_material.set_shader_parameter("bands", _slice_bands)

	_slice_dst = src


func _build_slices() -> void:
	# Two identical atlases; roles alternate every frame in _process().
	for i in 2:
		var vp := SubViewport.new()
		# NOT transparent: this pass writes every texel every frame.
		vp.transparent_bg = false
		vp.gui_disable_input = true
		# ⚠️ NOT CLEAR_MODE_NEVER. Retention was the original design and it does
		# NOT work on the Mali G715 under GL Compatibility — the atlas came back
		# black. Every texel is written explicitly now, so the clear mode is
		# irrelevant and nothing depends on driver-specific preservation.
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var r := TextureRect.new()
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_SCALE
		r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var m := ShaderMaterial.new()
		m.shader = SLICE_WRITE
		r.material = m
		# Capture the INPUT, never get_texture() — that is what keeps this a
		# history of real frames rather than a feedback loop.
		r.texture = display.texture
		vp.add_child(r)
		add_child(vp)
		_slice_vp.append(vp)
		_slice_rect.append(r)
		_slice_mat.append(m)


func _sync_slice_size() -> void:
	for vp in _slice_vp:
		vp.size = size
	if not _slice_vp.is_empty():
		# A resize reallocates the targets, so their contents are gone.
		_slice_prime = true


func _bind_slices() -> void:
	if _slice_vp.is_empty() or _material == null or _material.shader == null:
		return
	_material.set_shader_parameter("slices", _slice_vp[_slice_dst].get_texture())
	_material.set_shader_parameter("bands", _slice_bands)
	_material.set_shader_parameter("write_index", _slice_index)
	# Paired with the binding so the two can never disagree. RegionCompositor
	# uses the same effect array with no ring and pushes only `intensity`, so
	# there this stays false and the effect degrades to live passthrough.
	_material.set_shader_parameter("slices_bound", true)


func _build_history() -> void:
	_history = SubViewport.new()
	_history.transparent_bg = true
	# Nothing in here is interactive, and input picking over a full-screen rect
	# costs for no reason.
	_history.gui_disable_input = true
	_history_copy = TextureRect.new()
	_history_copy.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_history_copy.stretch_mode = TextureRect.STRETCH_SCALE
	_history_copy.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Straight copy — the passthrough shader, not the effect. The delay comes
	# from the two targets sampling each other, not from anything this pass does.
	var mat := ShaderMaterial.new()
	mat.shader = PASSTHROUGH
	_history_copy.material = mat
	_history.add_child(_history_copy)
	add_child(_history)
	# Sample OUR output. This is the second half of the cycle described above.
	_history_copy.texture = get_texture()


func _sync_history_size() -> void:
	if _history != null:
		_history.size = size


func _bind_history() -> void:
	if _history == null or _material == null or _material.shader == null:
		return
	_material.set_shader_parameter("prev_frame", _history.get_texture())
	# Paired with the binding ON PURPOSE, so the two can never disagree. An effect
	# whose hold/feedback branch emits garbage when `prev_frame` is unbound reads
	# this flag instead of trusting the sampler — RegionCompositor uses the same
	# effect array with NO history buffer and pushes only `intensity`, so there the
	# flag stays at its shader default of false and the effect degrades to
	# passthrough. Slit-scan depends on this; see slit_scan.gdshader.
	_material.set_shader_parameter("history_bound", true)
