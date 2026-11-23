class_name NetSource
extends Node
## Receives one video-link stream and exposes it as a texture any consumer can
## read. Two bodies behind one API, selected by set_codec() BEFORE listen():
##   "jpeg"  (default)  MJPEG over UDP — WIRE PROTOCOL v1, Stage 0. Everything
##                      below the STAGE 1 block describes this body.
##   "h264"             Stage 1 (docs/VIDEO_LINK_SPEC.md §6.6): the PocketVJVideoLink
##                      Kotlin plugin listens on TCP, MediaCodec hardware-decodes
##                      into a SurfaceTexture latched onto an ExternalTexture's
##                      OES name. Zero copies, zero GDScript on the hot path.
##
## ── STAGE 1 (codec "h264") ───────────────────────────────────────────────
## The plugin owns sockets, codec and threads; this node is the adapter that
## keeps the scene API identical. get_texture() returns an ExternalTexture —
## created ONCE, stable reference, same contract as the JPEG ImageTexture.
## ⚠️ An ExternalTexture must NEVER be assigned as a CanvasItem texture (the
## GLES3 canvas binds GL_TEXTURE_2D; an OES name on that target is silent
## black) — consume it through a `samplerExternalOES` ShaderMaterial uniform,
## see pipeline._build_link_layer(). Freshness is driven from the plugin's
## last-frame AGE (the JVM clock and ticks_msec share no epoch, so the plugin
## reports milliseconds-since, never a timestamp). If the plugin singleton is
## missing — desktop, or an APK from before Stage 1 — set_codec("h264") warns
## once and stays on jpeg: a broken Stage 1 degrades to exactly the Stage 0
## that already ran, never to a crash.
##
## ── SHAPE ────────────────────────────────────────────────────────────────
## Like LifeSource, this is a SOURCE: a plain node that owns its output and
## hands consumers a stable object to read. Here the object is a single
## ImageTexture created in _ready() and NEVER replaced — callers hold the
## reference once and every subsequent frame updates it in place. Handing out
## a fresh texture per frame would force every consumer to re-fetch, and the
## first consumer to cache would show a frozen frame forever.
##
## ── WIRE FORMAT (must stay byte-exact with every peer) ───────────────────
## UDP packets, 18-byte header, ALL multi-byte fields BIG-ENDIAN:
##   0  4  magic ASCII "PVJV"
##   4  1  flags: bit0 = last chunk of this frame
##   5  1  stream_id (0 = device main output, 1 = camera)
##   6  2  frame_seq u16, increments per frame, wraps
##   8  4  frame_total_bytes u32 (whole JPEG size)
##   12 4  chunk_offset u32
##   16 2  chunk_len u16
##   18 .. payload, max 1382 bytes (packet <= 1400)
## Receiver rules, straight from the spec: a packet with a NEW frame_seq
## discards any incomplete frame; a frame decodes when the received byte count
## equals frame_total_bytes (⚠️ NOT the last-chunk flag — UDP reorders, and the
## flagged packet routinely arrives before the middle of the frame does);
## frame_total_bytes is capped at 1 MB so a corrupt header cannot allocate the
## phone into the ground.
##
## ── THREADING ────────────────────────────────────────────────────────────
## JPEG decode is the only expensive step (~2-8 ms for a 720p frame) and it
## runs on a worker thread through a 1-deep mailbox: if a new frame completes
## while the decoder is still chewing the last one, the waiting frame is
## REPLACED, not queued — latest-wins is the right policy for live video,
## a backlog is just latency you can never spend down.
## ⚠️ ALL texture mutation happens on the MAIN thread. The worker only ever
## touches its own Image; _process() picks the result up and applies it.
## Textures are GPU-side objects and updating one off the main thread is a
## renderer race, not a shortcut.

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

## Emitted whenever freshness() changes value (LIVE / STALE / LOST).
signal state_changed(freshness: int)

## How stale the stream is. STALE draws attention, LOST is when a consumer
## should fall back to another source.
enum Freshness { LIVE, STALE, LOST }

const HEADER_SIZE := 18
const MAGIC_0 := 0x50  # 'P'
const MAGIC_1 := 0x56  # 'V'
const MAGIC_2 := 0x4A  # 'J'
const MAGIC_3 := 0x56  # 'V'

## Spec guard: a frame claiming more than this is a corrupt or hostile header.
const MAX_FRAME_BYTES := 1_000_000

