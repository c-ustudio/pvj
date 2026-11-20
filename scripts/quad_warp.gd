class_name QuadWarp
extends MeshInstance2D
## Stage 3 / Output of the PocketVJ pipeline — the GLOBAL output warp.
##
## Since per-region warp (Session 20) the mapping is TWO-LEVEL, and this node is
## the outer level: it aligns the WHOLE projection to the physical screen, and
## it stays the last stage of OutputWorld. Per-region warps live inside
## MaskWorld and map individual surfaces WITHIN that aligned frame. The two are
## deliberately not collapsed — the global warp is a property of where the
## projector sits, so folding it into the regions would mean re-warping every
## surface each time the projector moves.
##
## All the maths now lives in WarpSurface, shared with those per-region warps;
## this node is the scene-facing shell around one of them. Behaviour is
## unchanged from S18/S19 — the two modes are still:
##   QUAD (Session 18) — 4 draggable corners, mapped by a true HOMOGRAPHY.
##   MESH (Session 19) — an NxM lattice of control points on top of that
##                       homography, for curved and irregular surfaces.
## Corner order is 0=top-left, 1=top-right, 2=bottom-right, 3=bottom-left.
## See WarpSurface for the surface model and why it is shaped that way.
##
## Public contract, unchanged since the Polygon2D original: set_source(),
## fill_rect(), set_corner() and `corners`. Mesh UVs are NORMALIZED, so nothing
## needs re-pointing when a source viewport resizes (see pipeline._apply_quality).

# Re-exported so existing callers keep saying QuadWarp.MIN_GRID / MAX_GRID.
const RENDER_TARGET := WarpSurface.RENDER_TARGET
const MIN_GRID := WarpSurface.MIN_GRID
const MAX_GRID := WarpSurface.MAX_GRID
const DEFAULT_GRID := WarpSurface.DEFAULT_GRID

## The warp model this node renders. Exposed so the warp editor (and, later, a
## region) can be pointed at a surface directly.
var surface := WarpSurface.new()

# Read-only views onto the model, kept because callers already read them as
# plain fields (`quad.corners`, `quad.mesh_mode`, ...). Every MUTATION goes
# through a method below, which is what lets this node rebuild reliably.
var corners: PackedVector2Array:
	get: return surface.corners
var offsets: PackedVector2Array:
	get: return surface.offsets
var grid_cols: int:
	get: return surface.grid_cols
var grid_rows: int:
	get: return surface.grid_rows
var mesh_mode: bool:
	get: return surface.mesh_mode

var _mesh: ArrayMesh


## Set the texture to display (the previous stage's output).
func set_source(tex: Texture2D) -> void:
	texture = tex


# --- mutators (delegate, then rebuild) -----------------------------------

func fill_rect(rect_size: Vector2) -> void:
	surface.fill_rect(rect_size)
	_rebuild()


func reset_all(rect_size: Vector2) -> void:
	surface.reset_all(rect_size)
	_rebuild()


func set_corner(index: int, pos: Vector2) -> void:
	surface.set_corner(index, pos)
	_rebuild()


func set_control_point(idx: int, pos: Vector2) -> void:
	surface.set_control_point(idx, pos)
	_rebuild()


func set_mesh_mode(on: bool) -> void:
	surface.set_mesh_mode(on)
	_rebuild()


func set_grid_size(cols: int, rows: int) -> void:
	surface.set_grid_size(cols, rows)
	_rebuild()


func restore_state(state: Dictionary) -> void:
	surface.restore_state(state)
	_rebuild()


# --- queries (pure delegation) -------------------------------------------

func edit_cols() -> int:
	return surface.edit_cols()


func edit_rows() -> int:
	return surface.edit_rows()


func point_count() -> int:
	return surface.point_count()


func corner_of_index(idx: int) -> int:
	return surface.corner_of_index(idx)


func point_uv(idx: int) -> Vector2:
	return surface.point_uv(idx)


func control_rest(idx: int) -> Vector2:
	return surface.control_rest(idx)


func control_point(idx: int) -> Vector2:
	return surface.control_point(idx)


func surface_point(u: float, v: float) -> Vector2:
	return surface.surface_point(u, v)


func capture_state() -> Dictionary:
	return surface.capture_state()


# --- persistence ---------------------------------------------------------
# Forwarded rather than letting callers touch `surface` directly, so a load can
# never leave the rendered mesh stale behind the model.

func save_to(cfg: ConfigFile, section: String, out_size: Vector2) -> void:
	surface.save_to(cfg, section, out_size)


func load_from(cfg: ConfigFile, section: String, out_size: Vector2) -> bool:
	if not surface.load_from(cfg, section, out_size):
		return false
	_rebuild()
	return true


## Re-render after something mutated `surface` directly — the hook the warp
## editor holds, so it can drive the global warp and a region's warp through the
## one WarpSurface contract without knowing which it has.
func rebuild() -> void:
	_rebuild()


func _rebuild() -> void:
	if _mesh == null:
		_mesh = ArrayMesh.new()
		mesh = _mesh
	surface.build_into(_mesh)
