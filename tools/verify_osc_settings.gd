extends SceneTree
## Headless check of LIB ▸ OSC, the OSC OUT settings rows (SESSION_45 Task 1,
## OSC_NAMESPACE_SPEC.md §4).
##
##   godot --headless --path <project> --script tools/verify_osc_settings.gd -- --pro
##
## Checks:
##   1. OscOutput.parse_targets / status_line, pure: good lists normalise,
##      bad entries (no port, low port, host name, junk port, a 9th target) are
##      rejected by name; the status line says OFF / NO TARGETS / → targets.
##   2. The rows exist in the pro Main scene, each with a help card.
##   3. SET targets + the toggle apply LIVE: a socket on 127.0.0.1 receives a
##      /pvj/out/... bundle, and the status line and TRACKING's readout agree.
##   4. A list with one bad entry is refused WHOLE (targets unchanged).
##   5. OUT RATE reaches the live sender.
##   6. The toggle off frees the sender: nothing more arrives.
##   7. Everything lands in settings.cfg [osc] (out_enabled, out_targets,
##      out_rate_hz) — and settings.cfg is put back as it was afterwards.
##   8. OSC IN reads "UDP <port> · <ip>".
##   9. OUT TARGETS… raises a keyboard that can type ":" (URL, not the numeric pad).

const OscOutputS := preload("res://scripts/osc_output.gd")
const OscInputS := preload("res://scripts/osc_input.gd")
const PORT := 9123
const CFG := "user://settings.cfg"
const CFG_BAK := "user://settings.cfg.verify_osc_settings.bak"

var _fails: int = 0
var _checks: int = 0
var _rx := PacketPeerUDP.new()
var _got: Dictionary = {}   # address -> last value received


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


## Drain the socket for `ms`, decoding with the shipped parser. Returns packets seen.
func _listen(ms: int) -> int:
	var dec: Node = OscInputS.new()
	dec.message.connect(func(a: String, args: Array) -> void:
		_got[a] = args[0] if args.size() > 0 else null)
	var n := 0
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		while _rx.get_available_packet_count() > 0:
			dec._parse_element(_rx.get_packet())
			n += 1
		await process_frame
	dec.free()
	return n


