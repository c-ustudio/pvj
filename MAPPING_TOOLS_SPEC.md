# PocketVJ — Mapping Tools (spec / backlog)

**Status (2026-10-02, Session 37):** the mask editor gained the tools found missing on a real object
(the octahedron test) — nudge pad, CHECKER, FIT, per-mask clip lists with NEXT, LOCAL/DECK — see **§8**
and `SESSION_37_NOTES.md` (`f382c16`). The NUM panel was removed. Known-object mapping is noted in §8.4.

**Status (updated 2026-07-26, Session 19):** this spec predates four shipped changes that affect it.
**#3 is now MOSTLY SHIPPED:** Option C (true homography) in Session 18 (`dae278f`), and **§3(a), the N×M grid
mesh warp, in Session 19** (`ce07e23`) — default 3×3, selectable 2×2…8×8, QUAD kept alongside. What remains of
#3 is **§3(b), the Bézier/Coons mode**. See §3 below, `SESSION_18_NOTES.md` and `SESSION_19_NOTES.md`.
**#2 (raster masks) SHIPPED in Session 16** (`MaskOverlay` + `raster_mask.gdshader`, Library ▸ MASK IMAGE,
persisted in `regions.cfg [raster_mask]`; composes with polygon masks — projector-verified). **Session 17
shipped the routing precondition**: `RegionCompositor` renders into **MaskWorld**, a pre-warp SubViewport
QuadWarp samples whenever masks own the output — so **warp now applies to masked composites** (it used to be
bypassed entirely when regions existed, the old S8 routing). Output also reaches the projector at native res
via **DUAL·TEX** (Session 14), which this spec also predates. #1 / #3 / #4 remain open.
**Scope:** four independent items. None of them touch `ClipEngine` or the decode path — that stays settled.

Ordered by payoff-per-effort, not by size:

| # | Item | Effort | Depends on |
|---|---|---|---|
| 1 | Ping-pong playback | XS | nothing |
| 2 | ~~Image-as-mask (raster)~~ ✅ shipped S16 | S | nothing |
| 3 | Mesh / Bézier warp — **Option C ✅ S18, grid mesh (a) ✅ S19**; only Bézier (b) open | M | nothing |
| 4 | Contour tracing (camera-assisted masking) | M–L | shares raster→polygon path with #2 |

Each is shippable alone. Do them in any order; the table is a suggestion.

---

## 1. Ping-pong playback

**What:** play a clip forward, then in reverse, forever. Makes **any** clip loop seamlessly regardless of whether its first and last frames match — an immediate improvement to every clip in the library, not just new ones.

**The catch:** GoZen decodes forward (FFmpeg). Reverse playback at runtime means either backward seeking (expensive, will stutter) or holding decoded frames in memory. **Verify first** whether GoZen supports a negative playback rate or cheap backward seek. Assume it does not.

**Recommended implementation — offline, zero runtime cost:**

```bash
ffmpeg -i in.mp4 -filter_complex "[0:v]reverse[r];[0:v][r]concat=n=2:v=1[out]" \
  -map "[out]" -c:v libx264 -preset slow -b:v 7M -an -g 30 -movflags +faststart pingpong.mp4
```

The result is an ordinary file that loops seamlessly with **no engine changes at all**. A 10 s clip becomes a 20 s clip.

**Cost to note:** doubles duration and file size, and therefore roughly doubles bits parsed → demux time rises. Given the measured budget (≈195 ms typical / 251 ms worst at ~11 Mbps), **encode ping-pong clips at 6–7 Mbps** to stay inside cue lead. See `PROJECT_STATE.md` clip-library section.

**If GoZen turns out to support it at runtime:** a per-clip PING-PONG toggle is nicer UX (no storage cost, switchable live) and would be worth the swap. Test before building the offline path into a workflow.

---

## 2. Image-as-mask (raster masks)

**What:** load a PNG/JPG from device storage and use it as an alpha mask over the deck output. Complements the existing **polygon** mask system — a raster mask does soft edges, gradients, logos, textures, and organic shapes that a point polygon can't.

