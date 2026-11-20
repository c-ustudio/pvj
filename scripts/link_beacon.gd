class_name LinkBeacon
extends Node
## Discovery beacon for the video-link wire protocol (v1, Stage 0).
##
## Broadcasts one ASCII line at 1 Hz on UDP 4849 and listens on the same port
## for everyone else's, maintaining a table of live peers:
##
##   PVJ1|<name>|<role>|<codec>|<video_port>|<ctrl_port>
##
## ⚠️ WIRE FORMAT IS SHARED. The TouchDesigner bridge and the other phone parse
## this exact line; a "tidier" field order or separator here silently breaks
## discovery everywhere else. Change the protocol document first, then every
## endpoint, never just this file.
##
## ── SHAPE ────────────────────────────────────────────────────────────────
## Plain node, same contract as LifeSource: no autoload registration, no
## reaching for globals. The owner calls configure() once and listens to the
## signals. Works as an autoload OR a child of whatever owns networking.
##
## Two sockets, deliberately:
##   _listen  bound to 4849 to RECEIVE beacons. The bind can fail — another
##            PocketVJ instance on the same box, or a previous run that has not
##            released the port — and that must not stop us ANNOUNCING, so
##   _send    is a separate unbound socket (ephemeral port) that only
##            broadcasts. Beacons keep going out while the bind retries on the
##            1 s timer, so the other peers still see us even when we are
##            temporarily deaf.
##
## Nothing here blocks: PacketPeerUDP is non-blocking by default and packets
## are drained in _process.

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

## A peer we have not seen before sent a beacon.
signal peer_appeared(name: String)

## A peer went 5 s without a beacon (or its socket died) and was dropped.
signal peer_lost(name: String)

## The peer table changed in any way — appear, lose, or a peer's advertised
## ip/role/ports changing under the same name. Coarse on purpose: a UI that
## just redraws the list only needs this one.
signal peers_changed()

const BEACON_PORT := 4849
const BEACON_MAGIC := "PVJ1"
## Default codec — Stage 0 MJPEG. configure() overrides it per-session ("h264"
## once the Stage 1 receive path is actually listening): the field always
## existed for exactly this, so the 6-field line format does not move.
## ⚠️ Advertise the EFFECTIVE codec, never the settings value — a phone whose
## plugin fell back to jpeg must not invite an H.264 stream it cannot parse.
const BEACON_CODEC := "jpeg"
const BEACON_FIELDS := 6
## Peers expire after this long without a beacon. 5 beacons of grace — losing
## one or two datagrams on busy wifi must not flap the peer list.
const PEER_TTL_MSEC := 5000
const KNOWN_ROLES := ["main", "cam", "td"]

var _name := ""
var _role := ""
var _codec := BEACON_CODEC
var _video_port := 0
var _ctrl_port := 0
var _beacon: PackedByteArray = PackedByteArray()
var _configured := false

var _listen: PacketPeerUDP = null
var _send: PacketPeerUDP = null

## name -> {ip, role, codec, video_port, ctrl_port, last_seen_msec}
var _peers: Dictionary = {}

var _timer: Timer = null
## Warn once per condition, then keep quietly retrying — a beacon runs for the
## whole show and a per-second warning would drown the log.
var _bind_warned := false
var _send_warned := false


func _ready() -> void:
	# Pro module (Features.TD_PVJ_LINK). pipeline never builds it in the public
	# build; this is the backstop if anything ever does.
	if not FeaturesS.is_pro():
		push_warning("[link_beacon] pro-only module in a public build — freed")
		queue_free()
		return
	# Idle until configure(): an unconfigured beacon has no name to announce
	# and nothing to compare incoming names against.
	set_process(false)
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.autostart = false
	_timer.timeout.connect(_on_tick)
	add_child(_timer)


func _exit_tree() -> void:
	if _listen != null:
		_listen.close()
		_listen = null
	if _send != null:
		_send.close()
		_send = null


# ── Public ───────────────────────────────────────────────────────────────

## Set who we are and start announcing/listening. Safe to call again to change
## identity (the sockets survive, only the advertised line changes).
##
## video_port is where WE receive video (0 = we don't receive, e.g. the cam
## phone); ctrl_port is our TCP control listener; codec is what video_port
## speaks — the caller passes NetSource.get_codec() (the effective one, after
## any plugin fallback), and the default keeps every Stage 0 caller byte-exact.
func configure(name: String, role: String, video_port: int, ctrl_port: int,
		codec: String = BEACON_CODEC) -> void:
	# "|" and newlines are structural in the wire line; a name containing them
	# would corrupt every parser on the network. Sanitise rather than reject —
	# a beacon that refuses to start is worse than one with a mangled name.
	var clean_name := name.replace("|", "_").replace("\n", " ").replace("\r", " ").strip_edges()
	if clean_name == "":
		push_warning("[LinkBeacon] configure() with empty name — beacon not started")
		return
	if not KNOWN_ROLES.has(role):
		# Announce anyway: an unknown role is a version-skew problem for the
		# RECEIVER to ignore, not a reason for this peer to go dark.
		push_warning("[LinkBeacon] unknown role '%s' (expected one of %s)" % [role, KNOWN_ROLES])

	_name = clean_name
	_role = role
	# Same structural-character rule as the name: "|" in a codec would shift
	# every field after it in every parser on the network.
	_codec = codec.replace("|", "_").replace("\n", " ").replace("\r", " ").strip_edges()
	if _codec == "":
		_codec = BEACON_CODEC
	_video_port = video_port
	_ctrl_port = ctrl_port
	_beacon = ("%s|%s|%s|%s|%d|%d" % [
		BEACON_MAGIC, _name, _role, _codec, _video_port, _ctrl_port,
	]).to_ascii_buffer()

	_ensure_send_socket()
	_try_bind()

	_configured = true
	set_process(true)
	_timer.start()
	# First beacon immediately — waiting a full timer tick makes every fresh
	# launch look one second more broken than it is.
	_send_beacon()


