extends SceneTree
## Headless check that a clip which never opens cannot hold a deck
## (ClipEngine.OPEN_TIMEOUT_SEC): it is reported (clip_failed), skipped, and the
## deck lands on the next clip that opens.
##
##   godot --headless --path <project> --script tools/verify_dead_clip.gd
##
## Checks:
##   1. A cue onto a damaged .mkv gives up within the timeout, reports it once,
##      and re-cues the clip after it, which opens.
##   2. A jump() onto the dead clip (NEXT) moves on to the clip after it, still
##      waiting to cut; once the clip is known dead, a jump onto it cuts straight
##      to a warm clip after it.
##   3. A play_index() onto it (the boot path, front decoder) plays the next one.
##   4. A healthy cue is never reported, and scan() forgets the dead list.
##
## Real GoZen decoders on two demo clips plus one damaged file, in a scratch
## folder under user:// that is removed again at the end. Headless draws no
## frames, so a cue never turns "warm" (_finish_cue waits for frame_post_draw)
## and a jump never cuts: "opened" here is the open timer being cleared by
## video_loaded. The cut itself is checked on the phone.

const DIR := "user://_verify_dead_clip"
const GOOD := ["res://demo_clips/pvj_loop_03.mp4", "res://demo_clips/pvj_loop_04.mp4"]

var _fails: int = 0
var _checks: int = 0
var _failed: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("FAIL: %s" % what)


func _wait(sec: float) -> void:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var a := DIR.path_join("a_good.mp4")
	var b := DIR.path_join("b_dead.mkv")
	var c := DIR.path_join("c_good.mp4")
	DirAccess.copy_absolute(GOOD[0], a)
	DirAccess.copy_absolute(GOOD[1], c)
	# A damaged MKV: a valid EBML header (DocType "matroska"), an open-ended
	# Segment, then nothing but zeros — no tracks, so no video stream to open.
	# (Random bytes are no good here: FFmpeg's probe can read them as some audio
	# format, and the desktop GoZen build then crashes instead of failing.)
	var junk := FileAccess.open(b, FileAccess.WRITE)
	junk.store_buffer(PackedByteArray([0x1A, 0x45, 0xDF, 0xA3, 0xA3,
		0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81, 0x01, 0x42, 0xF2, 0x81, 0x04,
		0x42, 0xF3, 0x81, 0x08, 0x42, 0x82, 0x88]))
	junk.store_buffer("matroska".to_ascii_buffer())
	junk.store_buffer(PackedByteArray([0x42, 0x87, 0x81, 0x04, 0x42, 0x85, 0x81, 0x02,
		0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
	var zeros := PackedByteArray()
	zeros.resize(65536)
	junk.store_buffer(zeros)
	junk.close()

	# Loaded at run time: clip_engine.gd names the Storage autoload, which does
	# not resolve while this tool compiles (the FeaturesS trap, core/features.gd).
	var engine: Node = load("res://scripts/clip_engine.gd").new()
	root.add_child(engine)
	await process_frame
	var abc: Array[String] = [a, b, c]
	engine.clips = abc.duplicate()
	engine.clip_failed.connect(func(p: String) -> void: _failed.append(p))

	# 3 first: the boot path opens straight into the front decoder.
	engine.play_index(1)
	await _wait(engine.OPEN_TIMEOUT_SEC + 2.0)
	_ok(_failed == [b], "play_index(dead) reported once: %s" % [_failed])
	_ok(engine.current_index == 2, "play_index(dead) plays the next clip (at %d)" % engine.current_index)

	# 1: a cue onto it skips straight past (already dead this scan) …
	engine.cue(1)
	await _wait(1.5)
	_ok(engine.cued_index() == 2 or engine.cued_index() == 0, "cue(dead) skipped (cued %d)" % engine.cued_index())
	# … and after a scan() forgets it, the timeout catches it again.
	engine.scan()
	engine.clips = abc.duplicate()
	_ok(not engine.is_dead(b), "scan() forgets the dead list")
	_failed.clear()
	engine.current_index = 0
	engine.cue(1)
	await _wait(engine.OPEN_TIMEOUT_SEC + 2.0)
	_ok(_failed == [b], "cue(dead) reported once after the timeout: %s" % [_failed])
	_ok(engine.cued_index() == 2 and engine._cue_wait < 0.0, "the next clip is cued and opened (cued %d, wait %.1f)" % [engine.cued_index(), engine._cue_wait])

	# 2: NEXT from a onto the dead b cuts to c.
	engine.scan()
	engine.clips = abc.duplicate()
	_failed.clear()
	engine.current_index = 0
	engine.jump(1)
	await _wait(engine.OPEN_TIMEOUT_SEC + 2.0)
	_ok(engine.cued_index() == 2 and engine._swap_when_ready, "jump(dead) moved on to the next clip, cut pending (cued %d)" % engine.cued_index())
	_ok(_failed == [b], "jump(dead) reported once: %s" % [_failed])

	# 2b: NEXT onto a clip already known dead, with the clip after it warm (the
	# phone's case: the boot cue gave up on it and re-cued #1). Headless never
	# warms a cue, so mark it warm by hand; the jump must cut, not wait.
	engine._swap_when_ready = false
	engine.cue(2)
	await _wait(1.0)
	engine.current_index = 0
	engine._cue_ready = true
	engine.jump(1)   # b is dead → c (index 2), which is "warm"
	_ok(engine.current_index == 2 and not engine._swap_when_ready, "jump(known dead) cuts to the warm clip after it (at %d)" % engine.current_index)

	# 2c: PREV over the dead clip steps back past it, not forward onto itself.
	engine._swap_when_ready = false
	engine.cue(0)
	await _wait(1.0)
	engine.current_index = 2
	engine._cue_ready = true
	engine.prev_clip()   # from c, b is dead → a (index 0), which is "warm"
	_ok(engine.current_index == 0, "prev over a dead clip lands on the one before it (at %d)" % engine.current_index)

	# 4: a healthy cue is never reported. (Let the post-swap auto-cue of 2c,
	# CUE_DELAY_SEC later, land first, or it replaces this cue.)
	await _wait(0.5)
	_failed.clear()
	engine.cue(0)
	await _wait(engine.OPEN_TIMEOUT_SEC + 1.0)
	_ok(_failed.is_empty() and engine.cued_index() == 0 and engine._cue_wait < 0.0, "a healthy cue opens and is not reported: %s" % [_failed])

	engine.queue_free()
	await process_frame
	for f: String in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(DIR)
	print("verify_dead_clip: %d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
