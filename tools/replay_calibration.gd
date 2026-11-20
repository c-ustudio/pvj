extends SceneTree
## Replay a CalibEditor AUTO frame dump through CalibDetect, off the phone.
##
##   godot --headless --path <project> --script tools/replay_calibration.gd -- <dir> [min_contrast]
##
## <dir> holds frame_0.png … frame_N.png as AUTO wrote them to
## user://calib_dump on the device (it writes them only if that folder already
## exists: `adb shell run-as <pkg> mkdir files/calib_dump`). The order is the
## capture order: DARK, one frame per disc, DARK. Eleven frames are today's 3x3
## grid and go through CalibEditor.fit_grid() exactly as AUTO does it; seven
## are a dump from before the grid (four markers + the centre mark) and are
## solved the way that build did, so the old wall runs stay replayable.
##
## WHY. A detection that fails on a real wall cannot be debugged from its log
## line, and cannot be reproduced — the wall, the light and whoever walked
## through the shot are gone. The frames are the evidence; this runs the real
## detector over them as many times as it takes.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: … --script tools/replay_calibration.gd -- <dir with frame_N.png>")
		quit(2)
		return
	var dir := args[0]
	var det := CalibDetect.new()
	if args.size() > 1:
		det.min_contrast = int(args[1])   # optional: sweep the contrast floor
		print("min_contrast = %d" % det.min_contrast)
	var n := 0
	while true:
		var path := "%s/frame_%d.png" % [dir, n]
		if not FileAccess.file_exists(path):
			break
		var img := Image.load_from_file(path)
		if img == null:
			printerr("cannot read %s" % path)
			quit(1)
			return
		var t0 := Time.get_ticks_msec()
		var news := det.is_news(img)
		det.add_frame(img)
		var l := img.duplicate() as Image
		l.convert(Image.FORMAT_L8)
		var data := l.get_data()
		var sum := 0
		var sat := 0
		for i in range(0, data.size(), 16):
			sum += data[i]
			if data[i] >= 250:
				sat += 1
		@warning_ignore("integer_division")
		var samples := data.size() / 16
		print("frame %d: %dx%d mean %.1f saturated %.0f%% news=%s (%d ms)" % [n, img.get_width(),
			img.get_height(), float(sum) / samples, 100.0 * sat / samples, news,
			Time.get_ticks_msec() - t0])
		n += 1
	print("%d frames" % n)
	var out := Vector2(1920, 1080)
	var solos := n - 2
	var grid := solos == CalibPattern.GRID_COLS * CalibPattern.GRID_ROWS
	if not grid and solos != 5:
		printerr("%d disc frames: neither a 3x3 grid dump nor an old five-disc one" % solos)
		quit(1)
		return
	# What AUTO does with them: the strongest candidate per disc, then — if the
	# fit is short of the full grid — the runners-up as well.
	var first: Array = []
	var cands: Array = []
	for i in range(1, n - 1):
		var t0 := Time.get_ticks_msec()
		var list := det.candidates(i, CalibEditor.AUTO_ALTERNATIVES)
		print("disc %d (%d ms):" % [i, Time.get_ticks_msec() - t0])
		for c in list:
			print("    %s" % [c])
		cands.append(list)
		first.append([list[0]])
	var h: CalibHomography = null
	if grid:
		var fit := CalibEditor.fit_grid(first, out)
		_report("strongest only", fit)
		var used: PackedInt32Array = fit["used"]
		if not fit["ok"] or used.size() < solos:
			var again := CalibEditor.fit_grid(cands, out)
			_report("with runners-up", again)
			var used2: PackedInt32Array = again["used"]
			if again["ok"] and (not fit["ok"] or used2.size() > used.size()):
				fit = again
		if fit["ok"]:
			h = fit["h"]
	else:
		var src := PackedVector2Array()
		for i in 4:
			if not first[i][0]["ok"]:
				print("-> the old AUTO stopped here: marker %d %s" % [i + 1, first[i][0]["reason"]])
				quit(0)
				return
			src.append(first[i][0]["pos"])
		h = CalibHomography.solve(src, CalibPattern.marker_points(out))
		if h != null and first[4][0]["ok"]:
			var centre: Vector2 = first[4][0]["pos"]
			print("old five-disc dump: centre predicted %.2f camera px from where it was found"
				% h.inverse().apply(CalibPattern.centre_point(out)).distance_to(centre))
	if h == null:
		print("-> no calibration")
		quit(0)
		return
	var rect := CalibEditor.auto_surface(h.inverse(), out)
	print("projector frame in the camera: %s" % [CalibEditor.surface_to_corners(h.inverse(),
		PackedVector2Array([Vector2.ZERO, Vector2(out.x, 0), out, Vector2(0, out.y)]))])
	print("warp corners (squared up as seen from the phone): %s" % [CalibEditor.surface_to_corners(h, rect)])
	quit(0)


func _report(what: String, fit: Dictionary) -> void:
	print("fit (%s): ok=%s used=%s ranks=%s rms=%.2f seen=%d hidden=%s reason='%s'" % [what, fit["ok"],
		fit["used"], fit["ranks"], fit["rms"], fit["seen"], fit["hidden"], fit["reason"]])
