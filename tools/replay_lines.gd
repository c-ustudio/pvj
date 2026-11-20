extends SceneTree
## Run CalibLines (the WALL step's automatic level lines) over a frozen frame
## from a wall run, off the phone.
##
##   godot --headless --path <project> --script tools/replay_lines.gd -- <dir> [gx gy gz]
##
## <dir> holds still.png as AUTO dumped it (see tools/replay_calibration.gd) and
## meta.cfg, which AUTO writes beside it:
##   [meta] gravity=Vector3(…)                down, in camera space, at the freeze
##          frame=PackedVector2Array(4 px)    the projector's frame in the camera
##          discs=PackedVector2Array(9 px)    …or the nine discs, to work it out from
##          truth=Vector2(px)                 optional: a level vanishing point
##                                            measured by hand, to compare with
## Gravity can be given on the command line instead.
##
## WHY. Whether the lines it finds are the right ones is only answerable on
## real rooms — books, picture frames, a gong stand — and those cannot be
## synthesised. The frames from each wall run are the test set.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: … --script tools/replay_lines.gd -- <dir> [gx gy gz]")
		quit(2)
		return
	var dir := args[0]
	var img := Image.load_from_file("%s/still.png" % dir)
	if img == null:
		printerr("cannot read %s/still.png" % dir)
		quit(1)
		return
	var cfg := ConfigFile.new()
	cfg.load("%s/meta.cfg" % dir)
	var gravity: Vector3 = cfg.get_value("meta", "gravity", Vector3.ZERO)
	if args.size() >= 4:
		gravity = Vector3(float(args[1]), float(args[2]), float(args[3]))
	var out := Vector2(1920, 1080)
	var cam := Vector2(img.get_size())
	var frame: PackedVector2Array = cfg.get_value("meta", "frame", PackedVector2Array())
	var o2c: CalibHomography = null
	if cfg.has_section_key("meta", "discs"):
		var discs: PackedVector2Array = cfg.get_value("meta", "discs")
		o2c = CalibHomography.solve(CalibPattern.grid_points(out), discs)
	elif frame.size() == 4:
		o2c = CalibHomography.solve(PackedVector2Array([Vector2.ZERO, Vector2(out.x, 0), out, Vector2(0, out.y)]), frame)
	if o2c != null and frame.size() != 4:
		frame = PackedVector2Array()
		for c: Vector2 in [Vector2.ZERO, Vector2(out.x, 0), out, Vector2(0, out.y)]:
			frame.append(o2c.apply(c))
	var focal := CalibWall.focal_for(cam)
	print("frame %dx%d, gravity %s, focal %.0f, projector frame %s" % [int(cam.x), int(cam.y), gravity, focal, frame])

	var t0 := Time.get_ticks_msec()
	if cfg.has_section_key("meta", "truth"):
		# The hand-measured direction, as the compass angle CalibLines reports.
		var tv: Vector2 = cfg.get_value("meta", "truth")
		var g := gravity.normalized()
		var e1 := (Vector3.RIGHT - g * g.x).normalized()
		var e2 := g.cross(e1)
		var td := Vector3((tv.x - cam.x * 0.5) / focal, (tv.y - cam.y * 0.5) / focal, 1).normalized()
		print("hand-measured direction: azimuth %.2f deg, %.2f deg off horizontal" % [
			fposmod(rad_to_deg(atan2(td.dot(e2), td.dot(e1))), 180.0), 90.0 - rad_to_deg(acos(clampf(absf(td.dot(g)), 0.0, 1.0)))])
	var res := CalibLines.find(img, gravity, focal, cam * 0.5, frame, true)
	print("%d ms -> %s" % [Time.get_ticks_msec() - t0, res])
	if not res["ok"]:
		quit(0)
		return
	var level: PackedVector2Array = res["level"]
	# Where the two lines meet: the wall's level vanishing point.
	var l1 := Vector3(level[0].x, level[0].y, 1).cross(Vector3(level[1].x, level[1].y, 1))
	var l2 := Vector3(level[2].x, level[2].y, 1).cross(Vector3(level[3].x, level[3].y, 1))
	var vp := l1.cross(l2)
	if absf(vp.z) > 1e-9:
		var at := Vector2(vp.x / vp.z, vp.y / vp.z)
		print("level vanishing point: %s" % at)
		if cfg.has_section_key("meta", "truth"):
			var truth: Vector2 = cfg.get_value("meta", "truth")
			# Compared as directions in space: far-away points differ by many px
			# for very little angle.
			var a := Vector3((at.x - cam.x * 0.5) / focal, (at.y - cam.y * 0.5) / focal, 1).normalized()
			var b := Vector3((truth.x - cam.x * 0.5) / focal, (truth.y - cam.y * 0.5) / focal, 1).normalized()
			print("hand-measured %s: %.2f deg apart" % [truth, rad_to_deg(acos(clampf(a.dot(b), -1.0, 1.0)))])
	if o2c != null:
		var wall := CalibWall.solve(level, PackedVector2Array(), gravity, cam, 0.0)
		if wall != null:
			var rect := wall.surface(o2c, out)
			print("gravity %.2f deg off square to those lines; keystone on the wall %.2fx" % [wall.skew_deg, wall.keystone(o2c, out)])
			print("warp corners (square on the wall): %s" % [CalibEditor.surface_to_corners(o2c.inverse(), rect)])
	quit(0)