## Snapshot of the live peer table: name -> {ip, role, codec, video_port,
## ctrl_port, last_seen_msec}. A deep copy — callers can hold or mutate it
## freely.
func get_peers() -> Dictionary:
	return _peers.duplicate(true)


## One peer's entry, or an empty Dictionary if unknown/expired.
func get_peer(name: String) -> Dictionary:
	if not _peers.has(name):
		return {}
	var entry: Dictionary = _peers[name]
	return entry.duplicate(true)


# ── Receive ──────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _listen == null:
		return
	# Drain everything queued this frame. At 1 Hz per peer this is a handful of
	# packets, but a burst after a stall must not smear across frames.
	while _listen.get_available_packet_count() > 0:
		var pkt := _listen.get_packet()
		var ip := _listen.get_packet_ip()
		_handle_beacon(pkt.get_string_from_ascii(), ip)


func _handle_beacon(line: String, ip: String) -> void:
	# Tolerant of a trailing newline: the datagram already delimits the line,
	# but another implementation may send one anyway.
	var parts := line.strip_edges().split("|")
	# Silent on garbage, deliberately: 4849 is a broadcast port and anything on
	# the network can shout into it. Warning per bad packet is a log flood an
	# attacker (or a chatty printer) controls.
	if parts.size() != BEACON_FIELDS or parts[0] != BEACON_MAGIC:
		return
	var peer_name := parts[1]
	if peer_name == "" or peer_name == _name:
		return  # our own broadcast loops back — same-name comparison drops it
	if not parts[4].is_valid_int() or not parts[5].is_valid_int():
		return

	var entry := {
		"ip": ip,
		"role": parts[2],
		"codec": parts[3],
		"video_port": int(parts[4]),
		"ctrl_port": int(parts[5]),
		"last_seen_msec": Time.get_ticks_msec(),
	}

	var is_new := not _peers.has(peer_name)
	var changed := is_new
	if not is_new:
		var old: Dictionary = _peers[peer_name]
		changed = old.get("ip") != entry["ip"] \
			or old.get("role") != entry["role"] \
			or old.get("codec") != entry["codec"] \
			or old.get("video_port") != entry["video_port"] \
			or old.get("ctrl_port") != entry["ctrl_port"]
	_peers[peer_name] = entry

	if is_new:
		peer_appeared.emit(peer_name)
	if changed:
		peers_changed.emit()


# ── 1 s housekeeping: announce, retry bind, expire ───────────────────────

func _on_tick() -> void:
	if not _configured:
		return
	_send_beacon()
	if _listen == null:
		_try_bind()
	_expire_peers()


func _ensure_send_socket() -> void:
	if _send != null:
		return
	var sock := PacketPeerUDP.new()
	sock.set_broadcast_enabled(true)
	if sock.set_dest_address("255.255.255.255", BEACON_PORT) != OK:
		push_warning("[LinkBeacon] could not set broadcast destination — will retry")
		return
	_send = sock


func _send_beacon() -> void:
	# Retry-on-tick, same policy as the listener bind: a failed setup must
	# never leave announcing permanently dead.
	if _send == null:
		_ensure_send_socket()
	if _send == null or _beacon.is_empty():
		return
	var err := _send.put_packet(_beacon)
	if err != OK:
		if not _send_warned:
			push_warning("[LinkBeacon] beacon send failed: %d (will keep trying)" % err)
			_send_warned = true
	else:
		_send_warned = false


func _try_bind() -> void:
	if _listen != null:
		return
	var sock := PacketPeerUDP.new()
	# Broadcast enabled on the LISTENER too: some platforms drop broadcast
	# datagrams on sockets that have not opted in.
	sock.set_broadcast_enabled(true)
	var err := sock.bind(BEACON_PORT, "*")
	if err != OK:
		if not _bind_warned:
			push_warning(("[LinkBeacon] could not bind UDP %d (%d) — port busy? Announcing "
					+ "still works; retrying every second.") % [BEACON_PORT, err])
			_bind_warned = true
		return
	_listen = sock
	if _bind_warned:
		push_warning("[LinkBeacon] UDP %d bound after retry — discovery restored" % BEACON_PORT)
		_bind_warned = false


func _expire_peers() -> void:
	var now := Time.get_ticks_msec()
	var dead: Array[String] = []
	for peer_name in _peers:
		var entry: Dictionary = _peers[peer_name]
		if now - int(entry.get("last_seen_msec", 0)) > PEER_TTL_MSEC:
			dead.append(peer_name)
	if dead.is_empty():
		return
	for peer_name in dead:
		_peers.erase(peer_name)
		peer_lost.emit(peer_name)
	peers_changed.emit()
