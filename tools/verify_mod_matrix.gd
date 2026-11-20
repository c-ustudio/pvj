extends SceneTree
## Headless check of Mod v2 (AUDIO_REACTIVITY_SPEC.md §6) — the analyser, the
## matrix's targets and curves, recipes, and the band triggers — against the
## real GlobalBus and the real Main scene.
##
##   godot --headless --path <project> --script tools/verify_mod_matrix.gd
##
## No mic on a desk: the analyser's feeders are driven with synthetic band
## magnitudes, which is also why they are feeders. What this cannot say is
## whether KICK is the kick in a room; the panel's meters are for that.
##
## Checks:
##   1. Bands self-normalise: a steady tone reads 1.0 whatever its level, a
##      quieter passage reads against the recent peak, silence reads 0.
##   2. A band onset fires once on a jump and not again inside its cooldown.
##   3. hit falls to 1/e over hit_release; bright is 0 for bass, 1 for air.
##   4. Slot values: curves, invert, depth, master; matrix OFF == legacy drive.
##   5. FX A on a real effect: base + sum x half range, a moved slider becomes
##      the new base, matrix off puts the base back.
##   6. Recipes fill the slots and turn the matrix on; CLEAR empties them.
##   7. BEAT FLIP fires on KICK for a low-band onset only, HATS for a high one.
##   8. The target row names this effect's tunable.

const EPS := 1e-4

var _fails: int = 0
var _checks: int = 0


func _initialize() -> void:
	# The autoloads (GlobalBus among them) are not up inside _initialize; a
	# --script's own globals are not the project's either, so the bus is fetched
	# by path once the loop runs.
	_run_async.call_deferred()


func _bus() -> Node:
	return root.get_node("/root/GlobalBus")


