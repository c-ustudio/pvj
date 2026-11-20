class_name DdpOutput
extends Node
## Streams the render pipeline to a 64x64 HUB75 LED panel over DDP.
##
## Stage-agnostic sink: hand it any texture-producing viewport and it sends that
## viewport's image to the panel as DDP packets over UDP. Follows the same
## texture-in/packets-out shape as the rest of the pipeline — it consumes
## `get_texture()` like ShaderSlot consumes ClipEngine, and produces no visual
## output of its own, so it can hang off any stage without disturbing it.
##
##     MIRROR       QuadWarp / OutputWorld ──texture──► DdpOutput ──UDP──► panel
##     INDEPENDENT  DeckB_Render           ──texture──► DdpOutput ──UDP──► panel
##
## Receiver firmware and wire format: github.com/c-ustudio/led-matrix-bridge
##
## ── ⚠️ WHY THERE IS A DOWNSAMPLE CHAIN AND NOT JUST get_image() ──────────
## `get_texture().get_image()` is a GPU→CPU sync. MAPPING_TOOLS_SPEC §3 measured
## it at 10–30 ms at full resolution and rules it "one-shot only, never
## per-frame" — at 60 fps the whole frame budget is 16.6 ms, so a 1080p readback
## per frame cannot work, full stop.
##
## The way out is that the panel is 64x64. This node renders the source down to
## 64x64 ON THE GPU first and reads back only the tiny result — 4096 px instead
## of 2.07 M, a ~500x cut in transferred bytes. That is the same shape as
## ThumbnailService's "tiny 36k-px readback" (PROJECT_STATE §ThumbnailService),
## which sustains 60 fps, and this readback is ~9x smaller again.
##
## ⚠️ DO NOT "SIMPLIFY" THIS BY READING THE SOURCE VIEWPORT DIRECTLY AND
## SCALING ON THE CPU. That reinstates exactly the full-resolution per-frame
## readback the spec forbids, and it will cost the deck its 60 fps.
##
## ── ⚠️ WHY TWO DOWNSAMPLE STAGES ────────────────────────────────────────
## 1920x1080 → 64x64 in one bilinear step samples 4 texels out of every ~500 and
## discards the rest, which on live video reads as violent shimmer and crawling
## edges — at 64x64 there is no detail left to mask it. An intermediate 256x256
## pass gives each final texel a real neighbourhood to average. Two passes over
## tiny targets cost far less than the artefact costs perceptually.

## Emitted once per frame actually sent, with the packet count. Useful for a
## status readout; do not do work in the handler, it is on the render path.
signal frame_sent(packets: int)

## Emitted when the socket cannot be opened or the destination is rejected.
signal output_failed(reason: String)

enum Mode {
	## Stream whatever the main output shows — the composited pipeline, warp and
	## masks included. What the projector gets, the panel gets.
	MIRROR,
	## Stream a specific deck or bus, decoupled from the phone's main display.
	## ⚠️ STUB until Phase 2 dual-deck lands — see set_independent_source().
	INDEPENDENT,
}

# ── DDP wire format ──────────────────────────────────────────────────────
# Kept byte-identical to the TouchDesigner sender so one firmware serves both.
# Spec: http://www.3waylabs.com/ddp/

const DDP_PORT := 4048
const DDP_FLAGS_VER1 := 0x40   ## version 1 in bits 7-6
const DDP_FLAGS_PUSH := 0x01   ## last packet of a frame
const DDP_FLAGS_QUERY := 0x02  ## asking the device for something
const DDP_FLAGS_REPLY := 0x04  ## the device answering
const DDP_TYPE_RGB888 := 0x0B  ## standard / RGB / 8 bits per channel
const DDP_ID_DEFAULT := 1      ## "default output device"

## DDP reserves device IDs for structured messages rather than pixel data. The
## firmware implements two of them, so status, discovery and provisioning are
## part of the protocol rather than a private side channel — and identical on
## both senders, which is what keeps one firmware build serving both.
const DDP_ID_CONFIG := 250     ## JSON config, read/write
const DDP_ID_STATUS := 251     ## JSON status, read-only

## A config write is [32-byte HMAC-SHA256][16-byte nonce][JSON]. The HMAC covers
## nonce + JSON, so a captured write dies with its nonce rather than staying
## valid forever.
const CTRL_HMAC_LEN := 32
const CTRL_NONCE_LEN := 16

