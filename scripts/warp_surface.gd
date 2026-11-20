class_name WarpSurface
extends RefCounted
## The warp MODEL — a homography plus a lattice of offsets — with no scene
## presence of its own.
##
## This is the Session 18/19 maths lifted out of QuadWarp unchanged. It moved
## here because the warp is no longer a single global thing: the global output
## warp (QuadWarp, still the last stage of OutputWorld) and every per-region
## surface must share ONE implementation, or they drift. Two consequences worth
## stating, because they are the point of the extraction:
##
##  - `warp_editor.gd` drives a target purely through this contract
##    (edit_cols/edit_rows/control_point/set_control_point/set_grid_size/
##    set_mesh_mode/capture_state/restore_state/surface_point), so it can edit
##    the global warp or a region's warp with no changes.
##  - Smooth/Bezier (Coons) — spec 3b, deliberately NOT built yet — lands here
##    once and applies to the global warp and every region at the same time.
##
## THE SURFACE MODEL — homography + offsets. `corners` always defines a
## homography H (unit square -> quad). Every control point (i,j) has a REST
## position H(u_i, v_j) and stores an OFFSET from it; the rendered surface is
##
##     S(u,v) = H(u,v) + bilinear_blend_of_offsets(u,v)
##
## Three properties fall out of that, and they are why it is built this way:
##  1. **2x2 with zero offsets IS the plain homography** — the four lattice
##     corners ARE the quad corners, so their offsets are pinned to zero by
##     construction. MESH at 2x2 and QUAD render the same vertices from the
##     same code path: a strict superset, pixel-identical. A legacy 4-corner
##     warp.cfg slot loads as exactly that.
##  2. **Dragging a corner re-keystones the whole surface.** Corners feed H, so
##     every interior REST position moves with them while the offsets (the
##     user's actual deformation) ride along unchanged.
##  3. **No seams.** A per-cell-homography scheme would tear: two cells sharing
##     an edge agree on the endpoints but not on the projective parameterization
##     between them, so the texture would jump across every cell boundary.
##     Blending an offset FIELD over one global homography is C0 everywhere.
##
## The offset blend is bilinear (piecewise, creased at control lines) — the
## right feel for "drag a point, that region moves" and for the irregular
## surfaces this mode targets.
##
## PERSPECTIVE CORRECTNESS. The base is the exact unit-square -> quad
## homography (Heckbert closed form), and the RENDER mesh is subdivided far
## denser than the control lattice — at least RENDER_TARGET per side however
## coarse the lattice — so vertices land on the true perspective map and
## straight content lines stay straight (measured 0.63 px RMS in S18).

## Minimum render subdivisions per side. The real count is rounded UP to a whole
## number of subdivisions per control cell, so control lines always land exactly
## on render vertices and a crease is never smeared across a cell.
const RENDER_TARGET := 24
const EPS := 0.000001
const MIN_GRID := 2
const MAX_GRID := 8
## What MESH starts at. Distinct from MIN_GRID, which is what a legacy 4-corner
## preset restores to — those must come back as a flat 2x2, not as this.
const DEFAULT_GRID := 3

## The four output-space corners. Always the homography's control quad, in both
## modes — in MESH they are also the lattice's corner control points.
var corners: PackedVector2Array
var grid_cols: int = DEFAULT_GRID
var grid_rows: int = DEFAULT_GRID
## One offset per lattice point, row-major, in OUTPUT px. The four lattice
## corners are pinned to ZERO (they are expressed through `corners`/H instead).
var offsets: PackedVector2Array = PackedVector2Array()
## false = QUAD: offsets are ignored entirely, so QUAD is bit-identical to the
## S18 renderer no matter what lattice is stored. Kept rather than forcing the
## grid to 2x2 so switching QUAD <-> MESH is non-destructive.
var mesh_mode: bool = false

var _indices: PackedInt32Array
var _idx_for: Vector2i = Vector2i.ZERO   ## subdivision the cached indices are built for
var _co: PackedFloat32Array = PackedFloat32Array()
var _co_valid: bool = false


## Reset the quad to fill a rectangle of the given size (default framing).
## Corners ONLY — this is also the boot and HDMI-renegotiation path, and it must
## not silently discard a mesh. Editor RESET calls reset_all().
func fill_rect(rect_size: Vector2) -> void:
	set_domain(Rect2(Vector2.ZERO, rect_size))


## Undeformed framing over an ARBITRARY rect — the general form of fill_rect().
## The global output warp always spans the whole output (origin 0,0), but a
## REGION's warp spans its own domain, which does not start at the origin. See
## RegionCompositor.warp_domain().
func set_domain(rect: Rect2) -> void:
	corners = PackedVector2Array([
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	])
	_co_valid = false


