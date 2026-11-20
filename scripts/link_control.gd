class_name LinkControl
extends Node
## VIDEO-LINK control channel (wire protocol v1, Stage 0).
##
## TCP port 4850, newline-delimited JSON, both directions:
##   {"t":"hello","name":"...","role":"..."}
##   {"t":"start","stream":0,"ip":"<dest ip>","port":<dest video port>,"fps":24,"quality":0.75,"codec":"jpeg"}
##   {"t":"stop","stream":0}
##   {"t":"stats","fps":0.0,"kbps":0.0,"encode_ms":0.0}
##
## Model: the RECEIVER asks a sender to start streaming to it — "start" carries
## the address the video should be sent TO, not where it comes from. This node
## is only the signalling; the video frame path lives elsewhere and merely
## reacts to the signals emitted here.
##
## "codec" (spec §6.4, milestone 2) is OPTIONAL and says what the requester's
## port speaks — "jpeg" (UDP MJPEG, Stage 0) or "h264" (the TCP 4853 listener,
## §6.6). Tolerant BOTH directions by construction: a missing field parses as
## "jpeg" here, and a peer that predates the field ignores unknown JSON keys —
## so this line is always sent with the field and never requires it.
##
## ── SHAPE ────────────────────────────────────────────────────────────────
## One TCPServer accepting any number of inbound peers, plus short-lived
## outbound connections for our own requests. Everything is polled in
## _process — no threads, no blocking calls — because a control message a
## frame late is invisible, while a stall on the main thread mid-set is not.
##
## Buffers are PER CONNECTION on both sides: StreamPeerTCP hands back partial
## reads whenever the kernel feels like it, so half a JSON line from peer A
## must never be glued onto peer B's half, and an unflushed stats line must
## wait in its own connection's queue.

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

## A peer asked us to start streaming. dest_ip/dest_port are where the frames
## should be SENT (the requester's receive socket); codec is what that socket
## speaks ("jpeg" when the line predates the field); transport is its framing
## ("tcp" raw-NAL when the line predates the field, "srt" = MPEG-TS/SRT —
## the TouchDesigner leg, M3).
signal stream_requested(stream_id: int, dest_ip: String, dest_port: int, fps: float, quality: float, codec: String, transport: String)

## A peer asked us to stop the given stream. remote_ip is the TCP connection's
## far end — the same address the empty-ip rule resolves a start against — so
## the owner can scope the stop to that peer's own pull instead of killing
## every consumer of the stream. (Wire unchanged: the stop line still carries
## only t and stream; the ip comes from the socket, exactly like start's.)
signal stream_stopped(stream_id: int, remote_ip: String)

## A peer introduced itself. role is one of: main, cam, td.
signal peer_hello(peer_name: String, role: String)

## A peer reported encoder stats. The dictionary is the parsed JSON line as-is.
signal peer_stats(stats: Dictionary)

## The tempo master shared its grid (SEQ2 §3.4 / dual-phone N4): bpm + the
## master's beat/bar counters + its bar-phase at send. Sent once per bar and
## immediately on a tempo change. The link DISTRIBUTES the grid, never
## estimates it (R4) — the receiving side decides whether it is a slave.
signal beat_received(bpm: float, beat_index: int, bar_index: int, phase: float)

## A peer commanded a sequencer action (SEQ2 §3.4 "remote scene triggers"):
## op "slot" loads numbered slot N into the lane's working arrangement, op
## "auto" arms/disarms the lane's auto-advance. at "bar" = quantize to the
## receiver's next downbeat; "now" = panic, apply immediately.
signal seq_received(lane: String, op: String, slot: int, on: bool, at: String)

const DEFAULT_PORT := 4850

## Outbound connections that have not finished sending by then are abandoned.
## 3 s is forever on a LAN; anything slower is a peer that is gone.
const SEND_TIMEOUT_SECS := 3.0

## A peer that streams this much without a newline is not speaking the
## protocol — drop the connection rather than buffer garbage without bound.
const MAX_LINE_BYTES := 65536

## Newline in UTF-8. Lines are split on this; a trailing \r is stripped after.
const NL_BYTE := 10

var _server: TCPServer = null

## Inbound peers: { stream: StreamPeerTCP, inbuf: PackedByteArray,
##                  outbuf: PackedByteArray }
var _peers: Array[Dictionary] = []

## Fire-and-forget outbound sends: { stream: StreamPeerTCP,
##   payload: PackedByteArray, sent: int, started: float, label: String }
var _outgoing: Array[Dictionary] = []


