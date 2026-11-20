extends SceneTree
## Headless check of ASCII custom messaging over OSC (/pvj/fx/ascii/text|mode,
## OSC_NAMESPACE_SPEC.md §3, SESSION_45).
##
##   godot --headless --path <project> --script tools/verify_osc_ascii.gd -- --pro
##
## Checks, against the real pro Main scene over UDP 127.0.0.1:4855:
##   1. /pvj/fx/ascii/text TAKES OVER (owner's call): from FX Off it turns the
##      ASCII effect on, mode Custom, and the shader's cells spell the text.
##   2. The FX panel's TEXT field shows the OSC text, and typing in the field goes
##      through the same setter (one path, spec §5).
##   3. A second message only changes the text; a performer who switched the mode
##      away gets Custom back on the next message.
##   4. Text is capped at the shader's 64 cells; a message gets one trailing space
##      (so the repeats read HELLO HELLO, not HELLOHELLO) when there is room.
##   5. /pvj/fx/ascii/mode by name and index, leaving the effect alone; unknown
##      names, out-of-range indexes, a non-string text and no args change nothing.

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


func _fx_name(main: Node) -> String:
	return str(main._effects[main._effect_index].name)


func _param(main: Node, uniform: String) -> Variant:
	var mat: ShaderMaterial = main.shader_slot.get_shader_material()
	return mat.get_shader_parameter(uniform) if mat != null else null


## The first n shader cells back to text (A-Z 0..25, 0-9 26..35, 36 blank).
func _cells(main: Node, n: int) -> String:
	var codes: Variant = _param(main, "text_chars")
	if codes == null:
		return "<no material>"
	var out := ""
	for i in n:
		var c := int(codes[i])
		out += char(65 + c) if c < 26 else (char(48 + c - 26) if c < 36 else " ")
	return out


func _run() -> void:
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	main._tour_seen = true
	root.add_child(main)
	var t0 := Time.get_ticks_msec()
	while main._osc == null and Time.get_ticks_msec() - t0 < 15000:
		await process_frame
	await _frames(10)
	_ok(main._osc != null and main._osc.is_listening(), "pro Main listens for OSC", "port %d" % main._osc_port)
	if _fails > 0:
		_finish()
		return
	_udp.set_dest_address("127.0.0.1", main._osc_port)
	# A performer's starting look: FX Off, ASCII left in Brightness with the default text.
	main._set_effect(0)
	main._set_ascii_mode(0)
	main._set_ascii_text("LOVE")
	await _frames(2)
	_ok(_fx_name(main) == "Off", "starts with FX Off")

	# 1. take-over
	await _send("/pvj/fx/ascii/text", ["Hello World"])
	_ok(_fx_name(main) == "ASCII", "/pvj/fx/ascii/text turns the ASCII effect on", _fx_name(main))
	_ok(main._ascii_mode == main.ASCII_MODE_CUSTOM, "…in Custom mode", str(main._ascii_mode))
	_ok(main._ascii_text == "Hello World ", "…with the text and ONE trailing space (the repeats don't run together)",
		"'%s'" % main._ascii_text)
	_ok(int(_param(main, "mode")) == main.ASCII_MODE_CUSTOM and int(_param(main, "text_len")) == 12
		and _cells(main, 12) == "HELLO WORLD ", "…and the shader's cells spell it", "'%s' len %s" % [_cells(main, 12), _param(main, "text_len")])
	_ok(main.status.text == "OSC: TEXT HELLO WORLD", "…and flashes OSC: TEXT", main.status.text)

	# 2. the TEXT field, both ways
	main._rebuild_fx_settings()   # the FX panel's ASCII rows, as when it is opened
	await _frames(2)
	var edit: LineEdit = main._ascii_text_edit
	_ok(is_instance_valid(edit) and edit.text == "Hello World ", "the TEXT field shows the OSC text",
		edit.text if is_instance_valid(edit) else "no field")
	await _send("/pvj/fx/ascii/text", ["  again  "])
	_ok(is_instance_valid(edit) and edit.text == "again ", "…and follows the next message without a rebuild (edges trimmed, one space)",
		"'%s'" % (edit.text if is_instance_valid(edit) else ""))
	if is_instance_valid(edit):
		edit.text = "TYPED 2"
		edit.text_changed.emit("TYPED 2")   # what a keystroke does
		await _frames(1)
	_ok(main._ascii_text == "TYPED 2" and _cells(main, 7) == "TYPED 2", "typing in the field goes through the same setter (no space added)",
		"'%s' / '%s'" % [main._ascii_text, _cells(main, 7)])

	# 3. second message; the performer's mode change is overridden by the next message
	main._set_ascii_mode(0)
	await _frames(1)
	await _send("/pvj/fx/ascii/text", ["PVJ 2026"])
	_ok(_fx_name(main) == "ASCII" and main._ascii_mode == main.ASCII_MODE_CUSTOM and _cells(main, 8) == "PVJ 2026",
		"a message after the performer left Custom brings Custom back", "mode %d '%s'" % [main._ascii_mode, _cells(main, 8)])

	# 4. cap
	var long := "ABCDEFGHIJ".repeat(10)
	await _send("/pvj/fx/ascii/text", [long])
	_ok(main._ascii_text.length() == 64 and int(_param(main, "text_len")) == 64 and not main._ascii_text.ends_with(" "),
		"text is capped at the 64 shader cells (no space when full)",
		"%d chars" % main._ascii_text.length())

	# 5. mode, and refusals
	await _send("/pvj/fx/ascii/mode", ["binary"])
	_ok(main._ascii_mode == 1 and _fx_name(main) == "ASCII", "/pvj/fx/ascii/mode binary (by name)")
	await _send("/pvj/fx/ascii/mode", [2])
	_ok(main._ascii_mode == 2, "/pvj/fx/ascii/mode 2 (by index) = random")
	main._set_effect(0)
	await _send("/pvj/fx/ascii/mode", ["custom"])
	_ok(main._ascii_mode == main.ASCII_MODE_CUSTOM and _fx_name(main) == "Off",
		"mode alone leaves the effect alone (no take-over)", _fx_name(main))
	var before_text: String = main._ascii_text
	await _send("/pvj/fx/ascii/mode", ["sparkle"])
	await _send("/pvj/fx/ascii/mode", [9])
	await _send("/pvj/fx/ascii/text", [42])
	await _send("/pvj/fx/ascii/text")
	_ok(main._ascii_mode == main.ASCII_MODE_CUSTOM and _fx_name(main) == "Off" and main._ascii_text == before_text,
		"unknown mode, index 9, a number as text and no args change nothing")

	main._settings_dirty = false   # don't write the desktop settings.cfg
	main.queue_free()
	await _frames(4)
	_finish()


func _finish() -> void:
	print("verify_osc_ascii: %d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