## Full reset: default framing AND a flat (zero-offset) lattice.
func reset_all(rect_size: Vector2) -> void:
	reset_all_in(Rect2(Vector2.ZERO, rect_size))


func reset_all_in(rect: Rect2) -> void:
	_zero_offsets()
	set_domain(rect)


## Re-express this surface against a DIFFERENT domain rect, mapping `from` onto
## `to`. Corners are points (scale + translate); offsets are deltas, so they
## scale but never translate.
##
## This is what keeps a region's warp attached to its mask: edit the mask and
## its bounding box moves, so the warp authored against the old box is carried
## onto the new one instead of being silently reinterpreted or thrown away.
func refit(from: Rect2, to: Rect2) -> void:
	if from.size.x <= 0.0 or from.size.y <= 0.0:
		return
	var k := to.size / from.size
	if from.position.is_equal_approx(to.position) and k.is_equal_approx(Vector2.ONE):
		return   # nothing moved
	for i in corners.size():
		corners[i] = to.position + (corners[i] - from.position) * k
	for i in offsets.size():
		offsets[i] = offsets[i] * k
	_co_valid = false


## Move a single corner (for warp/keystone controls). Also moves every interior
## REST position, since the corners define the homography.
func set_corner(index: int, pos: Vector2) -> void:
	if index < 0 or index >= corners.size():
		return
	corners[index] = pos
	_co_valid = false


## True when this surface is the identity over `rect_size` — no keystone, no
## deformation. The migration contract for regions loaded from a pre-per-region
## regions.cfg: they must come back as exactly this and render as they always did.
func is_identity(rect_size: Vector2) -> bool:
	if mesh_mode:
		for o in offsets:
			if not o.is_zero_approx():
				return false
	if corners.size() != 4:
		return false
	var want := PackedVector2Array([
		Vector2(0, 0),
		Vector2(rect_size.x, 0),
		Vector2(rect_size.x, rect_size.y),
		Vector2(0, rect_size.y),
	])
	for i in 4:
		if not corners[i].is_equal_approx(want[i]):
			return false
	return true


# --- control lattice ------------------------------------------------------
# The editor drives everything through these, so it never has to branch on the
# mode: QUAD simply presents as a 2x2 lattice whose offsets are all zero.

func edit_cols() -> int:
	return grid_cols if mesh_mode else MIN_GRID


func edit_rows() -> int:
	return grid_rows if mesh_mode else MIN_GRID


func point_count() -> int:
	return edit_cols() * edit_rows()


## Which quad corner a lattice index is, or -1 for an edge/interior point.
## Lattice is row-major; quad order is TL, TR, BR, BL.
func corner_of_index(idx: int) -> int:
	var cols := edit_cols()
	var rows := edit_rows()
	var col := idx % cols
	var row := floori(float(idx) / float(cols))
	var last_c := cols - 1
	var last_r := rows - 1
	if row == 0 and col == 0:
		return 0
	if row == 0 and col == last_c:
		return 1
	if row == last_r and col == last_c:
		return 2
	if row == last_r and col == 0:
		return 3
	return -1


## Lattice parameters (u,v) in 0..1 for a control index.
func point_uv(idx: int) -> Vector2:
	var cols := edit_cols()
	var rows := edit_rows()
	return Vector2(
		float(idx % cols) / float(cols - 1),
		floorf(float(idx) / float(cols)) / float(rows - 1))


## Where the control point WOULD sit with no deformation (on the homography).
func control_rest(idx: int) -> Vector2:
	var uv := point_uv(idx)
	return _base(_coeffs(), uv.x, uv.y)


## The control point's live output-space position (rest + its offset).
func control_point(idx: int) -> Vector2:
	var uv := point_uv(idx)
	return _surface(_coeffs(), uv.x, uv.y)


## Move a control point to an absolute output-space position. Corners re-drive
## the homography; everything else stores an offset from its rest position.
func set_control_point(idx: int, pos: Vector2) -> void:
	var c := corner_of_index(idx)
	if c >= 0:
		set_corner(c, pos)
		return
	if not mesh_mode or offsets.size() != grid_cols * grid_rows:
		return
	offsets[idx] = pos - control_rest(idx)


## Switch QUAD <-> MESH. Non-destructive: the lattice and its offsets survive a
## trip through QUAD, they are just not applied while it is off.
func set_mesh_mode(on: bool) -> void:
	if mesh_mode == on:
		return
	mesh_mode = on
	if on:
		_ensure_offsets()