## Default receive port for the main phone (TD listens on 4852).
const DEFAULT_PORT := 4851

## OS receive buffer. The default 64 KiB holds barely a quarter of one 720p
## frame; at 24 fps the buffer must absorb everything that arrives between two
## _process() calls, including a frame-time hiccup, so ask for 1 MiB.
const RECV_BUF := 1 << 20

const STALE_MS := 250
const LOST_MS := 2000

# ── Stage 1 (h264) constants ─────────────────────────────────────────────

const H264_SINGLETON := "PocketVJVideoLink"
## Milestone port for the Stage 1 TCP listener (spec §6.6). The caller passes
## it to listen(); this is only the documented home of the number.
const H264_DEFAULT_PORT := 4853
## Decoder configure hint and initial ExternalTexture size. The plugin's
## frame_geometry signal corrects it the moment the real stream differs —
## metadata only, OES sampling is normalized, nothing restarts.
const H264_WIDTH := 1280
const H264_HEIGHT := 720
## Stats/age poll cadence. 100 ms keeps the 250 ms STALE edge honest while
## costing one JNI Dictionary marshal per tick, not per frame.
const H264_POLL_MS := 100
## While the plugin's receiver is GONE (is_receiving() false — it tears
## itself down on onGLSurfaceCreated because the old texture id dies with the
## context, and a failed rearm leaves it down too), retry start_receive this
## often. Re-fetching the id and re-arming is the recovery the plugin
## contract demands. Gating on the plugin's own truth — never on frame ages —
## is what keeps a merely-quiet stream from having its live connection torn
## down by its own receiver.
const H264_REARM_MS := 4000

## Only accept packets whose stream_id matches. -1 accepts any — fine for the
## normal one-stream-per-port layout; set it if two senders ever share a port.
@export var stream_filter: int = -1

# ── Texture (main thread only) ───────────────────────────────────────────

var _tex: ImageTexture = null
var _tex_format: int = Image.FORMAT_RGB8

# ── Stage 1 (h264) state (main thread only) ──────────────────────────────

var _codec := "jpeg"
var _plugin: Object = null             # Engine singleton, held once resolved
var _ext_tex: ExternalTexture = null   # the stable h264 texture — created once
# INTENT, not health: true from a successful listen() until stop(). The tick
# runs (and rearms) on intent; is_listening() reports the plugin's truth. A
# rearm failure must never clear this — that would disarm the very retry loop
# that exists to outlive transient failures.
var _h264_intent := false
var _h264_port := 0
var _h264_srt := {}                    # {host, ctrl} = SRT pull mode (TD leg); {} = TCP listener
var _srt_warned := false               # pre-M3 APK srt refusal warns ONCE
# Does this APK carry the Stage 3 slot-scoped receiver doors? -1 = not probed,
# 0 = pre-Stage-3 (use the whole-plugin doors), 1 = yes. Probed by CALLING:
# has_method() lies about @UsedByGodot methods, and a null return is the ONLY
# signature a missing JNI method has (see the JNI probe lesson).
var _slot_api := -1
var _h264_stats: Dictionary = {}       # last snapshot from the plugin
var _h264_poll_last := 0
var _h264_rearm_last := 0
var _h264_rearm_fails := 0             # throttles rearm warnings, 1st then every 10th
# start_receive resets the plugin's counters; this base folds pre-reset
# frames in so frames_ok never moves backwards — the bottom bar's "once
# flowed, LOST shows red" contract (see pipeline._update_link_stats) rides
# on that count surviving a rearm.
var _h264_frames_base := 0
var _h264_frames_last := 0

# ── UDP + reassembly (main thread only) ──────────────────────────────────

var _udp := PacketPeerUDP.new()
var _cur_seq: int = -1
var _cur_total: int = 0
var _cur_received: int = 0
# offset -> payload slice. A dictionary rather than writing into a prebuilt
# buffer because GDScript has no byte-range blit — a per-byte copy loop over
# ~700 chunks a frame would cost more than the decode. append_array() at
# completion is a C++ memcpy and near free. The dictionary also de-duplicates:
# a repeated offset is ignored, so a duplicated packet cannot inflate the
# received count into a premature (and corrupt) "complete".
var _chunks: Dictionary = {}

# ── Worker thread + mailboxes ────────────────────────────────────────────

