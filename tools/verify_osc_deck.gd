extends SceneTree
## Headless check of the deck transport over OSC (/pvj/deck/next|prev|clip,
## OSC_NAMESPACE_SPEC.md §3, SESSION_45 Task 2).
##
##   godot --headless --path <project> --script tools/verify_osc_deck.gd -- --pro
##
## (`-- --pro`: OSC is a pro module; without it Main never builds the listener.)
##
## Checks:
##   1. OscDeck.resolve, pure: 1-based numbers (0 / past the end refused, never
##      wrapped), ClipLibrary id, folder path, file name (= what /pvj/out/clip
##      sends), bare name, case, first-in-deck-order on a shared name, junk.
##   2. On the wire, against the real Main scene: packets to 127.0.0.1:4855
##      reach the deck through the SAME calls as the nav cells / grid tap:
##      NEXT and PREV move the deck's target one clip, CLIP i and CLIP s pick
##      the clip asked for, an unknown clip leaves the deck alone (one log line).
##   3. The dead-clip skip comes along: CLIP onto a clip that never opened lands
##      on the one after it; PREV steps back over it.
##   4. /pvj/out/clip echoes a file name that /pvj/deck/clip accepts (round trip).
##   5. /pvj/lane_b/clip (deck B's twin): refused while lane B is unarmed; once
##      armed (/pvj/lane_b/arm 1) CLIP i and CLIP s pick deck B's clip and leave
##      deck A alone; refused when lane B's source isn't CLIPS and after disarm;
##      /pvj/out/lane_b/clip round-trips; the lane-B grid tap still jumps deck B
##      through the same _lane_b_jump.
##
## Headless draws no frames, so a jump never CUTS (the cue never turns warm —
## see verify_dead_clip.gd): "the deck's target" is the back decoder's cued
## index, which is what the cut will show. The cut itself is checked on the phone.

const OscOutputS := preload("res://scripts/osc_output.gd")

var _fails: int = 0
var _checks: int = 0
var _udp := PacketPeerUDP.new()


func _initialize() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
	print("%s  %s%s" % ["ok  " if cond else "FAIL", what, ("  — " + detail) if detail != "" else ""])


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _send(address: String, args: Array = []) -> void:
	_udp.put_packet(OscOutputS.encode_message(address, args))
	await _frames(4)


## The clip the deck is heading to: the cued one if a jump is pending, else
## what is on the front decoder.
func _target(e: Node) -> int:
	return e.cued_index() if e._swap_when_ready else e.current_index


