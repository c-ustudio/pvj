extends SceneTree
## Headless check of the masks' MANUAL SEQUENCE (per-mask clip lists + NEXT)
## and the LOCAL/DECK switch, against the real RegionCompositor + RegionEditor
## and real GoZen decoders on three clips from the PC's mapping_test folder.
##
##   godot --headless --path <project> --script tools/verify_mask_sequence.gd
##
## Checks:
##   1. The picker builds a list: first clip plays alone, a second makes a
##      two-clip list, a fixed clip from before lists is kept as entry 1.
##   2. NEXT on a selected mask steps it and wraps; with none selected every
##      mask steps; a mask with no list steps to the next clip in the folder.
##   3. Removing the playing clip plays the one that slides into its place;
##      emptying the list goes back to the deck; FOLLOW DECK clears a list.
##   4. DECK: every mask shows the shared source, decoders stop rendering, the
##      clips are kept, and LOCAL brings them back.
##   5. regions.cfg round-trips the list, the position and the switch.
## (Whether a step HOLDS the last frame on the device is a device question.)

## A folder of test clips on the machine running the check; set PVJ_TEST_CLIPS.
var CLIPS: String = OS.get_environment("PVJ_TEST_CLIPS")
const OUT := Vector2(1920, 1080)

var _fails: int = 0
var _checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
	print("%s  %s%s" % ["ok  " if cond else "FAIL", what, ("  — " + detail) if detail != "" else ""])


func _tex(comp: RegionCompositor, i: int) -> Texture2D:
	return (comp._regions[i]["mesh_node"] as MeshInstance2D).texture