var _thread: Thread = null
var _job_sem := Semaphore.new()
var _job_mutex := Mutex.new()
var _job := PackedByteArray()          # 1-deep in-mailbox, guarded by _job_mutex
var _quit: bool = false                # guarded by _job_mutex

var _out_mutex := Mutex.new()
var _result: Dictionary = {}           # 1-deep out-mailbox, guarded by _out_mutex
var _result_drops: int = 0             # results overwritten unseen, guarded by _out_mutex

# ── Stats (main thread only) ─────────────────────────────────────────────

var _frames_ok: int = 0
var _frames_dropped: int = 0
var _decode_ms: float = 0.0
var _decode_fails: int = 0
var _fps: float = 0.0
var _kbps: float = 0.0
var _win_start: int = 0
var _win_frames: int = 0
var _win_bytes: int = 0
var _last_frame_ms: int = -1           # -1 = never received a frame
var _last_state: int = Freshness.LOST


func _ready() -> void:
	# Pro module (Features.TD_PVJ_LINK). pipeline never builds it in the public
	# build; this is the backstop if anything ever does.
	if not FeaturesS.is_pro():
		push_warning("[net_source] pro-only module in a public build — freed")
		queue_free()
		return
	# 16x9 black placeholder so a consumer wired before the first frame shows
	# black, not a magenta missing-texture error. Image.create zero-fills.
	var img := Image.create(16, 9, false, Image.FORMAT_RGB8)
	_tex = ImageTexture.create_from_image(img)
	_win_start = Time.get_ticks_msec()
	_thread = Thread.new()
	_thread.start(_decode_worker)


# ── Public API ───────────────────────────────────────────────────────────

## Pick the transport body. Call BEFORE listen(); a change while bound is
## refused (the pipeline rebuilds NetSource on a codec flip, so a mid-run
## switch here would only ever be a bug). "h264" silently stays "jpeg" when
## the plugin singleton is absent — the caller reads back get_codec() and
## gets the truth, which is also what the beacon must advertise.
func set_codec(codec: String) -> void:
	if codec == _codec:
		return
	if is_listening():
		push_warning("[NetSource] set_codec('%s') while listening — ignored" % codec)
		return
	match codec:
		"jpeg":
			_codec = "jpeg"
		"h264":
			if not Engine.has_singleton(H264_SINGLETON):
				push_warning("[NetSource] codec 'h264' requested but %s plugin is missing "
						% H264_SINGLETON + "(desktop, or a pre-Stage-1 APK) — staying on jpeg")
				return
			_plugin = Engine.get_singleton(H264_SINGLETON)
			_codec = "h264"
		_:
			push_warning("[NetSource] unknown codec '%s' — keeping '%s'" % [codec, _codec])


## The EFFECTIVE codec — after any fallback. This, not the setting, is what
## the beacon advertises: a peer aimed by the settings value could stream
## H.264 at a phone that quietly fell back to jpeg.
func get_codec() -> String:
	return _codec


## Bind the receive port. Safe to call again to move ports. A failed bind
## (port taken, no network) warns and returns the error — never crashes.
## In h264 mode the port is TCP and the plugin owns it (spec §6.6).
func listen(port: int = DEFAULT_PORT) -> Error:
	if _codec == "h264":
		_h264_srt = {}   # listener mode; pull_srt() is the other door
		return _h264_listen(port)
	_udp.close()
	_reset_partial()
	var err := _udp.bind(port, "*", RECV_BUF)
	if err != OK:
		push_warning("[NetSource] could not bind UDP port %d: error %d" % [port, err])
	return err


## Pull mode, the TD leg (M3 S1): instead of listening, dial the peer's SRT
## video listener at host:video_port — the plugin rings TD's srt_arm
## doorbell on ctrl_port before every dial (TD's Video Stream Out is
## single-shot per Active cycle), so there is no 'start' request; the dial
## IS the start. h264-only by construction. Same rearm behavior as
## listen(): a GL context recreation re-dials the stored target.
func pull_srt(host: String, video_port: int, ctrl_port: int) -> Error:
	if _codec != "h264":
		push_warning("[NetSource] pull_srt needs the h264 plugin — refusing")
		return ERR_UNAVAILABLE
	if host.strip_edges() == "" or video_port <= 0 or video_port > 65535 \
			or ctrl_port <= 0 or ctrl_port > 65535:
		push_warning("[NetSource] pull_srt with bad target %s:%d ctrl %d — refusing"
				% [host, video_port, ctrl_port])
		return ERR_INVALID_PARAMETER
	_h264_srt = {"host": host.strip_edges(), "ctrl": ctrl_port}
	return _h264_listen(video_port)