**Implementation:** a texture uniform multiplied against the composited deck output, applied at the same stage as `RegionCompositor`. Trivial compared to polygon masks — no editor, no point math.

- File picker: reuse `local_browser_ui.gd`'s breadcrumb pattern (already browses device storage).
- Store imported masks at `/storage/emulated/0/PocketVJ/masks/` — see §5 on why not `user://`.
- Controls worth having: invert, opacity, and fit mode (stretch / fit / fill), since mask aspect rarely matches output.
- Persist the chosen mask path in the existing settings/regions config alongside polygon masks.

**Second use:** an imported image can also be fed to the contour tracer (§4) to produce an **editable polygon** instead of a fixed raster — same code path, different output. Worth designing #2 and #4 to share it.

---

## 3. Mesh / Bézier warp

**The gap:** `QuadWarp` is a 4-corner warp — it handles flat rectangles and nothing else. Real venues have curved walls, arches, cylinders, cloth, and irregular surfaces. This is the single biggest capability jump in this document.

**FIRST TASK of the mesh-warp session — Option C, true homography. ✅ SHIPPED in Session 18** (`dae278f`,
Pixel-8 verified). `QuadWarp` was a `Polygon2D` quad — two triangles with affine UV interpolation — so on a
strong keystone straight content lines kinked across the diagonal. It is now a **`MeshInstance2D` + `ArrayMesh`,
24×24, with every vertex pushed through the exact unit-square→quad homography** (Heckbert closed form),
subdivided in SOURCE space so the vertices land exactly on the true perspective map. The dense-subdivision
route was taken over per-vertex `w` precisely because **the mesh renderer subsumes the quad case** — (a) and
(b) below now need only a control lattice in place of the 4 corners, not a new renderer. Both Session-17
constraints held: `set_source(texture)` is unchanged (`_refresh_output_source()` is still the one caller), and
the fix benefits masked output — verified with `[route] quad_warp <- MaskWorld`. The S16 test grid was indeed
the acceptance test: at TL(500,200) the centre circle went from **two mismatched arcs to one continuous conic**,
and a tracked grid row is straight to **max dev 3.57 px / RMS 0.63 px**. Legacy `warp.cfg` presets load
unchanged (explicitly verified: a preset written by the affine build, loaded by the mesh build). See
`SESSION_18_NOTES.md`.

**Two modes, both worth having:**

**(a) Grid mesh warp — ✅ SHIPPED in Session 19** (`ce07e23`, Pixel-8 verified). An N×M lattice of control
points, default **3×3**, selectable **2×2…8×8**. Drag any point; the surface deforms. Best for irregular and
freeform surfaces.

**How it actually works — homography + OFFSETS**, which is worth recording because two more obvious designs
are wrong. `corners` still defines the homography H; each control point has a REST position H(u_i,v_j) and
stores an OFFSET from it, and the surface is `S(u,v) = H(u,v) + bilinear_blend_of_offsets(u,v)`. That gives,
by construction: **2×2 with zero offsets IS the plain homography** (the lattice corners ARE the quad corners,
so their offsets are pinned to zero — QUAD is simply the 2×2 member of the family, and a legacy 4-corner slot
loads as exactly that); and **dragging a corner re-keystones the whole surface**, since the interior rest
positions move with H while the deformation rides along.

⚠️ **A homography PER CONTROL CELL would TEAR.** Two adjacent cells agree on a shared edge's endpoints but not
on the projective parameterization between them, so the texture jumps at every cell boundary. Blending an
offset FIELD over one global homography is C0 everywhere. ⚠️ **Plain bilinear over the control points** would
fail the other requirement — it is not a homography at 2×2, so it could not be a pixel-identical superset.

Density changes RESAMPLE the offset field, so 3×3 → 8×8 keeps the shape instead of discarding the work.

