class_name NetSender
extends Node
## Sends one video-link stream. Two bodies behind one API, selected per start()
## by the codec the REQUESTER asked for (§6.4 — the field defaults to "jpeg",
## so every existing call site is byte-identical):
##   "jpeg"  (default)  MJPEG over UDP — WIRE PROTOCOL v1, Stage 0. Everything
##                      below the STAGE 1 block describes this body.
##   "h264"             Stage 1 send (docs/VIDEO_LINK_SPEC.md §6.6): the same
##                      readback handed to the PocketVJVideoLink plugin, which
##                      converts + encodes (MediaCodec H.264, low-latency) +
##                      frames + CONNECTS OUT to the peer's TCP 4853 listener,
##                      all on its own thread.
##
## Owns a small SubViewport that rescales whatever texture set_source() hands it
## down to stream resolution, so the capture readback is a 640x360 image no
## matter how large the real output is (1280x720 in h264 mode — spec §3.4 v1).
## The shape mirrors LifeSource: a self-contained node that owns its viewport
## and exposes it through plain methods, with no reach into the pipeline.
##
## ── STAGE 1 (codec "h264") ───────────────────────────────────────────────
## The capture tick — including the burn-in label, which lives INSIDE the
## SubViewport and is therefore upstream of the readback — is shared with the
## jpeg body; only the mailbox differs: the plugin keeps its own 1-deep
## latest-wins mailbox behind push_frame() (drop, never buffer — the jpeg
## worker's policy, encoder edition), so the worker thread below never sees an
## h264 frame. v1 h264 is SINGLE-destination (§6.6: the far end accepts
## serially, a fan-out would stream into a kernel backlog nobody reads) — a
## new h264 start REPLACES the destination, and the reconnect is what
## guarantees fresh SPS/PPS. If the plugin singleton is missing or predates
## the send path, an h264 start warns once and REFUSES — never a jpeg
## fallback, because the requester aimed a TCP port at us that cannot parse
## MJPEG; jpeg requests are unaffected either way.
##
## FEEDS (milestone 2.5(b), spec §5 Stage 1 send v2): the h264 body has two
## ways of filling that encoder. "gpu" (default) hands the plugin the
## SubViewport's render-target GLuint (the projector/recorder pattern from
## pipeline.gd) and the render thread blits straight into the encoder's input
## Surface — the capture tick then does NO per-frame work at all: no
## get_image, no format convert, nothing but the seq advance the burn-in
## stamp's Δseq cross-check needs. The burn-in label still rides: it lives in
## the SubViewport, upstream of whichever feed reads it. "cpu" is the v1
## readback → push_frame stepping stone, kept as the escape hatch ([link]
## encoder_feed="cpu") and as the automatic fallback when the APK predates
## the GPU feed or its encoder refuses to build — degrade loudly to the
## slower feed of the SAME wire, never to black.
##
## ── THREADING ────────────────────────────────────────────────────────────
## The tick runs on the MAIN thread and does exactly one expensive thing: the
## GPU→CPU readback (get_image). JPEG encode and UDP send happen on a single
## worker thread, fed through a 1-deep mailbox. If the worker is still busy
## when the next frame arrives, the NEW frame is DROPPED — never queued.
## Queueing would smooth a momentary spike into permanent latency: every frame
## after the spike arrives one slot late, forever. Dropping keeps the stream
## live-ish, which is the whole point of a monitor feed.
##
## ⚠️ ALL multi-byte header fields are BIG-ENDIAN. StreamPeerBuffer defaults to
## little-endian; forgetting `big_endian = true` produces packets that parse as
## garbage sizes on the receiver and fail the frame-total guard — a silent
## black stream, not an error.

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

## Chunk payload cap. 18-byte header + 1382 = 1400, under a common 1500 MTU
## with room for IP/UDP headers. Must match the receiver byte-for-byte.
const MAX_PAYLOAD := 1382

## Sender-side mirror of the receiver's sanity guard: a frame this large would
## be discarded on arrival anyway, so don't spend the bandwidth sending it.
const MAX_FRAME_BYTES := 1_000_000

## Stream resolution. 640x360 keeps a 24 fps JPEG stream in the low hundreds
## of kbit/s at default quality — a monitor feed, not a mastering path.
@export var stream_size: Vector2i = Vector2i(640, 360)

