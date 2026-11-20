class_name M8EditorChrome
extends Control
## Minimal floating chrome shared by the warp and mask editors.
##
## Both editors are full-screen canvases: the deck's nav bar and status bar are
## hidden while they are open, and the only persistent UI is
##   - a small ESC / DONE pill in the TOP-RIGHT corner, and
##   - the editor's own bottom toolbar, which collapses to a thin strip and
##     AUTO-HIDES after IDLE_HIDE_SEC of no touch, reappearing on the next tap.
##
## This Control is full-rect but MOUSE_FILTER_IGNORE, and the pill is only as
## big as its two buttons, so everything outside those two buttons falls through
## to the editor's own _gui_input — dragging a warp corner or placing a mask
## point behind/around the pill still works.
##
## Activity is tracked in _input (not the editor's _gui_input) so that taps which
## land on toolbar BUTTONS also count as activity — those never reach the
## editor's _gui_input, and without this the bar would hide out from under the
## user mid-interaction.

signal esc_pressed
signal done_pressed

const IDLE_HIDE_SEC := 2.0    ## no touch for this long -> hide the toolbar
const FADE_SEC := 0.2

const M8_GREEN := Color(0.0, 1.0, 0.255)
const M8_TEXT := Color(0.929, 0.929, 0.929)

var _toolbar: Control          ## the editor's bottom strip (auto-hidden)
var _extra: Array[Control] = [] ## anything else that hides with the toolbar
var _pill: PanelContainer
var _idle: float = 0.0
var _active: bool = false
var _fade: Tween
var _bottom_centre: bool = false


## `toolbar` is auto-hidden on idle. `extra` hides/shows with it (e.g. the warp
## hint); pass an empty array to keep everything else always visible.
## `toolbar` may be null — then there is no auto-hide strip at all (mask mode
## hides its toolbar outright while drawing). `bottom_centre` puts the pill at
## the bottom middle (mask draw mode) instead of the top-right corner (warp).
func setup(toolbar: Control, extra: Array[Control] = [], bottom_centre: bool = false) -> void:
	_toolbar = toolbar
	_extra = extra
	_bottom_centre = bottom_centre
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # only the pill buttons take input
	_build_pill()
	visible = false
	set_process(false)


func _build_pill() -> void:
	_pill = PanelContainer.new()
	# Anchored so it needs no manual layout pass.
	if _bottom_centre:
		_pill.anchor_left = 0.5
		_pill.anchor_right = 0.5
		_pill.anchor_top = 1.0
		_pill.anchor_bottom = 1.0
		_pill.offset_left = -145.0
		_pill.offset_right = 145.0
		_pill.offset_top = -96.0
		_pill.offset_bottom = -30.0
	else:
		_pill.anchor_left = 1.0
		_pill.anchor_right = 1.0
		_pill.anchor_top = 0.0
		_pill.anchor_bottom = 0.0
		_pill.offset_left = -300.0
		_pill.offset_right = -20.0
		_pill.offset_top = 20.0
		_pill.offset_bottom = 86.0
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE   # gaps fall through to canvas

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)          # black
	sb.set_corner_radius_all(0)              # M8 = sharp
	sb.border_color = M8_GREEN               # green border
	sb.set_border_width_all(1)
	sb.set_content_margin_all(6)
	_pill.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_pill_button("ESC", M8_TEXT, func(): esc_pressed.emit()))
	row.add_child(_pill_button("DONE", M8_GREEN, func(): done_pressed.emit()))
	_pill.add_child(row)
	add_child(_pill)


func _pill_button(text: String, col: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(126, 54)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 18)
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", col)
	b.add_theme_color_override("font_pressed_color", Color(0, 0, 0))
	b.add_theme_stylebox_override("normal", _box(Color(0, 0, 0, 0), col, 0.55))
	b.add_theme_stylebox_override("hover", _box(Color(col.r, col.g, col.b, 0.12), col, 1.0))
	b.add_theme_stylebox_override("pressed", _box(col, col, 1.0))
	b.pressed.connect(on_press)
	return b


func _box(bg: Color, border: Color, a: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(6)
	sb.border_color = Color(border.r, border.g, border.b, a)
	sb.set_border_width_all(1)
	return sb


func set_active(on: bool) -> void:
	_active = on
	visible = on
	set_process(on)
	_idle = 0.0
	# Kill any in-flight fade: a pending tween callback could otherwise flip the
	# strip's visibility AFTER the editor has closed, leaving it over the deck.
	if _fade != null and _fade.is_valid():
		_fade.kill()
	if on and _toolbar != null:
		_set_strip_visible(true, false)   # start shown, then idle out
	elif _toolbar != null:
		_toolbar.modulate.a = 1.0         # leave it clean for the next open


# Any touch anywhere counts as activity: reveal the strip and restart the timer.
func _input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventScreenTouch or event is InputEventScreenDrag \
			or event is InputEventMouseButton:
		notify_activity()


func notify_activity() -> void:
	_idle = 0.0
	if _toolbar != null and not _toolbar.visible:
		_set_strip_visible(true, true)


func _process(delta: float) -> void:
	if not _active or _toolbar == null or not _toolbar.visible:
		return
	_idle += delta
	if _idle >= IDLE_HIDE_SEC:
		_set_strip_visible(false, true)


func _set_strip_visible(v: bool, animate: bool) -> void:
	var targets: Array[Control] = []
	if _toolbar != null:
		targets.append(_toolbar)
	for e in _extra:
		if e != null and is_instance_valid(e):
			targets.append(e)
	if targets.is_empty():
		return
	if _fade != null and _fade.is_valid():
		_fade.kill()
	if not animate:
		for t in targets:
			t.visible = v
			t.modulate.a = 1.0 if v else 0.0
		return
	_fade = create_tween().set_parallel(true)
	for t in targets:
		if v:
			t.visible = true          # visible BEFORE fading in
		_fade.tween_property(t, "modulate:a", 1.0 if v else 0.0, FADE_SEC)
	if not v:
		# Hide only after the fade so the strip stops accepting touches.
		_fade.chain().tween_callback(func() -> void:
			for t in targets:
				if is_instance_valid(t):
					t.visible = false)
