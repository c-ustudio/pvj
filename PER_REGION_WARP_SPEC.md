# PocketVJ — Per-Region Warp (spec / next session)

**Status:** not started. The last core mapping feature. Turns PocketVJ from "one global warp" into a real projection mapper.

**Prerequisites, both landed:** MaskWorld SubViewport (Option A — masks flow through warp), and the mesh grid warp (homography base + N×M draggable grid). This spec ties them together.

---

## 0. The idea, stated cleanly

Today: **one** global warp for the whole output; masks define shape but every region shares the same keystone/mesh.

Target: each region is a **surface** = a *shape* (mask) + a *transform* (warp), stacked. Map three faces of a box, or two separate walls, each with its own outline and its own geometry. This is the MadMapper / Resolume Arena abstraction.

**Warp and mask are orthogonal axes — do not merge them:**
- **Mask** = what shape shows through (the surface's silhouette). Polygon *or* raster image.
- **Warp** = how content is bent to sit on that surface (keystone / curve / mesh).

A real mapped surface needs both, independently adjustable. The **region** is the container that owns both. So the raster image mask stays a mask (it already is one) — the work is making mask *and* warp both per-region.

---

## 1. Data model

A `Region` (surface) owns:
- `shape`: polygon points **or** a raster image mask (greyscale PNG) + fit/invert/opacity — the existing two mask kinds, now per-region
- `warp`: its own mesh grid (control points, grid density) — defaulting to identity (full-rect, no deformation)
- `content`: the existing per-mask video/FX assignment
- `id`, `name`, enabled flag

The current global QuadWarp/mesh becomes **the default region's warp** when no explicit regions exist — so a project with no masks still warps exactly as today (strict superset, verify pixel-identical).

Persistence: extend `regions.cfg`. Each region serializes its shape + warp + content. **Load-then-merge on every write** — this file has burned us twice (autoload wipe, `_save()` clobber); every writer must merge, never fresh-write.

---

## 2. Rendering

Per region, in order: sample the deck (+ per-region FX) → apply the region's **mesh warp** → mask to the region's **shape** → composite onto the output. Regions stack (painter's order; later decision: explicit z-order vs creation order).

This is a real change from the single MaskWorld → single QuadWarp chain. Options to weigh in the plan:
- **A — per-region viewport + warp pass, composited.** Cleanest conceptually; cost is N viewports/passes. Fine for a few surfaces; measure at 3–4 regions on the Pixel 8's G3.
- **B — single pass, per-region warp baked into the composite shader.** Cheaper, hairier maths. Probably premature.

Recommend A for correctness first; optimize only if the region count that matters exceeds the budget. **Get the fps number for one dense mesh before building N of them** — that bounds how many surfaces are realistic.

## 3. Editor UX (where it lives or dies on a phone)

- **Region list / selector** — pick the active surface; its mask and warp become editable. The single hardest UX question: switching between surfaces on a small screen without clutter. Reuse the Session-15/16 pattern (fade chrome, submenus).
- Editing a region shows **its** mask handles and **its** warp grid — reuse the existing mask editor and mesh warp editor, scoped to the selected region.
- Add / duplicate / delete a region. Duplicate is valuable — mapping several similar faces.
- The **preview-swaps-to-pre-warp** rule (from Option A) still applies while editing a region's mask.

## 4. Compatibility (verify explicitly)

- Existing `regions.cfg` (polygon masks, the single raster mask, per-mask content) must load — each becomes a region with identity warp.
- Existing `warp.cfg` slots (global 4-corner / mesh) — decide: do they become the default region's warp, or a global post-composite warp applied to the stacked result? **A global final warp on top of per-region warps is probably wanted** (align the whole projection to the screen, then map surfaces within it). Worth confirming the two-level model (global output warp + per-region warps) rather than collapsing to one.

---

## 5. Owed from prior sessions (batch when 9a + HDMI is cabled)

- **Projector eyeball:** homography straightness under keystone; mesh smoothness at 5×5 / 8×8 on a real curved surface (faceting check).
- **fps at max grid density** on the Pixel 8 G3 — needed before N regions each with a mesh.
- Per-region warp is the feature you most want to *see* on the projector (mapping separate real surfaces) — this may be the session to finally cable the 9a and close all owed eyeballs at once.

---

## 6. After this

Mapping is complete: homography ✓, mesh ✓, masks-through-warp ✓, per-region ✓. Then the fork — audio reactivity, Phase 2 dual deck, or the Play beta (with its storage-permission + dev-account blockers, and the DUAL·TEX-beyond-the-9a robustness pass).
