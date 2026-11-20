class_name FrameSampler
extends RefCounted
## FrameSampler — the S4 frame-time instrument (SEQUENCER_2_SPEC §5).
##
## Spike S1's law, lifted out of its throwaway scene into the real app, so the
## full room can be measured where it actually runs: 0.5 s windows
## (t, fps, min, max, hitches), the first 5 s excluded from the distribution,
## then p50/p90/p95/p99/p99.9/max and hitches > 20 ms — the same percentile
## indexing as spike_s1.gd, so S4's numbers sit beside S1's without translation.
##
## Two deliberate differences from S1:
##   - spans come from Time.get_ticks_usec() between consecutive frames, not from
##     _process's delta (§5 method note: delta is what the frame loop reports,
##     not what the wall clock saw);
##   - a window's fps is its own frames / its own seconds, not the engine's
##     rolling counter.
##
## Off unless settings.cfg [perf] s4_run names a run (pipeline._start_s4). Every
## line goes to logcat as "[s4] ..." AND to user://s4_<run>_<unix>.csv, so a
## logcat flood (the 9a's) cannot eat a run.

const WINDOW_SEC := 0.5
const WARMUP_SEC := 5.0
const HITCH_MS := 20.0
const FLUSH_EVERY := 20          ## window lines between file flushes (~10 s)

var run := ""
var run_secs := 600.0
var done := false

var _log: FileAccess = null
var _last_us := -1
var _t := 0.0
var _win_t := 0.0
var _win_frames := 0
var _win_min_ms := 1.0e9
var _win_max_ms := 0.0
var _win_hitches := 0
var _win_lines := 0
var _all_ms := PackedFloat32Array()
var _notes := 0


## context: what the rig WAS when the run began — written as header lines so a
## run whose layers were not what the operator believed is caught by reading it.
func start(run_name: String, secs: float, context: Dictionary) -> void:
	run = run_name
	run_secs = maxf(secs, WARMUP_SEC + 1.0)
	var path := "user://s4_%s_%d.csv" % [run_name.validate_filename(),
		int(Time.get_unix_time_from_system())]
	_log = FileAccess.open(path, FileAccess.WRITE)
	_line("# s4 run=%s secs=%.0f started=%s file=%s" % [run, run_secs,
		Time.get_datetime_string_from_system(), ProjectSettings.globalize_path(path)])
	for k in context:
		_line("# ctx %s=%s" % [str(k), str(context[k])])
	_line("t,fps,win_min_ms,win_max_ms,hitches")


## Once per frame. The first call only seeds the clock.
func frame() -> void:
	if done or run == "":
		return
	var now := Time.get_ticks_usec()
	if _last_us < 0:
		_last_us = now
		return
	var dt_ms := float(now - _last_us) / 1000.0
	_last_us = now
	_t += dt_ms / 1000.0
	if _t >= WARMUP_SEC:
		_all_ms.append(dt_ms)
	_win_frames += 1
	_win_min_ms = minf(_win_min_ms, dt_ms)
	_win_max_ms = maxf(_win_max_ms, dt_ms)
	if dt_ms > HITCH_MS:
		_win_hitches += 1
	_win_t += dt_ms / 1000.0
	if _win_t >= WINDOW_SEC:
		_line("%.1f,%.1f,%.1f,%.1f,%d" % [_t, float(_win_frames) / _win_t,
			_win_min_ms, _win_max_ms, _win_hitches])
		_win_t = 0.0
		_win_frames = 0
		_win_min_ms = 1.0e9
		_win_max_ms = 0.0
		_win_hitches = 0
		_win_lines += 1
		if _log != null and _win_lines % FLUSH_EVERY == 0:
			_log.flush()   # a killed app must still leave most of its run on disk
	if _t >= run_secs:
		finish()


## An event that may spoil the windows around it (a stream going LOST) —
## timestamped into the same log, beside the numbers it affects.
func note(text: String) -> void:
	if done or run == "":
		return
	_notes += 1
	_line("# note t=%.1f %s" % [_t, text])


func finish() -> void:
	if done:
		return
	done = true
	var n := _all_ms.size()
	var sorted := _all_ms.duplicate()
	sorted.sort()
	_line("# summary run=%s frames=%d (first %.0f s excluded) notes=%d" % [run, n, WARMUP_SEC, _notes])
	if n > 0:
		for pct in [50.0, 90.0, 95.0, 99.0, 99.9]:
			var idx := mini(int(float(n) * pct / 100.0), n - 1)
			_line("# p%s_ms=%.2f" % [str(pct), sorted[idx]])
		_line("# max_ms=%.2f" % sorted[n - 1])
		var hitches := 0
		var total_ms := 0.0
		for v in _all_ms:
			total_ms += v
			if v > HITCH_MS:
				hitches += 1
		_line("# hitches_gt_%dms=%d (%.3f%%)" % [int(HITCH_MS), hitches,
			100.0 * float(hitches) / float(n)])
		_line("# mean_fps=%.2f" % (1000.0 * float(n) / total_ms))
	_line("# done")
	if _log != null:
		_log.close()
		_log = null


func _line(s: String) -> void:
	print("[s4] " + s)
	if _log != null:
		_log.store_line(s)
