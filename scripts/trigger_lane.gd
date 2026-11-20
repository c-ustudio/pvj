class_name TriggerLane
extends RefCounted

## One tracking trigger (docs/MEDIAPIPE_MODULE.md §5.4): hysteresis + dwell
## + optional beat/bar quantise over a single conditioned channel. Owned by
## TrackingEngine, fed once per values_updated with the channel's value.
##
## The lane is a two-state machine (idle | live) with a symmetric dwell on
## both edges. `fired` means the wire shows 1 (/pvj/out/trigger/<name>),
## `released` means 0. Quantise defers the FIRE to the next grid boundary —
## the commitment happens at dwell completion; the boundary only times it.
## Release is never quantised: an audio gate must close when the performer
## leaves, not a bar later.

signal fired
signal released

var channel: String = "head_z"   ## key into TrackingEngine's channel map
var enter_at: float = 0.6        ## fire threshold
var exit_at: float = 0.4         ## re-arm threshold (the 0.2 gap is the point)
var dwell_ms: int = 250          ## hold past the threshold this long (both edges)
var quantise: int = 0            ## 0 free · 1 next beat · 2 next bar
var invert: bool = false         ## fire on falling through instead

## The grid — null means the BeatClock autoload, looked up by path at commit
## time (a compile-time BeatClock reference would bind this script to the
## running app; the headless verify injects a stub here instead).
var clock: Object = null

var _live: bool = false          ## current wire state (1 while live)
var _dwell_start_ms: int = -1    ## rising-edge dwell clock (-1 = not counting)
var _rel_start_ms: int = -1     ## falling-edge dwell clock
var _pending: bool = false       ## committed, waiting on the grid boundary
var _gen: int = 0                ## invalidates in-flight grid one-shots on reset


func is_live() -> bool:
	return _live or _pending


## Called once per new inference with the channel's current value.
func feed(value: float, now_ms: int) -> void:
	if _pending:
		return   # committed; the grid callback owns the next transition
	var past_enter := value <= enter_at if invert else value >= enter_at
	var past_exit := value >= exit_at if invert else value <= exit_at
	if not _live:
		if past_enter:
			if _dwell_start_ms < 0:
				_dwell_start_ms = now_ms
			elif now_ms - _dwell_start_ms >= dwell_ms:
				_commit()
		else:
			_dwell_start_ms = -1
	else:
		if past_exit:
			if _rel_start_ms < 0:
				_rel_start_ms = now_ms
			elif now_ms - _rel_start_ms >= dwell_ms:
				_live = false
				_rel_start_ms = -1
				released.emit()
		else:
			_rel_start_ms = -1


func _commit() -> void:
	_dwell_start_ms = -1
	if quantise <= 0:
		_fire()
		return
	_pending = true
	var g := _gen
	var src: Object = clock
	if src == null:
		var tree := Engine.get_main_loop() as SceneTree
		src = tree.root.get_node_or_null("BeatClock") if tree != null else null
	if src == null:
		_fire()   # no grid anywhere: fire free rather than never
		return
	var sig: Signal = src.bar if quantise >= 2 else src.beat
	sig.connect(func(_i: int) -> void: _on_grid(g), CONNECT_ONE_SHOT)


func _on_grid(g: int) -> void:
	if _pending and g == _gen:   # a reset() while waiting cancels the fire
		_fire()


func _fire() -> void:
	_pending = false
	_live = true
	_rel_start_ms = -1
	fired.emit()


## Force the wire shut NOW — tracking stopped, no more feeds coming. No
## dwell, no grid wait; emits released only if consumers ever saw the 1.
func drop() -> void:
	var was_live := _live
	reset()
	if was_live:
		released.emit()


## Back to idle without emitting — subject lost, lane reconfigured, stop().
func reset() -> void:
	_gen += 1
	_live = false
	_pending = false
	_dwell_start_ms = -1
	_rel_start_ms = -1
