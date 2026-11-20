class_name TouchGestures
extends RefCounted
## Two-finger pinch/pan tracking, plus the single-finger LOCKOUT that is the
## actual reason this exists.
##
## ⚠️ THE LOCKOUT IS THE POINT. Lifting one finger out of a pinch leaves the other
## one down, and the next drag event it produces is a large one-finger delta — so
## whatever the editor does with a one-finger drag (move a vertex, pan the
## content) happens in one jump at the end of every pinch. Tracking `cool` until
## EVERY finger is up is what stops it. It was found and fixed once in the mask
## editor (S15); this class is that fix, extracted, so the second editor to grow a
## pinch does not have to rediscover it.
##
## Coordinates are SCREEN px throughout. The owner converts — both editors have an
## injected output->screen `Transform2D` and only they know which space their
## parameters live in. `pan_delta` is a DELTA, so it must be converted with
## `basis_xform` (no translation), not with the full transform.
##
## Usage:
##     if _g.eats_input(): accept_event(); return          # in _gui_input
##     ...
##     if _g.touch(ev.index, ev.pressed, ev.position):     # in _input, raw
##         _cancel_whatever_drag_was_running()
##     if _g.drag(ev.index, ev.position):
##         apply(_g.zoom_ratio, _g.pan_delta)

## May a gesture begin right now? The owner's precondition (something selected, no
## modal open, not mid-draw). Unset = always allowed.
var can_begin: Callable = Callable()

var touches: Dictionary = {}     ## live fingers: index -> screen pos
var active: bool = false         ## two-finger gesture in progress
## Eat single-finger input until ALL fingers lift. Outlives `active` on purpose.
var cool: bool = false

## Last step's pinch ratio (1.0 = no zoom change) and centroid delta, screen px.
var zoom_ratio: float = 1.0
var pan_delta: Vector2 = Vector2.ZERO

const MIN_SPAN := 8.0            ## floor on finger distance, so the ratio can't blow up

var _span: float = MIN_SPAN
var _centroid: Vector2 = Vector2.ZERO


## True while the owner must not act on single-finger input.
func eats_input() -> bool:
	return active or cool


## Feed a raw touch (press or release). Returns TRUE on the frame a gesture
## begins, which is the owner's cue to abandon any one-finger drag in progress —
## the fingers now mean something else.
func touch(index: int, pressed: bool, pos: Vector2) -> bool:
	if pressed:
		touches[index] = pos
	else:
		touches.erase(index)
	var began := false
	if touches.size() >= 2 and not active and _allowed():
		active = true
		cool = true
		_baseline()
		began = true
	elif touches.size() < 2 and active:
		active = false      # …but `cool` stays set: see the class note
	if touches.is_empty():
		cool = false
	return began


## Feed a raw drag. Returns true when zoom_ratio / pan_delta have been updated.
func drag(index: int, pos: Vector2) -> bool:
	if not active:
		return false
	touches[index] = pos
	var ids := touches.keys()
	if ids.size() < 2:
		return false
	var a: Vector2 = touches[ids[0]]
	var b: Vector2 = touches[ids[1]]
	var span := maxf(MIN_SPAN, a.distance_to(b))
	var c := (a + b) * 0.5
	zoom_ratio = span / _span
	pan_delta = c - _centroid
	_span = span
	_centroid = c
	return true


## Forget everything — for editor open/close, where fingers that were down are no
## longer this editor's business.
func reset() -> void:
	touches.clear()
	active = false
	cool = false
	zoom_ratio = 1.0
	pan_delta = Vector2.ZERO


func _allowed() -> bool:
	return can_begin.call() if can_begin.is_valid() else true


func _baseline() -> void:
	var ids := touches.keys()
	if ids.size() < 2:
		return
	var a: Vector2 = touches[ids[0]]
	var b: Vector2 = touches[ids[1]]
	_span = maxf(MIN_SPAN, a.distance_to(b))
	_centroid = (a + b) * 0.5
	zoom_ratio = 1.0
	pan_delta = Vector2.ZERO
