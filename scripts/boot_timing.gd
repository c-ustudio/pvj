class_name BootTiming
extends Node
## BootTiming — launch milestones and frame hitches in logcat (beta4, the
## storage-growth audit: docs/STORAGE_GROWTH_AUDIT.md). A tester reported PVJ
## getting slower session after session; these lines are what a before/after
## compares, without a profiler attached:
##
##     [boot] 380 ms storage ready (self-clean: 0 files, 0 KB)
##     [boot] 1630 ms pipeline ready
##     [boot] 1702 ms first clip on the deck
##     [boot] 4810 ms splash gone — interactive
##     [boot] first 20 s: 1103 frames, 4 over 50 ms, worst 180 ms
##     [perf] 30 s: 59.8 fps, 0 frames over 33 ms, worst 21 ms
##
## Times are Time.get_ticks_msec() — since the ENGINE started, not since the
## tap (`am start -W`'s TotalTime covers the Android side). Costs one tick read
## per frame; pipeline adds it first thing in _ready.

const WATCH_SEC := 20.0      ## the boot window the hitch line covers
const BOOT_HITCH_MS := 50    ## a boot frame this slow is a visible stall
const PERF_EVERY_SEC := 30.0 ## then one steady-state line per window
const PERF_SLOW_MS := 33     ## two vsyncs at 60 Hz: a dropped frame

static var _marked: Dictionary = {}

var _t0_us: int = 0          ## when this node started watching
var _last_us: int = 0
var _boot_done: bool = false
var _frames: int = 0
var _slow: int = 0
var _worst_ms: float = 0.0
var _win_us: int = 0         ## start of the current window


## One "[boot] <ms> <what>" line — the first time `what` is reached this run.
static func mark(what: String) -> void:
	if _marked.has(what):
		return
	_marked[what] = true
	print("[boot] %d ms %s" % [Time.get_ticks_msec(), what])


func _ready() -> void:
	_t0_us = Time.get_ticks_usec()
	_last_us = _t0_us
	_win_us = _t0_us


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var ms := float(now - _last_us) / 1000.0
	_last_us = now
	_frames += 1
	_worst_ms = maxf(_worst_ms, ms)
	if ms > (PERF_SLOW_MS if _boot_done else BOOT_HITCH_MS):
		_slow += 1
	if not _boot_done:
		if now - _t0_us >= int(WATCH_SEC * 1e6):
			print("[boot] first %.0f s: %d frames, %d over %d ms, worst %.0f ms"
				% [WATCH_SEC, _frames, _slow, BOOT_HITCH_MS, _worst_ms])
			_boot_done = true
			_reset(now)
	elif now - _win_us >= int(PERF_EVERY_SEC * 1e6):
		print("[perf] %.0f s: %.1f fps, %d frames over %d ms, worst %.0f ms"
			% [PERF_EVERY_SEC, _frames / (float(now - _win_us) / 1e6), _slow, PERF_SLOW_MS, _worst_ms])
		_reset(now)


func _reset(now: int) -> void:
	_frames = 0
	_slow = 0
	_worst_ms = 0.0
	_win_us = now
