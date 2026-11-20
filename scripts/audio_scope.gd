class_name AudioScope
extends Control
## AudioScope — the tuning display for the AUDIO INPUT panel (Session 23).
##
## A horizontal level bar carrying the three things the sliders below it cannot
## show: where the input level actually sits, where the NOISE FLOOR sits ON THE
## SAME SCALE, and whether the detector is firing. That triple is the whole point.
## The floor is a per-venue setting and the only honest way to place it is to watch
## room tone against it — a number in a slider says nothing about the room you are
## standing in.
##
## Reading the bar:
##   * the fill LEFT of the floor tick is dim — level down there cannot trigger.
##   * the fill RIGHT of it is bright — this is the range that fires.
##   * the peak-hold dash is what to aim the floor at: park the tick just above
##     where room tone peaks between tracks, and the deck stops cutting on silence.
##   * the border flashes on every detected onset, so "is it firing?" needs no log.
##
## It reads GlobalBus (level, beat_min_level) rather than being handed values: the
## panel's sliders write to GlobalBus, so reading back means the tick can never
## disagree with what the detector is actually using.
##
## ⚠️ The flash is the DETECTOR's onset (GlobalBus.beat), not the deck's cut. Those
## differ on purpose — the deck's 0.2 s refractory drops some onsets. This widget
## exists to tune the floor, so it shows what the floor gates, not what survives
## downstream.
##
## Redraw discipline matches M8Meter: _process samples at 60 Hz but only
## queue_redraw()s when a QUANTISED value changes, so a steady level costs nothing.

## Horizontal resolution of the redraw gate. Also the fill's step size, which is
## why it is coarse: a bar quantised to 1/48 still reads smoothly at this size and
## turns a drifting level into a handful of redraws a second instead of 60.
const SEGMENTS := 48
const BAR_H := 46.0
const VALUE_W := 110.0     ## right-hand readout column — matches _add_slider_row's
## Peak-hold: freeze at the new peak for HOLD seconds so a transient is readable,
## then fall. Slower than M8Meter's deck meter (0.4/s) because this one is read
## while adjusting a slider, not glanced at mid-performance.
const PEAK_HOLD_SEC := 1.2
const PEAK_DECAY := 0.35
## Onset flash decay. Quantised into FLASH_STEPS for the redraw gate, so one flash
## costs FLASH_STEPS redraws rather than one per frame for its whole fade.
const FLASH_DECAY := 3.0
const FLASH_STEPS := 6

var font: Font                    ## set by the owner; text is skipped when null

var _level: float = 0.0
var _peak: float = 0.0
var _hold: float = 0.0            ## seconds left on the peak hold
var _flash: float = 0.0           ## 1.0 on an onset, decays to 0

# Redraw gates — last DRAWN quantised state.
var _lit: int = -1
var _peak_seg: int = -1
var _floor_seg: int = -1
var _flash_step: int = -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # never intercept panel drag-to-scroll
	custom_minimum_size = Vector2(0, BAR_H)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	GlobalBus.beat.connect(_on_beat)
	# Lives inside a COLLAPSED accordion section for almost all of a set, and a
	# hidden Control still gets _process. Sleep unless actually on screen — the
	# signal connection above is cheap, the 60 Hz sampling is the part worth gating.
	# (visibility_changed propagates to descendants, so collapsing the section here
	# is what fires it, not this node's own `visible`.)
	visibility_changed.connect(_on_visibility)
	_on_visibility()


func _on_visibility() -> void:
	var on := is_visible_in_tree()
	set_process(on)
	if on:
		# Drop the held state on the way in. A peak dash frozen from the last time
		# this panel was open would be read as the CURRENT room — which is the one
		# question the widget exists to answer.
		_peak = 0.0
		_hold = 0.0
		_flash = 0.0


func _on_beat() -> void:
	_flash = 1.0


func _process(delta: float) -> void:
	_level = clampf(GlobalBus.level, 0.0, 1.0)
	if _level >= _peak:
		_peak = _level
		_hold = PEAK_HOLD_SEC
	elif _hold > 0.0:
		_hold -= delta
	else:
		_peak = maxf(_level, _peak - PEAK_DECAY * delta)
	_flash = maxf(0.0, _flash - FLASH_DECAY * delta)

	var lit := int(round(_level * float(SEGMENTS)))
	var pseg := clampi(int(ceil(_peak * float(SEGMENTS))) - 1, -1, SEGMENTS - 1)
	var fseg := clampi(int(round(GlobalBus.beat_min_level * float(SEGMENTS))), 0, SEGMENTS)
	var fstep := int(ceil(_flash * float(FLASH_STEPS)))
	if lit != _lit or pseg != _peak_seg or fseg != _floor_seg or fstep != _flash_step:
		_lit = lit
		_peak_seg = pseg
		_floor_seg = fseg
		_flash_step = fstep
		queue_redraw()


func _bar_w() -> float:
	return maxf(0.0, size.x - VALUE_W)


func _draw() -> void:
	var bw := _bar_w()
	if bw <= 0.0:
		return
	var seg_w := bw / float(SEGMENTS)
	var h := minf(size.y, BAR_H)

	# Track: a dim ghost of the full range, so the scale stays legible in silence.
	draw_rect(Rect2(0.0, 0.0, bw, h), M8Palette.GREEN.darkened(0.88))

	# Fill, split at the floor. Below it is dead range — drawn dim so an input that
	# is merely PRESENT but not triggerable is visibly different from one that is.
	var lit_w := float(_lit) * seg_w
	var floor_w := float(_floor_seg) * seg_w
	if lit_w > 0.0:
		var dead := minf(lit_w, floor_w)
		if dead > 0.0:
			draw_rect(Rect2(0.0, 0.0, dead, h), M8Palette.GREEN.darkened(0.55))
		if lit_w > floor_w:
			draw_rect(Rect2(floor_w, 0.0, lit_w - floor_w, h), M8Palette.GREEN)

	# The floor tick: full-height RED line with a notch above and below, so it reads
	# as a SETTING sitting on the scale rather than as part of the signal.
	draw_rect(Rect2(floor_w - 1.0, -3.0, 3.0, h + 6.0), M8Palette.RED)

	# Peak-hold dash — the thing you aim the tick at.
	if _peak_seg >= 0:
		draw_rect(Rect2(float(_peak_seg) * seg_w, 0.0, 3.0, h),
			M8Palette.TEXT)

	# Onset flash: a border round the whole bar. A border rather than a fill so it
	# never obscures the level it is reporting on.
	if _flash > 0.0:
		var a := float(_flash_step) / float(FLASH_STEPS)
		draw_rect(Rect2(0.0, 0.0, bw, h),
			Color(M8Palette.GREEN.r, M8Palette.GREEN.g, M8Palette.GREEN.b, a), false, 3.0)

	# Readout: the PEAK, not the instantaneous level — a 60 Hz number is unreadable,
	# and the peak is what the floor has to clear anyway. Drawn here rather than in a
	# Label so it inherits this widget's redraw gate instead of writing text every frame.
	if font != null:
		draw_string(font, Vector2(bw + 12.0, h * 0.5 + 8.0), "%.2f" % _peak,
			HORIZONTAL_ALIGNMENT_RIGHT, VALUE_W - 24.0, 22, M8Palette.TEXT)
