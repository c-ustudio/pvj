class_name M8Dialog
extends Control
## M8-styled modal confirm / error box.
##
## Replaces Godot's ConfirmationDialog + AcceptDialog, which render as native OS
## window-manager dialogs (rounded grey chrome, system fonts, an OS title bar) —
## completely off-aesthetic and, on the phone, sized for a desktop.
##
## This is a plain full-rect Control drawn INSIDE the app: a black scrim over the
## live view plus a sharp-cornered black box with a thin green border. It is
## therefore themed by the same global Theme as everything else, uses Departure
## Mono, and cannot be styled inconsistently by the platform.
##
## Usage (both are one-liners, parented to any node in the UI layer):
##   M8Dialog.confirm(self, "DELETE CLIP", "REMOVE name.mp4 FROM THE DEVICE?",
##       "DELETE", func(): _do_delete())
##   M8Dialog.error(self, "DOWNLOAD FAILED", "TIMED OUT", func(): _retry())

## Every live dialog joins this group, so Android BACK can find the topmost one
## WHEREVER it is parented — the deck's _chrome_layer, the mask editor, the clip
## browser. Without the group, pipeline.gd would have to know all three.
const GROUP := "m8_dialog"

const M8_GREEN := Color(0.0, 1.0, 0.255)          ## #00FF41
const M8_RED := Color(1.0, 0.267, 0.133)          ## #FF4422 — errors only
const M8_TEXT := Color(0.929, 0.929, 0.929)
const M8_LABEL := Color(0.929, 0.929, 0.929, 0.42)

signal confirmed
signal cancelled
signal submitted(text: String)   ## prompt() only — carries the field's contents
signal picked(index: int)        ## pick() only — the row that was tapped


## An M8 confirm box. `accent` tints the title + confirm button (green normally,
## red for a destructive/error action). Returns the dialog so callers can await
## its signals if they prefer that over the callback.
static func confirm(parent: Node, title: String, body: String, accept_text: String,
		on_accept: Callable, accent: Color = M8_GREEN, cancel_text: String = "CANCEL") -> M8Dialog:
	var d := M8Dialog.new()
	parent.add_child(d)
	d._build(title, body, accept_text, cancel_text, accent, false)
	if on_accept.is_valid():
		d.confirmed.connect(on_accept)
	return d


## An M8 note: title, body, one OK. Green; nothing to decide. The help cards.
static func note(parent: Node, title: String, body: String, ok_text: String = "OK") -> M8Dialog:
	var d := M8Dialog.new()
	parent.add_child(d)
	d._build(title, body, ok_text, "", M8_GREEN, false)
	d._hide_cancel()
	return d


## An M8 error box: red dot + uppercase message + a RETRY button (see item 14).
## `on_retry` is optional — pass an invalid Callable for a dismiss-only notice.
static func error(parent: Node, title: String, body: String,
		on_retry: Callable = Callable()) -> M8Dialog:
	var d := M8Dialog.new()
	parent.add_child(d)
	d._build(title, body, "RETRY", "DISMISS", M8_RED, true)
	if on_retry.is_valid():
		d.confirmed.connect(on_retry)
	else:
		d._hide_accept()
	return d


## An M8 prompt box: the confirm layout plus a single-line NUMERIC field. `on_submit`
## receives the raw text — the CALLER validates, because only it knows the units and
## the legal range. Cancel just closes, so backing out never commits a value.
##
##   M8Dialog.prompt(self, "SET BPM", "TEMPO IN BPM (40-300).", "120", "SET",
##       func(t: String): _apply_bpm_text(t))
##
## `extras`/`on_extra` add optional buttons at the LEFT of the row, for actions that
## FILL THE FIELD rather than close the box (BPM's per-algorithm DETECT buttons). The
## callback receives (dialog, label) so one handler can serve several buttons; it gets
## the dialog back so it can write into the field and the body — see set_field() and
## set_body(). Both are defaulted, so every existing caller is unaffected.
static func prompt(parent: Node, title: String, body: String, initial: String,
		accept_text: String, on_submit: Callable, accent: Color = M8_GREEN,
		extras: PackedStringArray = PackedStringArray(),
		on_extra: Callable = Callable()) -> M8Dialog:
	var d := M8Dialog.new()
	parent.add_child(d)
	d._extras = extras
	d._on_extra = on_extra
	d._build(title, body, accept_text, "CANCEL", accent, false, true, initial)
	if on_submit.is_valid():
		d.submitted.connect(on_submit)
	return d


