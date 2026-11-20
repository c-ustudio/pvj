package com.pocketvj

import android.app.Presentation
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.core.content.FileProvider
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.io.File
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * PocketVJ dual-screen bridge (Session 3b, Goal 3).
 *
 * Hosts an ExoPlayer inside an android.app.Presentation on the external
 * (FLAG_PRESENTATION) display — the BenQ over USB-C→HDMI — and plays whatever
 * clip the Godot ClipEngine currently has loaded. Looping, muted (line-in comes
 * from the Focusrite, not the clip), fill/cover so there's no letterboxing.
 * The phone keeps the full Godot UI + preview + effects.
 */
class PresentationPlugin(godot: Godot) : GodotPlugin(godot) {

    private val TAG = "PocketVJPresentation"
    private val VIDEO_MIME = "video/mp4"
    private var presentation: Presentation? = null
    private var player: ExoPlayer? = null
    private var currentDisplayId: Int = -1

    // Texture-output mode (Session 14): a second Presentation hosting a plain
    // SurfaceView; EglBridge blits OutputWorld's GL texture onto it each frame.
    private var texPresentation: Presentation? = null
    private var texDisplayId: Int = -1
    private var texModeWanted = false     // survives unplug: replug auto-rebuilds
    private var displayListener: DisplayManager.DisplayListener? = null

