# Per-Region Warp — Content Fit & Content Transform (Phase 2 addendum)

**Append to / replaces the earlier content-fit note in `PER_REGION_WARP_SPEC.md`.** Build after Phase 2b (region-scoped mesh editor with bounding-box domain — DONE, `170d477`). This increment makes per-region warp a *complete* mapping tool: you can position the content inside a surface, not only deform the surface.

*Revised after a code read of the Phase 2b seam. Corrections are marked ✅ CORRECTED and carry the file/line they were checked against.*

---

## 0. PREMISE CORRECTIONS (read first)

**(a) `MASK_BOUNDS` ≈ current behaviour; `FULL_FRAME` is the new mapping.** The earlier note had this backwards. `_apply_uv`/`_uv_at` have *always* fitted each clip into its mask's bounding box, so today's *content* behaviour is already `MASK_BOUNDS`-like — only the *warp* was full-frame (fixed in Phase 2b: the warp now spans the mask bbox too).

**(b) ✅ CORRECTED — the content transform ALREADY EXISTS. This increment is surface-and-retarget, not new machinery.** `RegionCompositor._uv_at()` already applies a per-region scale, offset and rotation:

```gdscript
var s: float     = r["scale"]    # pinch            (S15 gesture)
var off: Vector2 = r["offset"]   # two-finger pan   (S15 gesture)
var ang: float   = r["angle"]    # bumped by rotate_region()
...
centered = centered.rotated(-ang);  return center + centered / s + off
```

and `region_editor.gd:325-327` already drives `set_tex_scale()` / `set_offset()` from pinch and two-finger pan, with double-tap calling `reset_transform()`. So §1's "there is no way to move the content within the warp" is not quite the gap. **The real gap:** the transform lives only in the *mask* editor, has **no numeric entry**, is **not reachable from warp mode** where you are actually aiming, cannot express non-uniform scale, and its rotation **is not persisted** (§5). Sizing: closer to Phase 2b (retarget existing controls) than to a new subsystem.

**(c) ✅ CORRECTED — `FULL_FRAME` is a one-line rect swap; it is NOT the bulk of the work.** §0 of the previous revision over-corrected in the opposite direction. The seam already names the two rects, and the mode is just which one `fit` is:

```gdscript
var fit := _bounds_of(pts)                      # MASK_BOUNDS (today)
var fit := Rect2(Vector2.ZERO, output_size)     # FULL_FRAME
```

Same shape as the domain swap Phase 2b already made. **The real work of the fit half is §2 items 1 and 2 below** (an explicit pivot, and domain-anchored parameters) — without those, `FULL_FRAME` is not merely new, it is broken.

---

## 1. The real gap the user hit

Warp mode today is **per-point deformation only** — drag vertices, content stretches to follow. To reposition a clip inside a mapped surface you are forced to drag warp points, which changes the *surface shape* — the wrong tool. The transform that would do it correctly exists (§0b) but is in the other editor and has no precise control.

Mapping tools (MadMapper, Resolume) separate two independent things:
- **Warp** = the surface's geometry (drag points) — *edit surface*
- **Content transform** = how the source sits inside that geometry (scale / offset / rotation / fit) — *edit content*

Both are needed to aim a clip at a real object.

---

## 2. The model: a per-region content transform between clip and warp

```
clip -> CONTENT TRANSFORM (scale, offset x/y, rotation, fit) -> WARP (surface shape) -> MASK -> composite -> global output warp
```

The content transform is the **general case**; fit modes are **presets** of it (`FILL` / `FIT` / `STRETCH` / `FULL_FRAME` / `MANUAL`). That shape is right and is already how the code works — the increment is completing it, not introducing it.

Mechanically this is a transform on `fit` (the rect the source is normalized against) before the `_uv_at()` sample. `dom` (`RegionCompositor.warp_domain(i)`) is untouched.

### The five things that must change