func _run() -> void:
	_pure()

	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	main._tour_seen = true
	root.add_child(main)
	var e: Node = main.clip_engine   # untyped: naming ClipEngine compiles it before the autoloads exist
	var t0 := Time.get_ticks_msec()
	while (e.clips.size() < 4 or main._osc == null) and Time.get_ticks_msec() - t0 < 15000:
		await process_frame
	await _frames(10)
	_ok(main._osc != null and main._osc.is_listening(), "pro Main listens for OSC", "port %d" % main._osc_port)
	_ok(e.clips.size() >= 4, "the deck has clips to move through", "%d clips" % e.clips.size())
	if _fails > 0:
		_finish()
		return
	_udp.set_dest_address("127.0.0.1", main._osc_port)
	var n: int = e.clips.size()

	# 2. next / prev / clip i / clip s
	var start := _target(e)
	await _send("/pvj/deck/next")
	_ok(_target(e) == wrapi(start + 1, 0, n), "/pvj/deck/next moves the deck one clip on",
		"%d -> %d" % [start, _target(e)])
	_ok(main.status.text == "OSC: NEXT", "…and flashes OSC: NEXT", main.status.text)
	# PREV, like the button, steps back from the clip ON SCREEN — headless that
	# is still the boot clip (NEXT's cue never cuts here), not NEXT's target.
	var on_screen: int = e.current_index
	await _send("/pvj/deck/prev")
	_ok(_target(e) == wrapi(on_screen - 1, 0, n), "/pvj/deck/prev moves the deck one clip back from the one showing",
		"%d -> %d" % [on_screen, _target(e)])
	await _send("/pvj/deck/clip", [3])
	_ok(_target(e) == 2, "/pvj/deck/clip 3 (int) picks CLIP 3/N", "target %d" % _target(e))
	_ok(main.status.text == "OSC: CLIP 3/%d" % n, "…and flashes OSC: CLIP 3/N", main.status.text)
	await _send("/pvj/deck/clip", [2.0])
	_ok(_target(e) == 1, "/pvj/deck/clip 2.0 (float) picks CLIP 2/N", "target %d" % _target(e))
	var name4: String = e.clips[3].get_file()
	await _send("/pvj/deck/clip", [name4])
	_ok(_target(e) == 3, "/pvj/deck/clip \"%s\" (file name) picks it" % name4, "target %d" % _target(e))
	await _send("/pvj/deck/clip", [e.clips[0].get_file().get_basename().to_upper()])
	_ok(_target(e) == 0, "/pvj/deck/clip by bare name, any case, picks it", "target %d" % _target(e))
	var before := _target(e)
	var cued_before: int = e.cued_index()
	await _send("/pvj/deck/clip", ["no_such_clip.mp4"])
	await _send("/pvj/deck/clip", [n + 1])
	await _send("/pvj/deck/clip", [0])
	await _send("/pvj/deck/clip")
	_ok(_target(e) == before and e.cued_index() == cued_before,
		"unknown name, N+1, 0 and no arg all leave the deck alone")

	# 3. dead-clip skip (ClipEngine's own list; set as _give_up would)
	var dead: String = e.clips[2]
	e._dead[dead] = true
	await _send("/pvj/deck/clip", [3])
	_ok(_target(e) == 3, "/pvj/deck/clip onto a dead clip lands on the one after it", "target %d" % _target(e))
	# PREV from the clip after the dead one steps back over it. PREV goes through
	# jump() only once something is cued, so make sure the deck is on clip 4
	# from where prev starts.
	e.current_index = 3
	await _send("/pvj/deck/prev")
	_ok(_target(e) == 1, "/pvj/deck/prev steps back over the dead clip", "target %d" % _target(e))
	e._dead.erase(dead)

	# 4. /pvj/out/clip round-trips into /pvj/deck/clip
	var out_name: Variant = main._osc_out_snapshot()["/pvj/out/clip"]
	_ok(out_name is String and out_name != "", "/pvj/out/clip is a string (the file name)", str(out_name))
	if out_name is String and out_name != "":
		# Autoloads by node: their identifiers do not resolve under --script.
		var storage: Node = root.get_node("Storage")
		var lib: Node = root.get_node("ClipLibrary")
		var idx := OscDeck.resolve(out_name, e.clips, func(p: String) -> String: return storage.rel(p),
			func(id: String) -> String: return lib.path_for(id))
		_ok(idx >= 0 and e.clips[idx].get_file() == out_name, "…which /pvj/deck/clip resolves back to that clip",
			"index %d" % idx)

	await _lane_b(main, e)

	main.queue_free()
	await _frames(4)
	_finish()


