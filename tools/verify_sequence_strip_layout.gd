extends Node
## Headless check that nothing in the SequenceStrip's title row overlaps, and
## that the SAVE/LOAD/DEL feedback has its own place (Session 42). The status
## label used to sit at the end of a hand-placed slot group and drew across
## 1 BAR/SLOT and SHUFFLE; the LABEL field already covered CLEAR.
##
## Run as a SCENE, not --script (SequenceStrip names the ThumbnailService
## autoload, which does not resolve under --script):
##   godot --headless --path <project> res://tools/verify_sequence_strip_layout.tscn
##
## Checks, at the landscape widths of 2400 / 2340 / 2424 px phones (÷1.667) and
## an 18:9 (1296) and a 16:9 (1152) phone — those two in the compact row — for lane A, lane B, lane B·NET, every BARS PER SLOT caption,
## a 24-character label and a 3-digit count:
##   1. no two title-row boxes intersect, and every box is inside the strip;
##   2. the LABEL field keeps its minimum; the title is never cut; the Pixels
##      get the full row;
##   3. a flash shows the toast inside the slot row (below TITLE_H), clear of
##      every title-row box, never wider than the strip — it fades out, a tap
##      takes it down at once, and hidden it ignores touches;
##   4. the LOAD picker: 6 rows ≥ 76 px tall, empty slots disabled, the armed
##      one marked, a tap emits the row's index and closes the box.

var _fails := 0
var _checks := 0