## Which plugin receiver slot this instance owns. DERIVED from _h264_srt (the
## same field that already decides which start door listen() walks through), so
## it can never drift out of sync with the receiver actually running. Two
## NetSource instances therefore address two independent slots without either
## needing to be told which one it is.
func _slot() -> String:
	return "srt" if not _h264_srt.is_empty() else "tcp"


## True when the APK exposes stop_receive_slot/is_receiving_slot/get_stats_slot.
## One probe per instance, cached — a pre-Stage-3 APK keeps the old whole-plugin
## behaviour, which is correct for it because it can only hold one receiver.
func _has_slot_api() -> bool:
	if _slot_api < 0:
		if _plugin == null:
			return false
		var r: Variant = _plugin.call("is_receiving_slot", _slot())
		_slot_api = 0 if r == null else 1
		# Say it once per instance. Which door an APK offers decides whether two
		# layers can coexist at all, and the failure when it is missing is a
		# SILENT one (the sibling's receiver quietly torn down) — so the answer
		# belongs in the log before anything depends on it, not after.
		print("[NetSource] slot '%s': %s receiver API" % [_slot(),
				"slot-scoped" if _slot_api == 1 else "LEGACY whole-plugin (pre-Stage-3 APK)"])
	return _slot_api == 1


## The plugin's truth for THIS slot. ⚠️ Must be per-slot once two instances
## exist: the aggregate is_receiving() would report a healthy sibling as
## "receiving" to an instance whose own receiver had died, and the rearm that
## instance is owed would never fire — a silently dead layer.
func _plugin_is_receiving() -> bool:
	if _plugin == null:
		return false
	if _has_slot_api():
		return bool(_plugin.call("is_receiving_slot", _slot()))
	return bool(_plugin.is_receiving())


## Tear down THIS slot only, so a sibling instance keeps its layer.
func _plugin_stop_receive() -> void:
	if _plugin == null:
		return
	if _has_slot_api():
		_plugin.call("stop_receive_slot", _slot())
	else:
		_plugin.stop_receive()


## Stop receiving. The last decoded frame stays on the texture — same policy
## as LifeSource.set_running(false): a frozen frame reads as "paused", a black
## one reads as a fault. freshness() decays to LOST on its own. (The plugin
## honours the same rule: stop_receive never touches the GL texture, so the
## h264 layer freezes too, not blacks.)
func stop() -> void:
	if _codec == "h264":
		_plugin_stop_receive()   # idempotent on the Kotlin side, and slot-scoped
		_h264_intent = false
		return
	_udp.close()
	_reset_partial()
	# Clear any undecoded frame so a later listen() starts clean. No semaphore
	# accounting needed: the worker treats an empty job as a spurious wake.
	_job_mutex.lock()
	_job = PackedByteArray()
	_job_mutex.unlock()


## True while the receive socket is actually bound. listen() can fail (port
## taken by a second instance) and warns exactly once — this is what a caller
## checks BEFORE asking a peer to stream here, because a sender aimed at an
## unbound port burns its encode and the WiFi with nothing to show for it.
func is_listening() -> bool:
	if _codec == "h264":
		# The plugin's truth, not our intent: after a GL context recreation
		# the receiver is gone until the rearm lands, and a sender aimed in
		# that window would connect to nothing.
		return _h264_intent and _plugin != null and _plugin_is_receiving()
	return _udp.is_bound()


## The stable texture. Grab it ONCE and keep the reference — it is updated in
## place forever, including across resolution changes. In h264 mode it is the
## ExternalTexture (⚠️ shader-uniform consumption only — see the header).
func get_texture() -> Texture2D:
	if _codec == "h264":
		_h264_ensure_texture()
		return _ext_tex
	return _tex