## An M8 picker: a title and a grid of large rows (≥ 48 dp once scaled — 76
## logical px, like the prompt's field). `rows` is an Array of {text, enabled,
## marked}; a disabled row is drawn dim and ignores taps, a marked one (the
## current choice) is filled with a tint of the accent and keeps a 2 px edge
## (the caller puts a ▶ in its text — a suffix would be the first thing an
## ellipsis cuts). Tapping a row closes the box and
## calls `on_pick(index)`; tap-outside and Android BACK just close it (dismiss).
## The sequence strip's LOAD uses this to list the six saved slots. `body`
## (optional) is a line of text under the title, like confirm()'s.
static func pick(parent: Node, title: String, rows: Array, on_pick: Callable,
		accent: Color = M8_GREEN, columns: int = 2, body: String = "") -> M8Dialog:
	var d := M8Dialog.new()
	parent.add_child(d)
	var col := d._frame(accent)
	var title_lbl := Label.new()
	title_lbl.text = title.to_upper()
	title_lbl.add_theme_font_size_override("font_size", 24)
	title_lbl.add_theme_color_override("font_color", accent)
	col.add_child(title_lbl)
	d._title_lbl = title_lbl
	if body != "":
		var body_lbl := Label.new()
		body_lbl.text = body.to_upper()
		body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body_lbl.custom_minimum_size = Vector2(700, 0)
		body_lbl.add_theme_font_size_override("font_size", 20)
		body_lbl.add_theme_color_override("font_color", M8_TEXT)
		col.add_child(body_lbl)
		d._body_lbl = body_lbl
	var grid := GridContainer.new()
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	# More rows than the screen holds (a long DETAILS list, a library with many
	# folders): the grid scrolls inside the box instead of running off the screen.
	var host_c := parent as Control
	var vh := host_c.size.y if host_c != null and host_c.size.y > 0.0 else d.get_viewport_rect().size.y
	var lines := ceili(float(rows.size()) / float(columns))
	var avail := vh - 64.0 - 64.0 - 48.0 - (110.0 if body != "" else 0.0)
	var scrolls := lines * 90.0 > avail and avail > 90.0
	if scrolls:
		var sc := ScrollContainer.new()
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		sc.custom_minimum_size = Vector2(0, avail)
		sc.add_child(grid)
		col.add_child(sc)
	else:
		col.add_child(grid)
	# Two columns of 560 px fit the Pixels (≥1404 logical); a 16:9 phone (1152)
	# gets narrower rows and an ellipsis rather than a box off the screen.
	var host := parent as Control
	var vw := host.size.x if host != null and host.size.x > 0.0 else d.get_viewport_rect().size.x
	# One column (the storage panel, DETAILS) may use the width two would.
	var row_w := clampf((vw - 64.0 - 60.0 - 14.0 * float(columns - 1)) / float(columns), 380.0,
		560.0 if columns > 1 else 1134.0)
	for i: int in rows.size():
		var r: Dictionary = rows[i]
		var idx := i
		var on := bool(r.get("enabled", true))
		var b := d._button(str(r.get("text", "")), accent if on else M8_LABEL,
			func() -> void:
				d.picked.emit(idx)
				d.queue_free())
		b.custom_minimum_size = Vector2(row_w, 76)   # at 560: "▶ 6   <24-char name> · 999 CLIPS"
		if scrolls:
			# PASS, not STOP: a drag that starts on a row must reach the
			# ScrollContainer, or the list only scrolls by its thin bar (Pixel 8).
			b.mouse_filter = Control.MOUSE_FILTER_PASS
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.clip_text = true
		b.disabled = not on
		b.add_theme_color_override("font_disabled_color", M8_LABEL)
		b.add_theme_stylebox_override("disabled", d._btn_box(Color(0, 0, 0, 0), M8_LABEL, 0.35))
		if bool(r.get("marked", false)):
			var sb := d._btn_box(Color(accent.r, accent.g, accent.b, 0.18), accent, 1.0)
			sb.set_border_width_all(2)
			for st: String in ["normal", "hover", "disabled"]:
				b.add_theme_stylebox_override(st, sb)
		grid.add_child(b)
		d._rows.append(b)
	if on_pick.is_valid():
		d.picked.connect(on_pick)
	return d


