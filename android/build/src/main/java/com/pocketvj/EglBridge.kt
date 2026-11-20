package com.pocketvj

import android.util.Log
import android.view.Surface

/**
 * Blits a Godot GL texture onto the external display's Surface every frame.
 *
 * All EGL/GL work happens on Godot's render thread, inside the plugin's
 * onGLDrawFrame callback (Godot's EGL context is current there). The UI thread
 * and GDScript only *publish* state: the Presentation's Surface and the source
 * texture name. A generation counter hands the Surface across threads — the GL
 * thread reconciles on its next frame, so no EGL object is ever touched from
 * two threads.
 *
 * Session 22b: the EGL/shader/quad machinery moved to GlBlitter, which the
 * recorder shares. What is left here is the projector's own policy — surface
 * handoff, the vsync A/B, and the periodic telemetry line. GlBlitter keeps
 * swapInterval at 0: with interval 1 the render thread would block on two
 * unsynchronised 60 Hz vsyncs per frame (phone + projector) and fall to ~30 fps,
 * measured on device in S14.
 */
object EglBridge {
    private const val TAG = "PocketVJEglBridge"

    // -- published state (any thread) --
    private val lock = Any()
    private var pendingSurface: Surface? = null
    private var generation = 0          // bumped on every publish; GL thread reconciles
    @Volatile private var texId = 0
    @Volatile private var texW = 0
    @Volatile private var texH = 0
    @Volatile private var flipY = true          // Godot viewport textures are bottom-up

    // -- GL-thread state --
    private var boundGeneration = -1
    private var target: GlBlitter.Target? = null
    private var failedGeneration = -1   // don't retry a failed init every frame

    // -- per-second stats (logged so pacing stays visible in logcat) --
    private var statFrames = 0
    private var statSwapNs = 0L
    private var statMarkNs = 0L

    fun publishSurface(s: Surface?) {
        synchronized(lock) {
            pendingSurface = s
            generation++
        }
        Log.i(TAG, "surface published: ${s != null} (gen $generation)")
    }

    fun setSourceTexture(id: Int, w: Int, h: Int) {
        texId = id
        texW = w
        texH = h
        Log.i(TAG, "source texture set: id=$id ${w}x$h")
    }

    fun setFlipY(flip: Boolean) { flipY = flip }

    /** Godot's GL context was (re)created — GlBlitter has dropped everything. */
    fun onGodotContextRecreated() {
        target = null
        boundGeneration = -1
        failedGeneration = -1
    }

    /** Called every frame from GodotPlugin.onGLDrawFrame (Godot context current). */
    fun drawFrame() {
        val gen: Int
        val surf: Surface?
        synchronized(lock) { gen = generation; surf = pendingSurface }

        if (gen != boundGeneration) {
            GlBlitter.release(target)
            target = null
            boundGeneration = gen
            if (surf != null && surf.isValid && gen != failedGeneration) {
                target = GlBlitter.acquireTarget(surf, "projector")
                if (target == null) {
                    failedGeneration = gen
                } else {
                    Log.i(TAG, "EGL LINK UP: surface ${target!!.w}x${target!!.h}")
                    statFrames = 0
                    statSwapNs = 0
                    statMarkNs = System.nanoTime()
                }
            }
        }

        val t = target ?: return
        if (!t.alive) {
            // Surface died (unplug). The publish/generation path rebuilds it.
            GlBlitter.release(t)
            target = null
            return
        }

        val swapNs = GlBlitter.blit(t, texId, flipY)
        if (swapNs < 0) return

        statFrames++
        statSwapNs += swapNs
        val now = System.nanoTime()
        if (now - statMarkNs >= 5_000_000_000L) {
            val secs = (now - statMarkNs) / 1e9
            Log.i(TAG, "blit %.1f fps, swap avg %.2f ms, tex=%d %dx%d -> %dx%d".format(
                statFrames / secs, statSwapNs / 1e6 / statFrames,
                texId, texW, texH, t.w, t.h))
            statFrames = 0
            statSwapNs = 0
            statMarkNs = now
        }
    }
}