func _run() -> void:
	_pure()
	var had_cfg := FileAccess.file_exists(CFG)
	if had_cfg:
		DirAccess.copy_absolute(CFG, CFG_BAK)

	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	main._tour_seen = true
	root.add_child(main)
	var t0 := Time.get_ticks_msec()
	while main._osc == null and Time.get_ticks_msec() - t0 < 15000:
		await process_frame
	await _frames(10)
	# Start from a known state whatever the desktop settings.cfg said.
	main._set_osc_out_enabled(false)
	main._apply_osc_out_targets("")
	await _frames(2)

	# 2. rows + cards
	var want := ["OSC", "OSC/OSC IN", "OSC/OSC OUT", "OSC/OUT TARGETS…", "OSC/OUT RATE", "OSC/OUT STATUS"]
	var keys := {}
	for t: Array in main._help_targets:
		keys[t[1]] = true
	for k: String in want:
		_ok(keys.has(k) and not HelpText.find(k).is_empty(), "LIB ▸ OSC row %s is registered and has a card" % k)
	_ok(main._osc_lib_out_toggle != null and main._osc_lib_targets_btn != null
		and main._osc_lib_out_lbl != null and main._osc_lib_in_lbl != null, "the LIB ▸ OSC widgets exist")

	# 8. OSC IN
	var in_text: String = main._osc_lib_in_lbl.text
	_ok(in_text.begins_with("UDP %d · " % main._osc_port), "OSC IN reads the port and this machine's address", in_text)

	# 10. OUT RATE reads as a whole number ("30 Hz", not "30.00 Hz")
	var hz_whole := 0
	var hz_dec := 0
	for l: Node in main.find_children("*", "Label", true, false):
		var lt: String = (l as Label).text
		if lt.ends_with(" Hz"):
			if lt.contains("."):
				hz_dec += 1
			else:
				hz_whole += 1
	_ok(hz_whole >= 1 and hz_dec == 0, "OUT RATE's value reads as whole Hz", "%d whole, %d decimal" % [hz_whole, hz_dec])

	# 9. the prompt's soft keyboard can type "ip:port" (the numeric pad has no ':')
	main._prompt_osc_targets()
	await _frames(2)
	var dlg: Node = main._osc_targets_dlg
	_ok(dlg != null and dlg._field != null
		and dlg._field.virtual_keyboard_type == LineEdit.KEYBOARD_TYPE_URL,
		"OUT TARGETS… raises the URL keyboard (has ':'), not the numeric pad",
		str(dlg._field.virtual_keyboard_type) if dlg != null and dlg._field != null else "no dialog")
	if dlg != null:
		dlg.dismiss()
	await _frames(2)

	# 3. targets + toggle, live
	_ok(_rx.bind(PORT, "127.0.0.1") == OK, "test socket bound on 127.0.0.1:%d" % PORT)
	_ok(main._apply_osc_out_targets(" 127.0.0.1:%d " % PORT), "SET 127.0.0.1:%d is accepted" % PORT)
	_ok(main._osc_out_targets == "127.0.0.1:%d" % PORT, "…stored normalised", main._osc_out_targets)
	_ok(main._osc_lib_targets_btn.text == "OUT TARGETS: 127.0.0.1:%d…" % PORT, "…and shown on the row", main._osc_lib_targets_btn.text)
	_ok(main._osc_out == null and await _listen(400) == 0, "targets alone send nothing while OSC OUT is off")
	main._osc_lib_out_toggle.button_pressed = true   # a tap on the toggle (fires toggled)
	await _frames(2)
	_ok(main._osc_out_enabled and main._osc_out != null, "the toggle builds the sender live (no restart)")
	var pkts := await _listen(1500)
	_ok(pkts > 0 and _got.has("/pvj/out/bpm") and _got.has("/pvj/out/clip"),
		"/pvj/out/... arrives at the target", "%d packets, %d addresses" % [pkts, _got.size()])
	_ok(_got.get("/pvj/out/clip") is String, "/pvj/out/clip arrives as a string", str(_got.get("/pvj/out/clip")))
	var line: String = main._osc_lib_out_lbl.text
	_ok(line == "OSC OUT → 127.0.0.1:%d @ %d HZ" % [PORT, main._osc_out_rate], "the status line says where it goes", line)
	_ok(main._lbl_osc_out == null or main._lbl_osc_out.text == line, "TRACKING's readout says the same")
	_ok(main._btn_osc_out == null or main._btn_osc_out.text == "OSC out: ON", "TRACKING's OSC out button follows the toggle")

	# 4. a bad list is refused whole
	_ok(not main._apply_osc_out_targets("127.0.0.1:%d, laptop:9000" % PORT), "a list with a host name is refused")
	_ok(main._osc_out_targets == "127.0.0.1:%d" % PORT, "…and the targets are unchanged", main._osc_out_targets)
	_ok(main.status.text.begins_with("BAD TARGET, KEPT OLD:") and main.status.text.contains("laptop:9000"),
		"…and the flash names the bad entry", main.status.text)

	# 5. rate
	main._set_osc_out_rate(5)
	_ok(main._osc_out.rate_hz == 5 and main._osc_lib_out_lbl.text.ends_with("@ 5 HZ"), "OUT RATE reaches the live sender")
	main._set_osc_out_rate(99)
	_ok(main._osc_out_rate == 60, "OUT RATE clamps to 60")

	# 7. persistence
	main._save_settings()
	var cfg := ConfigFile.new()
	_ok(cfg.load(CFG) == OK, "settings.cfg written")
	_ok(cfg.get_value("osc", "out_enabled", false) == true
		and cfg.get_value("osc", "out_targets", "") == "127.0.0.1:%d" % PORT
		and int(cfg.get_value("osc", "out_rate_hz", 0)) == 60, "[osc] out_enabled / out_targets / out_rate_hz persisted",
		"%s / %s / %s" % [cfg.get_value("osc", "out_enabled"), cfg.get_value("osc", "out_targets"), cfg.get_value("osc", "out_rate_hz")])

	# 6. off frees the sender
	main._osc_lib_out_toggle.button_pressed = false
	await _frames(3)
	await _listen(200)   # anything already in flight
	_ok(main._osc_out == null and await _listen(1200) == 0, "the toggle off stops the sender")
	_ok(main._osc_lib_out_lbl.text == "OSC OUT OFF", "…and the status line says OFF", main._osc_lib_out_lbl.text)

	main._settings_dirty = false
	main.queue_free()
	await _frames(4)
	if had_cfg:
		DirAccess.copy_absolute(CFG_BAK, CFG)
		DirAccess.remove_absolute(CFG_BAK)
	else:
		DirAccess.remove_absolute(CFG)
	print("verify_osc_settings: %d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)


func _pure() -> void:
	var p: Dictionary = OscOutputS.parse_targets(" 192.168.1.20:9000 , 10.0.0.5:4855,,")
	_ok(p["spec"] == "192.168.1.20:9000,10.0.0.5:4855" and (p["rejected"] as Array).is_empty(),
		"two targets normalise (spaces, empty entries dropped)", p["spec"])
	p = OscOutputS.parse_targets("192.168.1.20, 192.168.1.20:80, laptop:9000, 1.2.3.4:90x0, :9000, 1.2.3.4:9000")
	_ok(p["spec"] == "1.2.3.4:9000" and (p["rejected"] as Array).size() == 5,
		"no port, port < 1024, host name, junk port and no ip are each rejected", str(p["rejected"]))
	var nine: PackedStringArray = []
	for i in 9:
		nine.append("10.0.0.%d:9000" % (i + 1))
	p = OscOutputS.parse_targets(",".join(nine))
	_ok((p["targets"] as Array).size() == OscOutputS.MAX_TARGETS and p["rejected"] == ["10.0.0.9:9000"],
		"a 9th target is rejected (max %d)" % OscOutputS.MAX_TARGETS)
	_ok(OscOutputS.parse_targets("").spec == "" and (OscOutputS.parse_targets("")["rejected"] as Array).is_empty(),
		"an empty list is valid (send nothing)")
	_ok(OscOutputS.status_line(false, "1.2.3.4:9000", 30) == "OSC OUT OFF", "status: off")
	_ok(OscOutputS.status_line(true, "", 30) == "OSC OUT ON · NO TARGETS (SILENT)", "status: on with no targets says it is silent")
	_ok(OscOutputS.status_line(true, "1.2.3.4:9000,5.6.7.8:9001", 30) == "OSC OUT → 1.2.3.4:9000, 5.6.7.8:9001 @ 30 HZ",
		"status: on, targets and rate")
	# set_targets stays lenient for a hand-edited settings.cfg: the good entry flies.
	var o: Node = OscOutputS.new()
	o.set_targets("1.2.3.4:9000, garbage")
	_ok(o.has_targets() and o._targets.size() == 1, "set_targets keeps the good entries of a hand-edited list")
	o.free()