**1. ⚠️ Make the pivot EXPLICIT.** `center := Vector2(0.5, 0.5)` is expressed in `nrm` space — i.e. the centre of **`fit`**. Today `fit` is the mask bbox, so scale/rotate pivot on the region and it reads correctly. Under `FULL_FRAME`, `fit` becomes the whole frame, so `0.5,0.5` is the **frame** centre and zooming a small region's content swings it across the screen. The pivot must become a parameter (the region's centre expressed in the current normalization space), decoupled from whichever rect is being normalized against. **This is the actual work of `FULL_FRAME`, not the sampling change.**

**2. ⚠️ Anchor the parameters to the DOMAIN, not to `fit`.** `offset` is currently in units of `fit`. Switch `MASK_BOUNDS` → `FULL_FRAME` with a non-zero offset and the same `0.1` goes from `0.1 × bbox` to `0.1 × 1920` — the content visibly **jumps** on a mode toggle. Anchor offset (and pivot) to `warp_domain(i)`, which is stable across fit modes, or explicitly re-normalize on switch. A silent jump on a mode button is exactly the "looks correct until you touch it" failure this spec exists to avoid.

**3. ⚠️ `scale` must become a `Vector2`.** It is a scalar today, so `STRETCH` (non-uniform) is not expressible. This also widens the on-disk `scale` float — a persistence change, not just a type change. Keep reading a legacy scalar as `Vector2(s, s)`.

**4. ⏭️ DEFERRED TO ITS OWN SESSION — the aspect presets are NOT in the content-transform increment.** `FILL` / `FIT` / `STRETCH` and item 5's mode-plus-delta model were held back deliberately; the increment shipped `MANUAL` (today's fit-to-bbox) and `FULL_FRAME` only. `ContentFit` is nevertheless defined with all five values in this order, so the on-disk `content_fit` int can never renumber when they land. **What that session must decide first — do not start it without answering this:**

> 🔴 **`FIT`'s letterbox does not exist yet, and cannot be had for free.** `FIT` means sampling a UV rect *larger* than `[0,1]²`, and a CanvasItem texture **clamps** outside that range — so the "bars" would be the edge row of pixels **smeared** outward, not black. Three options, none of them a one-liner: (a) a per-region `ShaderMaterial` that returns black outside `0..1` — but the region's material slot is already the per-region FX, so FX and letterbox would have to compose; (b) shrink the *geometry* instead of the UVs, so the mesh simply does not cover the bars — cleanest visually, but the mesh is the warp surface and the mask is the stencil, so it changes what `build_into` means; (c) declare `FIT` letterbox-free and document the smear. ⚠️ **The same wall already exists today** at `SCALE_MIN` (0.25): zooming content *out* samples 4× the fit rect and smears identically. Nobody has looked at it on a wall. Judge (c) against that before building (a) or (b).

**4b. ✅ CORRECTED — fit modes are simpler than assumed, because the source is ALWAYS 16:9.** `ClipEngine.DECODER_SIZE` is `1920x1080` and `RegionCompositor.DECODER_SIZE` is `1280x720`, both filled with `STRETCH_KEEP_ASPECT_COVERED`. The clip's real aspect is absorbed upstream and **never reaches `_uv_at`**. Consequences:
   - `FILL` / `FIT` / `STRETCH` depend only on the **mask bbox aspect**, never on the clip.
   - They therefore need recomputing on **mask edit**, not on clip switch — and mask edits already funnel through `_apply_points() -> rebuild_mesh()`, so a live fit mode recomputes **for free**.
   - `FIT`'s letterboxing is against the 16:9 stage texture, not the original clip's framing. Say so in the UI wording if it ever matters.

**5. ⚠️ Store `fit_mode` AND a manual delta — do NOT flip to `MANUAL` on hand-adjust.** Flipping freezes the fit, so the next mask reshape quietly un-fits content the user believed was pinned. Because re-fit is free (item 4), keep them separate:

```
effective transform = fit(fit_mode, bbox_aspect) ∘ manual_delta
```

Tapping a preset sets `fit_mode` and clears the delta; hand-adjusting accumulates into the delta and leaves the mode live. `MANUAL` stays available as an explicit mode meaning "no auto-fit".

### Persistence keys (per region, `regions.cfg`)

