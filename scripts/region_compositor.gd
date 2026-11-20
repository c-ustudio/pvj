class_name RegionCompositor
extends Node2D
## Multi-region mask compositor (Phase 2).
##
## Holds N freehand "mask" regions, drawn into MaskWorld — the pre-warp
## SubViewport whose texture QuadWarp samples while masks own the output
## (S17 / Option A routing). A region samples EITHER the
## shared RAW source (the active clip/camera) OR — when a clip is assigned — its
## OWN GoZen decoder (a private SubViewport + VideoPlayback), so different masks
## can play different videos at once. Each region also has its own effect
## ShaderMaterial and a UV transform (scale + pan) over its source. Everything
## outside a region is left to the black clear color.
##
## Per-mask decoders are the mobile cost driver — decoding several 1080p videos at
## once is heavy — so simultaneous decoders are capped (MAX_DECODERS) and masks
## that share a source stay on the single shared texture.

const StorageS := preload("res://core/storage.gd")   ## static: loads under --script too

const MAX_DECODERS := 6                     ## simultaneous per-mask video decoders (perf cap; measured 2026-10-01 with 720p clips, see the commit)
const DECODER_SIZE := Vector2i(1280, 720)   ## per-mask render target (decode cost is native-res, not this)

## How the source is FITTED into a region before the content transform is applied
## (PER_REGION_WARP_CONTENT_FIT.md §2). The ORDER OF THESE VALUES IS ON-DISK
## FORMAT — `content_fit` is persisted as the int, so new modes append.
##
## Only MANUAL and FULL_FRAME are wired today:
##   MANUAL     — no auto-fit; the source fills the mask's bounding box, which is
##                exactly the behaviour every saved project has always had.
##   FULL_FRAME — the source is fitted to the WHOLE OUTPUT FRAME instead, so a
##                region shows its slice of one shared composition.
## FILL / FIT / STRETCH are the aspect-driven presets of §2 items 4-5 and are
## deliberately NOT built yet (see the spec's TODO); they are reserved here so
## adding them later cannot renumber what is already on disk. Anything not
## FULL_FRAME currently fits to the mask box.
enum ContentFit { MANUAL, FILL, FIT, STRETCH, FULL_FRAME }

signal decoder_limit_hit(limit: int)

var _effects: Array = []               ## effect bank from pipeline: [{name, shader}]
var _source: Texture2D                 ## shared RAW source for un-assigned masks
## each region: {points, effect, poly, mesh_node, clip, scale, offset, warp, vp, player}
## `poly` is the CLIP shape (not drawn); `mesh_node` is the warped drawer under it.
var _regions: Array[Dictionary] = []
## The output basis a region's identity warp spans. OutputWorld is FIXED at
## 1920x1080 (S13), so this default is already the real value; the editor sets
## it explicitly from its own output-size provider before creating regions.
var output_size := Vector2(1920, 1080)
## CHECKER: every region draws a black/white board through its own warp instead
## of its clip (mask_checker.gdshader). A mapping aid, never saved — the mask
## editor's CHECKER cell and the region warp editor's GRID cell set it, and
## closing the mask editor clears it, so it cannot be left on stage.
var checker := false
const CHECKER_CELLS := 8.0                  ## cells along the warp domain's LONGER side
const CHECKER_SHADER := preload("res://shaders/mask_checker.gdshader")
## DECK: every region shows the deck's shared source instead of its own clip.
## The clips (and lists) are kept, so switching back restores every mask as it
## was. Own decoders are PAUSED and their viewports stop rendering meanwhile —
## the switch can only make masks cheaper. Persisted in regions.cfg (and so in
## a mask set) by RegionEditor.
var follow_deck_all := false


func setup(effects: Array) -> void:
	_effects = effects


## Shared source for masks WITHOUT an assigned clip (Phase 1 behaviour). Masks with
## their own decoder are unaffected.
func set_source(tex: Texture2D) -> void:
	_source = tex
	for r in _regions:
		if r["vp"] == null:
			rebuild_mesh(r)


func region_count() -> int:
	return _regions.size()


func has_regions() -> bool:
	return not _regions.is_empty()


func decoder_count() -> int:
	var n := 0
	for r in _regions:
		if r["vp"] != null:
			n += 1
	return n