func _ready() -> void:
	# Pro module (Features.TD_PVJ_LINK). pipeline never builds it in the public
	# build; this is the backstop if anything ever does.
	if not FeaturesS.is_pro():
		push_warning("[link_control] pro-only module in a public build — freed")
		queue_free()
		return
	# Idle until there is something to poll — same reasoning as LifeSource:
	# the common case is a phone with no link peers at all, and that case
	# should cost a stopped _process and nothing else.
	set_process(false)


func _exit_tree() -> void:
	stop()


# ── Public API ───────────────────────────────────────────────────────────

## Start accepting control connections. Returns the TCPServer error verbatim
## so the caller can tell "port taken" from "worked"; on failure this node
## just stays idle — a dead control channel must never take the deck with it.
func listen(port: int = DEFAULT_PORT) -> Error:
	stop_listening()
	_server = TCPServer.new()
	var err := _server.listen(port)
	if err != OK:
		push_warning("LinkControl: listen on %d failed (%s)" % [port, error_string(err)])
		_server = null
		return err
	set_process(true)
	return OK


## Ask the peer at peer_ip:peer_ctrl_port to start streaming stream_id to us.
## my_ip_hint/my_video_port are OUR receive address, carried in the message
## because the receiver-asks model means the sender otherwise has no idea
## where to aim (and the TCP source address may not be the right interface).
## codec is OUR receive port's EFFECTIVE codec (§6.4) — the caller passes what
## NetSource actually speaks after any plugin fallback, never the setting.
func request_stream(peer_ip: String, peer_ctrl_port: int, stream_id: int,
		my_ip_hint: String, my_video_port: int,
		fps: float = 24.0, quality: float = 0.75, codec: String = "jpeg") -> void:
	_send_json(peer_ip, peer_ctrl_port, {
		"t": "start",
		"stream": stream_id,
		"ip": my_ip_hint,
		"port": my_video_port,
		"fps": fps,
		"quality": quality,
		"codec": codec,
	}, "start")


## Ask the peer to stop streaming stream_id (to us).
func send_stop(peer_ip: String, peer_ctrl_port: int, stream_id: int) -> void:
	_send_json(peer_ip, peer_ctrl_port, {
		"t": "stop",
		"stream": stream_id,
	}, "stop")


## Tell a TD peer its SRT video listener can stand down — we stopped pulling.
## Politeness with a purpose: TD's single-shot Video Stream Out sits wedged
## (error-badged) after a client leaves; the disarm parks it clean instead.
func send_srt_disarm(peer_ip: String, peer_ctrl_port: int) -> void:
	_send_json(peer_ip, peer_ctrl_port, {"t": "srt_disarm"}, "srt_disarm")


## Share the master's grid with one peer (N4). Cheap and self-healing: one
## line per bar; a lost line is absorbed by the slave's median filter.
func send_beat(peer_ip: String, peer_ctrl_port: int,
		bpm: float, beat_index: int, bar_index: int, phase: float) -> void:
	_send_json(peer_ip, peer_ctrl_port, {
		"t": "beat",
		"bpm": bpm,
		"beat": beat_index,
		"bar": bar_index,
		"phase": phase,
	}, "beat")


## Command a peer's sequencer: load numbered slot `slot` into `lane` ("a"|"b"),
## quantized per `at` ("bar" | "now").
func send_seq_slot(peer_ip: String, peer_ctrl_port: int,
		lane: String, slot: int, at: String = "bar") -> void:
	_send_json(peer_ip, peer_ctrl_port, {
		"t": "seq", "lane": lane, "op": "slot", "slot": slot, "at": at,
	}, "seq_slot")


## Command a peer's sequencer: arm/disarm `lane`'s auto-advance.
func send_seq_auto(peer_ip: String, peer_ctrl_port: int,
		lane: String, on: bool, at: String = "bar") -> void:
	_send_json(peer_ip, peer_ctrl_port, {
		"t": "seq", "lane": lane, "op": "auto", "on": on, "at": at,
	}, "seq_auto")


## Queue a stats line to every connected inbound peer. "t" is forced to
## "stats" so a caller passing a plain measurements dict still speaks the
## protocol. Queued, not sent inline: the flush shares the per-connection
## outbuf path so a slow peer backs up its own socket and nobody else's.
func broadcast_stats(stats: Dictionary) -> void:
	var msg := stats.duplicate()
	msg["t"] = "stats"
	var line := _encode_line(msg)
	if line.is_empty():
		return
	for peer in _peers:
		var buf: PackedByteArray = peer["outbuf"]
		buf.append_array(line)
		peer["outbuf"] = buf
	if not _peers.is_empty():
		set_process(true)