## The picker's row buttons, in order (the verifiers press them).
func rows() -> Array[Button]:
	return _rows


## Dismiss = CANCEL. Tap-outside and Android BACK both come through here, so the
## two escape hatches cannot drift apart — and neither one can ever commit. On a
## prompt that means no value is set; on a confirm it means nothing is deleted.
func dismiss() -> void:
	cancelled.emit()
	queue_free()


## Write a value into the prompt's field (and select it, so typing replaces).
func set_field(text: String) -> void:
	if _field != null:
		_field.text = text
		_field.select_all()


## Swap the prompt's soft keyboard. The default numeric pad suits BPM and an
## IP, but has no ':' — a value like "ip:port" needs KEYBOARD_TYPE_URL (Gboard's
## numeric pad silently DROPS letters and ':'; found on the Pixel 8, SESSION_45).
func set_keyboard(kind: LineEdit.VirtualKeyboardType) -> void:
	if _field != null:
		_field.virtual_keyboard_type = kind


## Replace the body line — used to report the result of an in-dialog action.
func set_body(text: String) -> void:
	if _body_lbl != null:
		_body_lbl.text = text.to_upper()


var _accept_btn: Button
var _cancel_btn: Button
var _field: LineEdit       ## prompt() only; null for confirm/error
var _body_lbl: Label
var _title_lbl: Label      ## for the verifiers, which read which box came up
var _extras: PackedStringArray = PackedStringArray()
var _on_extra: Callable = Callable()
var _rows: Array[Button] = []   ## pick() only


# `with_field`/`field_initial` are DEFAULTED so confirm() and error() — and every
# existing call site — keep their exact signature and behaviour.
func _build(title: String, body: String, accept_text: String, cancel_text: String,
		accent: Color, is_error: bool, with_field: bool = false,
		field_initial: String = "") -> void:
	var col := _frame(accent)
	_build_body(col, title, body, accept_text, cancel_text, accent, is_error, with_field, field_initial)


## The modal shell every box shares: scrim (tap-outside = dismiss), the centred
## black box with the accent border. Returns the column the content goes in.
func _frame(accent: Color) -> VBoxContainer:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # modal: swallow taps behind it
	z_index = 100
	add_to_group(GROUP)   # so Android BACK can find this box — see GROUP

	# Scrim — near-opaque black, so the dialog is unmistakably modal.
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.88)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	# Tap-outside cancels. This is the ESCAPE HATCH for the case where the IME is up
	# over the button row. It used to be the ONLY one: Android BACK was a quit request
	# and closed the whole app, which mid-set is a hard stop. BACK now dismisses this
	# box instead (S24 §3) and lands on the very same call — cancel is always the safe
	# action, which is what makes it right for confirm/error boxes too.
	scrim.gui_input.connect(func(e: InputEvent) -> void:
		var tap := e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed
		var click := e is InputEventMouseButton and (e as InputEventMouseButton).pressed
		if tap or click:
			dismiss())
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(760, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)          # pure black
	sb.set_corner_radius_all(0)              # sharp corners
	sb.border_color = accent
	sb.set_border_width_all(1)
	sb.set_content_margin_all(32)
	box.add_theme_stylebox_override("panel", sb)
	center.add_child(box)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 22)
	box.add_child(col)
	return col


