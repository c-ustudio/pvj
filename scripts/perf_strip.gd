class_name PerfStrip
extends Control
## PerfStrip — the gig surface of Performance Mode (SEQUENCER_2_SPEC §3.6).
##
##   [A1..A6] ─── XFADE ─── [B1..B6] · [P] [T]
##
## PERF hides every piece of chrome; this is the one strip that stays: a pattern
## slot bank per lane (one tap, bar-quantized), the crossfader, and the two slot
## levels (P = the peer phone's layer, T = TD's). It lives on the UI layer, never
## in OutputWorld, and pipeline hides it in MIRROR, where the phone screen IS the
## projector. Three-finger tap still exits: pipeline reads that gesture in _input,
## ahead of GUI picking, so nothing here can swallow it.
##
## A VIEW with signals, like SequenceStrip: it owns no state pipeline cannot
## re-push. Call setup() AFTER add_child (hazard 2).

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

signal slot_pressed(lane: int, slot: int)                    ## lane 0 = A, 1 = B; slot 1..SLOT_COUNT
signal xfade_moved(value: float)                             ## a hand on the fader — demotes automation
signal level_moved(which: int, value: float, final: bool)    ## which 0 = P, 1 = T; final = finger lifted / tap

const SLOT_COUNT := 6
const STRIP_H := 104.0
const PAD := 12.0
const GAP := 6.0
const SLOT_W := 62.0
const MINI_W := 100.0
const XFADE_MIN_W := 140.0
const FLASH_SEC := 1.6

const GREEN := M8Palette.GREEN
## Lane B. ⚠️ Unlike ClipGrid and SequenceStrip, this strip shows BOTH lanes at
## once, so there is no "armed lane" for chrome to follow — everything here is
## IDENTITY. The A row is green and the B row is amber, side by side, always.
const AMBER := M8Palette.AMBER
const TEXT := M8Palette.TEXT
const LABEL := M8Palette.LABEL
const LINE := M8Palette.LINE
const BLACK := M8Palette.BLACK

var _font: Font = null
var _slot_btns: Array = [[], []]              ## [lane][slot - 1] -> Button
var _slot_exists: Array[bool] = []
var _slot_labels := PackedStringArray()
var _active := [-1, -1]                       ## slot number each lane last loaded; -1 = unknown
var _pending := [-1, -1]                      ## asked for, lands on the next bar
var _xfade: HSlider
var _xfade_dragging := false
var _level_sliders: Array[HSlider] = []
var _level_caps: Array[Label] = []
var _level_dragging := [false, false]
var _lane_b_cap: Label
var _captions: Array[Label] = []
var _status: Label
var _status_t := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(0, STRIP_H)
	# Taps landing BETWEEN controls must stop here, not fall through to whatever
	# editor sits under the preview.
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(false)

	var bg := ColorRect.new()
	bg.color = Color(BLACK, 0.88)   # the output stays faintly visible behind it
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var rule := ColorRect.new()
	rule.color = LINE
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	rule.offset_bottom = 1.0
	add_child(rule)

	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = PAD
	row.offset_right = -PAD
	row.offset_top = PAD
	row.offset_bottom = -PAD
	row.add_theme_constant_override("separation", int(GAP))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)

	row.add_child(_caption("A", GREEN))
	for i in SLOT_COUNT:
		row.add_child(_make_slot(0, i + 1))
	row.add_child(_spacer(GAP * 2.0))
	row.add_child(_make_xfade())
	row.add_child(_spacer(GAP * 2.0))
	_lane_b_cap = _caption("B", AMBER)
	row.add_child(_lane_b_cap)
	for i in SLOT_COUNT:
		row.add_child(_make_slot(1, i + 1))
	row.add_child(_spacer(GAP * 2.0))
	row.add_child(_make_level(0))
	row.add_child(_make_level(1))

	# The strip's own flash: the status bar is chrome, and chrome is hidden in
	# PERF — an "EMPTY" or "@ BAR" that nobody can see reads as a dead button.
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", GREEN)
	_status.add_theme_color_override("font_outline_color", BLACK)
	_status.add_theme_constant_override("outline_size", 6)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.position = Vector2(PAD, -22.0)   # just above the strip, over the output
	_status.visible = false
	add_child(_status)
	_restyle_slots()


func setup(font: Font) -> void:
	_font = font
	if _font == null:
		return
	for l: Label in _captions:
		l.add_theme_font_override("font", _font)
	_status.add_theme_font_override("font", _font)
	for lane in 2:
		for b: Button in _slot_btns[lane]:
			b.add_theme_font_override("font", _font)