## Same schema in both modes — the bottom-bar row indexes these exact keys.
## h264 values come from the plugin's last snapshot (polled in _process);
## coerced per key because a JNI Dictionary's numeric types are its own.
func get_stats() -> Dictionary:
	if _codec == "h264":
		return {
			"fps": float(_h264_stats.get("fps", 0.0)),
			"decode_ms": float(_h264_stats.get("decode_ms", 0.0)),
			"kbps": float(_h264_stats.get("kbps", 0.0)),
			# Base + snapshot: cumulative across rearms, like the jpeg body's
			# _frames_ok is cumulative across stop()/listen().
			"frames_ok": _h264_frames_base + int(_h264_stats.get("frames_ok", 0)),
			"frames_dropped": int(_h264_stats.get("frames_dropped", 0)),
		}
	return {
		"fps": _fps,
		"decode_ms": _decode_ms,
		"kbps": _kbps,
		"frames_ok": _frames_ok,
		"frames_dropped": _frames_dropped,
	}


## LIVE within STALE_MS of the last decoded frame, STALE to LOST_MS, LOST
## after that (and before the first frame ever arrives).
func freshness() -> int:
	if _last_frame_ms < 0:
		return Freshness.LOST
	var age := Time.get_ticks_msec() - _last_frame_ms
	if age >= LOST_MS:
		return Freshness.LOST
	if age >= STALE_MS:
		return Freshness.STALE
	return Freshness.LIVE


# ── Wire helpers ─────────────────────────────────────────────────────────
# ⚠️ Hand-rolled because PackedByteArray.decode_u16/u32 are LITTLE-endian and
# the wire is BIG-endian. Using the built-ins here is the byte-swap bug that
# passes every same-machine test and fails against the first real peer.

static func _be16(b: PackedByteArray, o: int) -> int:
	return (b[o] << 8) | b[o + 1]


static func _be32(b: PackedByteArray, o: int) -> int:
	return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]


# ── Main loop ────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _codec == "h264":
		_h264_tick()
	else:
		# Drain EVERYTHING waiting, not one packet per frame: a 720p frame is
		# ~200 packets, so one-per-frame would fall behind by design.
		while _udp.get_available_packet_count() > 0:
			_ingest(_udp.get_packet())

		_collect_result()
		_update_window()

	# Shared by both bodies: freshness works off _last_frame_ms either way,
	# and the LOST decay must keep emitting even when nothing is listening.
	var f := freshness()
	if f != _last_state:
		_last_state = f
		state_changed.emit(f)


# ── Stage 1 (h264) body ──────────────────────────────────────────────────

## Create the stable ExternalTexture (once, ever — recreating it would orphan
## the plugin's SurfaceTexture and break every consumer's held reference) and
## hook the geometry correction. Only the ID fetch needs the renderer up, so
## constructing here is safe whenever get_texture() is first called.
func _h264_ensure_texture() -> void:
	if _ext_tex != null:
		return
	_ext_tex = ExternalTexture.new()
	_ext_tex.size = Vector2(H264_WIDTH, H264_HEIGHT)
	# The plugin outlives this node (Engine singleton); Godot auto-disconnects
	# callables of freed objects, so a rebuilt NetSource never double-fires.
	_plugin.connect("frame_geometry", _on_h264_frame_geometry)


func _h264_listen(port: int, rearm := false) -> Error:
	_h264_ensure_texture()
	_h264_port = port
	# Fetched fresh on every (re)listen: the first call materializes the GL
	# name, and after a GL context recreation the old name is dead — this is
	# the one line that revives the path.
	var tex_id := _ext_tex.get_external_texture_id()
	if tex_id <= 0:
		# Renderer hasn't (re)materialized the name yet — a transient of
		# context recreation, NOT a bind failure. Named honestly so nobody
		# chases a phantom port squatter; the rearm tick retries.
		_h264_warn_listen(rearm, "ExternalTexture has no GL name yet (id %d)" % tex_id)
		return ERR_CANT_CREATE
	var ok := false
	if not _h264_srt.is_empty():
		# SRT pull mode (the TD leg): the plugin dials OUT and rings the
		# srt_arm doorbell itself; the rearm tick re-enters here with the
		# stored target after a GL context recreation. Probe by CALLING
		# (the has_method lesson): a pre-M3 APK answers null.
		var r: Variant = _plugin.call("start_receive_srt",
				str(_h264_srt["host"]), port, int(_h264_srt["ctrl"]),
				tex_id, int(_ext_tex.size.x), int(_ext_tex.size.y))
		if r == null:
			if not _srt_warned:
				_srt_warned = true
				push_warning("[NetSource] plugin has no SRT pull "
						+ "(pre-M3 APK) — srt pulls refused; tcp unaffected")
			return ERR_CANT_CREATE
		ok = bool(r)
	else:
		ok = bool(_plugin.start_receive(port, tex_id,
				int(_ext_tex.size.x), int(_ext_tex.size.y)))
	if not ok:
		_h264_warn_listen(rearm, "could not start receiver on port %d — plugin refused" % port)
		return ERR_CANT_CREATE
	_h264_rearm_fails = 0
	if not rearm:
		# Only the caller-facing listen() sets intent; a rearm neither grants
		# it (stop() already revoked it) nor — on failure — revokes it.
		_h264_intent = true
	return OK