## 480 px x 3 bytes = 1440 payload bytes. Plus the 10-byte DDP header, 8-byte UDP
## header and 20-byte IP header that is 1478 on the wire — under a 1500-byte MTU,
## so nothing fragments. A 64x64 frame is therefore 9 packets: 8 full + a 256 px
## remainder.
const MAX_PIXELS_PER_PACKET := 480

const PANEL_WIDTH := 64
const PANEL_HEIGHT := 64
const INTERMEDIATE_SIZE := 256  ## see the two-stage note in the class docs

# ── Configuration ────────────────────────────────────────────────────────

## Must match STATIC_IP in the firmware's secrets.h.
@export var target_ip: String = "192.168.1.50"
@export var target_port: int = DDP_PORT
@export var ddp_device_id: int = DDP_ID_DEFAULT

## Off by default. The panel is opt-in hardware; an install without one should
## pay nothing, not even the tap viewports (they are built lazily on enable).
@export var enabled: bool = false: set = set_enabled

## Frames per second pushed to the panel. 40-60 is the working range; below 40
## the panel visibly stutters on fast content. Independent of the deck's own
## frame rate — the deck keeps 60 fps regardless.
@export_range(1, 60, 1) var send_fps: float = 60.0

@export var mode: Mode = Mode.MIRROR: set = set_mode

## ⚠️ Godot viewport textures are commonly bottom-left origin, and the panel
## scans from the top (OUTPUT_ARCHITECTURE_SPEC §3 flags the same trap for the
## EGL bridge). Whether the flip is needed depends on the renderer, so it is a
## switch rather than a guess: if the panel image is upside down, toggle it.
@export var flip_vertical: bool = false

## Some HUB75 panels wire the shift register BGR. If red and blue are swapped,
## set this rather than changing the firmware — the other sender may not need it.
@export var swap_red_blue: bool = false

## Follow the panel's address when a status reply comes back from somewhere
## other than target_ip. Leave off when two panels share a subnet, or the
## output will chase whichever answers first.
@export var auto_retarget: bool = false

## How a 16:9 source is made square for a 1:1 panel.
##
## The panel is 64x64 and the deck is 1920x1080, so SOMETHING has to give and
## there is no default that is right for every source. This is the choice:
##
##   SQUASH    fit the whole frame, ignoring aspect. Nothing is lost, but a
##             circle becomes an ellipse and faces read as wrong — the
##             distortion is 1.78x horizontally.
##   CROP      keep aspect, fill the panel, discard the sides. The centre
##             1080x1080 survives; ⚠️ 44% OF THE FRAME WIDTH IS GONE, which
##             matters when the composition puts anything near an edge.
##   LETTERBOX keep aspect, fit the whole frame, black bars top and bottom.
##             Nothing is lost and nothing is distorted, but only 36 of the
##             panel's 64 rows carry picture — on an LED panel those dead rows
##             are visibly dark, not neutral.
##
## SQUASH is the default only because it is what shipped; it is not a
## recommendation. Pick this one while looking at the panel.
enum FitMode { SQUASH, CROP, LETTERBOX }

@export var fit_mode: FitMode = FitMode.SQUASH: set = set_fit_mode

# ── State ────────────────────────────────────────────────────────────────

var _udp: PacketPeerUDP
var _source: SubViewport            ## what we are mirroring
var _independent_source: SubViewport

var _stage1: SubViewport            ## 1080p -> 256x256
var _stage1_rect: TextureRect
var _stage2: SubViewport            ## 256x256 -> 64x64
var _stage2_rect: TextureRect

var _sequence: int = 0              ## DDP sequence, 1-15, 0 means "unused"
var _next_due: float = 0.0
var _sending: bool = false          ## re-entrancy guard, see _process()
var _applying: bool = false         ## re-entrancy guard, see set_enabled()
var _frames_sent: int = 0

var _panel_status: Dictionary = {}   ## last status reply from the board
var _status_time: float = -1.0       ## when it arrived, -1 = never
var _next_status_due: float = 0.0


func _ready() -> void:
	# The `enabled` setter bails when the node is outside the tree, so an
	# inspector-set `true` has not been applied yet — apply it now.
	if enabled:
		set_enabled(true)
	else:
		set_process(false)