`content_scale` (**Vector2**), `content_offset`, `content_rotation`, `content_pivot`, `content_fit` (enum `MANUAL / FILL / FIT / STRETCH / FULL_FRAME`). All default to the values reproducing **today's** fit-to-bbox behaviour — verify pixel-identical.

---

## 2b. ⚠️ A live persistence bug to fix HERE

`RegionEditor._save()` writes only `points`, `effect`, `clip`, `scale`, `offset`, and the `warp_*` keys. **`angle`, `geo_scale` and `geo_rot` are never written.** So today, rotating a mask bumps `angle` (rotating its content with it) and that rotation is **silently lost on restart**. Content rotation is a parameter of this increment, so this must be fixed as part of it — otherwise §6's "pixel-identical round-trip" cannot pass for any rotated region.

---

## 3. The UX: an edit-surface / edit-content sub-mode toggle

- **EDIT SURFACE** (current behaviour) — drag warp points, reshape geometry.
- **EDIT CONTENT** (new) — drag moves the content; pinch scales; NUM entry for exact scale/offset/rotation.

**✅ CORRECTED — the mode is the disambiguator; there is no gesture conflict to arbitrate.** The warp editor has **zero** gesture machinery (no `_touches`, no pinch, no `_gesture_cool`) — it is strictly one-finger-per-handle, and deliberately supports several fingers on several handles at once. The stated risk ("surface-drag and content-drag want the same gesture") dissolves if the mode simply changes what is grabbable. The genuine risk is **mode confusion**, and it is addressed by what is drawn, not by proximity heuristics — which are exactly what goes wrong on a phone.

- **⚠️ Hide the lattice handles entirely in EDIT CONTENT.** A stronger signal than any label: nothing looks draggable-as-geometry, so nothing suggests a drag reshapes. In that mode `_try_grab` should be a no-op.
- **Draw the pair.** The **dashed** bounds rect Phase 2b added stays fixed (the surface); a **solid** content rect moves inside it. Dashed = fixed extent, solid = the thing you are moving.
- **Retarget the nudge pad and NUM rather than adding controls.** The pad already does coarse/fine steps in output px and NUM already does numeric entry; pointing both at the transform is the same move Phase 2b made pointing the editor at a `WarpSurface`. That is most of §3's "NUM mirroring the per-corner panel" for free.
- **⚠️ Port `_gesture_cool` from `region_editor.gd:185`.** Lifting one finger out of a pinch otherwise lands as a one-finger delta and snaps the content. Extract it as a shared helper — it will then exist in two editors.
- Fit-mode buttons live in EDIT CONTENT.

---

## 4. Interaction with the two-level model

✅ **Confirmed against the code — the specced order already holds, no change needed.** UVs are a function of the lattice *parameter* (content), mesh vertices are the warp (surface), the `Polygon2D` clips, then `QuadWarp` applies globally:

1. clip → 2. **content transform** (this spec) → 3. region **warp** (`warp_domain(i)`) → 4. region **mask** → 5. composite → 6. **global output warp**, last, over everything.

---

## 5. Persistence & migration

- New keys per region, defaults = today's fitted behaviour. **Load-then-merge** (this file has been clobbered three times; every writer merges + erases sections above `count`).
- Fix the `angle` / `geo_scale` / `geo_rot` gap (§2b) in the same pass.
- Widen `scale` to `Vector2`, reading a legacy scalar as `Vector2(s, s)`.
- A pre-transform `regions.cfg` must round-trip and render **pixel-identical**. Verify against the real two-mask config — see §7 on snapshotting it first.

---

## 6. Verify

- EDIT CONTENT: scale/offset/rotate a region's clip *inside* a fixed mask+warp — surface shape and mask silhouette do not move, only the content.
- EDIT SURFACE still deforms geometry as before; the two sub-modes never cross-trigger from one drag.
- Fit presets each set the transform correctly; `FULL_FRAME` visibly samples the whole-frame composition, **and its pivot stays on the region** (§2 item 1).
- Toggling fit modes with a non-zero offset does **not** jump the content (§2 item 2).
- Reshape a mask with a live fit mode → content re-fits; with `MANUAL` → it does not.
- A rotated region survives a cold restart (§2b).
- Existing presets load unchanged, pixel-identical.
- Two regions, different transforms + fit modes, composite correctly on the external display via DUAL·TEX.