## First-listen failures are loud (the caller gets the Error and the beacon
## must not advertise the port); rearm failures are throttled — one per
## H264_REARM_MS is 15 lines a minute of the same news.
func _h264_warn_listen(rearm: bool, msg: String) -> void:
	if not rearm:
		push_warning("[NetSource] h264 listen failed: %s" % msg)
		return
	_h264_rearm_fails += 1
	if _h264_rearm_fails == 1 or _h264_rearm_fails % 10 == 0:
		push_warning("[NetSource] h264 rearm failed: %s (%d so far)"
				% [msg, _h264_rearm_fails])


## Per-frame h264 upkeep: latch, then (throttled) poll stats and translate the
## plugin's frame AGE into the ticks domain _last_frame_ms lives in.
func _h264_tick() -> void:
	if not _h264_intent or _plugin == null:
		return
	# Latch the newest decoded frame BEFORE this frame renders — without it
	# the plugin's onGLDrawFrame safety net still latches, one frame late.
	_plugin.pump_frame()

	var now := Time.get_ticks_msec()
	if now - _h264_poll_last < H264_POLL_MS:
		return
	_h264_poll_last = now
	_h264_stats = _plugin.call("get_stats_slot", _slot()) if _has_slot_api() \
			else _plugin.get_stats()
	var age := int(_h264_stats.get("last_frame_msec", -1))
	if age >= 0:
		# AGE, not timestamp — the JVM clock and ticks_msec share no epoch.
		_last_frame_ms = now - age
	# A snapshot count below the last one means start_receive reset the
	# plugin's stats (a rearm landed): bank what was on record.
	var fok := int(_h264_stats.get("frames_ok", 0))
	if fok < _h264_frames_last:
		_h264_frames_base += _h264_frames_last
	_h264_frames_last = fok

	# GL-recreation recovery (see H264_REARM_MS). Gated on the plugin's own
	# is_receiving(), the only honest signal: frame ages can't distinguish
	# "receiver torn down" from "sender quiet", and acting on the latter tore
	# down live connections the plugin was still happily inside its own 4 s
	# grace for. An idle-but-bound listener polls as receiving and is left
	# alone; a torn-down one rearms even before its first-ever frame.
	if not _plugin_is_receiving() and now - _h264_rearm_last >= H264_REARM_MS:
		_h264_rearm_last = now
		_h264_listen(_h264_port, true)


## The decoded stream's display size differs from the configure hint. Metadata
## only — OES sampling is normalized, so this never tears or restarts.
func _on_h264_frame_geometry(w: int, h: int) -> void:
	if _ext_tex != null:
		_ext_tex.size = Vector2(w, h)


func _ingest(packet: PackedByteArray) -> void:
	_win_bytes += packet.size()
	if packet.size() < HEADER_SIZE:
		return
	if packet[0] != MAGIC_0 or packet[1] != MAGIC_1 \
			or packet[2] != MAGIC_2 or packet[3] != MAGIC_3:
		return
	# packet[4] is flags; bit0 (last chunk) is deliberately unused — see header.
	if stream_filter >= 0 and packet[5] != stream_filter:
		return
	var seq := _be16(packet, 6)
	var total := _be32(packet, 8)
	var offset := _be32(packet, 12)
	var clen := _be16(packet, 16)
	if total <= 0 or total > MAX_FRAME_BYTES:
		return
	if clen != packet.size() - HEADER_SIZE:
		return
	if offset + clen > total:
		return

	if seq != _cur_seq:
		# Spec rule: any new frame_seq abandons the partial frame. This is also
		# the loss-recovery path — one dropped packet costs one frame, not a
		# wedged reassembler.
		if _cur_seq >= 0:
			_frames_dropped += 1
		_cur_seq = seq
		_cur_total = total
		_cur_received = 0
		_chunks.clear()
	elif total != _cur_total:
		# Same seq claiming a different size: junk. Drop the whole frame.
		_frames_dropped += 1
		_reset_partial()
		return

	if _chunks.has(offset):
		return
	_chunks[offset] = packet.slice(HEADER_SIZE)
	_cur_received += clen

	if _cur_received == _cur_total:
		var jpeg := _assemble()
		_reset_partial()
		if jpeg.is_empty():
			_frames_dropped += 1
			return
		_submit(jpeg)
	elif _cur_received > _cur_total:
		_frames_dropped += 1
		_reset_partial()


