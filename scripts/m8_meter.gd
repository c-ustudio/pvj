class_name M8Meter
extends Control
## M8Meter — the audio-reactive level meter, M8 MIXER style (Session 12).
##
## A vertical segmented bar, sized by whoever lays it out (it pairs with the FX
## intensity fader on the deck bar, matching its height). The track is a FIXED
## gradient from GREEN (#00FF41) at the bottom to error RED (#FF4422) at the top —
## colour maps to bar POSITION, not to level. We interpolate between the two
## existing M8Palette accents (Session 9b deliberately removed amber/orange, so no
## new entries). Discrete segments, not a smooth ramp — it's small and segments
## read cleaner. A peak-hold dash marks the recent peak and decays slowly.
## Reference: the M8's MIXER screen meters.
##
## Self-contained: it reads GlobalBus.level in _process and only queue_redraw()s
## when the lit-segment count or the peak segment actually changes (the same 60 Hz
## discipline as the rest of the UI). Segment height is derived from size.y, so the
## owner just sets size to match the fader.

const SEGMENTS := 14
const SEG_GAP := 4.0
const BAR_W := 26.0
## Peak falls this fraction of full-scale per second (slow hold, ~2.5 s from top).
const PEAK_DECAY := 0.4

var _level: float = 0.0
var _peak: float = 0.0
var _lit: int = -1        ## last drawn lit-segment count (redraw gate)
var _peak_seg: int = -1   ## last drawn peak segment (redraw gate)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # never intercept warp/UI input


func _process(delta: float) -> void:
	_level = clampf(GlobalBus.level, 0.0, 1.0)
	# Peak jumps up instantly, decays slowly (mixer peak-hold).
	if _level >= _peak:
		_peak = _level
	else:
		_peak = maxf(_level, _peak - PEAK_DECAY * delta)

	var lit := int(round(_level * float(SEGMENTS)))
	var pseg := clampi(int(ceil(_peak * float(SEGMENTS))) - 1, -1, SEGMENTS - 1)
	if lit != _lit or pseg != _peak_seg:
		_lit = lit
		_peak_seg = pseg
		queue_redraw()


func _seg_h() -> float:
	return (size.y - float(SEGMENTS - 1) * SEG_GAP) / float(SEGMENTS)


func _draw() -> void:
	var seg_h := _seg_h()
	if seg_h <= 0.0:
		return
	for i: int in SEGMENTS:
		# Fixed position→colour gradient: GREEN at the bottom, RED at the top.
		var t := float(i) / float(SEGMENTS - 1)
		var col := M8Palette.GREEN.lerp(M8Palette.RED, t)
		var top_y := size.y - float(i + 1) * seg_h - float(i) * SEG_GAP
		var rect := Rect2(0.0, top_y, size.x, seg_h)
		# Lit segments fill from the bottom; unlit segments stay as a dim ghost so the
		# full track (and its gradient) is always legible.
		draw_rect(rect, col if i < _lit else col.darkened(0.82))

	# Peak-hold dash: a short bright bar at the top of the recent-peak segment.
	if _peak_seg >= 0:
		var pt := float(_peak_seg) / float(SEGMENTS - 1)
		var pcol := M8Palette.GREEN.lerp(M8Palette.RED, pt).lightened(0.35)
		var py := size.y - float(_peak_seg + 1) * seg_h - float(_peak_seg) * SEG_GAP
		draw_rect(Rect2(0.0, py - 1.0, size.x, 3.0), pcol)