# ── Public API ───────────────────────────────────────────────────────────

## Point the sender at the stage it should stream. In MIRROR mode this is the
## final output (OutputWorld / QuadWarp); the node only reads its texture, so
## the source is unaffected.
func set_source(viewport: SubViewport) -> void:
	_source = viewport
	_rebind_source()


## Phase 2 hook: the deck or bus to stream in INDEPENDENT mode.
##
## ⚠️ STUB. Phase 2 dual-deck is designed but not built
## (PocketVJ_Architecture.md §"Phase 2 (dual deck) designed now, built later"),
## so there is no second deck to point at yet. The plumbing is complete and
## exercised by MIRROR; when DeckB_Render exists, its DeckController calls this
## with `deck.get_output_texture()`'s viewport and INDEPENDENT starts working
## with no further change here.
##
## Until then, selecting INDEPENDENT without calling this falls back to the
## mirror source and warns, rather than going black mid-set.
func set_independent_source(viewport: SubViewport) -> void:
	_independent_source = viewport
	_rebind_source()


func set_mode(value: Mode) -> void:
	mode = value
	if mode == Mode.INDEPENDENT and _independent_source == null:
		push_warning(
			"[DdpOutput] INDEPENDENT selected but no independent source is set "
			+ "(Phase 2 dual-deck not built yet) — falling back to MIRROR.")
	_rebind_source()


func set_enabled(value: bool) -> void:
	enabled = value
	if not is_inside_tree():
		return
	# A failed _open_socket() clears `enabled`, which re-enters this setter. The
	# guard lets that assignment stand while leaving the teardown below to the
	# outer call, instead of half-applying two passes over each other.
	if _applying:
		return
	_applying = true

	if enabled:
		if _open_socket():
			if _stage1 == null:
				_build_taps()
			_set_taps_updating(true)
			_rebind_source()
		else:
			enabled = false

	if not enabled:
		# DISABLED, not hidden: an updating viewport costs its pass whether or
		# not anything samples it — the same rule ShaderSlot follows for its
		# history buffer.
		_set_taps_updating(false)
		_close_socket()

	set_process(enabled)
	_applying = false


func get_frames_sent() -> int:
	return _frames_sent


## Last status the panel reported, or an empty Dictionary if it has never
## answered. Pair it with get_status_age() — a board that stopped replying
## leaves its last numbers here, and read alone they look current.
func get_panel_status() -> Dictionary:
	return _panel_status


## Seconds since the panel last answered, or -1.0 if it never has.
func get_status_age() -> float:
	if _status_time < 0.0:
		return -1.0
	return (Time.get_ticks_msec() / 1000.0) - _status_time


## Broadcast a status query and retarget at whoever answers. Worth calling when
## the panel has gone quiet: its address is only as stable as its DHCP lease,
## and a hardcoded target_ip silently points at nothing once that moves.
func discover() -> void:
	if _udp == null:
		return
	_udp.set_broadcast_enabled(true)
	_udp.set_dest_address("255.255.255.255", target_port)
	_udp.put_packet(build_status_query())
	_udp.set_dest_address(target_ip, target_port)
	_udp.set_broadcast_enabled(false)


func reset_counters() -> void:
	_frames_sent = 0
	_sequence = 0
	_next_due = 0.0
	_panel_status = {}
	_status_time = -1.0


# ── Per-frame ────────────────────────────────────────────────────────────


func _process(_delta: float) -> void:
	if not enabled or _udp == null or _stage2 == null:
		return

	# Send on wall-clock time, not on frame count, so send_fps is honoured
	# independently of the deck's frame rate.
	var now := Time.get_ticks_msec() / 1000.0

	# Before the frame-rate gate, so status keeps flowing at send_fps values
	# that would otherwise starve it.
	_poll_status(now)

	if now < _next_due:
		return
	# Reschedule from now rather than _next_due + period: after a hitch we want
	# the next frame, not a catch-up burst down a link that just proved slow.
	_next_due = now + (1.0 / maxf(1.0, send_fps))

	# ⚠️ _send_frame() awaits, so _process can re-enter before it finishes. Two
	# overlapping sends would interleave packets from different frames and the
	# firmware's arbitration would discard the loser — visible as a halved frame
	# rate for no reason.
	if _sending:
		return
	_sending = true
	_send_frame()