## Change the lattice density, RESAMPLING the existing offset field onto the new
## parameters so the surface does not jump — going 3x3 -> 5x5 keeps the shape
## and just hands you more handles. (Coarsening loses detail; unavoidable.)
func set_grid_size(cols: int, rows: int) -> void:
	cols = clampi(cols, MIN_GRID, MAX_GRID)
	rows = clampi(rows, MIN_GRID, MAX_GRID)
	if cols == grid_cols and rows == grid_rows and offsets.size() == cols * rows:
		return
	var resampled := PackedVector2Array()
	resampled.resize(cols * rows)
	var had := offsets.size() == grid_cols * grid_rows
	for j in rows:
		var v := float(j) / float(rows - 1)
		for i in cols:
			# _offset_at still reads the OLD lattice here — resample onto the new
			# (u,v) parameters BEFORE the new dimensions are committed.
			var u := float(i) / float(cols - 1)
			resampled[j * cols + i] = _offset_at(u, v) if had else Vector2.ZERO
	grid_cols = cols
	grid_rows = rows
	offsets = resampled
	_pin_corner_offsets()


func _ensure_offsets() -> void:
	if offsets.size() != grid_cols * grid_rows:
		_zero_offsets()


func _zero_offsets() -> void:
	offsets = PackedVector2Array()
	offsets.resize(grid_cols * grid_rows)


## The four lattice corners are expressed through `corners`, never through an
## offset — otherwise a corner would be movable by two different routes.
func _pin_corner_offsets() -> void:
	if offsets.size() != grid_cols * grid_rows:
		return
	offsets[0] = Vector2.ZERO
	offsets[grid_cols - 1] = Vector2.ZERO
	offsets[(grid_rows - 1) * grid_cols] = Vector2.ZERO
	offsets[grid_rows * grid_cols - 1] = Vector2.ZERO


## The rendered surface at (u,v) in output space — what the editor draws its
## lattice lines and handles from, so the overlay always matches the mesh.
func surface_point(u: float, v: float) -> Vector2:
	return _surface(_coeffs(), u, v)


## Whole-warp snapshot, for the editor's ESC (discard) and for preset I/O.
func capture_state() -> Dictionary:
	return {
		"corners": corners.duplicate(),
		"offsets": offsets.duplicate(),
		"cols": grid_cols,
		"rows": grid_rows,
		"mesh": mesh_mode,
	}


## Restore a snapshot EXACTLY — no offset resampling, unlike set_grid_size().
## Also the one loader for presets: a legacy 4-corner slot arrives here as
## cols=rows=2, no offsets, mesh=false, which renders identically to QUAD.
func restore_state(state: Dictionary) -> void:
	grid_cols = clampi(int(state.get("cols", MIN_GRID)), MIN_GRID, MAX_GRID)
	grid_rows = clampi(int(state.get("rows", MIN_GRID)), MIN_GRID, MAX_GRID)
	mesh_mode = bool(state.get("mesh", false))
	var incoming: PackedVector2Array = state.get("offsets", PackedVector2Array())
	offsets = incoming.duplicate() if incoming.size() == grid_cols * grid_rows \
		else PackedVector2Array()
	_ensure_offsets()
	_pin_corner_offsets()
	var c: PackedVector2Array = state.get("corners", PackedVector2Array())
	if c.size() == 4:
		corners = c.duplicate()
	_co_valid = false


# --- persistence ----------------------------------------------------------
# ONE serializer for both files. warp.cfg slots have carried exactly these keys
# since S19 (corners/mesh/grid/offsets, normalized against the output size);
# regions.cfg reuses the same code with a "warp_" prefix. The prefix is not
# cosmetic — an unprefixed "offsets" would sit one character away from the
# per-region texture-pan key "offset" in the same section.
#
# Geometry is normalized against `out_size` so presets survive a resolution
# change (S13 basis rule), and the reader tolerates every key being absent.

func save_to(cfg: ConfigFile, section: String, out_size: Vector2, prefix := "") -> void:
	var norm := PackedVector2Array()
	for p in corners:
		norm.append(Vector2(p.x / out_size.x, p.y / out_size.y))
	cfg.set_value(section, prefix + "corners", norm)
	var noff := PackedVector2Array()
	for o in offsets:
		noff.append(Vector2(o.x / out_size.x, o.y / out_size.y))
	cfg.set_value(section, prefix + "mesh", mesh_mode)
	cfg.set_value(section, prefix + "grid", Vector2i(grid_cols, grid_rows))
	cfg.set_value(section, prefix + "offsets", noff)