func add_region(points: PackedVector2Array) -> int:
	# The polygon is no longer the DRAWER — it is the CLIP SHAPE. It masks its
	# children and is not itself drawn (CLIP_CHILDREN_ONLY), so the mask stays a
	# rigid stencil in output space while the warped mesh below bends the content
	# behind it. That order — warp, then mask — is what keeps a silhouette you
	# aligned to a real object's edges from moving when you adjust the warp.
	var poly := Polygon2D.new()
	poly.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	add_child(poly)
	var mesh_node := MeshInstance2D.new()
	mesh_node.mesh = ArrayMesh.new()
	mesh_node.texture = _source
	poly.add_child(mesh_node)
	var domain := _bounds_of(points)
	if domain.size.x <= 0.0 or domain.size.y <= 0.0:
		domain = Rect2(Vector2.ZERO, output_size)
	var r := {
		"points": points, "effect": 0, "poly": poly, "mesh_node": mesh_node,
		"clip": "",
		# The CONTENT TRANSFORM (spec §2). Defaults reproduce the pre-transform
		# fit-to-bounding-box behaviour exactly. scale/offset/rotation were the
		# S15 keys `scale` (float) / `offset` / `angle`; pivot and fit are new.
		"content_scale": Vector2.ONE, "content_offset": Vector2.ZERO,
		"content_rotation": 0.0, "content_pivot": Vector2(0.5, 0.5),
		"content_fit": ContentFit.MANUAL,
		"geo_scale": 1.0, "geo_rot": 0.0,   # cumulative geometry transform (for numeric absolute set)
		"warp": _identity_warp(domain),     # per-region warp (S20), spanning its own domain
		"warp_domain": domain,              # the rect that warp is currently expressed in
		"vp": null, "player": null,
		# MANUAL SEQUENCE: the mask's clip list and which entry plays. Empty =
		# the pre-list behaviour (one fixed clip, or the deck). `clip` stays the
		# clip actually playing, so everything that read it before still works.
		"clips": PackedStringArray(), "clip_pos": 0,
		# The clip keys regions.cfg held for this mask when it was LOADED, kept
		# only while some of them did not resolve (a clip not in PVJ yet). The
		# editor writes them back so a missing clip never erases a mask's list
		# (STORAGE_REWORK_PLAN §E). Not used for drawing.
		"saved_keys": {},
	}
	_regions.append(r)
	_apply_points(r)
	_apply_effect(r)
	return _regions.size() - 1


func remove_region(i: int) -> void:
	if i < 0 or i >= _regions.size():
		return
	_free_decoder(_regions[i])
	var poly: Polygon2D = _regions[i]["poly"]
	poly.queue_free()
	_regions.remove_at(i)


func clear() -> void:
	for r in _regions:
		_free_decoder(r)
		var poly: Polygon2D = r["poly"]
		poly.queue_free()
	_regions.clear()


func get_points(i: int) -> PackedVector2Array:
	if i < 0 or i >= _regions.size():
		return PackedVector2Array()
	return _regions[i]["points"]


func set_points(i: int, points: PackedVector2Array) -> void:
	if i < 0 or i >= _regions.size():
		return
	_regions[i]["points"] = points
	_apply_points(_regions[i])


func get_effect(i: int) -> int:
	if i < 0 or i >= _regions.size():
		return 0
	return _regions[i]["effect"]


func set_effect(i: int, effect_index: int) -> void:
	if i < 0 or i >= _regions.size():
		return
	_regions[i]["effect"] = effect_index
	_apply_effect(_regions[i])


# --- per-region warp (Session 20) ----------------------------------------
# A region is a SURFACE: a shape (this polygon, or later a raster image) plus a
# transform (this warp). The two are orthogonal and stay that way — the mask is
# the silhouette of the physical object, the warp bends CONTENT to sit on it.
#
# The warp is expressed in the region's own DOMAIN (warp_domain below), not in
# frame space, so its handles land on the surface being mapped and the mesh only
# covers the area the mask can actually show.

## ⚠️ THE ONE AUTHORITY on the rect a region's warp is expressed in, and the
## deliberate seam for content-fit (PER_REGION_WARP_CONTENT_FIT.md).
##
## It is always the mask's BOUNDING BOX, which is what puts the warp handles on
## the surface being mapped instead of at the corners of the frame.
##
## ⚠️ CORRECTED — a fit mode does NOT change this rect. An earlier note here said
## FULL_FRAME would return `Rect2(Vector2.ZERO, output_size)`; that was wrong and
## would have moved the warp handles back to the frame corners as a side effect of
## a content decision. The fit mode swaps the rect the SOURCE is normalized
## against (`_fit_rect`), and this domain is deliberately the STABLE reference
## both of them are expressed relative to — which is what stops the content
## jumping on a mode toggle (spec §2 item 2).
##
## Identity warp, refit-on-mask-edit, the editor's drawn bounds, RESET and the
## content transform's pivot/offset all read the domain from here, so nothing can
## be left behind in the other space — the exact failure the spec warns about ("a
## fit that looks correct until you warp it, then the handles are in the wrong
## place").
func warp_domain(i: int) -> Rect2:
	if i < 0 or i >= _regions.size():
		return Rect2(Vector2.ZERO, output_size)
	return _warp_domain_of(_regions[i])


func _warp_domain_of(r: Dictionary) -> Rect2:
	var b := _bounds_of(r["points"])
	return b if b.size.x > 0.0 and b.size.y > 0.0 else Rect2(Vector2.ZERO, output_size)


## Carry a region's warp onto its current domain after the mask moved. Cheap and
## idempotent — refit() returns early when the domain has not actually changed.
func _sync_warp_domain(r: Dictionary) -> void:
	var want := _warp_domain_of(r)
	var have: Rect2 = r["warp_domain"]
	if have.size.x <= 0.0 or have.size.y <= 0.0:
		r["warp_domain"] = want
		return
	if have.is_equal_approx(want):
		return
	(r["warp"] as WarpSurface).refit(have, want)
	r["warp_domain"] = want