# --- Pipeline -> view ------------------------------------------------------

## labels[i] = slot i+1's saved label ("" = unlabeled); exists[i] = a file is
## there. The bank is SHARED: A3 and B3 are the same saved pattern, loaded into
## a different lane.
func set_slots(labels: PackedStringArray, exists: Array[bool]) -> void:
	_slot_labels = labels
	_slot_exists = exists
	_restyle_slots()


func set_active_slot(lane: int, slot: int) -> void:
	_active[lane] = slot
	if _pending[lane] == slot:
		_pending[lane] = -1
	_restyle_slots()


func set_pending_slot(lane: int, slot: int) -> void:
	_pending[lane] = slot
	_restyle_slots()
	set_process(true)


## Lane B's row and the crossfader only mean something while lane B is armed.
## badge "NET"/"TD" says the B row commands a REMOTE instrument, not deck B.
func set_lane_b(armed: bool, badge: String) -> void:
	_lane_b_cap.text = "B·%s" % badge if badge != "" else "B"
	for b: Button in _slot_btns[1]:
		b.modulate.a = 1.0 if armed else 0.35
	_xfade.modulate.a = 1.0 if armed else 0.35


## Automation moves the crossfade too; the strip follows it. Ignored mid-drag so
## the echo of the finger's own write never fights the finger.
func set_xfade(v: float) -> void:
	if _xfade_dragging:
		return
	if absf(_xfade.value - v) > 0.002:
		_xfade.set_value_no_signal(v)


## The two slot levels, pushed on every provider or level change. name "" =
## nobody streaming into that slot: the fader greys out rather than moving a
## level nobody is showing.
func set_levels(p_name: String, p_level: float, t_name: String, t_level: float) -> void:
	_apply_level(0, p_name, p_level)
	_apply_level(1, t_name, t_level)


func flash(text: String) -> void:
	_status.text = text
	_status.visible = true
	_status_t = FLASH_SEC
	set_process(true)


# --- Build -----------------------------------------------------------------

func _make_slot(lane: int, slot: int) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(SLOT_W, 0)
	b.size_flags_vertical = Control.SIZE_EXPAND_FILL
	b.clip_text = true
	b.add_theme_font_size_override("font_size", 15)
	b.text = str(slot)
	b.pressed.connect(func() -> void: slot_pressed.emit(lane, slot))
	_slot_btns[lane].append(b)
	return b


