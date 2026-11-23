class_name OscOutput
extends Node

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

## OSC 1.0 outbound (/pvj/out/... — docs/OSC_NAMESPACE_SPEC.md §4), the encoder
## sibling of OscInput. UDP fire-and-forget to a list of ip:port targets.
##
## The pipeline owns the namespace: it hands over a `snapshot` Callable that
## returns {address: value} (float | int | String; bool arrives coerced by the
## caller). This node only decides WHEN to speak and how the bytes look:
##   - a send pass at most `rate_hz` times a second;
##   - per pass, only addresses whose value CHANGED (floats against a
##     deadband) — a static deck costs the LAN almost nothing;
##   - once a second, EVERYTHING (keyframe) — a late-joining desk converges
##     within a second, and a lost packet heals the same way. UDP has no
##     other recovery, so the keyframe IS the reliability story.
##   - one #bundle per pass (immediate timetag) — receivers see a coherent
##     state frame, not an address drizzle.

const DEADBAND := 0.001         ## floats: quieter than any fader hand
const KEYFRAME_MS := 1000
const MAX_TARGETS := 8          ## a booth, not a broadcast

var rate_hz: int = 30
var snapshot: Callable          ## -> Dictionary {address: float|int|String}

var _udp := PacketPeerUDP.new()
var _targets: Array[Dictionary] = []   ## [{ip, port}]
var _sent: Dictionary = {}             ## address -> last value on the wire
var _events: Array[PackedByteArray] = []   ## one-shots riding the next pass
var _last_pass_ms: int = 0
var _last_keyframe_ms: int = 0


func _ready() -> void:
	# Pro module (Features.OSC). pipeline never builds it in the public
	# build; this is the backstop if anything ever does.
	if not FeaturesS.is_pro():
		push_warning("[osc_output] pro-only module in a public build — freed")
		queue_free()
		return


## "ip:port,ip:port" — the settings string, parsed leniently: a malformed
## entry is skipped with one log line, the rest still fly. (The settings row
## refuses a bad list before it gets here — parse_targets — so this lenience
## only matters for a hand-edited settings.cfg.)
func set_targets(spec: String) -> void:
	_targets.clear()
	_sent.clear()   # new audience: next pass keyframes everything
	var parsed := parse_targets(spec)
	for bad: String in parsed["rejected"]:
		print("[osc] out target skipped (want ip:port, max %d): %s" % [MAX_TARGETS, bad])
	_targets.assign(parsed["targets"])
	if not _targets.is_empty():
		print("[osc] out -> %d target(s)" % _targets.size())


## The one target parser, shared by set_targets and the settings row (which
## refuses the whole list when anything is rejected, rather than half-apply).
## Returns {"targets": [{ip, port}], "rejected": [entry...], "spec": String}:
## `spec` is the accepted targets re-joined as "ip:port,ip:port" (spaces gone),
## the form settings.cfg stores. Port 1024..65535, an IPv4/IPv6 literal (no
## host names: a DNS lookup has no place on the frame), at most MAX_TARGETS.
static func parse_targets(spec: String) -> Dictionary:
	var targets: Array[Dictionary] = []
	var rejected: Array[String] = []
	var accepted: PackedStringArray = []
	for entry: String in spec.split(",", false):
		var e := entry.strip_edges()
		if e.is_empty():
			continue
		var colon := e.rfind(":")
		var port_s := "" if colon < 0 else e.substr(colon + 1)
		var port := int(port_s) if port_s.is_valid_int() else -1
		var ip := "" if colon < 0 else e.substr(0, colon)
		if colon <= 0 or port < 1024 or port > 65535 or not ip.is_valid_ip_address() \
				or targets.size() >= MAX_TARGETS:
			rejected.append(e)
			continue
		targets.append({"ip": ip, "port": port})
		accepted.append("%s:%d" % [ip, port])
	return {"targets": targets, "rejected": rejected, "spec": ",".join(accepted)}