## Tell a region which domain its just-loaded warp was authored against, then
## carry it onto the domain the region has now. A file written by this build
## round-trips exactly (the two match, refit is a no-op); a file written BEFORE
## the warp moved into region space carries `Rect2()` here and is treated as
## frame-spanning, so its warp is refitted onto the mask box instead of being
## silently reinterpreted in the wrong space.
func adopt_warp_domain(i: int, authored: Rect2) -> void:
	if i < 0 or i >= _regions.size():
		return
	var r := _regions[i]
	r["warp_domain"] = authored if authored.size.x > 0.0 and authored.size.y > 0.0 \
		else Rect2(Vector2.ZERO, output_size)
	_sync_warp_domain(r)
	rebuild_mesh(r)


func get_warp(i: int) -> WarpSurface:
	if i < 0 or i >= _regions.size():
		return null
	return _regions[i]["warp"]


## True while region `i`'s warp is still the untouched identity over its box —
## FIT replaces that without asking.
func warp_is_plain(i: int) -> bool:
	if i < 0 or i >= _regions.size():
		return true
	var w: WarpSurface = _regions[i]["warp"]
	var plain := _identity_warp(_warp_domain_of(_regions[i]))
	for k in 4:
		if not w.corners[k].is_equal_approx(plain.corners[k]):
			return false
	for o in w.offsets:
		if not o.is_zero_approx():
			return false
	return true


## FIT: set region `i`'s warp from its own points, so the source lands on the
## face in the face's perspective instead of lying flat over the mask's box.
## Any lattice deformation is flattened. False = not 3 or 4 points.
func fit_warp_to_mask(i: int) -> bool:
	if i < 0 or i >= _regions.size():
		return false
	var quad := fit_quad(_regions[i]["points"])
	if quad.is_empty():
		return false
	var r := _regions[i]
	var w: WarpSurface = r["warp"]
	w.reset_all_in(_warp_domain_of(r))
	for k in 4:
		w.set_corner(k, quad[k])
	rebuild_mesh(r)
	return true


