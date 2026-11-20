class_name OscInput
extends Node

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

## OSC 1.0 inbound (OSC_NAMESPACE_SPEC.md) — UDP, messages + #bundles,
## type tags i/f/s only. STRICT: a packet that doesn't parse whole is
## dropped whole — garbage must never half-apply. Bundles' timetags are
## ignored (the receiver's bar quantization is the musical clock, not NTP).
##
## Emits message(address, args) for every message; the pipeline owns the
## namespace map — this node only speaks the wire.

signal message(address: String, args: Array)

var _udp := PacketPeerUDP.new()
var _listening := false
var _unknown_warned_msec := 0   # rate-limit for the pipeline's unknown-address log
var _dropped_warned_msec := 0   # rate-limit for a known address with an unusable arg

const MAX_PACKET := 8192        # OSC control traffic; anything bigger is not ours
const DRAIN_PER_FRAME := 64     # bounded drain, the link listeners' discipline


func _ready() -> void:
	# Pro module (Features.OSC). pipeline never builds it in the public
	# build; this is the backstop if anything ever does.
	if not FeaturesS.is_pro():
		push_warning("[osc_input] pro-only module in a public build — freed")
		queue_free()
		return


func listen(port: int) -> Error:
	stop()
	var err := _udp.bind(port)
	_listening = err == OK
	if _listening:
		print("[osc] listening on udp %d" % port)
	return err


func stop() -> void:
	if _listening:
		_udp.close()
	_listening = false


func is_listening() -> bool:
	return _listening


func _process(_delta: float) -> void:
	if not _listening:
		return
	var n := 0
	while _udp.get_available_packet_count() > 0 and n < DRAIN_PER_FRAME:
		n += 1
		var pkt := _udp.get_packet()
		if pkt.size() > 0 and pkt.size() <= MAX_PACKET:
			_parse_element(pkt)


## One bundle element or a bare message — bundles recurse.
func _parse_element(b: PackedByteArray) -> void:
	if b.size() >= 8 and b.slice(0, 7).get_string_from_ascii() == "#bundle":
		# 8 header + 8 timetag (ignored), then size-prefixed elements.
		var pos := 16
		while pos + 4 <= b.size():
			var size := _read_i32(b, pos)
			pos += 4
			if size < 0 or pos + size > b.size():
				return   # lost framing: drop the rest of the bundle
			_parse_element(b.slice(pos, pos + size))
			pos += size
		return
	_parse_message(b)


func _parse_message(b: PackedByteArray) -> void:
	var r = _read_string(b, 0)   # Variant: Array or null (strict typing can't infer)
	if r == null:
		return
	var address: String = r[0]
	var pos: int = r[1]
	if not address.begins_with("/"):
		return
	var args: Array = []
	if pos < b.size():
		r = _read_string(b, pos)
		if r == null:
			return
		var tags: String = r[0]
		pos = r[1]
		if not tags.begins_with(","):
			return
		for i in range(1, tags.length()):
			match tags[i]:
				"i":
					if pos + 4 > b.size():
						return
					args.append(_read_i32(b, pos))
					pos += 4
				"f":
					if pos + 4 > b.size():
						return
					args.append(_read_f32(b, pos))
					pos += 4
				"s":
					r = _read_string(b, pos)
					if r == null:
						return
					args.append(r[0])
					pos = r[1]
				_:
					return   # unsupported tag: drop the whole message (§1)
	message.emit(address, args)


## Rate-limited "unknown address" report for the pipeline (§3: one line,
## not a spray — a rig speaking tomorrow's namespace must not spam).
func warn_unknown(address: String) -> void:
	var now := Time.get_ticks_msec()
	if now - _unknown_warned_msec > 5000:
		_unknown_warned_msec = now
		print("[osc] unknown address (dropped): %s" % address)


## A KNOWN address whose argument names nothing (/pvj/deck/clip 99): dropped,
## one line per 5 s like warn_unknown — a desk sending a stale clip list must
## not spam the log.
func warn_dropped(what: String) -> void:
	var now := Time.get_ticks_msec()
	if _dropped_warned_msec == 0 or now - _dropped_warned_msec > 5000:
		_dropped_warned_msec = now
		print("[osc] dropped %s" % what)


# ── wire helpers ──────────────────────────────────────────────────────────

## Null-terminated, zero-padded to 4. Returns [String, next_pos] or null.
static func _read_string(b: PackedByteArray, pos: int):
	var end := pos
	while end < b.size() and b[end] != 0:
		end += 1
	if end >= b.size():
		return null   # unterminated = not OSC
	var s := b.slice(pos, end).get_string_from_utf8()
	var nxt := end + 1
	nxt = (nxt + 3) & ~3
	if nxt > b.size():
		nxt = b.size()
	return [s, nxt]


static func _read_i32(b: PackedByteArray, pos: int) -> int:
	var v := (b[pos] << 24) | (b[pos + 1] << 16) | (b[pos + 2] << 8) | b[pos + 3]
	if v & 0x80000000:
		v -= 0x100000000
	return v


static func _read_f32(b: PackedByteArray, pos: int) -> float:
	# decode_float reads little-endian; OSC is big-endian — reverse 4 bytes.
	var le := PackedByteArray([b[pos + 3], b[pos + 2], b[pos + 1], b[pos]])
	return le.decode_float(0)