## Drain replies and send a status query once a second. Called from _process,
## so it must never block: a status readout that can stall the render is worse
## than no status readout. PacketPeerUDP is non-blocking by default.
func _poll_status(now: float) -> void:
	while _udp.get_available_packet_count() > 0:
		var reply := parse_control_reply(_udp.get_packet())
		if reply.is_empty():
			continue
		if reply.has("fps"):
			_panel_status = reply
			_status_time = now
			# A reply from an address we are not sending to means the panel has
			# moved — which is the entire point of asking.
			var found: String = reply.get("ip", "")
			if auto_retarget and found != "" and found != target_ip:
				push_warning("[DdpOutput] panel moved to %s, retargeting" % found)
				target_ip = found
				_udp.set_dest_address(target_ip, target_port)

	if now < _next_status_due:
		return
	_next_status_due = now + 1.0
	_udp.put_packet(build_status_query())


func _send_frame() -> void:
	# The readback must happen after the frame has actually drawn, or we capture
	# the previous frame — or a partially drawn one.
	await RenderingServer.frame_post_draw

	var payload := _read_panel_bytes()
	if payload.is_empty():
		_sending = false
		return

	var packets := _emit_packets(payload)
	_frames_sent += 1
	_sending = false
	frame_sent.emit(packets)


## Read the 64x64 tap and flatten it to row-major RGB888, top-left origin.
##
## ⚠️ A SOURCE THAT IS ALREADY PANEL-SIZED SKIPS THE TAPS ENTIRELY. The chain
## exists to get 1920x1080 down to 64x64 without a full-resolution readback; a
## source that is natively 64x64 has nothing to downsample, and pushing it
## through anyway would scale it UP to 256 and back DOWN to 64. With linear
## filtering that round trip is not free — it softens exactly the one-pixel
## detail a generative 64x64 source is made of, which is the whole reason such a
## source would be used. Reading it directly is both cheaper and sharper.
func _read_panel_bytes() -> PackedByteArray:
	var tex: Texture2D = null
	if _source_is_panel_sized():
		tex = _active_source().get_texture()
	else:
		tex = _stage2.get_texture()
	if tex == null:
		return PackedByteArray()

	var image := tex.get_image()
	if image == null:
		return PackedByteArray()

	if flip_vertical:
		image.flip_y()

	# RGB8 is exactly the panel's format, so get_data() is already the payload —
	# 12 288 bytes, row-major from the top-left, no per-pixel loop in GDScript.
	if image.get_format() != Image.FORMAT_RGB8:
		image.convert(Image.FORMAT_RGB8)

	var data := image.get_data()

	if swap_red_blue:
		for i in range(0, data.size(), 3):
			var r := data[i]
			data[i] = data[i + 2]
			data[i + 2] = r

	return data


## Split the frame across DDP packets and put them on the wire. Returns the
## packet count.
func _emit_packets(payload: PackedByteArray) -> int:
	var total := payload.size()
	var bytes_per_packet := MAX_PIXELS_PER_PACKET * 3
	var offset := 0
	var packets := 0

	while offset < total:
		var chunk_len: int = mini(bytes_per_packet, total - offset)
		var is_last := (offset + chunk_len) >= total

		var packet := _build_header(offset, chunk_len, is_last)
		packet.append_array(payload.slice(offset, offset + chunk_len))

		var err := _udp.put_packet(packet)
		if err != OK:
			# One bad packet is a dropped frame, not a dead output — the panel
			# holds its previous frame because the firmware only shows a frame on
			# PUSH. Do not spam: this fires per packet on a downed link.
			push_warning("[DdpOutput] put_packet failed: %d" % err)
			return packets

		offset += chunk_len
		packets += 1

	return packets


