extends SceneTree
## Headless proof for TriggerLane (§5.4) + TrackingEngine's lane plumbing.
##
##   Godot --headless --path <project> --script tools/verify_trigger_lane.gd
##
## Time is synthetic (now_ms handed to feed), so dwell windows are exact and
## no frame loop is needed. The quantise tests emit BeatClock's signals by
## hand — the lane must not care who rings the bell, only that it fires on
## the boundary and never before. The gating tests drive the REAL
## TrackingEngine._lane_value over a faked snapshot frame: presence-gated
## channels must feed the released-direction extreme, not the frozen hold.

const TriggerLaneS := preload("res://scripts/trigger_lane.gd")
const TrackingEngineS := preload("res://scripts/tracking_engine.gd")

var _fails: int = 0


## Stands in for the BeatClock autoload (absent in --script mode).
class StubClock:
	extends Node
	signal beat(index: int)
	signal bar(index: int)


var _clock := StubClock.new()


func _check(what: String, got: Variant, want: Variant) -> void:
	var ok: bool
	if got is float and want is float:
		ok = absf(got - want) < 0.0001   # float32 storage vs double literals
	else:
		ok = got == want
	if ok:
		print("  ok   %s" % what)
	else:
		_fails += 1
		print("  FAIL %s: got %s want %s" % [what, got, want])


func _mklane(quantise: int = 0, invert: bool = false) -> TriggerLaneS:
	var l: TriggerLaneS = TriggerLaneS.new()
	l.channel = "head_z"
	l.enter_at = 0.6
	l.exit_at = 0.4
	l.dwell_ms = 250
	l.quantise = quantise
	l.invert = invert
	l.clock = _clock
	return l


func _initialize() -> void:
	var fired := [0]
	var released := [0]

	# 1. Free lane: hysteresis + dwell both ways.
	print("[1] free lane: dwell + hysteresis")
	var l := _mklane()
	l.fired.connect(func() -> void: fired[0] += 1)
	l.released.connect(func() -> void: released[0] += 1)
	l.feed(0.5, 0)          # between exit and enter: nothing
	l.feed(0.7, 100)        # past enter: dwell clock starts
	_check("no fire before dwell", fired[0], 0)
	l.feed(0.7, 200)        # 100 ms held — still short
	_check("no fire at 100ms", fired[0], 0)
	l.feed(0.3, 250)        # BOUNCE below enter: dwell clock must reset
	l.feed(0.7, 300)        # up again — fresh clock
	l.feed(0.7, 540)        # 240 ms — still one short
	_check("bounce reset the dwell", fired[0], 0)
	l.feed(0.7, 560)        # 260 ms held: FIRE
	_check("fired after full dwell", fired[0], 1)
	l.feed(0.5, 600)        # hysteresis gap: still live
	l.feed(0.7, 700)
	_check("no refire while live", fired[0], 1)
	_check("no release in the gap", released[0], 0)
	l.feed(0.35, 800)       # past exit: release dwell starts
	l.feed(0.35, 1000)
	_check("no release before dwell", released[0], 0)
	l.feed(0.35, 1060)      # 260 ms: RELEASE
	_check("released after full dwell", released[0], 1)
	l.feed(0.7, 1100)       # re-arm proven: full cycle again
	l.feed(0.7, 1360)
	_check("re-fired after re-arm", fired[0], 2)

	# 2. Inverted lane fires falling through.
	print("[2] inverted lane")
	var li := _mklane(0, true)
	li.enter_at = 0.4
	li.exit_at = 0.6
	var ifired := [0]
	li.fired.connect(func() -> void: ifired[0] += 1)
	li.feed(0.8, 0)
	li.feed(0.3, 100)       # below enter (inverted): dwell starts
	li.feed(0.3, 360)
	_check("inverted fired on fall", ifired[0], 1)

	# 3. Quantised lane: commit waits for the bell; reset cancels.
	print("[3] quantise")
	var lq := _mklane(1)
	var qfired := [0]
	lq.fired.connect(func() -> void: qfired[0] += 1)
	lq.feed(0.7, 0)
	lq.feed(0.7, 260)       # dwell done -> committed, pending
	_check("no fire before the beat", qfired[0], 0)
	_check("pending counts as live-ish", lq.is_live(), true)
	_clock.beat.emit(0)
	_check("fired ON the beat", qfired[0], 1)
	_clock.beat.emit(1)
	_check("one-shot: second beat is silent", qfired[0], 1)

	var lq2 := _mklane(1)
	var q2fired := [0]
	lq2.fired.connect(func() -> void: q2fired[0] += 1)
	lq2.feed(0.7, 0)
	lq2.feed(0.7, 260)      # pending...
	lq2.reset()             # ...cancelled
	_clock.beat.emit(2)
	_check("reset cancels the pending fire", q2fired[0], 0)

	# 4. drop(): released exactly once, and only if consumers saw the 1.
	print("[4] drop")
	var ld := _mklane()
	var dreleased := [0]
	ld.released.connect(func() -> void: dreleased[0] += 1)
	ld.feed(0.7, 0)
	ld.feed(0.7, 260)       # live
	ld.drop()
	_check("drop released a live lane", dreleased[0], 1)
	ld.drop()
	_check("second drop is silent", dreleased[0], 1)

	# 5. TrackingEngine._lane_value: presence gating feeds the release
	#    direction, never the frozen hold.
	print("[5] engine gating")
	var eng: Node = TrackingEngineS.new()
	var frame := PackedFloat32Array()
	frame.resize(17)
	frame[TrackingEngineS.IDX_PRESENCE] = 1.0
	frame[TrackingEngineS.IDX_HEAD_Z] = 0.8
	frame[TrackingEngineS.IDX_HAND_Y] = 0.9
	frame[TrackingEngineS.IDX_HAND_PRESENT] = 0.0
	eng._frame = frame
	var lz := _mklane()
	_check("present: real head_z", eng._lane_value(lz), 0.8)
	frame[TrackingEngineS.IDX_PRESENCE] = 0.0
	eng._frame = frame
	_check("absent: release-direction 0", eng._lane_value(lz), 0.0)
	var lzi := _mklane(0, true)
	_check("absent+invert: release-direction 1", eng._lane_value(lzi), 1.0)
	var lh := _mklane()
	lh.channel = "hand_y"
	_check("hand gone: hand_y gated to 0", eng._lane_value(lh), 0.0)
	frame[TrackingEngineS.IDX_HAND_PRESENT] = 1.0
	eng._frame = frame
	_check("hand back: real hand_y", eng._lane_value(lh), 0.9)
	var lp := _mklane()
	lp.channel = "presence"
	_check("presence channel is never gated", eng._lane_value(lp), 0.0)
	eng.free()

	if _fails == 0:
		print("VERIFY TRIGGER LANE: ALL PASS")
	else:
		print("VERIFY TRIGGER LANE: %d FAILURE(S)" % _fails)
	quit(1 if _fails > 0 else 0)
