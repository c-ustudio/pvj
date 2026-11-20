class_name OscDeck
extends RefCounted
## /pvj/deck/clip's argument -> the deck's clip index (OSC_NAMESPACE_SPEC.md §3).
## Pure: the pipeline hands over the deck's own clip list (ClipEngine.clips, the
## order CLIP n/N counts) and two lookups, and gets an index for the SAME jump()
## a grid tap makes. Static so tools/verify_osc_deck.gd can prove it without a
## scene.
##
## The argument:
##   i / f  — the clip NUMBER as the status line shows it, 1..N (CLIP 3/31 = 3).
##            1-based like /pvj/seq/slot; 0 or past the end is refused, never
##            wrapped (a desk off by one must not land on a random clip).
##   s      — tried in this order, first hit wins:
##            1. a ClipLibrary id;
##            2. the clip's path under the clips folder ("pack1/loop.mp4");
##            3. the file name ("loop.mp4") — what /pvj/out/clip SENDS, so a desk
##               can echo the feedback straight back and it round-trips;
##            4. the file name without its extension ("loop").
##            2-4 ignore case. Two clips sharing a name in different folders: the
##            first in deck order wins; the folder path (2) picks the other.
## Returns -1 when nothing matches (the caller drops it with one rate-limited log).

static func resolve(arg: Variant, clips: Array[String], rel_of: Callable,
		path_for_id: Callable) -> int:
	if clips.is_empty():
		return -1
	if arg is int or arg is float:
		var n := int(arg)
		return n - 1 if n >= 1 and n <= clips.size() else -1
	if not arg is String:
		return -1
	var key := String(arg).strip_edges()
	if key.is_empty():
		return -1
	if path_for_id.is_valid():
		var p: String = path_for_id.call(key)
		if p != "":
			var i := clips.find(p)
			if i >= 0:
				return i
	var low := key.to_lower()
	if rel_of.is_valid():
		for i in clips.size():
			if String(rel_of.call(clips[i])).to_lower() == low:
				return i
	for i in clips.size():
		if clips[i].get_file().to_lower() == low:
			return i
	for i in clips.size():
		if clips[i].get_file().get_basename().to_lower() == low:
			return i
	return -1
