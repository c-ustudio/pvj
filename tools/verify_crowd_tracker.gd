extends SceneTree
## Headless proof for CrowdTracker (§13.3/§13.4) — the M8b acceptance gate
## that does NOT need people standing in a room.
##
##   Godot --headless --path <project> --script tools/verify_crowd_tracker.gd
##
## Time is synthetic (now_ms handed to feed), so the birth debounce, the grace
## release and the slot cooldown are EXACT rather than approximately observed.
## Everything here is the logic that decides whether "person 3" is still the
## same human — the part a live test can only sample, never prove.

const CrowdTrackerS := preload("res://scripts/crowd_tracker.gd")

var _fails: int = 0
var _checks: int = 0


func _init() -> void:
	t_assignment()
	t_birth_debounce()
	t_jump_gate()
	t_grace_and_freeze()
	t_slot_cooldown()
	t_overflow()
	t_slot_stability_under_swap()
	t_mirror_is_output_only()
	t_aggregates()
	t_field_compat()
	print("\n%s  %d/%d checks passed" % [
		"FAIL" if _fails > 0 else "PASS", _checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func ck(label: String, cond: bool) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  ✗ %s" % label)
	else:
		print("  ✓ %s" % label)


func det(x: float, y: float, size: float = 0.3, conf: float = 0.8) -> Dictionary:
	return {"x": x, "y": y, "size": size, "conf": conf}


## Drive n inferences of the same detections, 80 ms apart (≈12 Hz).
func run(tr, dets: Array, n: int, t0: int, step: int = 80) -> int:
	var t := t0
	for i in n:
		tr.feed(dets, t)
		t += step
	return t


func fresh(slots: int = 6):
	var tr := CrowdTrackerS.new()
	tr.set_slots(slots)
	tr.filter_min_cutoff = 5.0    # near-passthrough so tests read positions, not lag
	tr.filter_beta = 0.0
	return tr


# -------------------------------------------------------------------------

func t_assignment() -> void:
	print("\n[assignment]")
	var tr = fresh()
	# two people, well apart, held past the debounce
	run(tr, [det(0.25, 0.5), det(0.75, 0.5)], 6, 1000)
	ck("two detections occupy two slots", tr.count() == 2)
	var x0 := tr.slot_channel(0, CrowdTrackerS.CH_X)
	var x1 := tr.slot_channel(1, CrowdTrackerS.CH_X)
	ck("slots hold distinct x", absf(x0 - x1) > 0.3)

	# nudge both slightly — each slot must follow ITS OWN person, not swap
	var near0 := minf(x0, x1)
	run(tr, [det(0.27, 0.5), det(0.73, 0.5)], 3, 2000)
	var n0 := minf(tr.slot_channel(0, CrowdTrackerS.CH_X), tr.slot_channel(1, CrowdTrackerS.CH_X))
	ck("nearest-centroid keeps each slot on its own subject", absf(n0 - near0) < 0.1)


func t_birth_debounce() -> void:
	print("\n[birth debounce — a one-frame phantom must never create a person]")
	var tr = fresh()
	tr.acquire_frames = 4
	tr.feed([det(0.5, 0.5)], 1000)
	ck("1 hit: no slot yet", tr.count() == 0)
	tr.feed([det(0.5, 0.5)], 1080)
	tr.feed([det(0.5, 0.5)], 1160)
	ck("3 hits: still no slot", tr.count() == 0)
	tr.feed([det(0.5, 0.5)], 1240)
	ck("4th consecutive hit births the slot", tr.count() == 1)

	# a phantom that appears once and vanishes must leave nothing behind
	var tr2 = fresh()
	tr2.feed([det(0.2, 0.2)], 1000)
	tr2.feed([], 1080)
	tr2.feed([det(0.2, 0.2)], 1160)
	tr2.feed([], 1240)
	ck("flickering phantom never accumulates a birth", tr2.count() == 0)


func t_jump_gate() -> void:
	print("\n[jump gate — beyond it is a DIFFERENT person standing where ours was]")
	var tr = fresh()
	tr.max_jump = 0.18
	run(tr, [det(0.3, 0.5)], 6, 1000)
	ck("subject held", tr.count() == 1)
	var before := tr.slot_channel(0, CrowdTrackerS.CH_X)
	# teleport well beyond the gate — must NOT be accepted as the same person
	tr.feed([det(0.9, 0.5)], 2000)
	var after := tr.slot_channel(0, CrowdTrackerS.CH_X)
	ck("slot does not teleport across the gate", absf(after - before) < 0.1)

	# a candidate that jumps mid-debounce restarts its clock
	var tr2 = fresh()
	tr2.acquire_frames = 4
	tr2.feed([det(0.2, 0.5)], 1000)
	tr2.feed([det(0.2, 0.5)], 1080)
	tr2.feed([det(0.8, 0.5)], 1160)   # different doorway
	tr2.feed([det(0.8, 0.5)], 1240)
	ck("jump mid-debounce restarts the count", tr2.count() == 0)


func t_grace_and_freeze() -> void:
	print("\n[grace — values FREEZE, they never decay]")
	var tr = fresh()
	tr.grace_ms = 900
	run(tr, [det(0.4, 0.6)], 6, 1000)
	var held_x := tr.slot_channel(0, CrowdTrackerS.CH_X)
	tr.feed([], 2000)                                  # vanished
	ck("present survives inside grace", tr.slot_channel(0, CrowdTrackerS.CH_PRESENT) == 1.0)
	ck("x FROZEN, not decayed toward centre",
		absf(tr.slot_channel(0, CrowdTrackerS.CH_X) - held_x) < 0.001)
	# ⚠️ the window runs from the LAST SIGHTING (t=1400 after 6 feeds at 80 ms),
	# not from the first empty feed. 2200 is 800 ms after it — inside. The first
	# version of this check probed 2500 (=1100 ms) and called it "500 ms": the
	# TEST was wrong, the tracker released exactly on time.
	tr.feed([], 2200)
	ck("still inside grace at 800 ms since last sighting",
		tr.slot_channel(0, CrowdTrackerS.CH_PRESENT) == 1.0)
	tr.feed([], 2400)                                  # 1000 ms > 900
	ck("released after grace expires", tr.slot_channel(0, CrowdTrackerS.CH_PRESENT) == 0.0)
	ck("count drops to zero", tr.count() == 0)


func t_slot_cooldown() -> void:
	print("\n[cooldown — an effect bound to slot 0 must not inherit a stranger]")
	var tr = fresh(1)          # ONE slot, so reuse is forced or refused
	tr.grace_ms = 100
	tr.cooldown_ms = 1500
	tr.acquire_frames = 2
	run(tr, [det(0.3, 0.5)], 4, 1000)
	ck("slot 0 held", tr.count() == 1)
	tr.feed([], 1400)
	tr.feed([], 1600)           # past grace -> freed at 1600
	ck("slot released", tr.count() == 0)
	# a NEW person immediately: must be refused while cooling
	run(tr, [det(0.8, 0.5)], 4, 1700)
	ck("new person refused during cooldown", tr.count() == 0)
	# after the cooldown, the same slot accepts them
	run(tr, [det(0.8, 0.5)], 4, 3400)
	ck("accepted once cooldown expires", tr.count() == 1)


func t_overflow() -> void:
	print("\n[overflow — the surplus is untracked, held slots are NEVER reshuffled]")
	var tr = fresh(2)
	tr.acquire_frames = 2
	run(tr, [det(0.2, 0.5), det(0.5, 0.5), det(0.8, 0.5)], 4, 1000)
	ck("only `slots` people are held", tr.count() == 2)
	ck("overflow flag raised", tr.overflow())
	ck("aggregates report overflow", float(tr.aggregates()["overflow"]) == 1.0)
	# the two held slots keep THEIR people even though a third is visible
	var xs := [tr.slot_channel(0, CrowdTrackerS.CH_X), tr.slot_channel(1, CrowdTrackerS.CH_X)]
	run(tr, [det(0.2, 0.5), det(0.5, 0.5), det(0.8, 0.5)], 3, 2000)
	ck("held slots unchanged while a third is visible",
		absf(tr.slot_channel(0, CrowdTrackerS.CH_X) - xs[0]) < 0.05
		and absf(tr.slot_channel(1, CrowdTrackerS.CH_X) - xs[1]) < 0.05)


func t_slot_stability_under_swap() -> void:
	print("\n[stability — detector ORDER is not identity]")
	var tr = fresh()
	run(tr, [det(0.25, 0.5), det(0.75, 0.5)], 6, 1000)
	var a := tr.slot_channel(0, CrowdTrackerS.CH_X)
	var b := tr.slot_channel(1, CrowdTrackerS.CH_X)
	# same two people, detector hands them back in the OPPOSITE order
	run(tr, [det(0.75, 0.5), det(0.25, 0.5)], 4, 2000)
	ck("slot 0 kept its person despite reordered detections",
		absf(tr.slot_channel(0, CrowdTrackerS.CH_X) - a) < 0.05)
	ck("slot 1 kept its person despite reordered detections",
		absf(tr.slot_channel(1, CrowdTrackerS.CH_X) - b) < 0.05)


func t_mirror_is_output_only() -> void:
	print("\n[§4.2 — mirror at OUTPUT, never in matching (the Session 34 bug)]")
	var tr = fresh()
	tr.mirror_output = true
	# feed an OFF-CENTRE subject: if the mirror leaked into matching, the
	# phantom distance |2x-1| would blow the gate and churn the lock
	run(tr, [det(0.2, 0.5)], 6, 1000)
	ck("off-centre subject locks with mirror on", tr.count() == 1)
	ck("output x IS mirrored", absf(tr.slot_channel(0, CrowdTrackerS.CH_X) - 0.8) < 0.05)
	# and it must HOLD across inferences rather than cycling
	run(tr, [det(0.21, 0.5)], 8, 2000)
	ck("lock holds off-centre (no churn)", tr.count() == 1)


func t_aggregates() -> void:
	print("\n[aggregates §13.4]")
	var tr = fresh()
	run(tr, [det(0.2, 0.5, 0.2), det(0.8, 0.5, 0.6)], 6, 1000)
	var a := tr.aggregates()
	ck("count", int(a["count"]) == 2)
	ck("centroid size-weighted toward the NEARER person",
		float(a["centroid_x"]) > 0.5)
	ck("nearest reports the largest box", absf(float(a["nearest"]) - 0.6) < 0.05)
	ck("balance leans right", float(a["balance"]) > 0.5)
	ck("spread non-zero for separated people", float(a["spread"]) > 0.0)
	var empty := fresh().aggregates()
	ck("empty crowd centroid holds 0.5, not garbage",
		float(empty["centroid_x"]) == 0.5 and int(empty["count"]) == 0)


func t_field_compat() -> void:
	print("\n[field compat §13.4 — the five FROZEN Kinect channels]")
	var tr = fresh()
	run(tr, [det(0.3, 0.5, 0.4), det(0.7, 0.5, 0.4)], 6, 1000)
	var f := tr.field_channels()
	for k in ["occupied_volume", "motion_energy", "centroid_x", "centroid_y", "spatial_variance"]:
		ck("channel present: %s" % k, f.has(k))
		ck("  %s in 0..1" % k, float(f[k]) >= 0.0 and float(f[k]) <= 1.0)
	ck("occupied_volume rises with more people",
		float(f["occupied_volume"]) > float(fresh().field_channels()["occupied_volume"]))