# ── Stage 1 (h264) constants ─────────────────────────────────────────────

const H264_SINGLETON := "PocketVJVideoLink"   # same singleton NetSource holds
## Stage 1 streams 720p (spec §3.4 v1): the viewport rescales to this while
## the h264 body is active, so the readback — the measured §9-M3 cost this
## v1 accepts until the v2 GPU blit — is exactly one 1280x720 image.
const H264_SIZE := Vector2i(1280, 720)
## Encoder budget, matching the PC test sender's default: ~4 Mbps CBR keeps
## three streams inside the §8 bandwidth table with margin.
const H264_BITRATE_BPS := 4_000_000

# ── Viewport ─────────────────────────────────────────────────────────────

var _view: SubViewport = null
var _rect: TextureRect = null
var _debug_label: Label = null   # latency burn-in; null = off, the normal path

# ── Stream config (main thread writes, worker reads via the mailbox job) ─

var _active := false
## Destinations, keyed by ip — ONE receiver per host, so a re-request from the
## same address (an app restart, a port move) replaces its entry rather than
## accumulating, and one host can never be streamed to twice. Values {ip, port}.
## In h264 mode the dictionary holds AT MOST one entry (§6.6 single
## destination) and only bookkeeps stop_target()/stop() — the wire lives in
## the plugin.
var _targets: Dictionary = {}
var _stream_id := 0
var _fps := 24.0
var _quality := 0.75

# ── Stage 1 (h264) state (main thread only) ──────────────────────────────

var _codec := "jpeg"                   # the ACTIVE body; sticky across stop()
var _plugin: Object = null             # Engine singleton, held once resolved
var _h264_warned := false              # missing plugin/send path warns ONCE
var _gpu_feed := true                  # [link] encoder_feed preference; false = v1 readback
var _gpu_active := false               # the RUNNING h264 stream rides the GPU feed
var _gpu_warned := false               # pre-2.5(b) APK fallback warns ONCE
var _transport := "tcp"                # h264 wire: "tcp" raw-NAL | "srt" MPEG-TS (TD leg)
var _srt_warned := false               # pre-M3 APK srt refusal warns ONCE
var _last_send_gl_id := 0              # render-target GLuint last published (0 = never)

var _accum := 0.0
var _frame_seq := 0

# ── Worker + mailbox ─────────────────────────────────────────────────────

var _thread: Thread = null
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _quit := false
## The 1-deep mailbox: null = empty, Dictionary = one pending job. The job
## carries EVERYTHING the worker needs (image, seq, targets, quality) so the
## worker never reads mutable config — a mid-flight start() with a new target
## affects the next frame, not the one being encoded.
var _job: Variant = null

# ── Stats (shared fields guarded by _mutex; readback is main-thread-only) ─

var _readback_ms := 0.0
var _encode_ms := 0.0
var _frames_sent := 0
var _frames_dropped := 0
var _win_start := 0.0
var _win_frames := 0
var _win_bytes := 0
var _last_fps := 0.0
var _last_kbps := 0.0


func _ready() -> void:
	# Pro module (Features.TD_PVJ_LINK). pipeline never builds it in the public
	# build; this is the backstop if anything ever does.
	if not FeaturesS.is_pro():
		push_warning("[net_sender] pro-only module in a public build — freed")
		queue_free()
		return
	_build_viewport()
	# The worker is created once and lives for the node's lifetime, parked on
	# the semaphore. Starting/stopping the stream never touches the thread, so
	# there is no start/join lifecycle to get wrong twice.
	_thread = Thread.new()
	_thread.start(_worker)
	set_process(false)


func _build_viewport() -> void:
	_view = SubViewport.new()
	_view.size = stream_size
	_view.transparent_bg = false
	_view.gui_disable_input = true
	# Idle until start(): an UPDATE_ALWAYS viewport nobody is capturing is a
	# 640x360 render pass burned every frame — the same reasoning that keeps
	# LifeSource's viewport disarmed. start() flips it to UPDATE_ALWAYS.
	_view.render_target_update_mode = SubViewport.UPDATE_DISABLED

	_rect = TextureRect.new()
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_view.add_child(_rect)
	add_child(_view)