⚠️ **adb cannot do multitouch.** Pinch is hands-only — PROJECT_STATE already records S15's gestures as never finger-verified. Plan the device-verifiable path around the **nudge pad and NUM entry**, and treat pinch/two-finger as an eyes-and-hands item rather than something the build can lean on.

---

## 7. Order of work (settle before code)

**Step 0 — pin the drag-scale mismatch.** The mask editor's XFORM drag moved ~1:1 with screen px while the warp editor's drag scales by the preview factor. ⚠️ **Treat this as UNRESOLVED, not as a proven bug:** the two observations came from different sessions and the external display was attached for only one of them, which can change the preview layout `xform_provider` derives from. Settle it with one A/B **in a single state**, using the **nudge pad as the conversion-free reference** (it works in output px): compare a pad 10 px step against a 10-screen-px drag in each editor. If a drag disagrees with the pad by exactly the preview factor in one editor and not the other, that pins it. Do this **before** EDIT CONTENT's drag — a third draggable thing inheriting the wrong conversion will feel broken and be blamed on the new code.

**Step 1 — snapshot the fixture.** ⚠️ The two migrated warps are the **only non-identity per-region warps in existence** and they are the regression fixture §5/§6 depend on. Before any re-authoring, copy `regions.cfg` plus a phone and an external-display capture into the repo. Otherwise the fixture changes and there is no stable "before" left to prove pixel-identity against.

**Step 2 — projector eyeball of the migrated warps.** Phase 2b refitted them frame-space → bbox-space. Confirm they look right, or re-author. **This is genuinely blocking**, and for a sharper reason than checking the refit: re-authoring *after* the content transform lands means doing it twice, because the transform changes what "correct" looks like — a misalignment you would currently fix by dragging warp points is one you would then fix with content offset.

**Step 3 — build**, in this order: persistence fixes (§2b + `Vector2` scale) → explicit pivot + domain-anchored params → fit modes as live mode + delta → EDIT CONTENT sub-mode → `FULL_FRAME` (last; it is the one-line swap once the pivot is right).

**✅ STEP 3 DONE (Session 21)**, in that order minus the fit-preset layer, which was scoped out to its own session (§2 item 4's TODO):

| | commit |
|---|---|
| §2b persistence + `Vector2` scale | `1a9b9f7` |
| explicit pivot + domain-anchored params | `bbef1d5` |
| `TouchGestures` shared helper (§3) | `f8ca040` |
| EDIT CONTENT sub-mode (§3) | `35c9254` |
| `FULL_FRAME` | *this commit* |

⚠️ **The `_uv_at` restructure is the load-bearing change, and it is not the one the spec predicted.** §2 items 1 and 2 were written as two fixes (parameterize the pivot; re-anchor the offset). Doing them as *one* change of representation — work entirely in **output px** and normalize against `fit` only on the last line — makes both conditions hold by construction rather than by arithmetic care, and hands over two properties the spec did not ask for: a move is **1:1 in output px at any scale and rotation** (which is what makes the pad's "10 PX" honest), and rotation becomes a **true rotation** instead of shearing content on a non-square bbox.

⚠️ **§6's "pixel-identical" is verified by mapping equality, not by capture diffing** — `tools/verify_content_transform.gd`, headless, against the two-region fixture. The UVs decide every pixel, so equal mappings mean equal renders; and it sidesteps the trap this file's fixture README warns about (the deck is playing, so two captures are different video frames and covered-pixel counts between them are meaningless). 19 checks: defaults == the pre-transform expression to ≤5e-7 UV on both hand-authored regions, the 1:1 move across 9 scale×rotation combinations, rigid rotation, the pivot staying on the region in **both** fit modes, offset meaning nothing different after a mode toggle, and the EDIT CONTENT overlay agreeing with the mapping it draws.
