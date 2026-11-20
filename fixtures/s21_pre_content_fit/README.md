# Pre-content-transform snapshot — Session 21, Pixel 8

Taken 2026-07-26 against the Pixel 8 (over wireless adb,
Android 17) before any content-fit / content-transform work
(`PER_REGION_WARP_CONTENT_FIT.md` §7 Step 1).

## ⚠️ The regression fixture no longer exists

§7 Step 1 assumed the two migrated per-region warps were still on the device — "the
**only** non-identity per-region warps in existence". **They are not.** `regions.cfg` on
the device reads `count=0`, last written `2026-07-26 03:33` (end of Session 20). Every
`region_N` section was erased by the S20 `_save()` behaviour that prunes sections above
`count`. No copy survives:

- device app-private `files/` — only the `count=0` file
- `/sdcard/` — nothing
- this repo — nothing tracked before this commit

So the snapshot below records an **empty** mask config, not the fixture. What is
unrecoverable is the *Phase 2b migration* evidence (frame-space → bbox-space refit),
which was verified on device in Session 20 and cannot be re-verified.

What is **not** lost: §5/§6 only need a *pre-transform* `regions.cfg` to prove
round-trip pixel-identity. A fixture authored now still serves that, because the content
transform has not landed yet. Authoring it is a live decision — see §7 Step 2.

## Contents

| file | what |
|---|---|
| `regions.cfg` | device mask config — `count=0` (the fixture is gone) |
| `warp.cfg` | global output warp, slot 1 = identity MESH 8×8 |
| `settings.cfg` | deck settings as found at session start |
| `phone_2400x1080_dual_fit.png` | phone preview, DUAL·TEX + Mirror fill Fit (pillarboxed, scale 1.0) |
| `hdmi_2560x1440_dualtex.png` | external BenQ PD2700U via DUAL·TEX — clean pipeline, no chrome |

## Device state at snapshot

- Display: **DUAL·TEX**, Mirror fill **Fit**
- External: BenQ PD2700U 2560×1440, SurfaceFlinger display id `4614449788371810427`,
  DisplayManager `displayId=11`
- Bridge: `PocketVJEglBridge: blit 59.5 fps, swap avg 0.54 ms, interval=0,
  tex=23 1920x1080 -> 2560x1440` — **the output basis stays 1920×1080**; the bridge
  scales to the link, so no HDMI renegotiation fires on this monitor.

Device state was left exactly as found: `regions.cfg` `count=0`, `warp.cfg`
byte-identical, DUAL·TEX + Fit.