# ── Public API ───────────────────────────────────────────────────────────

## Point the sender at a texture (a ViewportTexture from the output world, a
## camera feed — anything). Passing null clears it; the sender then sends
## nothing until a real source arrives, active or not.
func set_source(tex: Texture2D) -> void:
	if _rect == null:
		push_warning("NetSender: set_source before _ready, ignored")
		return
	_rect.texture = tex


## Begin (or JOIN) the stream. Calling while active ADDS the destination: one
## capture, one encode, every target gets the same chunks — so a second
## consumer of the same stream costs bandwidth, not a steal. (The old
## one-target retarget plus the receivers' 3 s LOST-retry made two pullers of
## one cam stream steal it back and forth forever, both strobing LIVE/LOST.)
## A start for a DIFFERENT stream_id still retargets everyone — one viewport,
## one encoder, one stream at a time; last writer wins there, as ever. fps and
## quality are also last-writer-wins, and an fps change takes effect on the
## very next tick — the accumulator model has no timer to restart.
## codec (§6.4, default "jpeg" = every old call site unchanged) picks the
## body: the JOIN semantics above are jpeg-only — an h264 start REPLACES the
## destination (§6.6 single destination, including a re-ask from the same
## address: the reconnect is what guarantees fresh SPS/PPS). A codec FLIP is
## not last-writer-wins (§6.6 cross-codec rule): while the other codec's
## consumers hold the stream it is REFUSED — the asker leaves its old pool
## first, so a sole consumer changing posture still wins the flip.
## Returns true when THIS call took effect; false is a refusal (bad args,
## unknown codec, missing send plugin, contested codec flip) the caller must
## surface itself — is_active() cannot answer for one call while some OTHER
## still-running stream keeps it true.
func start(target_ip: String, target_port: int, stream_id: int = 0, fps: float = 24.0,
		quality: float = 0.75, codec: String = "jpeg", transport: String = "tcp") -> bool:
	if target_ip.strip_edges() == "":
		push_warning("NetSender: start() with empty target ip, ignored")
		return false
	if target_port <= 0 or target_port > 65535:
		push_warning("NetSender: start() with bad port %d, ignored" % target_port)
		return false
	if codec != "jpeg" and codec != "h264":
		# Refuse, never fall back: a requester asking for a codec this build
		# has never heard of aimed its port at THAT wire format, and jpeg
		# blasted at it would be bytes into a parser that cannot say no.
		push_warning("NetSender: start() with unknown codec '%s', ignored" % codec)
		return false
	if transport != "tcp" and transport != "srt":
		# The codec rule, transport edition (§6.4): the requester's port
		# speaks ONE framing; the wrong one is bytes into a parser that
		# cannot say no.
		push_warning("NetSender: start() with unknown transport '%s', ignored" % transport)
		return false
	if transport == "srt" and codec != "h264":
		push_warning("NetSender: srt transport is h264-only (the TD leg), ignored")
		return false
	if codec == "h264" and not _h264_ready():
		return false   # warned (once) inside; jpeg requests keep working unaffected
	if transport == "srt" and not _srt_ready():
		# Refused BEFORE any teardown, deliberately: every synchronously-
		# knowable srt gate lives in _srt_ready() so a refused srt ask cannot
		# stop_send a healthy running stream (the contested-flip lesson,
		# transport edition — a killed stream's 3 s LOST-retry vs the asker's
		# retry is the exact LIVE/LOST strobe that gate exists to prevent).
		return false
	var sid := clampi(stream_id, 0, 255)
	var ip := target_ip.strip_edges()
	if _active and codec != _codec:
		# One wire format at a time, but a codec flip must NOT be last-writer-
		# wins (§6.6): honouring it would clear the other codec's consumers,
		# whose 3 s LOST-retry would steal the stream straight back — encoder
		# and viewport flipping every ≤3 s, both sides strobing LIVE/LOST
		# forever, the exact oscillation the jpeg fan-out join was built to
		# kill. The asker leaves its old pool first (it is opting out of that
		# wire either way); the flip proceeds only when that empties the pool,
		# so a sole consumer changing posture still wins and a CONTESTED flip
		# is refused. Warned per ask, not once: unlike a missing plugin, this
		# answer changes the moment the other consumer lets go.
		_targets.erase(ip)
		if not _targets.is_empty():
			push_warning("NetSender: %s start refused — %d %s consumer(s) hold the stream" % [
					codec, _targets.size(), _codec])
			return false
	# Every refusal that can leave the CURRENT stream running is behind us —
	# only now may the ask mutate shared state (a refused ask that had
	# already retuned _fps/_quality was retuning a stream it never owned).
	# The one refusal left, _start_h264_send's encoder build, tears the
	# stream down anyway via stop().
	_transport = transport
	_fps = clampf(fps, 1.0, 60.0)
	_quality = clampf(quality, 0.05, 1.0)
	# A stream_id change (or the now-uncontested codec flip) retargets
	# EVERYONE: one viewport, one encoder, one stream at a time — last
	# writer wins there, as ever.
	if _active and (sid != _stream_id or codec != _codec):
		if _codec == "h264" and _plugin != null:
			_plugin.stop_send()
		_targets.clear()
	_stream_id = sid

	if codec == "h264":
		# Single destination (§6.6): the far end serves one connection at a
		# time, so a second entry would stream into a kernel backlog nobody
		# reads. Replace — including the same address, deliberately: the
		# reconnect restarts the far decoder with fresh SPS/PPS, the same
		# repeat-start-is-restart contract the jpeg pull retry leans on.
		if _codec == "h264" and _active and not _targets.is_empty():
			_plugin.stop_send()
		_targets.clear()
		if _view != null and _view.size != H264_SIZE:
			_view.size = H264_SIZE
		if not _start_h264_send(ip, target_port):
			# False is SYNCHRONOUS knowledge only — bad geometry/args, or the
			# encoder refused to build (logcat says which). A dead peer is NOT
			# in here: the connect is asynchronous and the plugin redials every
			# 2 s while started, so an unreachable receiver keeps this stream
			# nominally active and heals on its own — the same repeat-ask
			# contract the jpeg pull retry leans on, not a failure to report.
			push_warning("NetSender: plugin refused start_send %s:%d — not sending" % [ip, target_port])
			stop()
			return false
		_codec = "h264"
	else:
		if _codec == "h264":
			# Back to Stage 0: the retarget above already stopped the plugin
			# send; the viewport returns to monitor-feed resolution.
			_codec = "jpeg"
			if _view != null and _view.size != stream_size:
				_view.size = stream_size
	_targets[ip] = {"ip": ip, "port": target_port}
	if not _active:
		_active = true
		_accum = 0.0
		_mutex.lock()
		_win_start = _now()
		_win_frames = 0
		_win_bytes = 0
		_mutex.unlock()
	if _view != null:
		_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	set_process(true)
	return true