    override fun getPluginName(): String = "PocketVJPresentation"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        // Emitted (with the surface's pixel size) once the projector surface is
        // live — GDScript answers by sizing OutputWorld and sending the texture.
        SignalInfo("texture_output_ready", Int::class.javaObjectType, Int::class.javaObjectType),
        SignalInfo("texture_output_lost")
    )

    /** Diagnostics: all displays + the presentation-capable ones. */
    @UsedByGodot
    fun getDisplayInfo(): String {
        val act = activity ?: return "no-activity"
        val dm = act.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val all = dm.displays.joinToString("; ") { "${it.displayId}:${it.name}" }
        val pres = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
            .joinToString("; ") { "${it.displayId}:${it.name}" }
        return "all=[$all] presentation=[$pres]"
    }

    /**
     * Play (or switch to) the given absolute clip path on the external display.
     * Creates the Presentation + ExoPlayer on first call (or after a display
     * change); subsequent calls just swap the media item. Safe to call on every
     * ClipEngine clip change.
     */
    @OptIn(UnstableApi::class)
    @UsedByGodot
    fun playOnHdmi(path: String): String {
        val act = activity ?: return "no-activity"
        val dm = act.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val displays = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
        if (displays.isEmpty()) return "no-presentation-display"
        val display = displays[0]

        act.runOnUiThread {
            try {
                // The texture path can't share the display — release it first.
                if (texPresentation != null) {
                    texModeWanted = false
                    EglBridge.publishSurface(null)
                    texPresentation?.dismiss()
                    texPresentation = null
                    texDisplayId = -1
                }
                if (presentation == null || currentDisplayId != display.displayId) {
                    // (Re)build the Presentation + player for this display.
                    presentation?.dismiss()
                    player?.release()

                    val p = Presentation(act, display)
                    val ep = ExoPlayer.Builder(p.context).build().apply {
                        volume = 0f                       // silent on HDMI
                        repeatMode = Player.REPEAT_MODE_ONE  // loop current clip
                    }
                    val view = PlayerView(p.context).apply {
                        useController = false
                        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM  // cover, no letterbox
                        setBackgroundColor(Color.BLACK)
                        layoutParams = FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT
                        )
                        player = ep
                    }
                    val root = FrameLayout(p.context).apply {
                        setBackgroundColor(Color.BLACK)
                        addView(view)
                    }
                    p.setContentView(root)
                    p.show()

                    presentation = p
                    player = ep
                    currentDisplayId = display.displayId
                    Log.i(TAG, "HDMI presentation created on ${display.name} (${display.displayId})")
                }

                player?.apply {
                    setMediaItem(MediaItem.fromUri(Uri.fromFile(File(path))))
                    prepare()
                    playWhenReady = true
                }
                Log.i(TAG, "HDMI playing: $path")
            } catch (e: Exception) {
                Log.e(TAG, "playOnHdmi failed: ${e.message}", e)
            }
        }
        return "ok:${display.displayId}:${display.name}"
    }

    // --- Texture output (EGL bridge) -------------------------------------

    /**
     * Claim the external display with a SurfaceView Presentation and start
     * blitting the source texture to it. Returns "ok:id:name:WxH@Hz" with the
     * display's negotiated mode, or an error token. Mutually exclusive with
     * the ExoPlayer path — playOnHdmi tears this down and vice versa.
     */
    @UsedByGodot
    fun startTextureOutput(): String {
        val act = activity ?: return "no-activity"
        val dm = act.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val displays = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
        if (displays.isEmpty()) return "no-presentation-display"
        val display = displays[0]
        val mode = display.mode
        texModeWanted = true

        act.runOnUiThread {
            try {
                // The player path can't share the display — release it first.
                player?.release()
                presentation?.dismiss()
                player = null
                presentation = null

                if (texPresentation == null || texDisplayId != display.displayId) {
                    texPresentation?.dismiss()
                    texPresentation = buildTexPresentation(display)
                    texPresentation?.show()
                    texDisplayId = display.displayId
                    Log.i(TAG, "texture presentation created on ${display.name} (${display.displayId})")
                }
                registerDisplayListener(dm)
            } catch (e: Exception) {
                Log.e(TAG, "startTextureOutput failed: ${e.message}", e)
            }
        }
        return "ok:${display.displayId}:${display.name}:" +
                "${mode.physicalWidth}x${mode.physicalHeight}@${display.refreshRate}"
    }

    @UsedByGodot
    fun stopTextureOutput() {
        texModeWanted = false
        EglBridge.publishSurface(null)
        activity?.runOnUiThread {
            texPresentation?.dismiss()
            texPresentation = null
            texDisplayId = -1
        }
    }

    /**
     * GDScript hands over OutputWorld's GL texture name (re-sent on resize).
     * Forwarded to BOTH consumers: the projector bridge and the set recorder
     * are independent readers of the same texture.
     */
    @UsedByGodot
    fun setSourceTexture(glId: Int, width: Int, height: Int) {
        EglBridge.setSourceTexture(glId, width, height)
        SurfaceRecorder.setSourceTexture(glId, width, height)
    }

    // --- Set recording (SET_RECORDING_SPEC.md approach A) ------------------

    /**
     * Start recording OutputWorld into `baseDir`/set_<stamp>/partNN.mp4.
     * Returns "ok:<dir>:<caps>" or an error token.
     *
     * `audioRate` is Godot's own AudioServer mix rate rather than an assumed
     * 44100/48000: project.godot does not pin audio/driver/mix_rate, so the PCM
     * arriving from the capture bus is at whatever rate the device negotiated,
     * and encoding it at a guessed rate is a pitch-shifted, out-of-sync track.
     */
    @UsedByGodot
    fun startRecording(
        baseDir: String, width: Int, height: Int, fps: Int, bitrateKbps: Int,
        mime: String, segmentSeconds: Int, reserveMb: Int,
        audioEnabled: Boolean, audioRate: Int, audioBitrateKbps: Int,
    ): String = SurfaceRecorder.start(
        baseDir, width, height, fps, bitrateKbps, mime,
        segmentSeconds, reserveMb.toLong() * 1024 * 1024,
        audioEnabled, audioRate, audioBitrateKbps)

    /**
     * Interleaved float32 STEREO PCM lifted straight off Godot's mic capture bus
     * (PackedVector2Array.to_byte_array()), downmixed to mono and AAC-encoded on
     * the Kotlin side. `padFrames` is the count AudioEffectCapture reports having
     * DISCARDED since the last push, so a capture overrun is filled with exactly
     * the silence that was lost instead of drifting the track early forever.
     */
    @UsedByGodot
    fun pushRecorderAudio(pcm: ByteArray, frames: Int, padFrames: Int) {
        AudioEncoder.push(pcm, frames, padFrames)
    }

    /** `reason` is surfaced in the UI and the log ("disk-full", "user", ...). */
    @UsedByGodot
    fun stopRecording(reason: String): String = SurfaceRecorder.stop(reason)

    /** "rec|elapsed_s|bytes|bytes_per_sec|segments|dir|error" — polled at ~1 Hz. */
    @UsedByGodot
    fun getRecorderStats(): String = SurfaceRecorder.stats()

    @UsedByGodot
    fun isRecording(): Boolean = SurfaceRecorder.isRecording()

    /**
     * Free space in MEBIBYTES on the volume holding `path`, or -1.
     * GDScript has no filesystem-free-space API, so this is the only route.
     * Reported in MB rather than bytes to keep the value inside a plain Int
     * across the JNI bridge — MB resolution is far finer than a storage UI needs.
     */
    @UsedByGodot
    fun getFreeMb(path: String): Int {
        val b = SurfaceRecorder.freeBytes(path)
        return if (b < 0) -1 else (b / 1048576L).toInt()
    }

    @UsedByGodot
    fun getTotalMb(path: String): Int {
        val b = SurfaceRecorder.totalBytes(path)
        return if (b < 0) -1 else (b / 1048576L).toInt()
    }

    // --- Recording playback / sharing -------------------------------------

    /**
     * Open a recorded part in whatever the phone uses to play video.
     * @return "ok", or a token the UI can show ("busy-recording", "no-player", ...).
     */
    @UsedByGodot
    fun openRecording(path: String): String = handOff(path, share = false)

    /** Same file, through the system share sheet. */
    @UsedByGodot
    fun shareRecording(path: String): String = handOff(path, share = true)

    /**
     * Mint a content:// URI for a recording and hand it to another app.
     *
     * ⚠️ REFUSES WHILE RECORDING. Starting an external activity backgrounds
     * Godot, which stops the GL thread that feeds the encoder — browsing your
     * past sets would damage the one you are currently making.
     *
     * ⚠️ No resolveActivity() pre-check on purpose: since Android 11, package
     * visibility filtering can make resolveActivity() return null even though a
     * handler exists, which would report "no player installed" on a phone that
     * has one. Catching ActivityNotFoundException is the answer that cannot lie.
     */
    private fun handOff(path: String, share: Boolean): String {
        val act = activity ?: return "no-activity"
        if (SurfaceRecorder.isRecording()) return "busy-recording"

        val f = File(path)
        if (!f.exists()) return "missing-file"

        // ⚠️ This is GODOT'S FileProvider, not one of ours. godot-lib declares
        // it with this exact authority and its godot_provider_paths.xml already
        // maps <external-path path="."> — so recordings under
        // /storage/emulated/0 are already coverable. Declaring our own provider
        // is not merely unnecessary, it FAILS THE MANIFEST MERGE (same
        // android:name, conflicting FILE_PROVIDER_PATHS meta-data).
        //
        // The broad path="." is not a leak: the provider is exported="false",
        // and a receiving app only ever gets the single URI we grant per intent
        // — it cannot enumerate or name anything else through it.
        val uri = try {
            FileProvider.getUriForFile(act, "${act.packageName}.fileprovider", f)
        } catch (e: IllegalArgumentException) {
            Log.e(TAG, "FileProvider rejected $path: ${e.message}")
            return "not-shareable"
        }

        val intent = if (share) {
            Intent(Intent.ACTION_SEND).apply {
                type = VIDEO_MIME
                putExtra(Intent.EXTRA_STREAM, uri)
            }
        } else {
            Intent(Intent.ACTION_VIEW).apply { setDataAndType(uri, VIDEO_MIME) }
        }
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

        val launch = if (share) {
            // The grant flag has to ride on the CHOOSER too, not just the inner
            // intent, or the app the user picks gets a URI it cannot read.
            Intent.createChooser(intent, "Share recording")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } else {
            intent
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        return try {
            act.startActivity(launch)
            Log.i(TAG, "handed off ${f.name} (${if (share) "share" else "view"}) as $uri")
            "ok"
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "no handler for ${f.name}: ${e.message}")
            "no-player"
        } catch (e: Exception) {
            Log.e(TAG, "handOff failed: ${e.message}", e)
            "launch-failed"
        }
    }

    /** Escape hatch if the projector image lands upside down. */
    @UsedByGodot
    fun setOutputFlipY(flip: Boolean) {
        EglBridge.setFlipY(flip)
        SurfaceRecorder.setFlipY(flip)
    }

    private fun buildTexPresentation(display: Display): Presentation {
        val act = activity!!
        val p = Presentation(act, display)
        val sv = SurfaceView(p.context)
        sv.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {}

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                EglBridge.publishSurface(holder.surface)
                emitSignal("texture_output_ready", width, height)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                EglBridge.publishSurface(null)
                emitSignal("texture_output_lost")
            }
        })
        val root = FrameLayout(p.context).apply {
            setBackgroundColor(Color.BLACK)
            addView(sv, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            ))
        }
        p.setContentView(root)
        return p
    }

    // Unplug: the Presentation dies with its display — drop our handle so a
    // replug rebuilds cleanly. Replug: rebuild automatically while texture
    // mode is wanted (a mid-set adapter bump should self-heal).
    private fun registerDisplayListener(dm: DisplayManager) {
        if (displayListener != null) return
        displayListener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {
                if (texModeWanted && texPresentation == null) {
                    Log.i(TAG, "display $displayId added — rebuilding texture output")
                    startTextureOutput()
                }
            }

            override fun onDisplayRemoved(displayId: Int) {
                if (displayId == texDisplayId) {
                    Log.i(TAG, "display $displayId removed — texture output down")
                    EglBridge.publishSurface(null)
                    texPresentation = null   // already invalid; dismiss would throw
                    texDisplayId = -1
                }
            }

            override fun onDisplayChanged(displayId: Int) {}
        }
        dm.registerDisplayListener(displayListener, Handler(Looper.getMainLooper()))
    }

    // --- Godot render-thread hooks ----------------------------------------

    override fun onGLDrawFrame(gl: GL10?) {
        EglBridge.drawFrame()
        SurfaceRecorder.drawFrame()   // second consumer of the same texture
    }

    override fun onGLSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        // Godot's GL context was (re)created — all shared objects are stale.
        // GlBlitter first: it owns the EGL objects, the other two only hold
        // references it is about to invalidate.
        GlBlitter.onGodotContextRecreated()
        EglBridge.onGodotContextRecreated()
        SurfaceRecorder.onGodotContextRecreated()
    }

    override fun onMainResume() {
        super.onMainResume()
        // The Presentation may have been dismissed while backgrounded.
        if (texModeWanted && texPresentation == null) startTextureOutput()
    }

    /** Tear down the external playback (e.g. on exit). */
    @UsedByGodot
    fun stopHdmi() {
        activity?.runOnUiThread {
            try {
                player?.release()
                presentation?.dismiss()
            } catch (e: Exception) {
                Log.e(TAG, "stopHdmi failed: ${e.message}", e)
            }
            player = null
            presentation = null
            currentDisplayId = -1
        }
    }
}