## The 10-byte DDP v1 header. Offset and length are in BYTES and go out
## BIG-endian — note this is the opposite of PackedByteArray's encode_* helpers,
## which are little-endian, hence the explicit byte writes.
func _build_header(offset: int, length: int, push: bool) -> PackedByteArray:
	_sequence += 1
	if _sequence > 15:
		_sequence = 1

	var flags := DDP_FLAGS_VER1
	if push:
		flags |= DDP_FLAGS_PUSH

	var h := PackedByteArray()
	h.append(flags)                          # byte 0  — VVxTSRQP
	h.append(_sequence & 0x0F)               # byte 1  — xxxxnnnn
	h.append(DDP_TYPE_RGB888)                # byte 2  — data type
	h.append(ddp_device_id)                  # byte 3  — destination ID
	h.append((offset >> 24) & 0xFF)          # bytes 4-7 — offset, big-endian
	h.append((offset >> 16) & 0xFF)
	h.append((offset >> 8) & 0xFF)
	h.append(offset & 0xFF)
	h.append((length >> 8) & 0xFF)           # bytes 8-9 — length, big-endian
	h.append(length & 0xFF)
	return h


# ---------------------------------------------------------------------------
# Control protocol — status, discovery and provisioning
#
# Byte-identical to the TouchDesigner sender's, and verified against it by the
# bridge repo's round-trip tests, so the two cannot drift apart silently.
# ---------------------------------------------------------------------------


## A 10-byte DDP header for a control message. Data type is 0 (undefined)
## rather than 0x0B: the payload is JSON, not pixels. Sequence is 0 — control
## messages are not part of a frame, so gap detection must not count them.
func build_control_header(device_id: int, length: int, query: bool = false,
		reply: bool = false) -> PackedByteArray:
	var flags := DDP_FLAGS_VER1
	if query:
		flags |= DDP_FLAGS_QUERY
	if reply:
		flags |= DDP_FLAGS_REPLY

	var h := PackedByteArray()
	h.append(flags)
	h.append(0)                              # sequence unused
	h.append(0)                              # data type undefined
	h.append(device_id)
	h.append(0); h.append(0); h.append(0); h.append(0)   # offset
	h.append((length >> 8) & 0xFF)
	h.append(length & 0xFF)
	return h


## Ask the panel for its status. Sent to a broadcast address this doubles as
## discovery — the board answers unicast, so the reply carries the address the
## sender was looking for.
func build_status_query() -> PackedByteArray:
	return build_control_header(DDP_ID_STATUS, 0, true)


## Ask the panel for a single-use nonce to sign a config write against.
func build_nonce_query() -> PackedByteArray:
	return build_control_header(DDP_ID_CONFIG, 0, true)


## A signed credential write. `nonce` is the 16 raw bytes from the board's
## reply; `key` is the shared provisioning secret, which must match the
## firmware's PROVISION_KEY.
func build_config_write(nonce: PackedByteArray, config_json: PackedByteArray,
		key: PackedByteArray) -> PackedByteArray:
	assert(nonce.size() == CTRL_NONCE_LEN, "nonce must be %d bytes" % CTRL_NONCE_LEN)

	var signed := nonce.duplicate()
	signed.append_array(config_json)

	var ctx := HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, key)
	ctx.update(signed)
	var sig := ctx.finish()

	var payload := sig.duplicate()
	payload.append_array(nonce)
	payload.append_array(config_json)

	var packet := build_control_header(DDP_ID_CONFIG, payload.size())
	packet.append_array(payload)
	return packet


## Parse a control reply into a Dictionary, or return an empty one. Never
## raises: this runs on network input, and a malformed packet from something
## else on the port must not take the output down mid-set.
func parse_control_reply(data: PackedByteArray) -> Dictionary:
	if data.size() < 10:
		return {}
	if (data[0] & 0xC0) != DDP_FLAGS_VER1:
		return {}
	if (data[0] & DDP_FLAGS_REPLY) == 0:
		return {}
	if data[3] != DDP_ID_STATUS and data[3] != DDP_ID_CONFIG:
		return {}

	var length := (data[8] << 8) | data[9]
	var body := data.slice(10, 10 + length)
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


# ── Internals ────────────────────────────────────────────────────────────


