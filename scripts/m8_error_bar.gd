class_name M8ErrorBar
extends PanelContainer
## Inline M8 error state: [red dot] UPPERCASE MESSAGE            [RETRY]
##
## The browsers used to report failures by dropping a lowercase sentence into the
## bottom status label ("Download failed: timed out"), which looks identical to a
## success message and offers the user no way forward. This is the standard error
## presentation instead: the red status dot, the message in uppercase, and a
## RETRY button wired to whatever action failed.
##
## Attach one per screen (usually just under the toolbar) and drive it with
## show_error() / clear(). It hides itself when there is no error, so it costs
## nothing in the normal case.
##
##   _err = M8ErrorBar.new()
##   vbox.add_child(_err)
##   _err.show_error("DOWNLOAD FAILED - TIMED OUT", func(): _retry())

const M8_RED := Color(1.0, 0.267, 0.133)     ## #FF4422 — errors only
const M8_TEXT := Color(0.929, 0.929, 0.929)

var _dot: ColorRect
var _label: Label
var _retry: Button
var _on_retry: Callable


func _ready() -> void:
	visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(M8_RED.r, M8_RED.g, M8_RED.b, 0.10)   # faint red wash
	sb.set_corner_radius_all(0)
	sb.border_color = M8_RED
	sb.border_width_left = 3                                  # red edge marker
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	add_child(row)

	_dot = ColorRect.new()
	_dot.color = M8_RED
	_dot.custom_minimum_size = Vector2(14, 14)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_dot)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", M8_TEXT)
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(_label)

	_retry = Button.new()
	_retry.text = "RETRY"
	_retry.focus_mode = Control.FOCUS_NONE
	_retry.custom_minimum_size = Vector2(150, 58)
	_retry.add_theme_font_size_override("font_size", 20)
	_retry.add_theme_color_override("font_color", M8_RED)
	_retry.add_theme_color_override("font_hover_color", M8_RED)
	_retry.add_theme_color_override("font_pressed_color", Color(0, 0, 0))
	_retry.add_theme_stylebox_override("normal", _box(Color(0, 0, 0, 0), 0.8))
	_retry.add_theme_stylebox_override("hover", _box(Color(M8_RED.r, M8_RED.g, M8_RED.b, 0.15), 1.0))
	_retry.add_theme_stylebox_override("pressed", _box(M8_RED, 1.0))
	_retry.pressed.connect(_fire_retry)
	row.add_child(_retry)


## Show an error. `message` is uppercased for you. Pass an invalid Callable to
## hide the RETRY button (for errors nothing can be retried on).
func show_error(message: String, on_retry: Callable = Callable()) -> void:
	_on_retry = on_retry
	_label.text = message.to_upper()
	_retry.visible = on_retry.is_valid()
	visible = true


func clear() -> void:
	visible = false
	_on_retry = Callable()


func _fire_retry() -> void:
	var cb := _on_retry
	clear()                       # dismiss first, so a re-failure re-shows cleanly
	if cb.is_valid():
		cb.call()


func _box(bg: Color, border_a: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(10)
	sb.border_color = Color(M8_RED.r, M8_RED.g, M8_RED.b, border_a)
	sb.set_border_width_all(1)
	return sb