## Stop sending to EVERYONE. The worker may still be encoding one in-flight
## frame, which is allowed to complete — half a frame on the wire is worse
## than one late one. (The h264 body has no such grace: stop_send closes the
## connection, and the far end's fresh-decoder-per-connection rule means a
## truncated tail frame costs nothing.)
func stop() -> void:
	_active = false
	_targets.clear()
	set_process(false)
	if _codec == "h264" and _plugin != null:
		_plugin.stop_send()   # idempotent on the Kotlin side, both feeds
	_gpu_active = false
	if _view != null:
		_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	# Discard any frame parked in the mailbox: the semaphore post it came with
	# just wakes the worker to find nothing, which is harmless.
	_mutex.lock()
	_job = null
	_mutex.unlock()


## Remove ONE destination — a peer said stop, or its link owner tore down.
## The stream only ends when the last one goes, so one consumer's stop can no
## longer black out another's layer. An unknown ip is a no-op: a stranger's
## stop must not kill a feed it never asked for.
func stop_target(target_ip: String) -> void:
	_targets.erase(target_ip.strip_edges())
	if _active and _targets.is_empty():
		stop()


func is_active() -> bool:
	return _active


## Feed preference for the h264 body: "cpu" = the v1 readback → push_frame
## stepping stone, anything else = the v2 GPU blit. Takes effect at the NEXT
## start — a running stream keeps the feed it started on (the far end never
## sees a difference; the wire is identical).
func set_encoder_feed(feed: String) -> void:
	_gpu_feed = feed != "cpu"