## Returns false and leaves the surface UNTOUCHED when the section carries no
## warp — which is the whole migration story for regions.cfg: a file written
## before per-region warp existed has no warp keys, so every region keeps the
## identity it was constructed with and renders exactly as it always did.
func load_from(cfg: ConfigFile, section: String, out_size: Vector2, prefix := "") -> bool:
	if not cfg.has_section_key(section, prefix + "corners"):
		return false
	var norm: PackedVector2Array = cfg.get_value(section, prefix + "corners")
	var c := PackedVector2Array()
	for p in norm:
		c.append(Vector2(p.x * out_size.x, p.y * out_size.y))
	# Missing mesh keys = a pre-S19 slot: a flat 2x2 lattice, mesh off. That
	# renders through the identical code path as the old 4-corner warp.
	var g: Vector2i = cfg.get_value(section, prefix + "grid", Vector2i(MIN_GRID, MIN_GRID))
	var noff: PackedVector2Array = cfg.get_value(
		section, prefix + "offsets", PackedVector2Array())
	var off := PackedVector2Array()
	for o in noff:
		off.append(Vector2(o.x * out_size.x, o.y * out_size.y))
	restore_state({
		"corners": c,
		"offsets": off,
		"cols": g.x,
		"rows": g.y,
		"mesh": bool(cfg.get_value(section, prefix + "mesh", false)),
	})
	return true


## Bilinear blend of the offset field at (u,v). Reads the CURRENT lattice.
func _offset_at(u: float, v: float) -> Vector2:
	if offsets.size() != grid_cols * grid_rows:
		return Vector2.ZERO
	var cx := grid_cols - 1
	var cy := grid_rows - 1
	var fx := clampf(u, 0.0, 1.0) * float(cx)
	var fy := clampf(v, 0.0, 1.0) * float(cy)
	var i0 := clampi(int(floorf(fx)), 0, cx - 1)
	var j0 := clampi(int(floorf(fy)), 0, cy - 1)
	var tx := fx - float(i0)
	var ty := fy - float(j0)
	var o00: Vector2 = offsets[j0 * grid_cols + i0]
	var o10: Vector2 = offsets[j0 * grid_cols + i0 + 1]
	var o01: Vector2 = offsets[(j0 + 1) * grid_cols + i0]
	var o11: Vector2 = offsets[(j0 + 1) * grid_cols + i0 + 1]
	return o00.lerp(o10, tx).lerp(o01.lerp(o11, tx), ty)


# --- homography ----------------------------------------------------------

## Map the unit square (0,0),(1,0),(1,1),(0,1) onto the four corners, in that
## order — which is exactly the TL,TR,BR,BL corner order.
##
## Returns the 8 coefficients [a,b,c,d,e,f,g,h] of
##     X = (a*u + b*v + c) / (g*u + h*v + 1)
##     Y = (d*u + e*v + f) / (g*u + h*v + 1)
## or an EMPTY array when no usable homography exists — _base() then falls back
## to a bilinear patch. Closed form after Heckbert, "Fundamentals of Texture
## Mapping and Image Warping", 2.2.
func _homography() -> PackedFloat32Array:
	if corners.size() != 4:
		return PackedFloat32Array()
	var p0 := corners[0]
	var p1 := corners[1]
	var p2 := corners[2]
	var p3 := corners[3]
	var sx := p0.x - p1.x + p2.x - p3.x
	var sy := p0.y - p1.y + p2.y - p3.y
	if absf(sx) < EPS and absf(sy) < EPS:
		# A parallelogram — the map is affine, g = h = 0. Handled separately
		# because the general solve divides by a determinant that is zero here.
		return PackedFloat32Array([
			p1.x - p0.x, p3.x - p0.x, p0.x,
			p1.y - p0.y, p3.y - p0.y, p0.y,
			0.0, 0.0,
		])
	var dx1 := p1.x - p2.x
	var dx2 := p3.x - p2.x
	var dy1 := p1.y - p2.y
	var dy2 := p3.y - p2.y
	var den := dx1 * dy2 - dx2 * dy1
	if absf(den) < EPS:
		return PackedFloat32Array()   # collapsed quad (two corners coincide)
	var g := (sx * dy2 - dx2 * sy) / den
	var h := (dx1 * sy - sx * dy1) / den
	# w = g*u + h*v + 1 is AFFINE in (u,v), so its minimum over the unit square
	# is always at a corner: w(0,0)=1, w(1,0)=1+g, w(1,1)=1+g+h, w(0,1)=1+h.
	# w <= 0 anywhere means the quad crosses the projection horizon, which is
	# exactly the non-convex case (a projective image of a convex square is
	# convex iff w stays positive). Reject it rather than divide by ~0.
	if minf(minf(1.0 + g, 1.0 + h), 1.0 + g + h) < EPS:
		return PackedFloat32Array()
	return PackedFloat32Array([
		p1.x - p0.x + g * p1.x, p3.x - p0.x + h * p3.x, p0.x,
		p1.y - p0.y + g * p1.y, p3.y - p0.y + h * p3.y, p0.y,
		g, h,
	])