func _run_async() -> void:
	await process_frame
	_check_analyser()
	await _check_matrix()
	print("\n%d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)


func _ok(cond: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
	print("%s  %s%s" % ["ok  " if cond else "FAIL", what, ("  — " + detail) if detail != "" else ""])


func _feed(band: int, mag: float, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		_bus()._feed_band(band, mag, 1.0 / 60.0)
		t += 1.0 / 60.0


# --- 1-3 -----------------------------------------------------------------

func _check_analyser() -> void:
	var g: Node = _bus()
	# A steady tone at two very different levels reads the same.
	_feed(g.BAND_LOW, 0.1, 1.0)
	var loud: float = g.low
	g._band_peak[g.BAND_LOW] = 0.0
	g.low = 0.0
	_feed(g.BAND_LOW, 0.01, 1.0)
	var quiet: float = g.low
	_ok(loud > 0.97 and quiet > 0.97, "a steady band reads ~1.0 at 0.1 and at 0.01: self-normalised",
		"%.3f and %.3f" % [loud, quiet])
	# Quieter than the recent peak: read against it, then the peak lets go.
	_feed(g.BAND_LOW, 0.1, 1.0)
	_feed(g.BAND_LOW, 0.03, 0.5)
	var against: float = g.low
	_feed(g.BAND_LOW, 0.03, 20.0)
	var later: float = g.low
	_ok(against > 0.2 and against < 0.45 and later > 0.95,
		"a quieter passage reads against the last peak (%.2f), and after 20 s the peak has come down to it (%.2f)" % [against, later])
	# Silence is 0, not "as loud as it has recently been".
	_feed(g.BAND_LOW, 0.0, 2.0)
	_ok(g.low < 0.01, "silence reads 0", "%.4f" % g.low)
	_feed(g.BAND_LOW, 0.001, 2.0)
	_ok(g.low < 0.01, "noise under the floor reads 0", "%.4f" % g.low)

	# An onset in one band.
	var fired: Array[int] = []
	var conn := func(band: int) -> void: fired.append(band)
	g.band_beat.connect(conn)
	_feed(g.BAND_HIGH, 0.02, 2.0)      # a steady hat bed (its start is itself an onset)
	var at_start := fired.size()
	fired.clear()
	_feed(g.BAND_HIGH, 0.02, 1.0)      # …and once it is steady, nothing
	_ok(at_start <= 1 and fired.is_empty(), "a sound starting fires at most once, and a steady one not at all",
		"%d at the start, %d after" % [at_start, fired.size()])
	_feed(g.BAND_HIGH, 0.2, 0.05)      # a hit
	_ok(fired == [g.BAND_HIGH], "a jump in the high band fires HATS once", str(fired))
	_feed(g.BAND_HIGH, 0.02, 0.03)
	_feed(g.BAND_HIGH, 0.2, 0.05)      # a second hit inside the cooldown
	_ok(fired.size() == 1, "…and not again inside the cooldown")
	_feed(g.BAND_HIGH, 0.02, 0.5)
	_feed(g.BAND_HIGH, 0.2, 0.05)
	_ok(fired.size() == 2, "…but again after it")
	_ok(not fired.has(g.BAND_LOW), "the low band, untouched, fired nothing")
	g.band_beat.disconnect(conn)

	# The hit follower and brightness.
	g.hit = 1.0
	var t := 0.0
	while t < g.hit_release:
		g._feed_hit(1.0 / 60.0)
		t += 1.0 / 60.0
	_ok(absf(g.hit - exp(-1.0)) < 0.03, "hit falls to 1/e over hit_release", "%.3f" % g.hit)
	var bass := PackedFloat32Array([0.2, 0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var air := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.05, 0.2])
	for i in 120:
		g._feed_centroid(bass, 1.0 / 60.0)
	var dark: float = g.bright
	for i in 120:
		g._feed_centroid(air, 1.0 / 60.0)
	_ok(dark < 0.1 and g.bright > 0.9, "bright: bass reads %.2f, air reads %.2f" % [dark, g.bright])


# --- 4-8 -----------------------------------------------------------------

func _check_matrix() -> void:
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 12:
		await process_frame
	var g: Node = _bus()

	# 4. Slot values.
	main._mod_init_defaults()
	main._mod_master = 1.0
	g.level = 0.4
	var off: float = main.audio_base + 0.4 * main.audio_amount
	main._mod_enabled = false
	_ok(absf(main._deck_intensity() - off) < EPS, "matrix off: the legacy drive, literally")
	main._mod_enabled = true
	_ok(absf(main._deck_intensity() - off) < EPS, "matrix on with the seed slot: the same number", "%.3f vs %.3f" % [main._deck_intensity(), off])
	var slot: Dictionary = main._mod_slots[1]
	slot["src"] = main.ModSource.LOW
	slot["dst"] = main.ModTarget.FX_A
	slot["depth"] = 1.0
	g.low = 0.5
	slot["curve"] = main.ModCurve.LIN
	var lin: float = main._slot_value(slot)
	slot["curve"] = main.ModCurve.SQR
	var sqr: float = main._slot_value(slot)
	slot["curve"] = main.ModCurve.SQRT
	var rt: float = main._slot_value(slot)
	_ok(absf(lin - 0.5) < EPS and absf(sqr - 0.25) < EPS and absf(rt - sqrt(0.5)) < EPS,
		"curves: LIN %.3f, SQR %.3f, SQRT %.3f of a 0.5 source" % [lin, sqr, rt])
	slot["curve"] = main.ModCurve.LIN
	slot["pol"] = main.ModPolarity.INV
	_ok(absf(main._slot_value(slot) - 0.5) < EPS, "invert: 1 - 0.5")
	g.low = 0.2
	_ok(absf(main._slot_value(slot) - 0.8) < EPS, "…ducks: 1 - 0.2")
	slot["pol"] = main.ModPolarity.NORM
	main._mod_master = 0.5
	_ok(absf(main._slot_value(slot) - 0.1) < EPS, "master amount halves it")
	main._mod_master = 1.0
	_ok(absf(main._mod_target_sum(main.ModTarget.FX_A) - 0.2) < EPS
		and absf(main._mod_target_sum(main.ModTarget.INTENSITY) - 0.4 * main.audio_amount) < EPS,
		"sums are per target: FX A holds slot 2, INTENSITY holds the seed")
	_ok(main._mod_routes(main.ModTarget.FX_A) and not main._mod_routes(main.ModTarget.SPEED), "_mod_routes knows what is routed")

	# 5. FX A on a real effect.
	var glitch := -1
	for i in main._effects.size():
		if str(main._effects[i].name) == "Glitch":
			glitch = i
	_ok(glitch >= 0, "the Glitch effect exists")
	main._effect_index = glitch
	main._apply_effect()
	var mat: ShaderMaterial = main.shader_slot.get_shader_material()
	var base0: float = float(mat.get_shader_parameter("block_size"))
	g.low = 0.5
	main._apply_mod_targets()
	var want: float = clampf(base0 + 0.5 * (35.0 - 1.0) * 0.5, 1.0, 35.0)
	_ok(absf(float(mat.get_shader_parameter("block_size")) - want) < EPS,
		"FX A: block size = its base + source x half the range", "%.2f -> %.2f" % [base0, float(mat.get_shader_parameter("block_size"))])
	_ok(main._mod_target_label(main.ModTarget.FX_A) == "FX A · BLOCK SIZE", "the target row names the tunable", main._mod_target_label(main.ModTarget.FX_A))
	# The slider moves under it: the new position is the base.
	mat.set_shader_parameter("block_size", 10.0)
	main._apply_mod_targets()
	_ok(absf(float(mat.get_shader_parameter("block_size")) - clampf(10.0 + 8.5, 1.0, 35.0)) < EPS,
		"a slider moved mid-set becomes the new base", "%.2f" % float(mat.get_shader_parameter("block_size")))
	g.low = 0.0
	main._apply_mod_targets()
	_ok(absf(float(mat.get_shader_parameter("block_size")) - 10.0) < EPS, "silence: back on the base")
	g.low = 0.5
	main._apply_mod_targets()
	main._mod_enabled = false
	main._apply_mod_targets()
	_ok(absf(float(mat.get_shader_parameter("block_size")) - 10.0) < EPS and main._mod_fx_written.is_empty(),
		"matrix off: the base is put back and nothing is remembered")
	main._mod_enabled = true

	# 6. Recipes.
	main._apply_mod_recipe(0)   # PUMP
	var s0: Dictionary = main._mod_slots[0]
	var s1: Dictionary = main._mod_slots[1]
	var s2: Dictionary = main._mod_slots[2]
	_ok(main._mod_enabled and int(s0["src"]) == main.ModSource.LOW and int(s0["dst"]) == main.ModTarget.INTENSITY
		and int(s0["curve"]) == main.ModCurve.SQR and int(s1["src"]) == main.ModSource.HIT
		and int(s1["dst"]) == main.ModTarget.FX_A and int(s2["src"]) == main.ModSource.NONE,
		"PUMP: LOW -> INTENSITY squared, HIT -> FX A, the rest empty, matrix on")
	main._apply_mod_recipe(main.MOD_RECIPES.size() - 1)   # CLEAR
	var empty := true
	for s: Dictionary in main._mod_slots:
		if int(s["src"]) != main.ModSource.NONE:
			empty = false
	_ok(empty and not main._mod_enabled, "CLEAR empties every slot and turns the matrix off")
	var labels := ""
	for r: Array in main.MOD_RECIPES:
		labels += str(r[0]) + " "
	_ok(main._mod_recipe_buttons.size() == main.MOD_RECIPES.size(), "one chip per recipe: %s" % labels.strip_edges())

	# 7. BEAT FLIP on a band.
	main._flip_enabled = true
	main._flip_div_index = 0
	main._flip_trig = main.FlipTrig.KICK
	var before: int = main._flip_count
	g.band_beat.emit(g.BAND_HIGH)
	_ok(main._flip_count == before, "set to KICK, a high-band onset does nothing")
	g.band_beat.emit(g.BAND_LOW)
	_ok(main._flip_count == before + 1, "…a low-band onset triggers the flip")
	main._flip_trig = main.FlipTrig.HATS
	g.band_beat.emit(g.BAND_HIGH)
	_ok(main._flip_count == before + 2, "set to HATS, a high-band onset triggers it")
	g.beat.emit()
	_ok(main._flip_count == before + 2, "…and the broadband onset does not")
	main._flip_enabled = false
	_ok(main.FLIP_TRIG_NAMES.size() == 4 and main.TRIG_BAND_NAMES == ["ONSET", "KICK", "HATS"],
		"the trigger words: Onset / Grid / Kick / Hats on the flip, ONSET / KICK / HATS on advance")
	main._cycle_audio_band()
	_ok(main._audio_band == main.TrigBand.KICK and main._audio_band_btn.text.contains("KICK"),
		"advance-on cycles and its row says so", main._audio_band_btn.text)
	main._audio_band = main.TrigBand.ONSET

	# 8. The meter row exists and reads the sources.
	g.low = 1.0
	g.high = 0.5
	_ok(main._bar8(1.0) == "########" and main._bar8(0.5) == "####....", "the meter's bars")

	root.remove_child(main)
	main.queue_free()