## The h264 start's feed dance: GPU first (when preferred), CPU as the
## fallback of the SAME wire. Returns false only when BOTH feeds refuse —
## the caller then surfaces the one refusal story.
func _start_h264_send(ip: String, port: int) -> bool:
	_gpu_active = false
	# Transport pref: the srt case was already set (and gated) by
	# _srt_ready() in start(), before anything was torn down.
	if _transport != "srt":
		# null on a pre-M3 APK is fine: that plugin only speaks tcp anyway.
		_plugin.call("set_send_transport", "tcp")
	if _gpu_feed:
		# Probe by CALLING (the _h264_ready lesson: has_method cannot see a
		# JNI plugin's methods). A pre-2.5(b) APK answers NULL plus one engine
		# error line — null specifically: an unknown method has no value to
		# marshal. A real answer is coerced with bool(), never type-checked —
		# the first on-device pass returned the Kotlin Boolean as a Variant
		# typeof() refused to call TYPE_BOOL, and the type test misread a
		# working GPU feed as a missing one (then started the CPU sender on
		# top of it). Marshalling is the JNI layer's business; truthiness is
		# the contract.
		var r: Variant = _plugin.call("start_send_gpu", ip, port,
				H264_SIZE.x, H264_SIZE.y, _fps, H264_BITRATE_BPS)
		if r == null:
			if not _gpu_warned:
				_gpu_warned = true
				push_warning("NetSender: plugin predates the GPU feed "
						+ "(pre-M2.5(b) APK) — using the CPU readback feed")
			_gpu_feed = false   # the answer cannot change until an APK does
		elif bool(r):
			_gpu_active = true
			_readback_ms = 0.0   # there IS no readback; the stat must not lie
			_last_send_gl_id = 0   # force a fresh publish on the next tick
			return true
		else:
			# Synchronous refusal (encoder refused to build in Surface mode —
			# logcat says why). NOT sticky: unlike a missing method, a codec
			# in a bad mood can recover, so every start re-asks.
			if _transport == "srt":
				push_warning("NetSender: start_send_gpu refused — "
						+ "srt has no cpu fallback, refusing this stream")
				return false
			push_warning("NetSender: start_send_gpu refused — "
					+ "falling back to the CPU readback feed for this stream")
	if _transport == "srt":
		# Only reachable when the GPU probe answered null (pre-2.5(b) APK)
		# — which set_send_transport succeeding should rule out, but a
		# refusal here beats tcp-framed bytes at an SRT listener.
		return false
	return bool(_plugin.start_send(ip, port,
			H264_SIZE.x, H264_SIZE.y, _fps, H264_BITRATE_BPS))


## The srt gates that are knowable WITHOUT tearing anything down — run by
## start() BEFORE its destructive retarget, so a refused srt ask can never
## stop_send a healthy running stream. srt is GPU-feed-only (the CPU sender
## is the frozen 22ae379 tcp baseline) and has NO cpu/tcp fallback — the far
## end's port speaks MPEG-TS/SRT and raw-NAL TCP at it is the silent black
## nothing. Passing sets the plugin's transport pref to "srt" as a side
## effect (the probe IS the setter). Only the encoder-build refusal inside
## _start_h264_send remains post-teardown; it is genuinely unknowable early.
func _srt_ready() -> bool:
	if not _gpu_feed:
		push_warning("NetSender: srt transport requires the GPU feed "
				+ "(encoder_feed=\"cpu\" is the frozen tcp baseline) — refusing")
		return false
	var tr: Variant = _plugin.call("set_send_transport", "srt")
	if tr == null or not bool(tr):
		# null = pre-M3 APK (probe-by-call, the has_method lesson); false =
		# the plugin refused the name. Neither changes until a build does —
		# warn once, refuse every time.
		if not _srt_warned:
			_srt_warned = true
			push_warning("NetSender: plugin has no SRT transport "
					+ "(pre-M3 APK) — refusing srt starts; tcp unaffected")
		return false
	return true