func _make_xfade() -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.custom_minimum_size = Vector2(XFADE_MIN_W, 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	box.add_child(_caption("A · XFADE · B"))
	_xfade = HSlider.new()
	_xfade.min_value = 0.0
	_xfade.max_value = 1.0
	_xfade.step = 0.001
	_xfade.focus_mode = Control.FOCUS_NONE
	# DRAGGABLE on purpose: a performance control, like the FX intensity fader.
	# The panel's drag-immune sliders are tunables (see _add_slider_row); nothing
	# scrolls under this one, so a finger on it always means "move the fade".
	_xfade.mouse_filter = Control.MOUSE_FILTER_STOP
	_xfade.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_xfade.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style_fader(_xfade, AMBER, TEXT)   # fill = deck B's share of the mix
	_xfade.drag_started.connect(func() -> void: _xfade_dragging = true)
	_xfade.drag_ended.connect(func(_changed: bool) -> void: _xfade_dragging = false)
	_xfade.value_changed.connect(func(v: float) -> void: xfade_moved.emit(v))
	box.add_child(_xfade)
	return box


func _make_level(which: int) -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(MINI_W, 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# P and T are link slots (peer phone, TD). Built either way so set_levels'
	# indices hold, but never shown where there is no link (public build).
	box.visible = FeaturesS.is_pro()
	box.add_theme_constant_override("separation", 2)
	var cap := _caption("P" if which == 0 else "T")
	cap.clip_text = true
	box.add_child(cap)
	_level_caps.append(cap)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.01
	s.focus_mode = Control.FOCUS_NONE
	s.mouse_filter = Control.MOUSE_FILTER_STOP
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style_fader(s)
	s.editable = false   # nothing streaming into that slot yet
	s.modulate.a = 0.35
	s.drag_started.connect(func() -> void: _level_dragging[which] = true)
	s.drag_ended.connect(func(_changed: bool) -> void:
		_level_dragging[which] = false
		level_moved.emit(which, s.value, true))
	# final=false while dragging: pipeline moves the layer live but logs and
	# persists once, on release — a drag is dozens of writes.
	s.value_changed.connect(func(v: float) -> void:
		level_moved.emit(which, v, not _level_dragging[which]))
	box.add_child(s)
	_level_sliders.append(s)
	return box


## A performance fader has to be FOUND by a thumb in the dark: the default theme's
## hairline track and tiny grabber read as decoration on a black strip over
## moving video (first device look, 9a). Thick track, a lit fill, and a tall
## grabber.
##
## fill_hue carries MEANING on the crossfader: its fill grows from A's end toward
## B's, so filling it AMBER makes the fader report how much deck B is in the mix
## rather than merely decorating. grab_hue stays TEXT there — the crossfader
## belongs to neither deck and must be findable at both ends. The P/T level
## faders keep green: peer and TD are not decks.
func _style_fader(s: HSlider, fill_hue: Color = GREEN, grab_hue: Color = GREEN) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(TEXT, 0.10)
	track.border_color = LINE
	track.set_border_width_all(1)
	track.content_margin_top = 9.0
	track.content_margin_bottom = 9.0
	s.add_theme_stylebox_override("slider", track)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(fill_hue, 0.45)
	fill.content_margin_top = 9.0
	fill.content_margin_bottom = 9.0
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	var img := Image.create(16, 44, false, Image.FORMAT_RGBA8)
	img.fill(grab_hue)
	var tex := ImageTexture.create_from_image(img)
	s.add_theme_icon_override("grabber", tex)
	s.add_theme_icon_override("grabber_highlight", tex)
	var dim := Image.create(16, 44, false, Image.FORMAT_RGBA8)
	dim.fill(Color(TEXT, 0.35))
	s.add_theme_icon_override("grabber_disabled", ImageTexture.create_from_image(dim))


## col defaults to LABEL — the neutral captions ("A · XFADE · B", "P", "T") name
## controls that belong to no deck. The two LANE captions pass their deck's hue.
func _caption(text: String, col: Color = LABEL) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", col)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_captions.append(l)
	return l


func _spacer(w: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, 0)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# --- View state ------------------------------------------------------------

func _apply_level(which: int, peer_name: String, level: float) -> void:
	var s: HSlider = _level_sliders[which]
	s.editable = peer_name != ""
	s.modulate.a = 1.0 if s.editable else 0.35
	var cap: Label = _level_caps[which]
	cap.text = ("P" if which == 0 else "T") + (" · %s" % peer_name.to_upper() if peer_name != "" else "")
	if not _level_dragging[which]:
		s.set_value_no_signal(level)


## active = the pattern that lane last loaded; pending = asked for, lands on the
## next bar; empty = no saved file (dim, still tappable so the flash can say so).
func _restyle_slots() -> void:
	for lane in 2:
		for i in SLOT_COUNT:
			var b: Button = _slot_btns[lane][i]
			var slot := i + 1
			var empty := i >= _slot_exists.size() or not _slot_exists[i]
			var active: bool = _active[lane] == slot
			var pending: bool = _pending[lane] == slot
			# ⚠️ The LANE's hue, not an armed lane's — both banks light at once.
			_style_slot(b, active, pending, empty, AMBER if lane == 1 else GREEN)
			var lbl: String = _slot_labels[i] if i < _slot_labels.size() else ""
			b.text = "%d\n%s" % [slot, lbl.substr(0, 6).to_upper()] if lbl != "" else str(slot)


## hue = the LANE's colour, not the armed lane's: both banks are on screen
## together, so A lights green and B lights amber at the same time.
func _style_slot(b: Button, active: bool, pending: bool, empty: bool,
		hue: Color = GREEN) -> void:
	var lit := active or pending
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(hue, 0.20) if active else BLACK
	sb.set_corner_radius_all(0)
	sb.set_border_width_all(2 if lit else 1)
	sb.border_color = hue if lit else LINE
	sb.set_content_margin_all(4)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(state, sb)
	var fg: Color = LABEL if empty else (hue if lit else TEXT)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(state, fg)


func _process(delta: float) -> void:
	var busy := false
	if _status_t > 0.0:
		_status_t -= delta
		if _status_t <= 0.0:
			_status.visible = false
		else:
			busy = true
	# A pending slot breathes until its bar lands (set_active_slot clears it).
	var pulse := 0.55 + 0.45 * sin(float(Time.get_ticks_msec()) / 110.0)
	for lane in 2:
		for i in SLOT_COUNT:
			var b: Button = _slot_btns[lane][i]
			if _pending[lane] == i + 1:
				b.self_modulate.a = pulse
				busy = true
			elif b.self_modulate.a != 1.0:
				b.self_modulate.a = 1.0
	if not busy:
		set_process(false)
