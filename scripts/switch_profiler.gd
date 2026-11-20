class_name SwitchProfiler
extends RefCounted
## ⚠️ TEMPORARY INSTRUMENTATION — v0.3 "Preload Fix", Task 0. STRIP BEFORE SHIPPING.
##
## Measures ONE clip switch end to end and dumps a single block to stdout (logcat
## -s godot). Everything is static, so there is no node/autoload to wire up and the
## whole thing collapses to an `if not ENABLED: return` when turned off.
##
## Call sites (all marked with a `# PROFILE:` comment):
##   scripts/clip_engine.gd            begin() at the switch, marks around the open
##   addons/gde_gozen/video_playback.gd  the internals of the open (worker + GPU)
##   scripts/pipeline.gd               frame() every frame, mark() at HDMI push
##
## What it answers:
##   1. wall-clock for set_video_path() to return                (the "open")
##   2. wall-clock from that return to the FIRST RENDERED FRAME   (the "upload")
##   3. inside the open: CPU demux/codec init (GoZen worker thread, video.open())
##      vs GPU texture creation (main-thread ImageTexture.set_image + the frame
##      stall it causes, visible in the per-frame delta trace).

const ENABLED := false   # OFF: SEQ2 runs two engines — interleaved captures lie (and its header says strip before shipping)
const CAPTURE_FRAMES := 40   ## frame deltas recorded after a switch is requested
const HITCH_MS := 20.0       ## deltas above this are flagged in the trace

static var _t0: int = 0
static var _active: bool = false
static var _label: String = ""
static var _lines: PackedStringArray = PackedStringArray()
static var _frames: PackedFloat32Array = PackedFloat32Array()
static var _frames_left: int = 0

## Written by the GoZen WORKER thread (video.open() = pure CPU demux/codec init),
## read on the main thread only after wait_for_task_completion() — no race.
static var worker_open_usec: int = 0


static func now() -> int:
	return Time.get_ticks_usec()


static func is_active() -> bool:
	return ENABLED and _active


## Start a capture. Restarts cleanly if one was already running.
static func begin(label: String) -> void:
	if not ENABLED:
		return
	_label = label
	_t0 = Time.get_ticks_usec()
	_active = true
	_lines.clear()
	_frames.clear()
	_frames_left = CAPTURE_FRAMES
	worker_open_usec = 0


## Record an instant (ms since begin).
static func mark(what: String) -> void:
	if not ENABLED or not _active:
		return
	_lines.append("  t=%8.1f            %s" % [_ms_since_start(), what])


## Record a duration; `start_usec` comes from now().
static func span(what: String, start_usec: int) -> void:
	if not ENABLED or not _active:
		return
	var took := float(Time.get_ticks_usec() - start_usec) / 1000.0
	_lines.append("  t=%8.1f  %8.2f ms  %s" % [_ms_since_start(), took, what])


## Record a duration measured elsewhere (e.g. on the worker thread).
static func span_usec(what: String, usec: int) -> void:
	if not ENABLED or not _active:
		return
	_lines.append("  t=%8.1f  %8.2f ms  %s" % [_ms_since_start(), float(usec) / 1000.0, what])


## Feed one frame delta (from pipeline._process). Dumps when the window closes.
static func frame(delta: float) -> void:
	if not ENABLED or not _active:
		return
	_frames.append(delta * 1000.0)
	_frames_left -= 1
	if _frames_left <= 0:
		_dump()


static func _ms_since_start() -> float:
	return float(Time.get_ticks_usec() - _t0) / 1000.0


static func _dump() -> void:
	_active = false
	var out := PackedStringArray()
	out.append("")
	out.append("========== SWITCH PROFILE · %s ==========" % _label)
	out.append("  t = ms since the switch was requested")
	for l: String in _lines:
		out.append(l)

	# Per-frame trace: the GPU cost is deferred past the GDScript that queues it,
	# so it only shows up here, as the frame that actually stalls.
	var worst := 0.0
	var worst_i := -1
	var trace := PackedStringArray()
	for i: int in _frames.size():
		var ms := _frames[i]
		if ms > worst:
			worst = ms
			worst_i = i
		trace.append("%s%.1f%s" % ["[" if ms > HITCH_MS else "", ms, "]" if ms > HITCH_MS else ""])
	out.append("  frame deltas (ms, [hitch] > %.0f):" % HITCH_MS)
	out.append("    " + " ".join(trace))
	out.append("  worst frame: %.1f ms (frame +%d)" % [worst, worst_i])
	out.append("=========================================================")
	# One print() PER LINE. Godot's Android logger emits a whole print() as a single
	# log message, and logcat truncates it — a long capture lost its frame trace,
	# which is the most important part. Separate calls cannot be truncated away.
	for line: String in out:
		print(line)
