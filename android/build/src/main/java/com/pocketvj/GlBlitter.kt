package com.pocketvj

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Blits a Godot GL texture onto any number of consumer Surfaces.
 *
 * Session 14 gave the projector bridge a private EGL context + shader + quad;
 * the Session-22 recording spike COPIED all of it, deliberately, so a recorder
 * bug could not take the projector down while it was still unknown whether
 * hardware encoding was even viable. It is viable, so the duplication is now
 * just duplication — this is the one implementation both consumers share.
 *
 * ONE context, N targets. The context lives in Godot's share group (so Godot's
 * textures are readable) and is built on Godot's own EGLConfig, looked up via
 * EGL_CONFIG_ID — a surface or context on any other config risks EGL_BAD_MATCH
 * at eglMakeCurrent. Because the program and VBO are GL objects they belong to
 * that one context, so they are compiled and uploaded ONCE no matter how many
 * consumers attach.
 *
 * Per-target teardown is also stricter than what it replaces: the old bridge
 * destroyed its whole context when a surface died, which with two consumers
 * would have taken the other one's target with it. Losing the projector surface
 * now costs exactly the projector's Target.
 *
 * THREADING: every method must be called on Godot's render thread, from inside
 * onGLDrawFrame, where Godot's EGL context is current. Callers publish Surfaces
 * from other threads and reconcile here — see EglBridge/SurfaceRecorder.
 */
object GlBlitter {
    private const val TAG = "PocketVJBlit"

    /** A consumer surface. Dead targets must be released and re-acquired. */
    class Target(
        @JvmField val eglSurface: EGLSurface,
        @JvmField val w: Int,
        @JvmField val h: Int,
        @JvmField val label: String,
    ) {
        @Volatile @JvmField var alive: Boolean = true
    }

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var ctx: EGLContext = EGL14.EGL_NO_CONTEXT
    private var cfg: EGLConfig? = null
    private var program = 0
    private var vbo = 0
    private var uFlip = -1
    private val targets = mutableListOf<Target>()

    /**
     * Wrap a consumer Surface in an EGL window surface, creating the shared
     * context on first use. Returns null if the surface or the context cannot
     * be set up; the caller should not retry until its surface changes.
     */
    fun acquireTarget(surface: Surface, label: String): Target? {
        val godotDraw = EGL14.eglGetCurrentSurface(EGL14.EGL_DRAW)
        val godotRead = EGL14.eglGetCurrentSurface(EGL14.EGL_READ)
        val godotCtx = EGL14.eglGetCurrentContext()
        if (!ensureContext()) return null

        var eglSurface = EGL14.EGL_NO_SURFACE
        try {
            eglSurface = EGL14.eglCreateWindowSurface(
                display, cfg, surface, intArrayOf(EGL14.EGL_NONE), 0)
            if (eglSurface == EGL14.EGL_NO_SURFACE) {
                Log.e(TAG, "$label: eglCreateWindowSurface failed 0x${err()}")
                return null
            }
            if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, ctx)) {
                Log.e(TAG, "$label: eglMakeCurrent failed 0x${err()}")
                EGL14.eglDestroySurface(display, eglSurface)
                return null
            }

            if (program == 0 && !buildGl()) {
                EGL14.eglDestroySurface(display, eglSurface)
                return null
            }

            val wh = IntArray(2)
            EGL14.eglQuerySurface(display, eglSurface, EGL14.EGL_WIDTH, wh, 0)
            EGL14.eglQuerySurface(display, eglSurface, EGL14.EGL_HEIGHT, wh, 1)

            // Never pace on a consumer surface. With interval 1 the render
            // thread would block on two unsynchronised 60 Hz vsyncs per frame
            // (phone + projector) and fall to ~30 fps — measured in S14.
            EGL14.eglSwapInterval(display, 0)

            // One-shot state: this context is ours alone, nothing re-enables these.
            GLES20.glDisable(GLES20.GL_DEPTH_TEST)
            GLES20.glDisable(GLES20.GL_BLEND)
            GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
            GLES20.glDisable(GLES20.GL_CULL_FACE)

