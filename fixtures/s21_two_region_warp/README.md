# The regression fixture — two hand-authored regions with non-identity warps

**Frozen pre-content-transform reference for `PER_REGION_WARP_CONTENT_FIT.md` §5/§6.**
Authored by hand on the Pixel 8 on 2026-07-26 (Session 21), with the BenQ PD2700U live
via DUAL·TEX. Replaces the Session-20 fixture, which was lost — see
`../s21_pre_content_fit/README.md`.

## Why this one is usable

Both regions carry **genuinely non-identity `warp_corners`** at QUAD, measured against
their own bounding-box domain (the Phase 2b domain, `170d477`):

| region | mask | domain (output px) | max deviation from identity |
|---|---|---|---|
| `region_0` | 3-pt triangle | x=140 y=219 w=784 h=490 | **347 px** |
| `region_1` | 4-pt quad | x=1068 y=243 w=628 h=482 | **387 px** |

That matters: an identity fixture would pass a round-trip check trivially and prove
nothing. These deform hard enough that any error in the content-transform work — a wrong
pivot, a fit-mode jump, a domain-anchoring slip — shows up as visible movement.

Both are QUAD (`warp_mesh=false`, `warp_offsets` empty), so they exercise the homography
path. Neither has a per-region clip or effect (`clip=""`, `effect=0`), and both sit at
`scale=1.0` / `offset=(0,0)` — i.e. the **default content transform**, which is exactly
what §5 requires: "defaults reproducing today's fit-to-bbox behaviour — verify
pixel-identical".

## Contents

| file | what |
|---|---|
| `regions.cfg` | **the fixture** — 2 regions, non-identity QUAD warps |
| `warp.cfg` | global output warp, slot 1 = identity MESH 8×8 (unchanged all session) |
| `settings.cfg` | deck settings as captured |
| `phone_2400x1080.png` | phone preview — nav reads `2 MASKS`, both regions visible |
| `hdmi_2560x1440.png` | **BenQ PD2700U via DUAL·TEX** — both regions compositing, no chrome |

## How to use it for §5/§6

1. Push `regions.cfg` to `files/regions.cfg` (or restore by hand), cold-start.
2. It must load and render **pixel-identical** to `hdmi_2560x1440.png` / `phone_2400x1080.png`
   before any content-transform code runs.
3. After the transform lands with default values, re-render and diff. Any difference is a
   regression — the defaults are specified to reproduce today's behaviour exactly.

⚠️ **Diff the geometry, not the pixels.** The deck was in SEQ and advancing, so the two
captures here are of *different video frames* — the phone shows `D2_pops_texsam_30s_1080_07.mp4`,
the HDMI capture a later clip. Comparing "covered pixel" counts between captures of
different frames is the invalid method PROJECT_STATE records burning hours on. Freeze the
deck in **MANUAL** before any comparison, and prefer ground truth against the polygons in
`regions.cfg`.

## Capture conditions

- Display: **DUAL·TEX**, bridge `blit 56–58 fps, swap avg 0.6–0.8 ms, interval=0,
  tex=23 1920x1080 -> 2560x1440`. Output basis stays 1920×1080; the bridge scales to the link.
- ⚠️ `settings.cfg` here reads `dual_feed=0` (PLAYER) — that is a **stale flush**, not the
  live state. The bridge telemetry proves TEX was active. The previous battery death
  killed the app before it flushed `_settings_dirty`, so on-disk settings lag reality.
- ⚠️ **`FPS 22` in the phone capture is battery, not rendering.** Captured at 2% with the
  phone discharging (the USB-C port held the HDMI cable, so it could not charge). Do not
  read this as a per-region warp cost — Session 20 measured 52 fps with a real display
  attached under a heavier configuration.

## ⚠️ `screencap` on the Presentation surface is unreliable

Earlier this session, three consecutive `screencap -p -d <hdmi-id>` calls returned
**byte-identical flat black** (17,878 bytes) while the bridge logged 60 fps and the user
confirmed the monitor was showing the pipeline correctly. The same command had worked
minutes before and worked again afterwards (this capture, 288 KB of real content).

Cause unknown. It is **not** a reliable liveness signal for the external display — a black
capture does not mean a black monitor. Trust the `EglBridge` telemetry plus a human
eyeball; treat a black capture as "try again", not as evidence of failure.