## Resolve the send half of the PocketVJVideoLink singleton. Warned ONCE per
## build, then quietly refused: the h264 ask re-arrives with every pull retry
## and the answer cannot change until an APK does. Refusal — never a jpeg
## fallback — because the requester's port speaks the codec it asked for
## (§6.4); MJPEG at a TCP 4853 is the silent black nothing.
func _h264_ready() -> bool:
	if _plugin != null:
		return true
	if _h264_warned:
		return false   # refused once already — quiet, no re-probe, same answer
	if not Engine.has_singleton(H264_SINGLETON):
		if not _h264_warned:
			_h264_warned = true
			push_warning("NetSender: codec 'h264' requested but %s plugin is missing " % H264_SINGLETON
					+ "(desktop, or a pre-Stage-1 APK) — refusing; jpeg unaffected")
		return false
	var p: Object = Engine.get_singleton(H264_SINGLETON)
	# has_method() CANNOT see an Android plugin's methods: JNISingleton keeps
	# its @UsedByGodot registrations in a private method_map and overrides
	# only callp(), so Object.has_method answers from ClassDB — false for
	# every plugin method, on every APK, M2 included. Probe by CALLING the
	# harmless one: get_send_stats() answers a Dictionary on a send-capable
	# plugin and a null (plus one engine error line) on a milestone-1 APK —
	# which shipped the receive half only, the singleton with no encoder
	# behind it. The _h264_warned gate above keeps that probe to one shot.
	if typeof(p.call("get_send_stats")) != TYPE_DICTIONARY:
		if not _h264_warned:
			_h264_warned = true
			push_warning("NetSender: %s plugin predates the send path " % H264_SINGLETON
					+ "(milestone-1 APK) — refusing h264; jpeg unaffected")
		return false
	_plugin = p
	return true


## Latency burn-in (VIDEO_LINK_SPEC §9): this device's Time.get_ticks_msec()
## burned into every streamed frame, big and outlined so it survives a q0.75
## JPEG at 640x360. Photograph the RECEIVER's screen and this device's own
## live clock readout in one shot; the difference between the two numbers is
## glass-to-glass latency in ms — both come from this one clock, so no
## cross-device clock ever enters the measurement. Off means the label does
## not exist at all: the normal path renders and encodes exactly as before.
func set_debug_counter(on: bool) -> void:
	if on == (_debug_label != null):
		return
	if not on:
		_debug_label.queue_free()
		_debug_label = null
		return
	if _view == null:
		push_warning("NetSender: set_debug_counter before _ready, ignored")
		return
	_debug_label = Label.new()
	# Monospace so successive stamps hold their width — a jittering layout
	# smears under JPEG and reads worse off a photo.
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["monospace"])
	_debug_label.add_theme_font_override("font", f)
	_debug_label.add_theme_font_size_override("font_size", 48)
	_debug_label.add_theme_color_override("font_color", Color.WHITE)
	_debug_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_debug_label.add_theme_constant_override("outline_size", 10)
	_debug_label.position = Vector2(8, 8)
	_view.add_child(_debug_label)   # after _rect in tree order = drawn on top


## Rolling-window stats. fps/kbps are measured over the interval since
## the previous call (so poll at a steady rate, ~1 Hz, for stable numbers);
## readback_ms/encode_ms are the most recent single-frame measurements.
## Key names match the wire stats schema so the dict can go straight into
## LinkControl.broadcast_stats(). Same schema in both bodies (plus "codec",
## which is the EFFECTIVE body — a refused h264 start leaves it reading
## "jpeg", which is how the stats row tells that story); h264 numbers come
## from the plugin, whose thread owns convert+encode+socket — readback_ms
## stays ours, the one cost still paid on this side. Coerced per key because
## a JNI Dictionary's numeric types are its own.
func get_stats() -> Dictionary:
	if _codec == "h264":
		var s: Dictionary = {}
		if _plugin != null:
			s = _plugin.get_send_stats()
		return {
			"fps": float(s.get("fps", 0.0)),
			"readback_ms": _readback_ms,
			"encode_ms": float(s.get("encode_ms", 0.0)),
			"kbps": float(s.get("kbps", 0.0)),
			"frames_sent": int(s.get("frames_sent", 0)),
			"frames_dropped": int(s.get("frames_dropped", 0)),
			"convert_ms": float(s.get("convert_ms", 0.0)),
			"codec": "h264",
		}
	var now := _now()
	_mutex.lock()
	var elapsed := now - _win_start
	# Below ~50 ms the window is noise; report the previous reading instead of
	# a wild spike from one frame landing in a tiny interval.
	if elapsed > 0.05:
		_last_fps = float(_win_frames) / elapsed
		_last_kbps = float(_win_bytes) * 8.0 / 1000.0 / elapsed
		_win_start = now
		_win_frames = 0
		_win_bytes = 0
	var out := {
		"fps": _last_fps,
		"readback_ms": _readback_ms,
		"encode_ms": _encode_ms,
		"kbps": _last_kbps,
		"frames_sent": _frames_sent,
		"frames_dropped": _frames_dropped,
		"codec": "jpeg",
	}
	_mutex.unlock()
	return out