## Cached coefficients — the editor asks for up to 64 control positions per
## redraw, and each would otherwise re-solve the homography.
func _coeffs() -> PackedFloat32Array:
	if not _co_valid:
		_co = _homography()
		_co_valid = true
	return _co


func _project(co: PackedFloat32Array, u: float, v: float) -> Vector2:
	var w := co[6] * u + co[7] * v + 1.0
	return Vector2(
		(co[0] * u + co[1] * v + co[2]) / w,
		(co[3] * u + co[4] * v + co[5]) / w)


## Fallback for quads a homography can't describe (non-convex, or collapsed).
## Degrades to the same bilinear patch the old two-triangle Polygon2D drew —
## for a parallelogram this is exactly affine, i.e. identical to before.
func _bilinear(u: float, v: float) -> Vector2:
	if corners.size() != 4:
		return Vector2.ZERO
	return corners[0].lerp(corners[1], u).lerp(corners[3].lerp(corners[2], u), v)


## The undeformed base surface: the homography where one exists.
func _base(co: PackedFloat32Array, u: float, v: float) -> Vector2:
	return _project(co, u, v) if co.size() == 8 else _bilinear(u, v)


## The full surface: base + the blended offset field (MESH only).
func _surface(co: PackedFloat32Array, u: float, v: float) -> Vector2:
	if not mesh_mode:
		return _base(co, u, v)
	return _base(co, u, v) + _offset_at(u, v)


# --- mesh ----------------------------------------------------------------

## Render subdivisions per side. Rounded UP to a whole number per control cell
## so every control line lands on render vertices, and never below
## RENDER_TARGET — a coarse lattice must not coarsen the perspective sampling.
## QUAD ignores the lattice entirely and returns the S18 value exactly.
func _render_subdiv() -> Vector2i:
	if not mesh_mode:
		return Vector2i(RENDER_TARGET, RENDER_TARGET)
	var cx := maxi(1, grid_cols - 1)
	var cy := maxi(1, grid_rows - 1)
	return Vector2i(
		ceili(float(RENDER_TARGET) / float(cx)) * cx,
		ceili(float(RENDER_TARGET) / float(cy)) * cy)


## Rebuild `mesh` as this surface's triangle mesh.
##
## `uv_xform` maps the lattice parameter (u,v) to a texture coordinate. The
## default is the identity, i.e. plain NORMALIZED UVs (so a source-viewport
## resize never strands them) — that is what the global output warp wants.
## A REGION passes its own affine instead, because a region's content mapping
## predates per-region warp and must be preserved exactly: see
## RegionCompositor._uv_xform().
##
## The UV is a function of the PARAMETER, never of the deformed position, which
## is what makes content ride along with the surface when it is warped.
func build_into(mesh: ArrayMesh, uv_xform := Transform2D.IDENTITY) -> void:
	if corners.size() != 4 or mesh == null:
		return
	var co := _coeffs()
	var sub := _render_subdiv()
	if _indices.is_empty() or _idx_for != sub:
		_build_indices(sub)
	var sw := sub.x + 1
	var sh := sub.y + 1
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	verts.resize(sw * sh)
	uvs.resize(sw * sh)
	var i := 0
	for jy in sh:
		var v := float(jy) / float(sub.y)
		for ix in sw:
			var u := float(ix) / float(sub.x)
			verts[i] = _surface(co, u, v)
			uvs[i] = uv_xform * Vector2(u, v)
			i += 1
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = _indices
	mesh.clear_surfaces()
	# ARRAY_FLAG_USE_2D_VERTICES: vertices are Vector2, not Vector3.
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays,
		[] as Array[Array], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)


func _build_indices(sub: Vector2i) -> void:
	var sw := sub.x + 1
	_indices = PackedInt32Array()
	_indices.resize(sub.x * sub.y * 6)
	var i := 0
	for jy in sub.y:
		for ix in sub.x:
			var a := jy * sw + ix
			_indices[i] = a
			_indices[i + 1] = a + 1
			_indices[i + 2] = a + sw
			_indices[i + 3] = a + 1
			_indices[i + 4] = a + sw + 1
			_indices[i + 5] = a + sw
			i += 6
	_idx_for = sub