## The warp quad (TL, TR, BR, BL) a FIT gives a 3- or 4-point mask; empty for
## any other count.
##  - 4 points: the points themselves, wound clockwise on screen and started at
##    the one nearest the top-left — a face's four corners ARE its homography,
##    so this is exact perspective.
##  - 3 points: three corners only pin an AFFINE map, so perspective cannot be
##    recovered. The base is the most horizontal edge, and the quad is the
##    parallelogram on that base reaching the apex (apex at the middle of the
##    far side), so the source stands upright on the face with its centre
##    under the apex. Right for small or face-on triangles; the further the
##    face turns away, the more it is off.
static func fit_quad(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() == 4:
		var q := pts.duplicate()
		var area := 0.0
		for k in 4:
			area += q[k].x * q[(k + 1) % 4].y - q[(k + 1) % 4].x * q[k].y
		if area < 0.0:
			q.reverse()   # y is down: a positive sum is clockwise on screen
		var start := 0
		for k in 4:
			if q[k].x + q[k].y < q[start].x + q[start].y:
				start = k
		var out := PackedVector2Array()
		for k in 4:
			out.append(q[(start + k) % 4])
		return out
	if pts.size() == 3:
		var base := 0          # edge base..base+1
		var flattest := INF
		for k in 3:
			var d := pts[(k + 1) % 3] - pts[k]
			var tilt := absf(d.y) / maxf(d.length(), 0.0001)
			if tilt < flattest:
				flattest = tilt
				base = k
		var a := pts[(base + 2) % 3]
		var bl := pts[base]
		var br := pts[(base + 1) % 3]
		if bl.x > br.x:
			var t := bl
			bl = br
			br = t
		var m := (bl + br) * 0.5
		if a.y < m.y:   # apex above the base: the base is the bottom edge
			return PackedVector2Array([a + (bl - m), a + (br - m), br, bl])
		return PackedVector2Array([bl, br, a + (br - m), a + (bl - m)])
	return PackedVector2Array()


## Identity over the region's own domain: no keystone, no deformation. A region
## whose warp is untouched is exactly the region it was before per-region warp
## existed — spanning the domain rather than the frame is a reparameterisation,
## not a visual change (see _uv_at).
func _identity_warp(domain: Rect2) -> WarpSurface:
	var w := WarpSurface.new()
	w.set_domain(domain)
	return w


# --- per-mask video (Phase 2) --------------------------------------------

func get_clip(i: int) -> String:
	if i < 0 or i >= _regions.size():
		return ""
	return _regions[i]["clip"]


## Assign a video to a mask by full path ("" = revert to the shared source).
## Returns false if the decoder cap would be exceeded (emits decoder_limit_hit).
func set_clip(i: int, path: String) -> bool:
	if i < 0 or i >= _regions.size():
		return false
	var r := _regions[i]
	if path == "":
		_free_decoder(r)
		r["clip"] = ""
		r["clips"] = PackedStringArray()   # FOLLOW DECK ends a sequence too
		r["clip_pos"] = 0
		rebuild_mesh(r)   # re-points the mesh at the shared source
		return true
	if r["vp"] == null:
		if decoder_count() >= MAX_DECODERS:
			decoder_limit_hit.emit(MAX_DECODERS)
			return false
		_make_decoder(r)
		_sync_decoder_running(r)   # born paused under DECK
	r["clip"] = path
	# Playing a clip that is not on the list ends the list (the folder-order NEXT
	# of a one-clip mask, a direct assignment). The list methods set the list
	# AFTER calling this, so they are unaffected.
	if not (r["clips"] as PackedStringArray).has(path):
		r["clips"] = PackedStringArray()
		r["clip_pos"] = 0
	var player: VideoPlayback = r["player"]
	# Under DECK the mask is not showing this decoder: open the clip, but do not
	# start decoding it until the switch comes back.
	player.enable_auto_play = not follow_deck_all
	player.set_video_path(StorageS.node().playable(path))   # SAF-aware (core/storage.gd)
	rebuild_mesh(r)
	return true


## The stored keys of region `i` (see "saved_keys" in add_region); {} = none.
func get_saved_keys(i: int) -> Dictionary:
	if i < 0 or i >= _regions.size():
		return {}
	return _regions[i]["saved_keys"]


func set_saved_keys(i: int, keys: Dictionary) -> void:
	if i >= 0 and i < _regions.size():
		_regions[i]["saved_keys"] = keys


# --- manual sequence (per-mask clip lists) --------------------------------
# A mask can hold a LIST of clips and be stepped through it by hand (NEXT). One
# decoder per mask, as before: a step reopens it (the open runs on a worker
# thread, see VideoPlayback.set_video_path), so a step can show a brief hold —
# the price of not doubling the decoder count. MAX_DECODERS is unchanged.

func get_clip_list(i: int) -> PackedStringArray:
	if i < 0 or i >= _regions.size():
		return PackedStringArray()
	return _regions[i]["clips"]


func get_clip_pos(i: int) -> int:
	if i < 0 or i >= _regions.size():
		return 0
	return _regions[i]["clip_pos"]


## Put `path` on region `i`'s list and play it. A mask that had one fixed clip
## (no list yet) starts its list with that clip, so adding a second makes a
## two-clip sequence rather than silently dropping the first. False = the
## decoder cap stopped it (nothing changed).
func add_to_list(i: int, path: String) -> bool:
	if i < 0 or i >= _regions.size() or path == "":
		return false
	var r := _regions[i]
	var list: PackedStringArray = r["clips"].duplicate()
	if list.is_empty() and r["clip"] != "":
		list.append(r["clip"])
	if not list.has(path):
		list.append(path)
	if not set_clip(i, path):
		return false
	r["clips"] = list
	r["clip_pos"] = list.find(path)
	return true


## Take `path` off region `i`'s list. If it was the one playing, the entry that
## slides into its place plays; an emptied list goes back to the deck.
func remove_from_list(i: int, path: String) -> void:
	if i < 0 or i >= _regions.size():
		return
	var r := _regions[i]
	var list: PackedStringArray = r["clips"].duplicate()
	var at := list.find(path)
	if at < 0:
		return
	list.remove_at(at)
	if list.is_empty():
		set_clip(i, "")
		return
	var pos: int = r["clip_pos"]
	if at < pos:
		pos -= 1
	pos = clampi(pos, 0, list.size() - 1)
	r["clips"] = list
	r["clip_pos"] = pos
	if r["clip"] != list[pos]:
		set_clip(i, list[pos])


## Restore a saved list (paths already resolved) and play entry `pos`.
func set_clip_list(i: int, list: PackedStringArray, pos: int) -> bool:
	if i < 0 or i >= _regions.size() or list.is_empty():
		return false
	pos = clampi(pos, 0, list.size() - 1)
	if not set_clip(i, list[pos]):
		return false
	_regions[i]["clips"] = list
	_regions[i]["clip_pos"] = pos
	return true


## NEXT (dir 1) / PREV (dir -1) on region `i`'s list, wrapping. False = it has
## fewer than two clips, so there is nothing to step to.
func step_clip(i: int, dir: int) -> bool:
	if i < 0 or i >= _regions.size():
		return false
	var r := _regions[i]
	var list: PackedStringArray = r["clips"]
	if list.size() < 2:
		return false
	var pos := posmod(int(r["clip_pos"]) + dir, list.size())
	if not set_clip(i, list[pos]):
		return false
	r["clip_pos"] = pos
	return true


## Switch every region between its OWN clip and the DECK (see follow_deck_all).
func set_follow_deck_all(on: bool) -> void:
	if follow_deck_all == on:
		return
	follow_deck_all = on
	for r in _regions:
		_sync_decoder_running(r)
		rebuild_mesh(r)


## A region's own decoder runs only while it is what the region shows.
func _sync_decoder_running(r: Dictionary) -> void:
	if r["vp"] == null:
		return
	var vp: SubViewport = r["vp"]
	var player: VideoPlayback = r["player"]
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED if follow_deck_all \
		else SubViewport.UPDATE_ALWAYS
	player.enable_auto_play = not follow_deck_all
	if follow_deck_all:
		player.pause()
	elif player.is_open():
		player.play()


func _make_decoder(r: Dictionary) -> void:
	var vp := SubViewport.new()
	vp.size = DECODER_SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = true
	add_child(vp)
	var player := VideoPlayback.new()
	player.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	player.loop = true
	player.enable_auto_play = true
	player.enable_audio = false   # mask clips are silent; skips the main-thread FFmpeg audio open
	vp.add_child(player)
	player.video_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	r["vp"] = vp
	r["player"] = player


func _free_decoder(r: Dictionary) -> void:
	if r["vp"] != null:
		var vp: SubViewport = r["vp"]
		vp.queue_free()
		r["vp"] = null
		r["player"] = null


# --- the CONTENT TRANSFORM (scale / offset / rotation / pivot / fit) ------
# How the source sits INSIDE a region, as opposed to the region's warp (which is
# the surface's shape). The two are independent: this moves the picture, the warp
# bends the surface, and the mask silhouette holds still through both.
#
# ⚠️ `content_scale` was a float on disk until this increment; `set_content_scale`
# takes a Vector2 so non-uniform (STRETCH) is expressible. A legacy scalar is
# read back as Vector2(s, s) — see RegionEditor.load_saved().

const SCALE_MIN := 0.25
const SCALE_MAX := 4.0


func get_content_scale(i: int) -> Vector2:
	if i < 0 or i >= _regions.size():
		return Vector2.ONE
	return _regions[i]["content_scale"]


func set_content_scale(i: int, s: Vector2) -> void:
	if i < 0 or i >= _regions.size():
		return
	_regions[i]["content_scale"] = Vector2(
		clampf(s.x, SCALE_MIN, SCALE_MAX), clampf(s.y, SCALE_MIN, SCALE_MAX))
	_apply_uv(_regions[i])


func get_content_offset(i: int) -> Vector2:
	if i < 0 or i >= _regions.size():
		return Vector2.ZERO
	return _regions[i]["content_offset"]


func set_content_offset(i: int, o: Vector2) -> void:
	if i < 0 or i >= _regions.size():
		return
	_regions[i]["content_offset"] = o
	_apply_uv(_regions[i])


func get_content_rotation(i: int) -> float:
	if i < 0 or i >= _regions.size():
		return 0.0
	return _regions[i]["content_rotation"]


## Absolute content rotation, in radians. Distinct from rotate_region(), which
## rotates the SHAPE and bumps this alongside so content rides with it.
func set_content_rotation(i: int, radians: float) -> void:
	if i < 0 or i >= _regions.size():
		return
	_regions[i]["content_rotation"] = radians
	_apply_uv(_regions[i])


func get_content_pivot(i: int) -> Vector2:
	if i < 0 or i >= _regions.size():
		return Vector2(0.5, 0.5)
	return _regions[i]["content_pivot"]


func set_content_pivot(i: int, p: Vector2) -> void:
	if i < 0 or i >= _regions.size():
		return
	_regions[i]["content_pivot"] = p
	_apply_uv(_regions[i])


func get_content_fit(i: int) -> int:
	if i < 0 or i >= _regions.size():
		return ContentFit.MANUAL
	return _regions[i]["content_fit"]


func set_content_fit(i: int, mode: int) -> void:
	if i < 0 or i >= _regions.size():
		return
	_regions[i]["content_fit"] = clampi(mode, 0, ContentFit.size() - 1)
	_apply_uv(_regions[i])


## Whole content transform in one value, for an editor's discard (ESC). Mirrors
## WarpSurface.capture_state()/restore_state() so the warp editor can put BOTH
## halves of a region back — the surface and the picture inside it.
func capture_content_state(i: int) -> Dictionary:
	if i < 0 or i >= _regions.size():
		return {}
	var r := _regions[i]
	return {
		"scale": r["content_scale"], "offset": r["content_offset"],
		"rotation": r["content_rotation"], "pivot": r["content_pivot"],
		"fit": r["content_fit"],
	}


func restore_content_state(i: int, state: Dictionary) -> void:
	if i < 0 or i >= _regions.size() or state.is_empty():
		return
	var r := _regions[i]
	r["content_scale"] = state.get("scale", Vector2.ONE)
	r["content_offset"] = state.get("offset", Vector2.ZERO)
	r["content_rotation"] = state.get("rotation", 0.0)
	r["content_pivot"] = state.get("pivot", Vector2(0.5, 0.5))
	r["content_fit"] = state.get("fit", ContentFit.MANUAL)
	_apply_uv(r)


## The four corners of the SOURCE FRAME, mapped back into output px — i.e. where
## the picture's own edges sit inside the region. The warp editor draws this as
## the solid rect that moves, against the dashed domain rect that does not.
##
## In the UNDEFORMED domain: this is the content transform's doing, and the warp
## is a separate stage (see WarpEditor._draw_content_rect for why that is the
## right space to show it in).
func content_quad(i: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if i < 0 or i >= _regions.size():
		return out
	var r := _regions[i]
	var dom := _warp_domain_of(r)
	# _uv_at is affine, so its inverse takes a texture UV straight back to a
	# lattice parameter — no need to invert the steps by hand.
	var inv := _uv_xform(r).affine_inverse()
	for uv in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
		out.append(dom.position + (inv * uv) * dom.size)
	return out


## The pivot in output px. The stored value is a fraction of the region's domain;
## this is the one conversion, so the editor cannot disagree with _uv_at about
## where the pivot is.
func content_pivot_px(i: int) -> Vector2:
	if i < 0 or i >= _regions.size():
		return Vector2.ZERO
	var dom := _warp_domain_of(_regions[i])
	return dom.position + (_regions[i]["content_pivot"] as Vector2) * dom.size


## Back to the default content transform: the source fitted to the region, no
## zoom, no pan, no rotation, pivot at the region's centre. The fit MODE is left
## alone — it says which rect to fit to, which is not what "reset" is asking.
func reset_transform(i: int) -> void:
	if i < 0 or i >= _regions.size():
		return
	var r := _regions[i]
	r["content_scale"] = Vector2.ONE
	r["content_offset"] = Vector2.ZERO
	r["content_rotation"] = 0.0
	r["content_pivot"] = Vector2(0.5, 0.5)
	_apply_uv(r)


# --- mask GEOMETRY transform (move / scale / rotate the shape itself) -----
# Handle-drag calls these incrementally; the numeric panel calls the absolute
# setters below. Geometry is baked into the points; `geo_scale`/`geo_rot` track
# the cumulative transform so absolute numeric values work. `angle` (the texture
# UV rotation) is bumped alongside geometry rotation so content rotates WITH the
# shape.

func region_centroid(i: int) -> Vector2:
	if i < 0 or i >= _regions.size():
		return Vector2.ZERO
	var pts: PackedVector2Array = _regions[i]["points"]
	if pts.is_empty():
		return Vector2.ZERO
	var c := Vector2.ZERO
	for p in pts:
		c += p
	return c / float(pts.size())


func region_bounds(i: int) -> Rect2:
	if i < 0 or i >= _regions.size():
		return Rect2()
	return _bounds_of(_regions[i]["points"])


## The mask's axis-aligned bounding box, in output px. Degenerate masks (a
## single point, or a line) are widened to 1 px so nothing downstream divides
## by a zero span.
func _bounds_of(pts: PackedVector2Array) -> Rect2:
	if pts.is_empty():
		return Rect2()
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	r.size.x = maxf(r.size.x, 1.0)
	r.size.y = maxf(r.size.y, 1.0)
	return r


func translate_region(i: int, delta: Vector2) -> void:
	if i < 0 or i >= _regions.size():
		return
	var r := _regions[i]
	var pts: PackedVector2Array = r["points"]
	var out := PackedVector2Array()
	for p in pts:
		out.append(p + delta)
	r["points"] = out
	_apply_points(r)


func scale_region(i: int, f: float, pivot: Vector2) -> void:
	if i < 0 or i >= _regions.size() or f <= 0.0:
		return
	var r := _regions[i]
	var pts: PackedVector2Array = r["points"]
	var out := PackedVector2Array()
	for p in pts:
		out.append(pivot + (p - pivot) * f)
	r["points"] = out
	r["geo_scale"] = float(r["geo_scale"]) * f
	_apply_points(r)


func rotate_region(i: int, angle: float, pivot: Vector2) -> void:
	if i < 0 or i >= _regions.size():
		return
	var r := _regions[i]
	var pts: PackedVector2Array = r["points"]
	var out := PackedVector2Array()
	for p in pts:
		out.append(pivot + (p - pivot).rotated(angle))
	r["points"] = out
	r["geo_rot"] = float(r["geo_rot"]) + angle
	# Rotate the CONTENT with the shape. ⚠️ Until the content-transform increment
	# this bump was never persisted, so rotating a mask rotated its content and
	# the rotation was silently lost on restart (spec §2b).
	r["content_rotation"] = float(r["content_rotation"]) + angle
	_apply_points(r)


# Numeric (absolute) setters/getters — for the Numbers panel.
func get_geo_scale(i: int) -> float:
	if i < 0 or i >= _regions.size():
		return 1.0
	return _regions[i]["geo_scale"]


func get_geo_rot(i: int) -> float:
	if i < 0 or i >= _regions.size():
		return 0.0
	return _regions[i]["geo_rot"]


func set_region_center(i: int, target: Vector2) -> void:
	translate_region(i, target - region_centroid(i))


func set_geo_scale(i: int, s: float) -> void:
	if i < 0 or i >= _regions.size() or s <= 0.0:
		return
	var cur: float = _regions[i]["geo_scale"]
	if cur <= 0.0:
		return
	scale_region(i, s / cur, region_centroid(i))


func set_geo_rot(i: int, radians: float) -> void:
	if i < 0 or i >= _regions.size():
		return
	var cur: float = _regions[i]["geo_rot"]
	rotate_region(i, radians - cur, region_centroid(i))


## Restore the cumulative geometry bookkeeping WITHOUT re-transforming anything.
## Loading a region hands over points that are already in their transformed
## positions, so the loader must set these two directly — going through
## set_geo_scale()/set_geo_rot() would apply the transform a second time.
## Without this the numeric panel reads 100% / 0° for a scaled, rotated mask.
func restore_geo(i: int, gscale: float, grot: float) -> void:
	if i < 0 or i >= _regions.size():
		return
	_regions[i]["geo_scale"] = gscale if gscale > 0.0 else 1.0
	_regions[i]["geo_rot"] = grot


# Delete one vertex of a mask (keeps a valid triangle minimum).
func delete_point(i: int, vertex: int) -> bool:
	if i < 0 or i >= _regions.size():
		return false
	var pts: PackedVector2Array = _regions[i]["points"]
	if pts.size() <= 3 or vertex < 0 or vertex >= pts.size():
		return false
	pts.remove_at(vertex)
	_regions[i]["points"] = pts
	_apply_points(_regions[i])
	return true


# --- selection / audio ----------------------------------------------------

## Topmost region whose polygon contains pos (search front-to-back / last-drawn first).
func region_at(pos: Vector2) -> int:
	for i in range(_regions.size() - 1, -1, -1):
		var pts: PackedVector2Array = _regions[i]["points"]
		if pts.size() >= 3 and Geometry2D.is_point_in_polygon(pos, pts):
			return i
	return -1


## Drive audio-reactive intensity on every region's effect material (mirrors the
## global ShaderSlot drive so masks pulse with the audio too).
func set_intensity(v: float) -> void:
	for r in _regions:
		var mesh_node: MeshInstance2D = r["mesh_node"]
		var mat: Material = mesh_node.material
		if mat is ShaderMaterial:
			(mat as ShaderMaterial).set_shader_parameter("intensity", v)


# --- rendering helpers ----------------------------------------------------

func _region_texture(r: Dictionary) -> Texture2D:
	if r["vp"] == null or follow_deck_all:
		return _source
	var vp: SubViewport = r["vp"]
	return vp.get_texture()


func _apply_points(r: Dictionary) -> void:
	var pts: PackedVector2Array = r["points"]
	var poly: Polygon2D = r["poly"]
	poly.polygon = pts
	# Reshape / move / scale / rotate / delete-point all land here, so this is the
	# one place a moved bounding box can carry the region's warp with it.
	_sync_warp_domain(r)
	_apply_uv(r)


## The rect the SOURCE is normalized against — the content FIT target, and the
## one thing a fit mode changes.
##
## ⚠️ Not to be confused with warp_domain(): that is which output area the
## parameter square spans, and it stays the mask's bounding box in every fit mode
## (spec §2 — "`dom` is untouched"). Swapping THIS rect for the whole frame is
## the entire mechanism of FULL_FRAME.
func _fit_rect(r: Dictionary) -> Rect2:
	if int(r["content_fit"]) == ContentFit.FULL_FRAME:
		return Rect2(Vector2.ZERO, output_size)
	# MANUAL — and, until the aspect presets land, FILL / FIT / STRETCH too:
	# the source is fitted to the mask's own box, which is what every saved
	# project has always done.
	return _warp_domain_of(r)


## The content mapping, evaluated at one lattice parameter. This is EXACTLY the
## mapping the pre-warp code applied to a polygon vertex — fit the whole source
## into the mask's bounding box, then scale/rotate/pan it — but fed the IDENTITY
## DOMAIN POINT rather than the vertex's warped position.
##
## ⚠️ That distinction is the migration. Emitting plain 0..1 UVs instead would
## silently turn every existing mask from "the whole video, fitted to this
## shape" into "a window onto the video", which is a different look for every
## project anyone has saved. Feeding the identity point means an identity warp
## reproduces the old UVs exactly; and because this map is AFFINE, the old
## affine-interpolated Polygon2D UVs and the new densely-sampled mesh UVs agree
## to the pixel.
##
## ⚠️ EVERYTHING HERE IS IN OUTPUT PIXELS UNTIL THE LAST LINE, and that is the
## whole point of the shape it has (spec §2 items 1 and 2). The earlier version
## worked in fit-normalized space with a hardcoded `Vector2(0.5, 0.5)` centre,
## which broke in two ways the moment `fit` stopped being the mask box:
##
##  1. `0.5,0.5` meant "the centre of whatever fit is". Under FULL_FRAME that is
##     the centre of the FRAME, so zooming a small region's content would swing
##     it across the screen. Here the pivot is a point on the REGION, expressed
##     as a fraction of the domain, so it cannot move when the fit rect changes.
##  2. `offset` was in units of `fit`. The same 0.1 meant 0.1 x bbox in one mode
##     and 0.1 x 1920 in the other, so toggling the mode made content JUMP. Here
##     it is a fraction of the DOMAIN, which is stable across modes.
##
## Two further properties fall out, and both matter for a mapping tool:
##  - a drag or a pad step moves content EXACTLY that many output px, whatever
##    the scale and rotation are, because the move is applied in output space
##    before them;
##  - rotation is a TRUE rotation (isotropic). In the old normalized form a
##    non-square bbox sheared the content as it turned. Nothing on disk can
##    regress from this: `angle` was never persisted (§2b), so no saved project
##    has a non-zero rotation.
##
## At the defaults (scale 1, offset 0, rotation 0, pivot 0.5,0.5) this reduces
## algebraically to the old expression — p == ident, so the result is exactly
## `(ident - fit.position) / fit.size`, i.e. pixel-identical for every region
## that has ever been saved.
##
## Because it is a function of the PARAMETER and never of the deformed position,
## content rides along when the surface is warped.
func _uv_at(r: Dictionary, u: float, v: float) -> Vector2:
	var pts: PackedVector2Array = r["points"]
	if pts.is_empty():
		return Vector2(u, v)
	var dom := _warp_domain_of(r)                     # STABLE across fit modes
	var fit := _fit_rect(r)                           # what the source spans
	var sc: Vector2 = r["content_scale"]
	var ang: float = r["content_rotation"]
	# Pivot and move are anchored to the DOMAIN, so both are region-relative and
	# survive a fit-mode toggle, a mask reshape and a resolution change.
	var piv: Vector2 = dom.position + (r["content_pivot"] as Vector2) * dom.size
	var mov: Vector2 = (r["content_offset"] as Vector2) * dom.size
	var p := dom.position + Vector2(u, v) * dom.size   # the identity domain point
	# Inverse of "move, then scale, then rotate the content": undo it on the
	# SAMPLING side, which is what makes the content itself move +mov / +ang.
	p -= mov + piv
	if ang != 0.0:
		p = p.rotated(-ang)
	return (piv + p / sc - fit.position) / fit.size


## _uv_at is affine in (u,v), so three evaluations pin the whole transform —
## which sidesteps hand-composing (and mis-ordering) the six steps above.
func _uv_xform(r: Dictionary) -> Transform2D:
	var f00 := _uv_at(r, 0.0, 0.0)
	return Transform2D(_uv_at(r, 1.0, 0.0) - f00, _uv_at(r, 0.0, 1.0) - f00, f00)


func _apply_uv(r: Dictionary) -> void:
	rebuild_mesh(r)


## Rebuild a region's warped mesh. Cheap enough to call on any change (points,
## transform, warp, source) — it is O(render verts), not per frame.
func rebuild_mesh(r: Dictionary) -> void:
	var mesh_node: MeshInstance2D = r["mesh_node"]
	var surface: WarpSurface = r["warp"]
	mesh_node.texture = _region_texture(r)
	# The checker spans the warp's PARAMETER square (UV = u,v), not the content
	# mapping: it shows the warp alone, whatever the clip's zoom/pan/rotation.
	surface.build_into(mesh_node.mesh as ArrayMesh,
		Transform2D.IDENTITY if checker else _uv_xform(r))
	if checker:
		_sync_checker_cells(r)


## Turn the CHECKER on or off for every region.
func set_checker(on: bool) -> void:
	if checker == on:
		return
	checker = on
	for r in _regions:
		_apply_effect(r)
		rebuild_mesh(r)


## Square cells at the identity warp: the domain's longer side gets
## CHECKER_CELLS, the shorter side the whole number closest to square (min 2).
## Whole numbers, so the board's corners are the warp's corners.
func _sync_checker_cells(r: Dictionary) -> void:
	var mat := (r["mesh_node"] as MeshInstance2D).material as ShaderMaterial
	if mat == null:
		return
	var dom := _warp_domain_of(r)
	var cell := maxf(dom.size.x, dom.size.y) / CHECKER_CELLS
	mat.set_shader_parameter("cells", Vector2(
		maxf(2.0, roundf(dom.size.x / cell)), maxf(2.0, roundf(dom.size.y / cell))))


## Rebuild region `i` — the hook the warp editor calls after mutating a region's
## surface, mirroring what QuadWarp does for the global warp.
func rebuild_region(i: int) -> void:
	if i < 0 or i >= _regions.size():
		return
	rebuild_mesh(_regions[i])


func _apply_effect(r: Dictionary) -> void:
	var idx: int = r["effect"]
	var mesh_node: MeshInstance2D = r["mesh_node"]
	if checker:
		# The board replaces the effect as well as the clip; set_checker(false)
		# comes back through here and restores the region's own effect.
		var board := ShaderMaterial.new()
		board.shader = CHECKER_SHADER
		mesh_node.material = board
		_sync_checker_cells(r)
		return
	if idx < 0 or idx >= _effects.size():
		mesh_node.material = null
		return
	var shader: Shader = _effects[idx]["shader"]
	if shader == null:
		mesh_node.material = null   # "Off" — raw video through the mask
		return
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mesh_node.material = mat