**(b) Bézier quad — STILL OPEN, and now a contained change.** 4 corners plus 2 tangent handles per edge (8 handles), interior filled as a Coons patch. Fewer controls, smooth curvature. Best for cylinders, arches, and anything genuinely curved. The S19 renderer already consumes an offset FIELD over the homography, so this is a matter of swapping the bilinear blend for a smooth one (and giving the editor tangent handles) rather than a new renderer. Bilinear was chosen for (a) deliberately — the crease at a control line is the right feel for 'drag a point, that region moves'.

**Rendering:** replace the current final-stage quad with an `ArrayMesh` (or `RenderingServer.canvas_item_add_triangle_array`) — subdivide into triangles, UVs sampled from the composited texture. One mesh draw instead of one quad draw; performance impact negligible.

**The one real gotcha — perspective correctness. ✅ SOLVED in S18** — the renderer already carries the exact homography per vertex, so (a) and (b) inherit it; what follows is the original reasoning, kept because it explains the density choice (`SUBDIV = 24`). Naively subdividing a quad and interpolating UVs linearly gives **affine texture distortion**: straight lines in the source bend visibly, worst on strong keystone angles. Two fixes: subdivide densely enough (≈20×20 for the render mesh, independent of the *control* grid density) that the error is sub-pixel, or carry a per-vertex `w` and interpolate perspective-correctly. Dense subdivision is simpler and cheap at these sizes — start there and only do the maths if artifacts show.

**Backwards compatibility (✅ verified S18 and again S19):** the six existing `user://warp.cfg` presets must keep loading. Treat a legacy 4-corner preset as a 2×2 grid with no handle offsets — it should produce a pixel-identical result to today. **Verify this explicitly**; the warp slots are performance-critical state.

**UI — ✅ done for (a) in S19.** The `WarpEditor` + `m8_editor_chrome.gd` pattern was kept and the editor became
LATTICE-BASED rather than corner-based, so QUAD is not a special case. Bar is now
`SLOT | SAVE | LOAD | RESET | QUAD·MESH | 2x2…8x8 | NUM | GRID`; the nudge pad, the selected-point ring and
per-point numeric entry all extend to any control point. Still open: per-point reset (RESET is all-or-nothing),
a BÉZIER entry on the mode cell, and non-square lattices (the model carries `cols`/`rows` independently — only
the selector is square).

⚠️ **Two phone hazards this surfaced, both fixed — do not regress them.** (1) `GRAB_RADIUS` as a FLAT constant
is wrong for a lattice: at 8×8 on the Pixel 8 the control points are only ~165 screen px apart horizontally and
~93 vertically, so the old 150 px radius made every tap ambiguous. It is now capped at just under half the
neighbour spacing and floored at `MIN_GRAB`. (2) **A lattice puts control points UNDER the nudge pad** — a 3×3
grid's right-edge midpoint lands dead centre on it, the same "handles unreachable under the toolbar" failure the
S15 mask pass fixed. The pad can now be FLIPPED to the other side (the `◄►` cell). Verified on device: pad
right, the tap is eaten by the pad; pad left, it selects the point.

---

## 4. Contour tracing — camera-assisted masking

**Frame it as an assist, not automation.** The camera produces a *rough* polygon; you drag the points to finish. That's achievable and genuinely useful. One-tap perfect masking is not.