# ── Capture tick ─────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _active:
		return
	if _debug_label != null:
		# Refreshed every RENDER frame, not once per capture: text set here is
		# drawn in this frame's render pass and read back by a LATER
		# _capture(), the same render→readback path the real content rides.
		# The burned stamp therefore carries exactly the pipeline latency
		# being measured — updating only at capture time would leave it a
		# whole capture interval (~17 ms at 60 fps h264, ~42 at 24 jpeg) staler than the pixels
		# around it and bias the photo-diff upward.
		_debug_label.text = "%d\nseq %d" % [Time.get_ticks_msec(), _frame_seq]
	var interval := 1.0 / maxf(_fps, 0.001)
	_accum += delta
	if _accum < interval:
		return
	_accum -= interval
	# Cap the catch-up at one capture per frame: after a stall, a burst of
	# readbacks would stall the deck AGAIN, and the mailbox would drop all but
	# one of them anyway.
	if _accum > interval:
		_accum = interval
	if _codec == "h264" and _gpu_active:
		_gpu_tick()
	else:
		_capture()


## The GPU feed's capture slot (milestone 2.5(b)): no readback, no convert —
## the plugin blits on the render thread with its own accumulator at the same
## fps. Two jobs remain here. (1) Poll-and-republish the render target's
## GLuint (pipeline.gd's projector rule: Godot recreates render targets, and
## GL recycles freed names — a stale id blits garbage until re-sent; the poll
## is two RenderingServer calls, cheap at capture cadence). The viewport's
## OWN texture RID, never the ViewportTexture resource — that proxy answers 0.
## (2) Advance the seq for the burn-in stamp's Δseq cross-check (§9-M7); the
## stamp label refresh stays in _process, upstream of whichever feed reads it.
func _gpu_tick() -> void:
	if _view == null or _plugin == null:
		return
	var rid := RenderingServer.viewport_get_texture(_view.get_viewport_rid())
	var gl_id := RenderingServer.texture_get_native_handle(rid)
	if gl_id != _last_send_gl_id:
		_last_send_gl_id = gl_id
		_plugin.call("set_send_texture", gl_id, _view.size.x, _view.size.y)
	_frame_seq = (_frame_seq + 1) % 65536


func _capture() -> void:
	# No source yet — legal state, per the contract that start() may precede
	# set_source(). Send nothing until there is something to send.
	if _rect == null or _rect.texture == null or _view == null:
		return
	var vt := _view.get_texture()
	if vt == null:
		return
	var t0 := Time.get_ticks_usec()
	var img := vt.get_image()
	_readback_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	if img == null or img.is_empty():
		return

	if _codec == "h264":
		# Stage 1 body: the SAME readback (so the burn-in label, a child of
		# this viewport, is stamped into h264 frames exactly as into jpeg),
		# then the plugin's thread owns everything after — push_frame lands
		# in its 1-deep latest-wins mailbox and never blocks; the plugin
		# counts the drops.
		if _plugin == null:
			return
		if img.get_format() != Image.FORMAT_RGB8:
			# The push_frame contract is tightly-packed RGB8; the compat
			# renderer reads back RGBA8. One CPU convert at 720p, part of the
			# v1 readback bill (§9-M3) that the v2 GPU blit deletes whole.
			img.convert(Image.FORMAT_RGB8)
		_plugin.push_frame(img.get_data(), img.get_width(), img.get_height())
		# The seq still advances for the burn-in stamp's Δseq cross-check
		# (§9-M7); there is no wire header for it to ride in h264.
		_frame_seq = (_frame_seq + 1) % 65536
		return

	_mutex.lock()
	if _job != null:
		# Worker still busy with the previous frame: drop THIS one. The seq is
		# not consumed, so the receiver sees a contiguous sequence and dropped
		# frames are invisible on the wire — only the stats know.
		_frames_dropped += 1
		_mutex.unlock()
		return
	_job = {
		"image": img,
		"seq": _frame_seq,
		"stream": _stream_id,
		"quality": _quality,
		"targets": _targets.values().duplicate(true),
	}
	_mutex.unlock()
	_frame_seq = (_frame_seq + 1) % 65536
	_sem.post()