## Stop listening and drop every connection, inbound and outbound. Safe to
## call at any time, including before listen().
func stop() -> void:
	stop_listening()
	for peer in _peers:
		(peer["stream"] as StreamPeerTCP).disconnect_from_host()
	_peers.clear()
	for out in _outgoing:
		(out["stream"] as StreamPeerTCP).disconnect_from_host()
	_outgoing.clear()
	set_process(false)


## Close only the listening socket; live connections keep draining.
func stop_listening() -> void:
	if _server != null:
		_server.stop()
		_server = null


func is_listening() -> bool:
	return _server != null and _server.is_listening()


func peer_count() -> int:
	return _peers.size()


# ── Polling ──────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	_accept_pending()
	_poll_peers()
	_poll_outgoing()
	# Nothing left to watch — go back to sleep until listen()/send re-arms.
	if _server == null and _peers.is_empty() and _outgoing.is_empty():
		set_process(false)


func _accept_pending() -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var stream := _server.take_connection()
		if stream == null:
			break
		# Control lines are tiny and latency-tolerant, but Nagle adds up to
		# 200 ms to a "start" — pointless on a LAN.
		stream.set_no_delay(true)
		_peers.append({
			"stream": stream,
			"inbuf": PackedByteArray(),
			"outbuf": PackedByteArray(),
		})


func _poll_peers() -> void:
	var keep: Array[Dictionary] = []
	for peer in _peers:
		var stream: StreamPeerTCP = peer["stream"]
		stream.poll()
		var status := stream.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			continue                                  # gone — drop silently, peers churn
		if status != StreamPeerTCP.STATUS_CONNECTED:
			keep.append(peer)                         # still handshaking
			continue

		# Drain whatever arrived. get_partial_data because a JSON line can and
		# will arrive split across reads — the buffer reassembles it.
		var avail := stream.get_available_bytes()
		if avail > 0:
			var res := stream.get_partial_data(avail)
			if res[0] == OK:
				var inbuf: PackedByteArray = peer["inbuf"]
				inbuf.append_array(res[1])
				peer["inbuf"] = inbuf
			else:
				push_warning("LinkControl: read error from peer (%s)" % error_string(res[0]))
				stream.disconnect_from_host()
				continue

		if not _drain_lines(peer):
			stream.disconnect_from_host()             # protocol abuse — see MAX_LINE_BYTES
			continue

		# Flush anything queued for this peer (stats broadcasts). Partial
		# writes just stay queued for the next frame.
		var outbuf: PackedByteArray = peer["outbuf"]
		if not outbuf.is_empty():
			var sent := stream.put_partial_data(outbuf)
			if sent[0] == OK:
				peer["outbuf"] = outbuf.slice(sent[1])
			else:
				push_warning("LinkControl: write error to peer (%s)" % error_string(sent[0]))
				stream.disconnect_from_host()
				continue

		keep.append(peer)
	_peers = keep


## Split complete lines out of the peer's inbuf and dispatch each. Returns
## false only when the peer must be dropped (unbounded line).
func _drain_lines(peer: Dictionary) -> bool:
	var inbuf: PackedByteArray = peer["inbuf"]
	var remote := (peer["stream"] as StreamPeerTCP).get_connected_host()
	while true:
		var nl := inbuf.find(NL_BYTE)
		if nl < 0:
			break
		var line_bytes := inbuf.slice(0, nl)
		inbuf = inbuf.slice(nl + 1)
		_handle_line(line_bytes.get_string_from_utf8(), remote)
	peer["inbuf"] = inbuf
	if inbuf.size() > MAX_LINE_BYTES:
		push_warning("LinkControl: peer sent %d bytes with no newline — dropping connection" % inbuf.size())
		return false
	return true


# ── Message dispatch ─────────────────────────────────────────────────────

