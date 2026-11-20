# PocketVJ — Output Architecture (spec)

**Problem:** neither output mode delivers the rendered pipeline to the projector at full resolution.

| Mode | What reaches the projector | Resolution |
|---|---|---|
| **DUAL** | the raw clip via a standalone ExoPlayer — **no warp, no masks, no shaders** | 1080p, but wrong content |
| **MIRROR** | the phone framebuffer, so the pipeline *does* arrive | **1920×864** — 20:9 letterboxed into 16:9, ~20% of vertical lost. Also projects the UI. |

**Both are the same underlying problem:** Godot's rendered output never reaches the Presentation surface. Fix that once and DUAL gains the pipeline, the letterbox disappears, and the UI stays on the phone.

---

## 0. Two things established by research (don't re-investigate)

1. **Godot has no native second-display support on Android.** `FEATURE_SUBWINDOWS` covers Windows/macOS/Linux only; an open proposal (godot-proposals discussion #14211, Feb 2026) requests Android multi-screen and is unresolved. There is no engine setting for this.
2. **MIRROR can never be full resolution.** Android mirroring always scales the *entire* phone framebuffer to fit the external display, preserving aspect. 2400×1080 → 1920×864 is arithmetic, not a setting. **Only a direct-render path gives 1920×1080.** Any plan that keeps MIRROR as the primary output accepts the letterbox permanently.

---

## 1. Step 1 — scene restructure (do this first, regardless of path)

**Both** remaining options require the same thing: the rendered output must live in its own `SubViewport`, separate from the UI. This is the `OutputWorld` seam from `PocketVJ_Architecture.md` §2, deferred back in Session 11 — it's now load-bearing.

```
Main
├── OutputWorld (SubViewport, 1920×1080)     ← this texture is what goes to the projector
│   ├── ClipEngine (DecoderA/B)
│   ├── ShaderSlot
│   ├── RegionCompositor   (masks)
│   └── QuadWarp           (later: MeshWarp)
│
└── ControlSurface (CanvasLayer)             ← phone only, never projected
    ├── preview (TextureRect showing OutputWorld's texture, letterboxed to taste)
    ├── ClipGrid / SequenceStrip / TransportBar / editors
    └── status bar
```

**Why this is safe to do now:** it's GDScript only, no plugin, no Kotlin. When finished, the phone shows the preview plus UI exactly as today, and MIRROR behaves as it does now. Nothing regresses — but the output texture becomes a single, addressable thing that either option below can consume.

**It also immediately fixes the UI-on-projector problem** even if you stay on MIRROR: render `OutputWorld` full-bleed behind the UI, or add a PERFORM toggle that hides all chrome. Worth doing for that alone.

**Verify:** phone looks unchanged; MIRROR still projects the pipeline; warp/masks/shaders all still apply; 60 fps held.

---

## 2. Option A — third-party plugin — ❌ REJECTED (Session 14, 2026-07-24, from source)

**Verdict: cannot work under GL Compatibility, by design — no device test needed.** The plugin's
source is public (github.com/flametime/Godot-Android-DS-plugin). Its renderer creates a **second
Vulkan swapchain** and feeds it with `vkCmdBlitImage` from Godot's `RenderingDevice`
(`ayn_thor_renderer.cpp`). Under GL Compatibility `RenderingServer.get_rendering_device()` returns
null, so init aborts at line 75 — and the author spells it out at line 85:
`"Vulkan device or instance is null. Is OpenGL Compatibility mode active? Plugin requires Vulkan."`
The HDMI half would have been fine (its Kotlin side uses `DISPLAY_CATEGORY_PRESENTATION`, same as
ours). Switching PocketVJ to a Vulkan renderer to adopt a one-rating plugin is a worse trade than
Option B — and §3 is *easier* under GL Compatibility, not harder. **Go to §3.**

**flametime's "Godot Android Dual Screen Plugin"** (itch.io, free / name-your-price, 440 kB). Built for dual-screen Android handhelds (AYN Thor, Anbernic RG DS).

- Both viewports go in a `SubViewportContainer` — matches the §1 structure.
- Claims resolution management, resizing, and render synchronisation handled internally.
- Requires **Use Gradle Build** enabled (already true for this project).
- Ships with a demo — **run the demo first** on the Pixel 9a with HDMI attached, before touching PocketVJ.

**Risks to establish before investing:**
- It mentions **Vulkan** render synchronisation; PocketVJ runs **GL Compatibility**. This is the main unknown — test the demo build with the Compatibility renderer.
- One rating total. Niche and unproven; assume nothing works until seen on device.
- Presentation vs. Android's own display routing — confirm it drives an HDMI display, not just built-in secondary panels.

**If the demo works on the 9a with HDMI + GL Compatibility, this is days of work instead of weeks. Try it before Option B.**

---

## 3. Option B — EGL bridge in the existing Presentation plugin — ✅ SHIPPED (Session 14, 2026-07-24, hardware-verified)

Implemented as `EglBridge.kt` + the texture path in `PresentationPlugin.kt`, wired as **DUAL·TEX**
(Display button cycles DUAL·TEX → DUAL·PLAYER → MIRROR). Verified on the 9a + NEC NP-P506QL:
1920×1080@60 negotiated, projector == preview frame-for-frame, blit ~59.5–60 fps at ~0.5 ms swap.
**Corrections to the sketch below, learned on device:** (a) it omits `eglSwapInterval(0)` on the
projector surface — measured: on same-rate 60 Hz sinks interval choice barely matters (BufferQueue
absorbs it), but interval=0 is kept as the drift-immune default; (b) the EGLConfig must be Godot's own,
looked up via `EGL_CONFIG_ID` (else `EGL_BAD_MATCH`); (c) the GDScript snippet below is WRONG about the
RID — `ViewportTexture.get_rid()` is a proxy and `texture_get_native_handle` returns 0 for it; use
`RenderingServer.viewport_get_texture(viewport.get_viewport_rid())`; (d) replug teardown/rebuild is
implemented but not yet exercised with a physical unplug. Narrative: `SESSION_14_NOTES.md`.

The correct architecture, and **more tractable than expected because of the GL Compatibility renderer**. On Vulkan this would be considerably harder.

### Why it's feasible

- Under GL Compatibility, `RenderingServer.texture_get_native_handle()` returns a real **GLuint** texture name for a viewport texture.
- `PresentationPlugin.kt` already creates the `Presentation` and owns its `Surface`.
- Godot's Android `GodotPlugin` exposes **`onGLDrawFrame(GL10 gl)`**, called **on the render thread, every frame, with Godot's GL context current**. That is the integration point — no thread marshalling, no context guessing.

### Sketch

**One-time setup** (on the render thread, once the Presentation exists):
1. `eglGetCurrentDisplay()` / `eglGetCurrentContext()` → Godot's EGLDisplay and EGLContext.
2. Create a shared context: `eglCreateContext(display, config, godotContext, attribs)` — sharing means the second context can sample Godot's textures directly.
3. `eglCreateWindowSurface(display, config, presentationSurface, null)` → the projector's EGLSurface.
4. Compile a trivial passthrough shader + fullscreen-quad VBO.

**Per frame**, inside `onGLDrawFrame`:
1. Save the current surface/context.
2. `eglMakeCurrent(display, projSurface, projSurface, sharedContext)`.
3. `glViewport(0, 0, 1920, 1080)`; bind the `OutputWorld` texture (GLuint passed in from GDScript); draw the fullscreen quad.
4. `eglSwapBuffers(display, projSurface)`.
5. **`eglMakeCurrent` back to Godot's surface and context** — miss this and Godot renders into the wrong target.

**GDScript side:** pass the output texture's native handle down once (and again on any viewport resize):
```gdscript
var rid := output_viewport.get_texture().get_rid()
var gl_id: int = RenderingServer.texture_get_native_handle(rid)
_hdmi.setSourceTexture(gl_id, 1920, 1080)
```

### Gotchas to expect

- **Texture handle invalidation.** The GLuint changes if the viewport is resized or recreated — re-fetch and re-send on any resize.
- **Y-flip.** Godot's viewport textures are commonly bottom-left origin; if the projector image is upside down, flip V in the quad's UVs.
- **`eglMakeCurrent` cost** is small but non-zero, twice per frame. Measure — the deck holds 60 fps and must continue to.
- **Presentation lifecycle.** Adapter unplugged mid-set → surface destroyed. Tear down the EGLSurface on `onDisplayRemoved` or it will crash.
- **Breaks the GDScript-only constraint.** This is Kotlin + EGL. Accepted deliberately — it's the only path to a correct output.
- **Android 17 Presentation fragility** was observed on the Pixel 8 (a "Desktop/Mirror" system chooser, and the BenQ going black mid-test). **Develop against the Pixel 9a**, which is the known-good HDMI device.

### Effort

A week or two of sessions with genuine debugging risk. Permanent fix; nothing else on the roadmap depends on it (Phase 2 dual-deck compositing happens inside Godot and works either way).

---

## 4. Option C — Android desktop mode (10-minute test, do it before Option B)

Android 15+ introduced external-display desktop modes, and the **"Connect to external display: Desktop / Mirror" chooser was observed on the Pixel 8 running Android 17**. If choosing Desktop lets the PocketVJ window sit on the external display at its native 1920×1080, that may deliver full-resolution output with **zero code**.

The likely catch: Godot is single-window on Android, so the app would be *on* the projector rather than on the phone — losing the phone as a control surface. That may be useless for performance, or it may be fine with a Bluetooth controller or as a fallback.

**Cheap to test, so test it before committing to Option B.**

---

## 5. Recommended order

1. **§1 scene restructure** — GDScript, no risk, needed by every path, and fixes UI-on-projector on its own.
2. **§4 desktop-mode test** — ten minutes, might be free.
3. **§2 plugin demo** on the 9a with HDMI and GL Compatibility — an afternoon; if it works, done.
4. **§3 EGL bridge** — the real fix if 2 and 3 fail.

Do **not** start §3 before §1 is committed and verified: the bridge needs a clean output texture to consume, and debugging both at once would be miserable.

---

## 6. What "working" means (acceptance criteria)

- Projector shows the **rendered pipeline** — warp, masks, and shaders all applied.
- Projector runs at **1920×1080**, no letterbox.
- **Phone shows the UI**; the UI never appears on the projector.
- Deck holds **60 fps** with both outputs live.
- Unplugging and replugging HDMI mid-session does not crash the app.