func _ready() -> void:
	call_deferred("_go")


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _go() -> void:
	var font := FontVariation.new()   # the app's _font_label: Departure Mono, tracked +3
	font.base_font = load("res://fonts/DepartureMono-Regular.otf")
	font.spacing_glyph = 3
	for w: float in [1440.0, 1404.0, 1454.0, 1296.0, 1152.0]:
		for lane_case: String in ["A", "B", "B·NET"]:
			var s := SequenceStrip.new()
			add_child(s)
			s.size = Vector2(w, SequenceStrip.STRIP_H)
			var seq := Sequence.new()
			var ids: Array[String] = []
			for i: int in 120:
				ids.append("x%d" % i)
			seq.entries = ids
			s.setup(seq, font)
			if lane_case != "A":
				s._select_lane(1)
			if lane_case == "B·NET":
				s.set_lane_b_badge("NET")
			s._label_edit.text = "AAAAAAAAAAAAAAAAAAAAAAAA"
			for beats: int in [1, 2, 4, 8]:
				s.set_beats_per_slot(beats)
				await get_tree().process_frame
				await get_tree().process_frame
				_check_row(s, "w=%d %s bps=%d" % [w, lane_case, beats])
			s.flash("LOADED SLOT 3 · 2 DROPPED · AND A VERY LONG REFUSAL THAT GOES ON AND ON AND ON")
			await get_tree().process_frame
			await get_tree().process_frame
			_check_toast(s, "w=%d %s" % [w, lane_case])
			s.queue_free()
	await _check_fade(font)
	await _check_picker()
	print("verify_sequence_strip_layout: %d checks, %d failed" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _row_boxes(s: SequenceStrip) -> Array:
	var row := s.get_node("TitleRow") as HBoxContainer
	var out: Array = []
	for c: Node in row.get_children():
		var ctl := c as Control
		if ctl.visible:
			out.append([ctl, Rect2(ctl.global_position - s.global_position, ctl.size)])
	return out


func _name(c: Control) -> String:
	return str(c.get("text")) if c.get("text") != null and str(c.get("text")) != "" else c.get_class()


func _check_row(s: SequenceStrip, tag: String) -> void:
	var boxes := _row_boxes(s)
	var strip := Rect2(Vector2.ZERO, s.size)
	for i: int in boxes.size():
		var r: Rect2 = boxes[i][1]
		_ok(strip.encloses(r), "%s: %s %s leaves the strip" % [tag, _name(boxes[i][0]), r])
		for j: int in range(i + 1, boxes.size()):
			var q: Rect2 = boxes[j][1]
			_ok(not r.intersects(q), "%s: %s %s overlaps %s %s" % [tag, _name(boxes[i][0]), r, _name(boxes[j][0]), q])
	var tw := s._title_w(s._title.text)
	_ok(s._title.size.x + 0.5 >= tw, "%s: title \"%s\" cut (%.0f < %.0f)" % [tag, s._title.text, s._title.size.x, tw])
	_ok(s._title.text.contains(str(s._ids.size())), "%s: title \"%s\" lost the count" % [tag, s._title.text])
	var min_w := SequenceStrip.LABEL_MIN_W_COMPACT if s._compact else SequenceStrip.LABEL_MIN_W
	_ok(s._compact == (s.size.x < 1400.0), "%s: compact=%s" % [tag, s._compact])
	_ok(s._label_edit.size.x >= min_w - 0.5,
		"%s: LABEL field squeezed to %.0f" % [tag, s._label_edit.size.x])


func _check_toast(s: SequenceStrip, tag: String) -> void:
	_ok(s.toast_text() != "", "%s: toast not showing" % tag)
	var t := Rect2(s._toast.global_position - s.global_position, s._toast.size)
	_ok(t.position.y >= SequenceStrip.TITLE_H, "%s: toast %s reaches into the title row" % [tag, t])
	_ok(Rect2(Vector2.ZERO, s.size).encloses(t), "%s: toast %s leaves the strip" % [tag, t])
	for b: Array in _row_boxes(s):
		_ok(not t.intersects(b[1]), "%s: toast overlaps %s" % [tag, _name(b[0])])


func _check_fade(font: Font) -> void:
	var s := SequenceStrip.new()
	add_child(s)
	s.size = Vector2(1440, SequenceStrip.STRIP_H)
	s.setup(Sequence.new(), font)
	s.flash("SAVED SLOT 2")
	await get_tree().process_frame
	_ok(s.toast_text() == "SAVED SLOT 2", "toast text is %s" % s.toast_text())
	_ok(not s._empty.visible, "the empty-lane hint shows around the toast")
	await get_tree().create_timer(SequenceStrip.TOAST_HOLD * 0.5).timeout
	s.flash("CLEARED SLOT 2")   # a second flash restarts the hold
	await get_tree().create_timer(SequenceStrip.TOAST_HOLD * 0.8).timeout
	_ok(s.toast_text() == "CLEARED SLOT 2", "second flash cut short")
	await get_tree().create_timer(SequenceStrip.TOAST_HOLD + SequenceStrip.TOAST_FADE).timeout
	_ok(s.toast_text() == "", "toast never faded")
	_ok(s._empty.visible, "the empty-lane hint did not come back after the toast")
	_ok(s._toast.mouse_filter == Control.MOUSE_FILTER_IGNORE, "faded toast still takes touches")
	s.flash("SAVED SLOT 3")
	await get_tree().process_frame
	_ok(s._toast.mouse_filter == Control.MOUSE_FILTER_STOP, "showing toast ignores a tap")
	var tap := InputEventScreenTouch.new()
	tap.pressed = true
	s._toast.gui_input.emit(tap)
	_ok(s.toast_text() != "", "the toast went on the PRESS — its release falls through to a slot")
	var up := InputEventScreenTouch.new()
	up.pressed = false
	s._toast.gui_input.emit(up)
	await get_tree().process_frame
	_ok(s.toast_text() == "" and s._toast.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"a tap did not dismiss the toast")
	# A press INSIDE the showing toast, delivered to the strip (what the 9a did):
	# it dismisses the toast and selects nothing.
	var seq0 := Sequence.new()
	var ids0: Array[String] = ["a", "b", "c", "d", "e", "f", "g", "h"]
	seq0.entries = ids0
	s.set_model(seq0)
	var got0 := [-1]
	var cb0 := func(i: int) -> void: got0[0] = i
	s.slot_selected.connect(cb0)
	s.flash("SAVED SLOT 2 · S42_LONG_SEQUENCE_NAME_X")
	await get_tree().process_frame
	await get_tree().process_frame
	var tr := Rect2(s._toast.global_position - s.global_position, s._toast.size)
	var inside := Vector2(tr.position.x + 40.0, tr.get_center().y)   # on a slot, not a gap
	_ok(s._index_at(inside) >= 0, "test setup: no slot under the toast centre %s (ids %d)" % [tr, s._ids.size()])
	s._press(inside, true)
	s._press(inside, false)
	_ok(got0[0] == -1, "a tap on the toast reached slot %d under it" % (got0[0] + 1))
	_ok(s.toast_text() == "", "a tap on the toast (through the strip) did not dismiss it")
	s._press(inside, true)   # toast gone: the same spot is a slot again
	s._press(inside, false)
	_ok(got0[0] == s._index_at(inside), "with the toast gone, the slot under it did not take the tap")
	s.slot_selected.disconnect(cb0)
	# A release whose press went elsewhere (the toast) must not select a slot.
	var seq := Sequence.new()
	var ids: Array[String] = ["a", "b", "c", "d", "e"]
	seq.entries = ids
	s.set_model(seq)
	var picked := [-1]
	s.slot_selected.connect(func(i: int) -> void: picked[0] = i)
	var at := Vector2(SequenceStrip.PAD + (SequenceStrip.SLOT_W + SequenceStrip.GAP) * 3.0 + 20.0,
		SequenceStrip.TITLE_H + 30.0)
	s._press(at, true)
	s._press(at, false)
	_ok(picked[0] == 3, "a real tap on slot 4 selected %d" % picked[0])
	picked[0] = -1
	s._press(at, false)   # a stray release: no press of its own
	_ok(picked[0] == -1, "a stray release selected slot %d" % (picked[0] + 1))
	s.queue_free()


func _check_picker() -> void:
	for w: float in [1404.0, 1152.0]:
		await _check_picker_at(w)


func _check_picker_at(w: float) -> void:
	var layer := Control.new()
	layer.size = Vector2(w, 648)
	add_child(layer)
	var rows := [
		{"text": "1   WARMUP · 12 CLIPS", "enabled": true},
		{"text": "2   EMPTY", "enabled": false},
		{"text": "3   A VERY LONG SEQUENCE NAME X · 999 CLIPS", "enabled": true},
		{"text": "4   EMPTY", "enabled": false},
		{"text": "5   EMPTY", "enabled": false},
		{"text": "▶ 6   S42_LONG_SEQUENCE_NAME_X · 999 CLIPS", "enabled": true, "marked": true}]
	var got := [-1]
	var d := M8Dialog.pick(layer, "LOAD INTO LANE A", rows, func(i: int) -> void: got[0] = i)
	await get_tree().process_frame
	await get_tree().process_frame
	var bs := d.rows()
	_ok(bs.size() == 6, "picker has %d rows" % bs.size())
	for i: int in bs.size():
		_ok(bs[i].size.y >= 76.0, "row %d is %.0f px tall" % [i + 1, bs[i].size.y])
		var f := bs[i].get_theme_font("font")
		var need := f.get_string_size(bs[i].text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			bs[i].get_theme_font_size("font_size")).x + 24.0
		_ok(i == 2 or w < 1400.0 or bs[i].size.x >= need, "row %d cuts \"%s\" (%.0f < %.0f)" % [i + 1, bs[i].text, bs[i].size.x, need])
		_ok(bs[i].disabled == not bool(rows[i]["enabled"]), "row %d enabled state" % (i + 1))
		_ok(Rect2(Vector2.ZERO, layer.size).encloses(Rect2(bs[i].global_position, bs[i].size)),
			"row %d leaves the screen" % (i + 1))
	var marked := bs[5].get_theme_stylebox("normal") as StyleBoxFlat
	_ok(marked != null and marked.border_width_left == 2, "armed row is not marked")
	_ok((bs[0].get_theme_stylebox("normal") as StyleBoxFlat).border_width_left == 1, "an unarmed row is marked")
	bs[2].pressed.emit()
	await get_tree().process_frame
	_ok(got[0] == 2, "tapping row 3 picked %d" % got[0])
	_ok(not is_instance_valid(d) or d.is_queued_for_deletion(), "picker stayed open after a pick")
	layer.queue_free()
