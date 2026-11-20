extends SceneTree
## Headless check of the help cards (HELP_CARDS_SPEC.md) against the real Main
## scene.
##
##   godot --headless --path <project> --script tools/verify_help.gd
##
## Checks:
##   1. Every control the panels register has a card — the list of misses is
##      printed, and gated to zero. (Every effect's settings are built for it.)
##   2. A hold on a row opens its card, and the touch is swallowed.
##   3. Help mode intercepts a row and leaves a nav cell alone.
##   4. The tour runs its cards and records itself as seen; skipping counts.
##   5. HelpText.find: exact keys, the longest prefix for a live caption, and
##      never a section's card for a row.
##   6. ABOUT shows FFmpeg's LGPL credit and the open-source licences row.

var _fails: int = 0
var _checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
	print("%s  %s%s" % ["ok  " if cond else "FAIL", what, ("  — " + detail) if detail != "" else ""])


func _run() -> void:
	# 5 first: pure.
	_ok(HelpText.find("MOD MATRIX/AMOUNT")["title"] == "AMOUNT", "an exact key finds its card")
	_ok(HelpText.find("MOD MATRIX/SLOT 2   HIGH")["title"] == "SLOT — SOURCE", "a live caption finds the longest prefix key")
	_ok(HelpText.find("MOD MATRIX/NO SUCH ROW").is_empty(), "a row with no card is not answered by its section's card")
	_ok(HelpText.find("EFFECT/HUD RINGS")["title"] == "HUD RINGS" and HelpText.find("EFFECT/HUD")["title"] == "HUD",
		"HUD and HUD RINGS each get their own")
	_ok(HelpText.TOUR.size() == 5, "the tour is five cards")
	# The public build never names what only the pro build has.
	var pro := HelpText.FeaturesS.is_pro()
	_ok(HelpText.find("MOD MATRIX/SLOT 1   LOW")["body"].contains("TRACK") == pro, "the slot card names the tracker only in the pro build")
	_ok(HelpText.tour()[0][1].contains("LOCAL FILES") == pro and HelpText.tour().size() == 5, "the tour's first card names the import this build has")
	for k: String in HelpText.PUBLIC.keys():
		_ok(HelpText.CARDS.has(k), "public wording %s overrides a card that exists" % k)

	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	main._tour_seen = true   # no tour popping up under the checks below
	root.add_child(main)
	for i in 12:
		await process_frame
	main._tour_seen = true

	# 1. Coverage — build every effect's settings so their rows register too.
	var was_effect: int = main._effect_index
	for i in main._effects.size():
		main._effect_index = i
		main._rebuild_fx_settings()
	main._effect_index = was_effect
	main._rebuild_fx_settings()
	var missing: Array[String] = []
	var seen := {}
	var registered := 0
	for t: Array in main._help_targets:
		if not is_instance_valid(t[0]):
			continue
		registered += 1
		var key: String = t[1]
		if seen.has(key):
			continue
		seen[key] = true
		if HelpText.find(key).is_empty():
			missing.append(key)
	missing.sort()
	_ok(registered > 100, "the panels register their controls", "%d controls, %d distinct keys" % [registered, seen.size()])
	_ok(missing.is_empty(), "every registered control has a card", "missing: %s" % [missing])

	# 6. ABOUT carries FFmpeg's LGPL credit (THIRD_PARTY.md) and the licences row.
	var credit := main._mode_panel.find_child("FfmpegCredit", true, false) as Label
	_ok(credit != null and credit.text.contains("FFmpeg") and credit.text.contains("LGPLv2.1"),
		"ABOUT shows FFmpeg's LGPL credit", credit.text if credit != null else "no FfmpegCredit label")
	var licences_row := false
	for t: Array in main._help_targets:
		if is_instance_valid(t[0]) and t[1] == "ABOUT/OPEN-SOURCE LICENCES…":
			licences_row = true
	_ok(licences_row and str(main.LICENCES_URL).ends_with("/THIRD_PARTY.md"),
		"ABOUT has the open-source licences row, and it opens THIRD_PARTY.md")

	# 2. A hold on a row.
	main._toggle_mode_panel()
	await process_frame
	var row: Control = null
	var header: Control = null
	for t: Array in main._help_targets:
		if is_instance_valid(t[0]) and t[1] == "MOD MATRIX":
			header = t[0]
		if is_instance_valid(t[0]) and t[1] == "MOD MATRIX/AMOUNT":
			row = t[0]
	_ok(header != null and row != null, "the MOD MATRIX header and its AMOUNT row are registered")
	if header != null:
		header.pressed.emit()   # expand the section
	for i in 3:
		await process_frame
	_ok(row.is_visible_in_tree(), "the row is showing once its section is open")
	main._help_hold_pos = row.get_global_rect().get_center()
	main._help_hold_fire()
	var dlg: Node = main._topmost_dialog()
	_ok(dlg != null and main._row_suppressed and main._help_swallow, "a hold on AMOUNT opens its card and swallows the touch")
	if dlg != null:
		dlg.dismiss()
	await process_frame
	main._help_hold_pos = Vector2(-50, -50)
	main._help_hold_fire()
	_ok(main._topmost_dialog() == null, "a hold on nothing opens nothing")

	# 3. Help mode.
	main._set_help_mode(true)
	_ok(main._help_mode and main.status.visible and main.status.text.begins_with("HELP MODE"), "help mode says so on the status line")
	var cell: Control = main._cell_mode[0]
	_ok(not main._help_intercept(cell.get_global_rect().get_center()) and main._topmost_dialog() == null and main._help_mode,
		"in help mode a tap on a nav cell is left alone, and the mode stays armed")
	var help_row: Control = null
	for t: Array in main._help_targets:
		if is_instance_valid(t[0]) and t[1] == "HELP/HELP MODE":
			help_row = t[0]
	_ok(help_row != null and not main._help_intercept(help_row.get_global_rect().get_center()) and main._help_mode,
		"…and so is the HELP MODE toggle itself (it is how you turn the mode off)")
	var took: bool = main._help_intercept(row.get_global_rect().get_center())
	dlg = main._topmost_dialog()
	_ok(took and dlg != null and not main._help_mode and not main.status.visible,
		"a tap on a row shows its card instead — and that was the one tap: help mode is off again")
	if dlg != null:
		dlg.dismiss()
	await process_frame
	_ok(not main._help_intercept(row.get_global_rect().get_center()) and main._topmost_dialog() == null,
		"with help mode off a tap is a tap")

	# 3b. Areas (the clip grid, the sequencer): help mode only; a hold is theirs.
	main._toggle_clip_grid()   # lazy: built on the first LIB
	for i in 3:
		await process_frame
	var grid: Control = main._clip_grid
	var strip: Control = main._seq_strip
	var strip_pos: Vector2 = strip.get_global_rect().get_center()
	# Headless has no hovered control, so the rectangles decide: a point in the
	# grid's body, clear of the nav bar (which the grid's rect also covers).
	var grid_pos: Vector2 = Vector2(grid.get_global_rect().get_center().x, grid.get_global_rect().get_center().y - 100.0)
	main._help_swallow = false   # (a real touch release clears it; there is none here)
	main._help_hold_pos = strip_pos
	main._help_hold_fire()
	dlg = main._topmost_dialog()
	_ok(dlg == null and not main._help_swallow, "a hold on the sequencer opens no card (the hold is the strip's own)",
		"" if dlg == null else "opened '%s' — target %s" % [dlg._title_lbl.text, main._help_target_at(strip_pos)])
	if dlg != null:
		dlg.dismiss()
		await process_frame
		main._help_swallow = false
	main._set_help_mode(true)
	var took_strip: bool = main._help_intercept(strip_pos)
	dlg = main._topmost_dialog()
	_ok(took_strip and dlg != null and dlg._title_lbl.text == "SEQUENCER", "in help mode a tap on a slot shows the SEQUENCER card (not the grid's — the strip sits inside the grid)")
	var gated: bool = bool(strip.press_gate.call()) and bool(grid.press_gate.call())
	_ok(gated, "…and the grid's and strip's gates say the touch is taken")
	if dlg != null:
		dlg.dismiss()
	await process_frame
	main._help_swallow = false
	main._set_help_mode(true)
	var took_grid: bool = main._help_intercept(grid_pos)
	dlg = main._topmost_dialog()
	_ok(took_grid and dlg != null and dlg._title_lbl.text == "CLIP GRID", "…and a tap on the grid shows the CLIP GRID card",
		"took %s, dialog %s, target %s, grid rect %s" % [took_grid, dlg._title_lbl.text if dlg != null else "none", main._help_target_at(grid_pos), grid.get_global_rect()])
	if dlg != null:
		dlg.dismiss()
	await process_frame
	main._help_swallow = false
	var seq_keys: Array = []
	for hb: Array in strip.help_buttons():
		seq_keys.append("SEQUENCER/" + hb[1])
		_ok(not HelpText.find("SEQUENCER/" + hb[1]).is_empty(), "the strip's %s button has a card" % hb[1])

	# 4. The tour.
	main._tour_seen = false
	main._show_tour(0)
	var steps := 0
	while main._topmost_dialog() != null and steps < 10:
		var d: Node = main._topmost_dialog()
		d._accept()   # NEXT … DONE
		await process_frame
		steps += 1
	_ok(steps == HelpText.TOUR.size() and main._tour_seen, "the tour runs its %d cards to DONE and is then seen" % HelpText.TOUR.size(), "%d steps" % steps)
	main._tour_seen = false
	main._show_tour(0)
	var d2: Node = main._topmost_dialog()
	if d2 != null:
		d2.dismiss()   # SKIP
	await process_frame
	_ok(main._tour_seen and main._topmost_dialog() == null, "SKIP ends the tour and counts as seen")

	root.remove_child(main)
	main.queue_free()
	print("\n%d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