func _run() -> void:
	if root.get_node_or_null("Storage") == null:
		var st: Node = load("res://core/storage.gd").new()
		st.name = "Storage"
		root.add_child(st)
	if CLIPS.is_empty():
		print("FAIL  set PVJ_TEST_CLIPS to a folder with 3 or more .mp4 clips")
		quit(1)
		return
	var files := DirAccess.get_files_at(CLIPS)
	var paths: Array = []
	for f in files:
		if f.ends_with(".mp4") and paths.size() < 3:
			paths.append(CLIPS.path_join(f))
	if paths.size() < 3:
		print("FAIL  need 3 clips in %s" % CLIPS)
		quit(1)
		return
	var a: String = paths[0]
	var b: String = paths[1]
	var c: String = paths[2]

	var comp := RegionCompositor.new()
	comp.output_size = OUT
	root.add_child(comp)
	comp.setup([{"name": "Off", "shader": null}])
	var deck_tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	comp.set_source(deck_tex)
	var ed := RegionEditor.new()
	root.add_child(ed)
	ed.setup(comp, PackedStringArray(["Off"]), CLIPS)
	ed.clip_list_provider = func() -> Array: return paths
	ed.output_size_provider = func() -> Vector2: return OUT
	ed.set_active(true)
	comp.add_region(PackedVector2Array([Vector2(100, 100), Vector2(600, 100), Vector2(350, 500)]))
	comp.add_region(PackedVector2Array([Vector2(800, 100), Vector2(1300, 100), Vector2(1050, 500)]))
	comp.add_region(PackedVector2Array([Vector2(100, 600), Vector2(600, 600), Vector2(350, 1000)]))

	# 1. Building a list through the picker.
	ed._selected = 0
	ed._sync_selected()
	ed._open_picker()
	ed._pick(a)
	_ok(comp.get_clip(0) == a and comp.get_clip_list(0) == PackedStringArray([a]),
		"the first clip picked plays, as a one-clip list")
	ed._pick(b)
	_ok(comp.get_clip(0) == b and comp.get_clip_list(0) == PackedStringArray([a, b])
		and comp.get_clip_pos(0) == 1 and ed._picker.visible,
		"a second pick makes a two-clip list, plays it, and the picker stays open",
		str(comp.get_clip_list(0)))
	# A mask with one fixed clip from before lists existed (set_clip direct).
	comp.set_clip(1, c)
	_ok(comp.add_to_list(1, a) and comp.get_clip_list(1) == PackedStringArray([c, a]),
		"a fixed clip from before lists is kept as entry 1", str(comp.get_clip_list(1)))

	# 2. NEXT.
	ed._picker.visible = false
	ed._next_clip()
	_ok(comp.get_clip(0) == a and comp.get_clip_pos(0) == 0, "NEXT on the selected mask wraps to entry 1")
	ed._next_clip()
	_ok(comp.get_clip(0) == b, "…and steps on")
	_ok(comp.get_clip(1) == a, "a mask that is not selected does not step")
	comp.set_clip(2, c)   # one clip, no list
	ed._selected = -1
	ed._sync_selected()
	ed._next_clip()
	_ok(comp.get_clip(0) == a and comp.get_clip(1) == c and comp.get_clip(2) == a,
		"with nothing selected every mask steps: lists in their order, a one-clip mask to the next in the folder",
		"%s %s %s" % [comp.get_clip(0).get_file(), comp.get_clip(1).get_file(), comp.get_clip(2).get_file()])

	ed._selected = 2
	ed._sync_selected()
	ed._next_clip()
	_ok(comp.get_clip(2) == b and comp.get_clip_list(2).is_empty(), "a selected one-clip mask steps through the folder")
	ed._selected = -1
	ed._sync_selected()

	# 3. Removing.
	comp.add_to_list(0, c)       # list a b c, plays c (pos 2)
	comp.step_clip(0, -1)        # plays b (pos 1)
	comp.remove_from_list(0, b)  # c slides into pos 1
	_ok(comp.get_clip_list(0) == PackedStringArray([a, c]) and comp.get_clip(0) == c
		and comp.get_clip_pos(0) == 1, "removing the playing clip plays the one that takes its place",
		"%s pos %d" % [comp.get_clip_list(0), comp.get_clip_pos(0)])
	comp.remove_from_list(0, a)
	_ok(comp.get_clip_list(0) == PackedStringArray([c]) and comp.get_clip(0) == c and comp.get_clip_pos(0) == 0,
		"removing one before it keeps the same clip playing")
	comp.remove_from_list(0, c)
	_ok(comp.get_clip(0) == "" and comp._regions[0]["vp"] == null and _tex(comp, 0) == deck_tex,
		"an emptied list goes back to the deck and frees the decoder")
	comp.add_to_list(0, a)
	comp.add_to_list(0, b)
	ed._selected = 0
	ed._sync_selected()
	ed._pick("")
	_ok(comp.get_clip_list(0).is_empty() and comp.get_clip(0) == "", "FOLLOW DECK clears the list")
	comp.add_to_list(0, a)
	comp.add_to_list(0, b)

	# 4. LOCAL / DECK.
	ed._toggle_deck()
	var all_deck := true
	for i in 3:
		all_deck = all_deck and _tex(comp, i) == deck_tex
	var stopped := true
	for i in 3:
		var vp: SubViewport = comp._regions[i]["vp"]
		stopped = stopped and vp != null and vp.render_target_update_mode == SubViewport.UPDATE_DISABLED
	_ok(comp.follow_deck_all and all_deck, "DECK: every mask shows the deck")
	_ok(stopped, "DECK: the masks' own decoders stop rendering")
	_ok(comp.get_clip(0) == b and comp.get_clip_list(0).size() == 2 and comp.get_clip(1) == c,
		"DECK keeps every mask's clip and list")
	var before := comp.get_clip(0)
	ed._next_clip()
	_ok(comp.get_clip(0) == before, "NEXT does nothing while the masks show the deck")
	ed._toggle_deck()
	var own := true
	for i in 3:
		var vp: SubViewport = comp._regions[i]["vp"]
		own = own and _tex(comp, i) == vp.get_texture() \
			and vp.render_target_update_mode == SubViewport.UPDATE_ALWAYS
	_ok(not comp.follow_deck_all and own, "LOCAL brings each mask's own clip back")

	# 5. Round trip through regions.cfg (the desktop file is put back after).
	var had := FileAccess.file_exists(RegionEditor.SAVE_PATH)
	var keep := FileAccess.get_file_as_bytes(RegionEditor.SAVE_PATH) if had else PackedByteArray()
	comp.step_clip(0, 1)   # plays a (pos 0) — position must survive too
	ed._toggle_deck()
	ed._save()
	comp.clear()
	comp.set_follow_deck_all(false)
	# load_saved() resolves keys against the LAST scan (Storage.resolve), as on the
	# device, where the deck has always scanned the clips folder first.
	root.get_node("Storage").scan(CLIPS)
	ed.load_saved()
	_ok(comp.region_count() == 3 and comp.get_clip_list(0).size() == 2
		and comp.get_clip(0).get_file() == a.get_file() and comp.get_clip_pos(0) == 0,
		"the list and its position come back from regions.cfg",
		"%s pos %d" % [comp.get_clip_list(0), comp.get_clip_pos(0)])
	_ok(comp.follow_deck_all, "the DECK switch comes back too")
	_ok(comp.get_clip(2).get_file() == b.get_file() and comp.get_clip_list(2).is_empty(),
		"a one-clip mask comes back as one clip, no list")
	if had:
		var f := FileAccess.open(RegionEditor.SAVE_PATH, FileAccess.WRITE)
		f.store_buffer(keep)
		f.close()
	else:
		DirAccess.remove_absolute(RegionEditor.SAVE_PATH)

	ed.set_active(false)
	print("\n%d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