**Reduced need since S16:** image masks already cover much of what tracing was for — a matte photographed or authored externally loads directly as a raster mask (soft edges included, which a traced polygon can't do). Contour tracing only earns its keep when the result must be an **editable polygon** (per-mask video/FX, vertex tweaks). Re-weigh this item against #3 before starting it.

**Pipeline:**

1. **Freeze frame** — `camera_engine.gd` and `camera_ycbcr.gdshader` already exist; capture to a static `ImageTexture`.
2. **Edge / threshold shader** — Sobel-style gradient magnitude → binary. One pass on a frozen frame, **not per-frame** — cheap. Expose threshold, contrast, and invert as live sliders (real rooms have bad lighting; these need tuning by eye).
3. **Readback** — `get_texture().get_image()`, a GPU→CPU sync of ~10–30 ms. **One-shot only, never per-frame.** Do it on an explicit user action, and downsample the analysis viewport (720p is plenty) to keep it quick.
4. **Trace** — seed-based is the better UX: user taps the object, flood-fill the connected region, then trace its boundary (marching squares). Tap-to-seed also sidesteps "which of the 40 contours did you mean?"
5. **Simplify** — Douglas–Peucker, epsilon on a **DETAIL** slider. Target 8–40 points. This is what makes the result editable rather than a 3,000-point blob.
6. **Hand off** — emit normalized 0..1 points in `RegionEditor`'s existing polygon format, land it as a selected mask, and let the user drag vertices. It becomes an ordinary mask from that moment on: persisted in `regions.cfg`, per-mask clip assignment, all existing behaviour.

**Steps 4–5 are the actual work.** The shader is the easy part; the doc that inspired this skips the raster→polygon conversion entirely.

**Viewpoint caveat:** the phone camera is not where the projector is, so the traced outline is the object's silhouette *from the phone*. For 2D masking this is forgiving — you hand-adjust afterwards — but results are best with the phone held as close to the projector's optical axis as possible. Say so in the UI hint.

**Explicitly out of scope: 3D volumetric mapping.** Generating a mesh from silhouettes requires projector-camera calibration (position, lens, throw) to be useful for projection, which is the hard problem real 3D mapping tools solve with structured light or lengthy manual alignment. Without it you get an accurate mesh you cannot project onto accurately. Revisit only for a fixed installation where calibration can be done once and left alone.

---

## 5. Export — masks and reference frames

**For generative video (Veo and similar) and for reuse.**

Export two aligned PNGs on demand:
- `frame_reference.png` — the camera snapshot of the target surface
- `object_mask.png` — the binary mask (rasterize polygon masks for this)

**Write to `/storage/emulated/0/PocketVJ/exports/`, not `user://`.** On Android `user://` is app-private and effectively invisible to other apps and to the file manager — an export nobody can reach isn't an export. The clip library already lives at `/storage/emulated/0/PocketVJ/clips/`, so exports belong alongside it. An Android share intent would be nicer still, but the public folder is the zero-plugin version and works today.

**Round trip:** generated clips come back into the library as ordinary files, and §1's ping-pong encode makes them loop cleanly. Prompt hint worth putting in the docs rather than the app: specify continuous motion and seamless-loop intent, and mask the region you want filled.

---

## 6. Performance notes

- Nothing here touches `ClipEngine`. The decode path stays settled.
- Warp mesh: replaces an existing draw. Negligible.
- Edge detection: one-shot on a frozen frame, downsampled. Negligible.
- Contour trace: one-shot CPU work behind an explicit user action. Show a busy state; do not run it in `_process`.
- Raster mask: one texture uniform + a multiply. Free.
- **Ping-pong is the only item with a real ongoing cost** — doubled duration means doubled bits parsed at load, so it eats cue-lead budget. Encode at 6–7 Mbps.

---

## 7. Open questions

- ~~Should mesh warp replace `QuadWarp` outright, or sit as a mode alongside it?~~ **Answered S19: BOTH, without duplication.** MESH is a mode on the same node, and QUAD is the 2×2 member of the same lattice family rather than a parallel code path — so there is one renderer and one editor, and QUAD stays the default. Legacy presets verified loading identically (a slot written by the S18 build, loaded by the S19 build). `set_source()` is untouched, so `_refresh_output_source()` and the MaskWorld routing are unchanged.
- ~~Do raster masks and polygon masks compose, or is it one or the other?~~ **Answered S16: they compose.** `MaskOverlay` multiplies the composited output (topmost OutputWorld child, post-warp — correct for edge blending, which is projector-space); polygon masks shape the content pre-warp in MaskWorld (S17).
- Per-mask ping-pong, or per-clip? Per-clip is simpler and probably right.
- Is the camera assist worth it if the phone must be near the projector axis anyway? Try the manual polygon workflow on a real surface first — it may already be fast enough, in which case #3 and #2 matter more than #4.

---

## 8. Mask editor tools — SHIPPED 2026-10-02 (Session 37, `f382c16`)

Built the day after mapping a cardboard octahedron with triangle masks. Details, decisions and device
findings are in `SESSION_37_NOTES.md`; this section is the reference for what each tool *is*.

### 8.1 Placing points exactly — the nudge pad (EDIT)
The warp editor's pad pointed at the **selected point** of the selected mask: 10 / 1 output px per
step, hold-to-repeat, centre cell cycles P1..Pn, ◄► flips it beside ADD PT / DEL PT. A grab or an
ADD PT selects a point. The point is boxed twice on the phone and on the projector (MaskGuides), and
the projector crosshair follows it while an arrow is held. Steps are in output px, so 1 px is one
projector pixel before the global warp.

### 8.2 Seeing the perspective — CHECKER
`RegionCompositor.checker` replaces every mask's clip and effect with `shaders/mask_checker.gdshader`,
drawn with an identity UV — i.e. across the region warp's **parameter square** — so the board bends
exactly as the warp bends content. Square cells and straight rows on the object mean the warp is
right. Reachable from the mask editor (CHECKER cell) and from the region-warp editor (GRID). Not saved;
cleared when the mask editor closes, so it cannot be left on stage. (The frame-wide GridOverlay could
never answer this: it sits over MaskWorld unwarped by any region.)

### 8.3 Getting the perspective — FIT
`RegionCompositor.fit_warp_to_mask` / `fit_quad`:
- **4 points:** the warp's TL/TR/BR/BL are the mask's points (wound clockwise, started nearest the
  top-left), so content lands in the face's exact perspective.
- **3 points:** three correspondences pin only an affine map. FIT stands the content upright on the
  flattest edge (the parallelogram on that base reaching the apex). Right for small or face-on
  triangles; increasingly off as the face turns away.
- Other counts: refused with a hint. A hand-adjusted warp is confirmed before it is replaced.

### 8.4 Not built: exact perspective on triangles (known-object mapping)
A planar face's projector image is a homography, which needs 4 correspondences — a triangle has 3.
With the object's 3D shape known (octahedron, cube), the vertices the operator already taps while
drawing masks give ≥ 6 point correspondences, enough to solve the projector's pose (DLT/PnP). Every
face then gets an exact homography, and content can flow across faces as one picture. No camera
needed. Estimated at a few days, mostly the UI for saying which tapped corner is which model vertex.
Post-beta. The camera-finds-the-faces version is `SHAPE_MAPPING_SPEC.md`.

### 8.5 Clips on masks — lists, NEXT, LOCAL/DECK
- **Lists (manual sequence v1):** VIDEO's picker builds a per-mask list (`[n]` = position, `►` =
  playing; tap a listed clip to remove it; FOLLOW DECK clears). Persisted as `clips` + `clip_pos`.
- **NEXT:** selected mask → that mask; nothing selected → every mask. A list steps in order; a mask
  without a list steps to the next clip in the folder. Playing a clip that is not on the list ends
  the list.
- **One decoder per mask:** a step reopens it (worker-thread open). Seamless steps would need two
  decoders per mask and halve `MAX_DECODERS`' effective mask count (6 → 3); deferred. Not yet watched
  frame by frame on the projector (hold vs. black).
- **LOCAL / DECK:** `follow_deck_all` — all masks sample the deck's shared source; own decoders pause
  and their SubViewports go `UPDATE_DISABLED`, so DECK is never dearer than LOCAL. Persisted as
  `[regions] follow_deck`.

### 8.6 Open
- Masks low on the object sit under the bottom toolbar; a tap there hits a cell.
- NEXT and LOCAL/DECK live only in the mask bar; mid-set use means opening MSK with GUIDES off.
- The nudge pad is a copy of the warp editor's; one shared `NudgePad` would remove the duplication.
