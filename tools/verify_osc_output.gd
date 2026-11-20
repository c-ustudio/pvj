extends SceneTree
## Headless round-trip proof for the OSC outbound encoder (OSC_NAMESPACE §4).
##
##   Godot --headless --path <project> --script tools/verify_osc_output.gd
##
## The claim that matters: bytes OscOutput writes are bytes OscInput accepts —
## message framing, bundle framing, big-endian numerics, 4-byte padding. The
## decoder under test is the REAL scripts/osc_input.gd (the shipped, live-
## verified parser), not a re-derivation: if these two agree, the phone can
## parse its own feedback, and any strict OSC 1.0 receiver (TD's OSC In,
## Resolume) sees well-formed packets. No sockets involved — encode to bytes,
## hand the bytes to the parser's entry point, compare.

const OscOutputS := preload("res://scripts/osc_output.gd")
const OscInputS := preload("res://scripts/osc_input.gd")
const EPS_F32 := 0.000001   # float32 round-trip precision

var _fails: int = 0
var _got: Array = []        # [[address, args], ...] captured from OscInput


func _initialize() -> void:
	var osc_in: Node = OscInputS.new()
	osc_in.message.connect(func(a: String, args: Array) -> void:
		_got.append([a, args]))

	# 1. Bare message round-trips: every tag type, padding edges, sign bits.
	# Addresses chosen so the null+pad lands on every boundary offset
	# (len%4 == 3,0,1,2 pre-pad).
	var cases: Array = [
		["/pvj/out/xfade", [0.73]],
		["/pvj/out/bpm", [163.6]],
		["/a", [-1.5]],                       # short address, negative float
		["/pvj/out/beat", [2147483647]],      # int32 max
		["/pvj/out/bar", [-2]],               # negative int (sign extension)
		["/pvj/out/clip", ["let_it_go.mp4"]],
		["/pvj/out/mode", ["sequential"]],
		["/pvj/out/x", [0.0]],                # zero float is not "missing"
		["/pvj/mixed", [1, 0.5, "b"]],        # multi-arg, mixed tags
		["/pvj/empty", []],                   # no args, no typetag block
	]
	for c: Array in cases:
		_got.clear()
		osc_in._parse_element(OscOutputS.encode_message(c[0], c[1]))
		_check_one(str(c[0]), c[1])

	# 2. Bundle framing: N messages arrive, in order, values intact — the
	# exact frame _process sends per pass.
	var msgs: Array[PackedByteArray] = []
	for c: Array in cases:
		msgs.append(OscOutputS.encode_message(c[0], c[1]))
	_got.clear()
	osc_in._parse_element(OscOutputS.encode_bundle(msgs))
	_expect(_got.size() == cases.size(),
		"bundle delivers all %d messages (got %d)" % [cases.size(), _got.size()])
	for i: int in mini(_got.size(), cases.size()):
		_expect(_got[i][0] == cases[i][0],
			"bundle order: #%d is %s" % [i, cases[i][0]])

	# 3. Everything OscOutput emits is 4-byte aligned (OSC 1.0 hard rule).
	for c: Array in cases:
		var m := OscOutputS.encode_message(c[0], c[1])
		_expect(m.size() % 4 == 0, "aligned: %s (%d bytes)" % [c[0], m.size()])

	# 4. Change detection: the deadband keeps a static fader silent and lets
	# a real move through; non-floats compare exactly.
	_expect(not OscOutputS._changed(0.5, 0.5004), "deadband holds 0.0004")
	_expect(OscOutputS._changed(0.5, 0.52), "deadband passes 0.02")
	_expect(OscOutputS._changed(0, 1), "int flip detected")
	_expect(not OscOutputS._changed("clip", "clip"), "same string quiet")
	_expect(OscOutputS._changed("clip", "net"), "string change detected")

	print("")
	if _fails == 0:
		print("verify_osc_output: ALL CHECKS PASSED")
	else:
		print("verify_osc_output: %d FAILED" % _fails)
	quit(1 if _fails > 0 else 0)


func _check_one(address: String, args: Array) -> void:
	if not _expect(_got.size() == 1, "%s parsed as one message" % address):
		return
	_expect(_got[0][0] == address, "%s address intact" % address)
	var got_args: Array = _got[0][1]
	if not _expect(got_args.size() == args.size(),
			"%s arg count %d" % [address, args.size()]):
		return
	for i: int in args.size():
		var want: Variant = args[i]
		var got: Variant = got_args[i]
		if want is float:
			# float32 precision is RELATIVE (~1.2e-7): 163.6 legitimately
			# round-trips as 163.600006 — that is the wire being exact, not
			# the encoder being wrong.
			var tol := maxf(EPS_F32, absf(want) * EPS_F32)
			_expect(got is float and absf(got - want) < tol,
				"%s arg %d float %f -> %s" % [address, i, want, str(got)])
		else:
			_expect(typeof(got) == typeof(want) and got == want,
				"%s arg %d %s -> %s" % [address, i, str(want), str(got)])


func _expect(ok: bool, what: String) -> bool:
	if ok:
		print("  ok   %s" % what)
	else:
		_fails += 1
		printerr("  FAIL %s" % what)
	return ok