## The settings row's status line (and the tracking section's readout): what
## the outbound tree is doing right now, in the words a performer checks
## before a set. Empty targets is the case that silently does nothing, so it
## says so.
static func status_line(enabled: bool, spec: String, rate: int) -> String:
	if not enabled:
		return "OSC OUT OFF"
	if spec.strip_edges() == "":
		return "OSC OUT ON · NO TARGETS (SILENT)"
	return "OSC OUT → %s @ %d HZ" % [spec.replace(",", ", "), rate]


func has_targets() -> bool:
	return not _targets.is_empty()


## A one-shot EVENT (/pvj/out/track/acquired and kin): rides the next pass's
## bundle exactly once — never dedup'd, never repeated by the keyframe. The
## state snapshot cannot say these (a keyframe would re-announce them).
func event(address: String, value: Variant) -> void:
	if _targets.is_empty():
		return
	_events.append(encode_message(address, [value]))


func _process(_delta: float) -> void:
	if _targets.is_empty() or not snapshot.is_valid():
		return
	var now := Time.get_ticks_msec()
	if now - _last_pass_ms < 1000 / maxi(rate_hz, 1):
		return
	_last_pass_ms = now

	var keyframe := now - _last_keyframe_ms >= KEYFRAME_MS
	if keyframe:
		_last_keyframe_ms = now

	var state: Dictionary = snapshot.call()
	var msgs: Array[PackedByteArray] = []
	if not _events.is_empty():
		msgs.append_array(_events)
		_events.clear()
	for address: String in state:
		var v: Variant = state[address]
		if not keyframe and _sent.has(address) and not _changed(_sent[address], v):
			continue
		msgs.append(encode_message(address, [v]))
		_sent[address] = v
	if msgs.is_empty():
		return

	var pkt := encode_bundle(msgs)
	for t: Dictionary in _targets:
		_udp.set_dest_address(str(t["ip"]), int(t["port"]))
		_udp.put_packet(pkt)


static func _changed(prev: Variant, v: Variant) -> bool:
	if v is float and prev is float:
		return absf(v - prev) > DEADBAND
	return prev != v


# ── wire encoders (OSC 1.0, big-endian; the mirror of OscInput's readers) ──

static func encode_message(address: String, args: Array) -> PackedByteArray:
	var b := PackedByteArray()
	_write_string(b, address)
	var tags := ","
	for a: Variant in args:
		if a is float:
			tags += "f"
		elif a is int or a is bool:
			tags += "i"
		else:
			tags += "s"
	_write_string(b, tags)
	for a: Variant in args:
		if a is float:
			_write_f32(b, a)
		elif a is int or a is bool:
			_write_i32(b, int(a))
		else:
			_write_string(b, str(a))
	return b


## "#bundle" + immediate timetag (1) + size-prefixed elements — exactly the
## frame OscInput._parse_element walks.
static func encode_bundle(msgs: Array[PackedByteArray]) -> PackedByteArray:
	var b := PackedByteArray()
	_write_string(b, "#bundle")
	b.append_array(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 1]))
	for m: PackedByteArray in msgs:
		_write_i32(b, m.size())
		b.append_array(m)
	return b


## Null-terminated, zero-padded to a 4-byte boundary.
static func _write_string(b: PackedByteArray, s: String) -> void:
	b.append_array(s.to_utf8_buffer())
	b.append(0)
	while b.size() % 4 != 0:
		b.append(0)


static func _write_i32(b: PackedByteArray, v: int) -> void:
	b.append((v >> 24) & 0xFF)
	b.append((v >> 16) & 0xFF)
	b.append((v >> 8) & 0xFF)
	b.append(v & 0xFF)


static func _write_f32(b: PackedByteArray, v: float) -> void:
	# encode_float writes little-endian; OSC is big-endian — reverse 4 bytes.
	var le := PackedByteArray([0, 0, 0, 0])
	le.encode_float(0, v)
	b.append_array(PackedByteArray([le[3], le[2], le[1], le[0]]))
