class_name Sequence
extends Resource
## Sequence — the ordered list of clip ids a deck plays through (sequencer Step 5).
##
## Pure model: an array of ClipLibrary ids (duplicates allowed — a set can repeat
## a clip). SequenceStrip renders it; the Deck/pipeline mutates it and jumps the
## engine. Serializable (@export) so SessionStore can save a set to disk later.
##
## Every mutation emits Resource's built-in `changed`; the view rebuilds from the
## model on that signal (never per drag-frame — see SequenceStrip + Architecture
## §7 risk 6). We reuse Resource.changed rather than declaring our own.

@export var entries: Array[String] = []
@export var label: String = ""       ## optional short name for a saved slot (Session 12)


func size() -> int:
	return entries.size()


func is_empty() -> bool:
	return entries.is_empty()


func get_id(index: int) -> String:
	return entries[index] if index >= 0 and index < entries.size() else ""


func append(clip_id: String) -> void:
	entries.append(clip_id)
	emit_changed()


## Insert at `index`, clamped to [0, size]. Grid→strip drop lands here (Step 6).
func insert(index: int, clip_id: String) -> void:
	entries.insert(clampi(index, 0, entries.size()), clip_id)
	emit_changed()


## Move the entry at `from` to `to` (post-removal index semantics), clamped.
func move(from: int, to: int) -> void:
	if from < 0 or from >= entries.size():
		return
	var id := entries[from]
	entries.remove_at(from)
	entries.insert(clampi(to, 0, entries.size()), id)
	emit_changed()


func remove_at(index: int) -> void:
	if index < 0 or index >= entries.size():
		return
	entries.remove_at(index)
	emit_changed()


func clear() -> void:
	if entries.is_empty():
		return
	entries.clear()
	emit_changed()


## In-place Fisher–Yates. Returns the id that was at `keep_index` before the
## shuffle (so a caller can re-find the playing clip's new slot), or "" if none.
func shuffle_fisher_yates(keep_index: int = -1) -> String:
	var kept := get_id(keep_index)
	for i: int in range(entries.size() - 1, 0, -1):
		var j := randi() % (i + 1)
		var tmp := entries[i]
		entries[i] = entries[j]
		entries[j] = tmp
	emit_changed()
	return kept


func find_id(clip_id: String, from: int = 0) -> int:
	return entries.find(clip_id, from)


## Serializable snapshot / restore for SessionStore (Step later).
func to_array() -> Array[String]:
	return entries.duplicate()


func from_array(ids: Array[String]) -> void:
	entries = ids.duplicate()
	emit_changed()