## 5. Lane B over OSC. Deck B's "target" is read the same way as deck A's.
func _lane_b(main: Node, e: Node) -> void:
	var a_target := _target(e)
	main._lane_b_armed = false   # a clean start, whatever settings.cfg restored
	var status_before: String = main.status.text
	await _send("/pvj/lane_b/clip", [2])
	_ok(main.status.text == status_before, "/pvj/lane_b/clip while lane B is unarmed is refused (no flash)",
		main.status.text)

	await _send("/pvj/lane_b/arm", [1])
	var eb: Node = main._clip_engine_b   # untyped, like `e`
	var t0 := Time.get_ticks_msec()
	while (eb == null or eb.clips.size() < 4) and Time.get_ticks_msec() - t0 < 10000:
		await process_frame
		eb = main._clip_engine_b
	_ok(main._lane_b_armed and eb != null and eb.clips.size() >= 4, "/pvj/lane_b/arm 1 builds deck B with clips",
		"%d clips" % (eb.clips.size() if eb != null else 0))
	if eb == null or eb.clips.size() < 4:
		return
	await _frames(10)
	var nb: int = eb.clips.size()

	await _send("/pvj/lane_b/clip", [3])
	_ok(_target(eb) == 2, "/pvj/lane_b/clip 3 (int) picks deck B's CLIP 3/N", "target %d" % _target(eb))
	_ok(main.status.text == "OSC: B CLIP 3/%d" % nb, "…and flashes OSC: B CLIP 3/N", main.status.text)
	var name4: String = eb.clips[3].get_file()
	await _send("/pvj/lane_b/clip", [name4])
	_ok(_target(eb) == 3, "/pvj/lane_b/clip \"%s\" (file name) picks it on deck B" % name4, "target %d" % _target(eb))
	_ok(_target(e) == a_target, "…and deck A's target never moved", "A target %d" % _target(e))

	var b_before := _target(eb)
	await _send("/pvj/lane_b/clip", ["no_such_clip.mp4"])
	await _send("/pvj/lane_b/clip", [nb + 1])
	await _send("/pvj/lane_b/clip")
	_ok(_target(eb) == b_before, "unknown name, N+1 and no arg leave deck B alone")

	# The source gate. A NET source needs a link; set the field directly — the
	# gate under test is _lane_b_jump's, not _set_lane_b_source's.
	main._lane_b_source = 1   # LaneBSource.NET
	await _send("/pvj/lane_b/clip", [1])
	_ok(_target(eb) == b_before, "/pvj/lane_b/clip with lane B on NET is refused", "target %d" % _target(eb))
	main._lane_b_source = 0   # back to CLIP

	# /pvj/out/lane_b/clip: set by deck B's clip_changed, which only fires on a
	# cut (never headless) — so emit what the engine would, then round-trip it.
	var snap: Dictionary = main._osc_out_snapshot()
	_ok(snap.has("/pvj/out/lane_b/clip") and snap["/pvj/out/lane_b/clip"] is String,
		"/pvj/out/lane_b/clip is in the feedback frame, as a string")
	eb.clip_changed.emit(eb.clips[1].get_file(), 1, nb)
	var out_b: Variant = main._osc_out_snapshot()["/pvj/out/lane_b/clip"]
	_ok(out_b == eb.clips[1].get_file(), "deck B's cut sets /pvj/out/lane_b/clip to its file name", str(out_b))
	await _send("/pvj/lane_b/clip", [out_b])
	_ok(_target(eb) == 1, "…and /pvj/lane_b/clip resolves that name back to the clip", "target %d" % _target(eb))

	# The grid tap aimed at lane B goes through the same _lane_b_jump.
	var lib: Node = root.get_node("ClipLibrary")
	var strip_lane: int = main._strip_lane
	main._strip_lane = 1
	main._on_grid_clip_activated(lib.id_for_path(eb.clips[2]))
	await _frames(4)
	_ok(_target(eb) == 2, "the lane-B grid tap still jumps deck B", "target %d" % _target(eb))
	main._strip_lane = strip_lane

	await _send("/pvj/lane_b/arm", [0])
	var b_now := _target(eb)
	await _send("/pvj/lane_b/clip", [4])
	_ok(not main._lane_b_armed and _target(eb) == b_now, "after /pvj/lane_b/arm 0, /pvj/lane_b/clip is refused again")


func _pure() -> void:
	var clips: Array[String] = [
		"/c/Loop_A.mp4", "/c/pack1/beam.mp4", "/c/pack2/beam.mp4", "/c/zz.webm"]
	var rel := func(p: String) -> String: return p.trim_prefix("/c/")
	var ids := {"id-zz": "/c/zz.webm", "id-gone": "/c/gone.mp4"}
	var by_id := func(id: String) -> String: return ids.get(id, "")
	var r := func(arg: Variant) -> int: return OscDeck.resolve(arg, clips, rel, by_id)
	_ok(r.call(1) == 0 and r.call(4) == 3, "number: 1 and N are the first and last clip")
	_ok(r.call(0) == -1 and r.call(5) == -1 and r.call(-1) == -1, "number: 0, N+1 and negatives are refused, not wrapped")
	_ok(r.call(2.9) == 1, "number: a float is truncated (2.9 -> CLIP 2)")
	_ok(r.call("id-zz") == 3, "string: a ClipLibrary id")
	_ok(r.call("id-gone") == -1, "string: an id whose clip is not in the deck is refused")
	_ok(r.call("pack2/beam.mp4") == 2, "string: the folder path picks the second of two same-named clips")
	_ok(r.call("beam.mp4") == 1, "string: a shared file name picks the first in deck order")
	_ok(r.call("loop_a.MP4") == 0 and r.call("LOOP_A") == 0, "string: file name or bare name, any case")
	_ok(r.call("  zz  ") == 3, "string: surrounding spaces ignored")
	_ok(r.call("") == -1 and r.call("nope") == -1, "string: empty or unknown refused")
	_ok(OscDeck.resolve(1, [] as Array[String], rel, by_id) == -1, "an empty deck refuses everything")


func _finish() -> void:
	print("verify_osc_deck: %d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
