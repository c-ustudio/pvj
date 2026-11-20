extends Node
## BeatClock (autoload) — the ONE musical tap-tempo clock.
##
## Extracted from pipeline.gd's inline BPM/tap logic (sequencer build, Step 0).
## SEQUENTIAL clip-advance subscribes to `beat` today; the visual sequencer's
## auto-advance and launch quantization will subscribe to `bar` / `downbeat` and
## read `phase` next. RANDOM and LFO run their own rates and do NOT use this clock.
##
## NOTE — distinct from GlobalBus.beat, which is a MIC-DETECTED onset (drives the
## TAP-dot pulse, audio reactivity). This is the tap-tempo GRID. Two different
## "beats" on purpose.

signal beat(index: int)          ## every beat; index counts up monotonically from 0
signal bar(index: int)           ## fires ON the first beat of each bar; index counts bars
signal downbeat                  ## fires with `bar`, for callers that don't need the index
signal bpm_changed(value: float) ## tempo changed (tap or set_bpm)

const BPM_MIN := 40.0
const BPM_MAX := 300.0

## Read these; mutate bpm only via set_bpm().
var bpm: float = 120.0
var beats_per_bar: int = 4       ## API for the strip/auto-advance; nothing sets it yet
var phase: float = 0.0           ## 0..1 position within the CURRENT bar (recomputed per frame)
var running: bool = true         ## gate ticking without disconnecting listeners

var _accum: float = 0.0          ## seconds toward the next beat
var _beat_index: int = 0         ## beats since start (monotonic)
var _bar_index: int = 0          ## bars since start (monotonic)
var _beat_in_bar: int = 0        ## 0 .. beats_per_bar-1
var _tap_times: Array[float] = []   ## recent tap timestamps for tap-tempo

# Cross-device grid share (SEQ2 §3.4, law v2): a SLAVE closes a measured phase
# error smoothly instead of stepping — video tolerates a slow stretch, never a
# visible stutter. Positive remaining = our grid runs LATE and must catch up
# (time is ADDED); negative = we run early and the grid stretches.
var _slew_remaining: float = 0.0   ## seconds of grid shift still to apply
var _slew_rate: float = 0.0        ## |seconds of shift| per second of wall time


func _process(delta: float) -> void:
	if not running:
		return
	var period := 60.0 / bpm
	_accum += delta
	# Law v2's gentle correction: consume the pending slew a sliver per frame.
	# A negative step may not exceed _accum this frame (the grid stays
	# monotonic — we stretch toward the next beat, never un-emit one); the
	# remainder just carries to the following frames.
	if _slew_remaining != 0.0:
		var step := clampf(_slew_rate * delta, 0.0, absf(_slew_remaining)) \
			* signf(_slew_remaining)
		if step < 0.0:
			step = maxf(step, -_accum)
		_accum += step
		_slew_remaining -= step
	# `while`, not `if`: a long frame (e.g. a clip-load hitch) can span >1 beat and
	# must not silently drop beats off the grid.
	while _accum >= period:
		_accum -= period
		_advance_beat()
	# Fractional position through the bar, for the sequencer UI (0 at the downbeat).
	phase = (float(_beat_in_bar) + _accum / period) / float(beats_per_bar)


func _advance_beat() -> void:
	# Emit bar/downbeat ON beat 0 of the bar so the downbeat coincides with the beat.
	if _beat_in_bar == 0:
		bar.emit(_bar_index)
		downbeat.emit()
		_bar_index += 1
	beat.emit(_beat_index)
	_beat_index += 1
	_beat_in_bar = (_beat_in_bar + 1) % beats_per_bar


## Tap-tempo entry point (moved verbatim from pipeline._tap_tempo). Realigns the
## grid to the latest tap when it (re)computes a tempo — a tap IS a downbeat.
func tap() -> void:
	var t := Time.get_ticks_msec() / 1000.0
	# Drop taps older than 2s (treat as a new tempo entry).
	while _tap_times.size() > 0 and t - _tap_times[0] > 2.0:
		_tap_times.pop_front()
	_tap_times.append(t)

	if _tap_times.size() >= 2:
		var span := _tap_times[-1] - _tap_times[0]
		if span > 0.0:
			set_bpm((_tap_times.size() - 1) * 60.0 / span)
			reset_grid()   # align beats to the latest tap


func set_bpm(value: float) -> void:
	var v := clampf(value, BPM_MIN, BPM_MAX)
	if is_equal_approx(v, bpm):
		return
	bpm = v
	bpm_changed.emit(bpm)


## Realign the beat grid so the next beat is a downbeat. Called on tap and on a
## switch into SEQUENTIAL (preserving the old `_beat_accum = 0` behavior).
func reset_grid() -> void:
	_accum = 0.0
	_beat_in_bar = 0
	phase = 0.0


## Law v2's gentle half: shift the grid by `delta_sec` spread over `over_sec`
## of wall time (SEQ2 §3.4 as amended by spike S3 — correct over 2 bars, no
## visible stutter). A new call REPLACES the pending slew: the caller
## re-measures every bar, so this behaves as a proportional controller with a
## 2-bar time constant rather than stacking corrections.
func slew(delta_sec: float, over_sec: float) -> void:
	_slew_remaining = delta_sec
	_slew_rate = absf(delta_sec) / maxf(over_sec, 0.1)


## Law v2's hard half: jump the grid to the given bar-phase (0..1) NOW. Only
## for a FILTERED half-beat disagreement (the grids genuinely differ — e.g. a
## re-tapped master, or a slave resuming from Android pause). The monotonic
## beat/bar counters are untouched; only the position within the bar moves.
func snap_to_phase(target: float) -> void:
	var beats := fposmod(target, 1.0) * float(beats_per_bar)
	_beat_in_bar = int(beats) % beats_per_bar
	_accum = (beats - floor(beats)) * (60.0 / bpm)
	_slew_remaining = 0.0
	phase = fposmod(target, 1.0)