func _build_taps() -> void:
	# Stage 1 — source down to 256x256.
	_stage1 = SubViewport.new()
	_stage1.size = Vector2i(INTERMEDIATE_SIZE, INTERMEDIATE_SIZE)
	_stage1.transparent_bg = false
	_stage1.gui_disable_input = true
	_stage1.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_stage1_rect = _make_rect()
	# The taps are built lazily on enable, so a fit_mode set before that had
	# nowhere to land — apply it here or the setting silently does nothing until
	# it is touched a second time.
	_stage1_rect.stretch_mode = _stretch_for(fit_mode)
	_stage1.add_child(_stage1_rect)
	add_child(_stage1)

	# Stage 2 — 256x256 down to the panel's 64x64. This is the only texture ever
	# read back to the CPU.
	_stage2 = SubViewport.new()
	_stage2.size = Vector2i(PANEL_WIDTH, PANEL_HEIGHT)
	_stage2.transparent_bg = false
	_stage2.gui_disable_input = true
	_stage2.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_stage2_rect = _make_rect()
	_stage2_rect.texture = _stage1.get_texture()
	_stage2.add_child(_stage2_rect)
	add_child(_stage2)


## ⚠️ APPLIES TO STAGE 1 ONLY, and that is the whole trick. Stage 1 is where a
## 16:9 texture meets a square target, so it is the only place aspect can be
## lost or preserved. Stage 2 is 256x256 -> 64x64 — square to square — where
## every stretch mode does exactly the same thing. Setting it on both would
## imply stage 2 had a say, and a later reader would waste time working out why
## it does not.
func set_fit_mode(value: FitMode) -> void:
	fit_mode = value
	if _stage1_rect != null:
		_stage1_rect.stretch_mode = _stretch_for(value)


func _stretch_for(value: FitMode) -> TextureRect.StretchMode:
	match value:
		FitMode.CROP:
			# Scales until the SHORTER side fits, so the long side overflows and
			# is clipped by the control — the crop is free, no scissor needed.
			return TextureRect.STRETCH_KEEP_ASPECT_COVERED
		FitMode.LETTERBOX:
			# Longer side fits; the remainder stays the viewport's clear colour,
			# which is why _stage1.transparent_bg is false — bars must be BLACK,
			# not transparent, or stage 2 samples undefined pixels at the edges.
			return TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_:
			return TextureRect.STRETCH_SCALE


func _make_rect() -> TextureRect:
	var r := TextureRect.new()
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Linear filtering is what makes the downsample an average rather than a
	# point-sample; with NEAREST the two-stage chain would buy nothing.
	r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	return r


func _active_source() -> SubViewport:
	if mode == Mode.INDEPENDENT and _independent_source != null:
		return _independent_source
	return _source


func _rebind_source() -> void:
	if _stage1_rect == null:
		return
	var src := _active_source()
	_stage1_rect.texture = src.get_texture() if src != null else null
	_set_taps_updating(enabled and src != null)


func _set_taps_updating(on: bool) -> void:
	if _stage1 == null:
		return
	# A panel-sized source bypasses the taps in _read_panel_bytes(), so leaving
	# them rendering would cost two passes a frame to produce a texture nothing
	# reads. Gate the update mode on the same condition as the bypass.
	var m := SubViewport.UPDATE_ALWAYS if (on and not _source_is_panel_sized()) \
		else SubViewport.UPDATE_DISABLED
	_stage1.render_target_update_mode = m
	_stage2.render_target_update_mode = m


func _source_is_panel_sized() -> bool:
	var src := _active_source()
	return src != null and src.size == Vector2i(PANEL_WIDTH, PANEL_HEIGHT)


## Returns false if the destination could not be set, in which case the caller
## is expected to leave the output disabled.
func _open_socket() -> bool:
	if _udp != null:
		return true
	_udp = PacketPeerUDP.new()

	# Bind before setting the destination. PacketPeerUDP will happily *send*
	# unbound, but it cannot receive — get_available_packet_count() stays at
	# zero forever — and status replies come back to the port the query left
	# from. Port 0 asks the OS for an ephemeral one, which is all we need.
	# A bind failure is not fatal: frames still go out, only status is lost.
	if _udp.bind(0) != OK:
		push_warning("[DdpOutput] could not bind for replies — status and "
			+ "discovery will be unavailable, frames are unaffected")

	var err := _udp.set_dest_address(target_ip, target_port)
	if err != OK:
		var reason := "cannot reach %s:%d (error %d)" % [target_ip, target_port, err]
		push_error("[DdpOutput] " + reason)
		_udp = null
		output_failed.emit(reason)
		return false
	return true


func _close_socket() -> void:
	if _udp != null:
		_udp.close()
		_udp = null


func _exit_tree() -> void:
	_close_socket()
