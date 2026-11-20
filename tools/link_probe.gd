extends SceneTree
## Desktop repro harness for the video link's camera coupling.
## Runs the exact CameraEngine -> NetSender chain pipeline.gd wires for
## stream 1, pointed at 127.0.0.1:4999, printing the sender's stats every
## second for 6 s. On a machine with no camera, CameraEngine retries then
## fails and the viewport stays transparent — the capture/encode/send chain
## still runs, which is exactly the part this probes.
##   <godot> --path . --script tools/link_probe.gd
## Setup happens on the FIRST process tick, not in _initialize: nodes added
## before the loop runs get their _ready deferred, which is not how the live
## pipeline adds them.

var _sender: NetSender
var _cam: CameraEngine
var _t := 0.0
var _next_tick := 1.0
var _setup_done := false


func _process(_delta: float) -> bool:
	if not _setup_done:
		_setup_done = true
		_cam = CameraEngine.new()
		_cam.name = "CameraEngine"
		_cam.size = Vector2i(640, 360)
		root.add_child(_cam)
		_sender = NetSender.new()
		_sender.name = "NetSender"
		root.add_child(_sender)
		_cam.start()
		print("[probe] camera running=%s (desktop: expect false, retries in flight)" % _cam.is_running())
		_sender.set_source(_cam.get_texture())
		print("[probe] source tex: %s" % _cam.get_texture())
		_sender.start("127.0.0.1", 4999, 1, 24.0, 0.75)
		print("[probe] sender active: %s" % _sender.is_active())
		return false

	_t += _delta
	if _t >= _next_tick:
		_next_tick += 1.0
		print("[probe] t=%.0fs stats=%s" % [_t, _sender.get_stats()])
	return _t >= 6.5   # true = quit