            val t = Target(eglSurface, wh[0], wh[1], label)
            targets.add(t)
            Log.i(TAG, "$label: target up, ${wh[0]}x${wh[1]} (${targets.size} live)")
            return t
        } finally {
            EGL14.eglMakeCurrent(display, godotDraw, godotRead, godotCtx)
        }
    }

    /**
     * Draw texId over the whole target and swap.
     *
     * @param presentationTimeNs when >= 0, stamped via eglPresentationTimeANDROID
     *        before the swap — MediaCodec reads its PTS from this, so the deck's
     *        own cadence drives the recording's timebase. The projector ignores it.
     * @return nanoseconds spent inside eglSwapBuffers, or -1 if the target died.
     *
     * That return value is the load-bearing measurement of this whole feature:
     * a surface consumer that cannot keep up fills its BufferQueue and blocks
     * the producer INSIDE the swap, so time-in-swap is how back-pressure becomes
     * visible before it becomes dropped frames.
     */
    fun blit(t: Target, texId: Int, flipY: Boolean, presentationTimeNs: Long = -1L): Long {
        if (!t.alive || texId == 0) return -1L
        val godotDraw = EGL14.eglGetCurrentSurface(EGL14.EGL_DRAW)
        val godotRead = EGL14.eglGetCurrentSurface(EGL14.EGL_READ)
        val godotCtx = EGL14.eglGetCurrentContext()

        if (!EGL14.eglMakeCurrent(display, t.eglSurface, t.eglSurface, ctx)) {
            // Surface died mid-frame (unplug, or the codec went away).
            Log.w(TAG, "${t.label}: eglMakeCurrent lost the surface")
            t.alive = false
            EGL14.eglMakeCurrent(display, godotDraw, godotRead, godotCtx)
            return -1L
        }

        GLES20.glViewport(0, 0, t.w, t.h)
        GLES20.glUseProgram(program)
        GLES20.glUniform1f(uFlip, if (flipY) 1f else 0f)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texId)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo)
        GLES20.glEnableVertexAttribArray(0)
        GLES20.glEnableVertexAttribArray(1)
        GLES20.glVertexAttribPointer(0, 2, GLES20.GL_FLOAT, false, 16, 0)
        GLES20.glVertexAttribPointer(1, 2, GLES20.GL_FLOAT, false, 16, 8)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        if (presentationTimeNs >= 0L) {
            EGLExt.eglPresentationTimeANDROID(display, t.eglSurface, presentationTimeNs)
        }

        val t0 = System.nanoTime()
        val swapped = EGL14.eglSwapBuffers(display, t.eglSurface)
        val t1 = System.nanoTime()

        EGL14.eglMakeCurrent(display, godotDraw, godotRead, godotCtx)

        if (!swapped) {
            Log.w(TAG, "${t.label}: eglSwapBuffers failed 0x${err()}")
            t.alive = false
            return -1L
        }
        return t1 - t0
    }

    /** Destroy one target's EGL surface. The shared context outlives it. */
    fun release(t: Target?) {
        if (t == null) return
        t.alive = false
        targets.remove(t)
        if (display != EGL14.EGL_NO_DISPLAY && t.eglSurface != EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroySurface(display, t.eglSurface)
        }
        Log.i(TAG, "${t.label}: target released (${targets.size} live)")
    }

    /**
     * Godot's GL context was (re)created — every shared object is dead, ours
     * included. Consumers see their Target go !alive and re-acquire.
     */
    fun onGodotContextRecreated() {
        for (t in targets) {
            t.alive = false
            if (display != EGL14.EGL_NO_DISPLAY && t.eglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(display, t.eglSurface)
            }
        }
        targets.clear()
        if (display != EGL14.EGL_NO_DISPLAY && ctx != EGL14.EGL_NO_CONTEXT) {
            EGL14.eglDestroyContext(display, ctx)
        }
        ctx = EGL14.EGL_NO_CONTEXT
        display = EGL14.EGL_NO_DISPLAY
        cfg = null
        program = 0
        vbo = 0
    }

    // --- internals ---------------------------------------------------------

    private fun err() = Integer.toHexString(EGL14.eglGetError())

    private fun ensureContext(): Boolean {
        if (ctx != EGL14.EGL_NO_CONTEXT) return true
        display = EGL14.eglGetCurrentDisplay()
        val godotCtx = EGL14.eglGetCurrentContext()
        if (display == EGL14.EGL_NO_DISPLAY || godotCtx == EGL14.EGL_NO_CONTEXT) {
            Log.e(TAG, "no current EGL display/context (not on the GL thread?)")
            return false
        }

        // Godot's own config. Anything else risks EGL_BAD_MATCH at makeCurrent.
        val cfgId = IntArray(1)
        EGL14.eglQueryContext(display, godotCtx, EGL14.EGL_CONFIG_ID, cfgId, 0)
        val cfgs = arrayOfNulls<EGLConfig>(1)
        val num = IntArray(1)
        EGL14.eglChooseConfig(
            display, intArrayOf(EGL14.EGL_CONFIG_ID, cfgId[0], EGL14.EGL_NONE), 0,
            cfgs, 0, 1, num, 0
        )
        if (num[0] < 1 || cfgs[0] == null) {
            Log.e(TAG, "no EGLConfig for Godot's EGL_CONFIG_ID ${cfgId[0]}")
            return false
        }
        cfg = cfgs[0]

        // Share group = Godot's, so Godot's render-target textures are ours to read.
        ctx = EGL14.eglCreateContext(
            display, cfg, godotCtx,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0
        )
        if (ctx == EGL14.EGL_NO_CONTEXT) {
            Log.e(TAG, "eglCreateContext failed 0x${err()}")
            return false
        }
        Log.i(TAG, "shared context up on Godot's config id ${cfgId[0]}")
        return true
    }

    private fun buildGl(): Boolean {
        val vs = """
            attribute vec2 aPos;
            attribute vec2 aUv;
            uniform float uFlip;
            varying vec2 vUv;
            void main() {
                vUv = vec2(aUv.x, mix(aUv.y, 1.0 - aUv.y, uFlip));
                gl_Position = vec4(aPos, 0.0, 1.0);
            }
        """
        val fs = """
            precision mediump float;
            uniform sampler2D uTex;
            varying vec2 vUv;
            void main() { gl_FragColor = texture2D(uTex, vUv); }
        """
        val v = compile(GLES20.GL_VERTEX_SHADER, vs)
        val f = compile(GLES20.GL_FRAGMENT_SHADER, fs)
        if (v == 0 || f == 0) return false
        program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, v)
        GLES20.glAttachShader(program, f)
        GLES20.glBindAttribLocation(program, 0, "aPos")
        GLES20.glBindAttribLocation(program, 1, "aUv")
        GLES20.glLinkProgram(program)
        val linked = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0)
        GLES20.glDeleteShader(v)
        GLES20.glDeleteShader(f)
        if (linked[0] == 0) {
            Log.e(TAG, "program link failed: ${GLES20.glGetProgramInfoLog(program)}")
            program = 0
            return false
        }
        uFlip = GLES20.glGetUniformLocation(program, "uFlip")
        GLES20.glUseProgram(program)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTex"), 0)

        // Fullscreen quad as a triangle strip: x, y, u, v.
        val quad = floatArrayOf(
            -1f, -1f, 0f, 0f,
             1f, -1f, 1f, 0f,
            -1f,  1f, 0f, 1f,
             1f,  1f, 1f, 1f
        )
        val buf = ByteBuffer.allocateDirect(quad.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer().put(quad)
        buf.position(0)
        val ids = IntArray(1)
        GLES20.glGenBuffers(1, ids, 0)
        vbo = ids[0]
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo)
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, quad.size * 4, buf, GLES20.GL_STATIC_DRAW)
        return true
    }

    private fun compile(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, src)
        GLES20.glCompileShader(s)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) {
            Log.e(TAG, "shader compile failed: ${GLES20.glGetShaderInfoLog(s)}")
            GLES20.glDeleteShader(s)
            return 0
        }
        return s
    }
}