# ── Worker thread ────────────────────────────────────────────────────────

func _worker() -> void:
	# The socket lives on the worker and only the worker: PacketPeerUDP is not
	# thread-safe, and one owner means no question of who closes it.
	var udp := PacketPeerUDP.new()
	while true:
		_sem.wait()
		_mutex.lock()
		if _quit:
			_mutex.unlock()
			break
		var job: Variant = _job
		_job = null
		_mutex.unlock()
		if job == null:
			continue  # stop() emptied the mailbox after the post; nothing to do
		_encode_and_send(udp, job)
	udp.close()


func _encode_and_send(udp: PacketPeerUDP, job: Dictionary) -> void:
	var img: Image = job["image"]
	var t0 := Time.get_ticks_usec()
	var jpeg: PackedByteArray = img.save_jpg_to_buffer(job["quality"])
	var enc_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	if jpeg.is_empty():
		push_warning("NetSender: JPEG encode produced no bytes, frame dropped")
		return
	if jpeg.size() > MAX_FRAME_BYTES:
		# The receiver's guard would bin it on arrival; save the bandwidth.
		push_warning("NetSender: frame %d bytes exceeds %d, dropped (lower quality?)" % [jpeg.size(), MAX_FRAME_BYTES])
		return
	# Chunks are built ONCE and fanned out per target: N consumers cost N sends
	# and N× bandwidth, never N encodes — the encode is the expensive half.
	var total: int = jpeg.size()
	var offset := 0
	var packets: Array[PackedByteArray] = []
	while offset < total:
		var chunk_len := mini(MAX_PAYLOAD, total - offset)
		var last := offset + chunk_len >= total
		var spb := StreamPeerBuffer.new()
		spb.big_endian = true  # ⚠️ the whole protocol; see header comment
		spb.put_data("PVJV".to_ascii_buffer())
		spb.put_u8(1 if last else 0)            # flags: bit0 = last chunk
		spb.put_u8(job["stream"])
		spb.put_u16(job["seq"])
		spb.put_u32(total)
		spb.put_u32(offset)
		spb.put_u16(chunk_len)
		spb.put_data(jpeg.slice(offset, offset + chunk_len))
		packets.append(spb.data_array)
		offset += chunk_len

	var wire_bytes := 0
	for t in job["targets"]:
		var err := udp.set_dest_address(t["ip"], t["port"])
		if err != OK:
			push_warning("NetSender: bad destination %s:%d (err %d), frame dropped" % [t["ip"], t["port"], err])
			continue
		for p in packets:
			var perr := udp.put_packet(p)
			if perr != OK:
				# Abandon the REST of the frame FOR THIS TARGET: a receiver can
				# only complete a frame with every byte present, so the chunks
				# already sent are a loss either way and the next frame_seq
				# flushes them. The other targets still get their full frame.
				push_warning("NetSender: put_packet failed (err %d), rest of frame dropped" % perr)
				break
			wire_bytes += p.size()

	_mutex.lock()
	_encode_ms = enc_ms
	_frames_sent += 1
	_win_frames += 1
	_win_bytes += wire_bytes
	_mutex.unlock()


# ── Shutdown ─────────────────────────────────────────────────────────────

func _exit_tree() -> void:
	# The plugin outlives this node (Engine singleton): a teardown that skips
	# stop() must not leave its encoder paying CBR into the WiFi forever.
	if _codec == "h264" and _plugin != null and _active:
		_plugin.stop_send()
	if _thread == null:
		return
	_mutex.lock()
	_quit = true
	_job = null
	_mutex.unlock()
	_sem.post()
	if _thread.is_started():
		_thread.wait_to_finish()
	_thread = null


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