## Stitch the chunks back together in offset order. Returns empty on any gap
## or overlap — right byte COUNT with wrong byte LAYOUT decodes to garbage.
func _assemble() -> PackedByteArray:
	var offsets := _chunks.keys()
	offsets.sort()
	var out := PackedByteArray()
	for o in offsets:
		if int(o) != out.size():
			return PackedByteArray()
		out.append_array(_chunks[o])
	if out.size() != _cur_total:
		return PackedByteArray()
	return out


## Hand a complete JPEG to the decoder. 1-deep, latest-wins: an unconsumed
## older frame is replaced and counted dropped. The semaphore is only posted
## when the mailbox was empty, so its count never runs ahead of real work.
func _submit(jpeg: PackedByteArray) -> void:
	_job_mutex.lock()
	var had_pending := not _job.is_empty()
	_job = jpeg
	_job_mutex.unlock()
	if had_pending:
		_frames_dropped += 1
	else:
		_job_sem.post()


## Pick up whatever the worker finished and apply it — the ONLY place the
## texture is touched.
func _collect_result() -> void:
	_out_mutex.lock()
	var r := _result
	_result = {}
	var drops := _result_drops
	_result_drops = 0
	_out_mutex.unlock()

	_frames_dropped += drops
	if r.is_empty():
		return
	_decode_ms = r["decode_ms"]
	var img: Image = r["image"]
	if img == null:
		_frames_dropped += 1
		_decode_fails += 1
		# Throttled: at 24 fps a bad sender would otherwise print 24 warnings
		# a second and bury everything else in the log.
		if _decode_fails == 1 or _decode_fails % 100 == 0:
			push_warning("[NetSource] JPEG decode failed (%d so far)" % _decode_fails)
		return

	# update() needs size AND format to match; a grayscale JPEG decodes to L8
	# while color is RGB8, so format alone can force the slow path.
	if img.get_width() == _tex.get_width() and img.get_height() == _tex.get_height() \
			and img.get_format() == _tex_format:
		_tex.update(img)
	else:
		# set_image(), NOT create_from_image(): the resize happens inside the
		# SAME texture object, so every caller's held reference stays valid.
		_tex.set_image(img)
		_tex_format = img.get_format()

	_frames_ok += 1
	_win_frames += 1
	_last_frame_ms = Time.get_ticks_msec()


## Roll the 1 s stats window. fps and kbps go to zero on their own when the
## stream stops, which is what makes them honest.
func _update_window() -> void:
	var now := Time.get_ticks_msec()
	var elapsed := now - _win_start
	if elapsed < 1000:
		return
	_fps = _win_frames * 1000.0 / elapsed
	_kbps = _win_bytes * 8.0 / elapsed
	_win_start = now
	_win_frames = 0
	_win_bytes = 0


func _reset_partial() -> void:
	_cur_seq = -1
	_cur_total = 0
	_cur_received = 0
	_chunks.clear()


# ── Worker thread ────────────────────────────────────────────────────────

func _decode_worker() -> void:
	while true:
		_job_sem.wait()
		_job_mutex.lock()
		var quit := _quit
		var jpeg := _job
		_job = PackedByteArray()
		_job_mutex.unlock()
		if quit:
			return
		if jpeg.is_empty():
			continue  # spurious wake (stop() cleared the mailbox)
		var t0 := Time.get_ticks_usec()
		var img := Image.new()
		var err := img.load_jpg_from_buffer(jpeg)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		_out_mutex.lock()
		if not _result.is_empty():
			_result_drops += 1
		_result = {
			"image": img if err == OK else null,
			"decode_ms": ms,
		}
		_out_mutex.unlock()


func _exit_tree() -> void:
	if _plugin != null and _h264_intent:
		_plugin_stop_receive()
		_h264_intent = false
	_udp.close()
	_job_mutex.lock()
	_quit = true
	_job_mutex.unlock()
	_job_sem.post()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