func _build_body(col: VBoxContainer, title: String, body: String, accept_text: String,
		cancel_text: String, accent: Color, is_error: bool, with_field: bool,
		field_initial: String) -> void:
	# Title row: for an error, a solid red DOT precedes the title.
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 14)
	if is_error:
		title_row.add_child(_dot(M8_RED))
	var title_lbl := Label.new()
	title_lbl.text = title.to_upper()
	title_lbl.add_theme_font_size_override("font_size", 24)
	title_lbl.add_theme_color_override("font_color", accent)
	title_row.add_child(title_lbl)
	_title_lbl = title_lbl
	col.add_child(title_row)

	var body_lbl := Label.new()
	_body_lbl = body_lbl
	body_lbl.text = body.to_upper()
	body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_lbl.custom_minimum_size = Vector2(700, 0)
	body_lbl.add_theme_font_size_override("font_size", 20)
	body_lbl.add_theme_color_override("font_color", M8_TEXT)
	col.add_child(body_lbl)

	if with_field:
		_field = LineEdit.new()
		_field.text = field_initial
		_field.custom_minimum_size = Vector2(260, 76)
		_field.add_theme_font_size_override("font_size", 28)
		_field.alignment = HORIZONTAL_ALIGNMENT_CENTER
		# Numeric pad rather than full QWERTY — the warp editor's NUM fields do the
		# same. Without it Android raises a letter keyboard for a number.
		_field.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
		# The IME's Done key commits, so the value can be entered without reaching
		# past the keyboard for the accept button.
		_field.text_submitted.connect(func(_t: String) -> void: _accept())
		# ⚠️ DO NOT GRAB FOCUS HERE. Auto-focusing raised the Android IME the instant
		# the dialog opened, and the keyboard covers roughly the bottom 60% of a
		# landscape phone — which BURIED THE ENTIRE BUTTON ROW. DETECT, CANCEL and SET
		# were all unreachable, so the dialog could only be escaped through the IME's
		# own Done key. Opening with the keyboard DOWN keeps every button pressable;
		# tapping the field is what raises it, which is also when it is actually wanted.
		#
		# select_all moves to focus_entered so typing still REPLACES the current value
		# rather than appending — "120" with the caret at the end would become "120130".
		_field.focus_entered.connect(_field.select_all)
		col.add_child(_field)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 16)
	btns.alignment = BoxContainer.ALIGNMENT_END
	# ⚠️ Extra buttons do NOT close the dialog — they act INTO it (fill the field) and
	# hand back `self` so the caller can also update the body text. Closing here would
	# defeat the point: the performer must still see the value and choose to accept it.
	if _on_extra.is_valid():
		var me := self
		for label: String in _extras:
			var lbl := label
			btns.add_child(_button(lbl, accent, func(): _on_extra.call(me, lbl)))
	_cancel_btn = _button(cancel_text, M8_LABEL, func(): cancelled.emit(); queue_free())
	btns.add_child(_cancel_btn)
	_accept_btn = _button(accept_text, accent, _accept)
	btns.add_child(_accept_btn)
	col.add_child(btns)


# One accept path for both the button and the field's Done key, so they cannot
# diverge. A prompt reports its text; confirm/error keep emitting `confirmed`.
func _accept() -> void:
	if _field != null:
		submitted.emit(_field.text)
	else:
		confirmed.emit()
	queue_free()


func _hide_accept() -> void:
	if _accept_btn != null:
		_accept_btn.visible = false


func _hide_cancel() -> void:
	if _cancel_btn != null:
		_cancel_btn.visible = false


# A small filled square — the M8 "status dot".
func _dot(col: Color) -> Control:
	var c := ColorRect.new()
	c.color = col
	c.custom_minimum_size = Vector2(16, 16)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return c


func _button(text: String, col: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text.to_upper()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(190, 74)
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", col)
	b.add_theme_color_override("font_pressed_color", Color(0, 0, 0))
	b.add_theme_stylebox_override("normal", _btn_box(Color(0, 0, 0, 0), col, 0.8))
	b.add_theme_stylebox_override("hover", _btn_box(Color(col.r, col.g, col.b, 0.12), col, 1.0))
	b.add_theme_stylebox_override("pressed", _btn_box(col, col, 1.0))
	b.pressed.connect(on_press)
	return b


func _btn_box(bg: Color, border: Color, border_a: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(12)
	sb.border_color = Color(border.r, border.g, border.b, border_a)
	sb.set_border_width_all(1)
	return sb