func _handle_line(line: String, remote_host: String = "") -> void:
	line = line.strip_edges()                          # eats the \r of CRLF senders too
	if line.is_empty():
		return
	var msg: Variant = JSON.parse_string(line)
	if msg == null or not (msg is Dictionary):
		# Malformed lines are skipped, not fatal: one bad message from a peer
		# must not cost us the messages after it on the same connection.
		push_warning("LinkControl: skipping malformed control line: %s" % line.left(120))
		return
	var dict: Dictionary = msg
	var t := String(dict.get("t", ""))
	match t:
		"start":
			# Empty ip means "stream to whoever is asking" — the requester
			# rarely knows its own LAN address, but this end of the TCP
			# connection always does.
			var dest_ip := String(dict.get("ip", ""))
			if dest_ip.is_empty():
				dest_ip = remote_host
			stream_requested.emit(
				int(dict.get("stream", 0)),
				dest_ip,
				int(dict.get("port", 0)),
				float(dict.get("fps", 24.0)),
				float(dict.get("quality", 0.75)),
				# Absent on a pre-milestone-2 peer's line = Stage 0 MJPEG —
				# the default IS the old wire's meaning (§6.4).
				String(dict.get("codec", "jpeg")),
				# Absent on a pre-M3 peer's line = raw-NAL TCP, same rule.
				String(dict.get("transport", "tcp")))
		"stop":
			stream_stopped.emit(int(dict.get("stream", 0)), remote_host)
		"hello":
			peer_hello.emit(String(dict.get("name", "")), String(dict.get("role", "")))
		"stats":
			peer_stats.emit(dict)
		"beat":
			beat_received.emit(
				float(dict.get("bpm", 0.0)),
				int(dict.get("beat", 0)),
				int(dict.get("bar", 0)),
				float(dict.get("phase", 0.0)))
		"seq":
			seq_received.emit(
				String(dict.get("lane", "a")),
				String(dict.get("op", "")),
				int(dict.get("slot", 1)),
				bool(dict.get("on", false)),
				# Absent on any future sender's line = quantized — the safe
				# meaning (a mid-bar surprise is the exceptional ask).
				String(dict.get("at", "bar")))
		_:
			push_warning("LinkControl: unknown control message type '%s'" % t)


# ── Outgoing (fire-and-forget) ───────────────────────────────────────────

## JSON dict -> UTF-8 line with trailing \n, or empty on a stringify failure.
func _encode_line(msg: Dictionary) -> PackedByteArray:
	var text := JSON.stringify(msg)
	if text.is_empty():
		push_warning("LinkControl: could not stringify control message")
		return PackedByteArray()
	return (text + "\n").to_utf8_buffer()


## Open a short-lived connection, queue one line, and let _process see it
## out. Never blocks: connect_to_host only starts the handshake, and the
## write happens across frames via put_partial_data until sent or the 3 s
## timeout gives up. The connection closes after the send either way — the
## reply path in this protocol is the peer connecting BACK, not this socket.
func _send_json(ip: String, port: int, msg: Dictionary, label: String) -> void:
	var line := _encode_line(msg)
	if line.is_empty():
		return
	var stream := StreamPeerTCP.new()
	var err := stream.connect_to_host(ip, port)
	if err != OK:
		push_warning("LinkControl: %s to %s:%d failed to connect (%s)" % [label, ip, port, error_string(err)])
		return
	stream.set_no_delay(true)
	_outgoing.append({
		"stream": stream,
		"payload": line,
		"sent": 0,
		"started": _now(),
		"label": "%s -> %s:%d" % [label, ip, port],
	})
	set_process(true)


func _poll_outgoing() -> void:
	var keep: Array[Dictionary] = []
	for out in _outgoing:
		var stream: StreamPeerTCP = out["stream"]
		stream.poll()
		var status := stream.get_status()

		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			push_warning("LinkControl: %s failed (connection refused or dropped)" % out["label"])
			continue

		if _now() - float(out["started"]) > SEND_TIMEOUT_SECS:
			push_warning("LinkControl: %s timed out" % out["label"])
			stream.disconnect_from_host()
			continue

		if status != StreamPeerTCP.STATUS_CONNECTED:
			keep.append(out)                          # still connecting — give it time
			continue

		var payload: PackedByteArray = out["payload"]
		var sent := int(out["sent"])
		var res := stream.put_partial_data(payload.slice(sent))
		if res[0] != OK:
			push_warning("LinkControl: %s write failed (%s)" % [out["label"], error_string(res[0])])
			stream.disconnect_from_host()
			continue
		sent += int(res[1])
		out["sent"] = sent
		if sent >= payload.size():
			stream.disconnect_from_host()             # done — graceful close flushes
			continue
		keep.append(out)
	_outgoing = keep


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
