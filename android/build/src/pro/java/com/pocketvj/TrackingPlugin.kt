package com.pocketvj

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import android.util.Size
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.ProcessLifecycleOwner
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MediaImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.ImageProcessingOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarkerResult
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetectorResult
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.hypot

/**
 * PocketVJ tracking module — M1 (docs/MEDIAPIPE_MODULE.md §11).
 *
 * CameraX → FaceLandmarker (LIVE_STREAM, CPU) → arbitration-lite →
 * baseline-relative z → One Euro → a seq-numbered snapshot GDScript polls.
 *
 * M0 verdicts baked in (SESSION_33_NOTES.md):
 *  - The sample-app ImageProxy→Bitmap convert is what halves the blit rate
 *    with a display attached, so the DEFAULT input path is the MediaImage
 *    (YUV, zero-copy) one, with the bitmap path kept as a runtime fallback
 *    selectable from GDScript (setInputPath) — the device answers doc §10
 *    #4 without a rebuild either way. Rotation goes through
 *    ImageProcessingOptions in BOTH paths, never a rotated-Bitmap copy.
 *  - Default inference rate is 15 Hz (the honest CPU landmark rate with a
 *    face in frame), clamped 5..30, live-tunable.
 *  - The camera mutual-exclusion gate lives in GDScript (TrackingEngine +
 *    pipeline) — by the doc's §2.1 design the plugin never decides policy,
 *    it only reports "camera-lost".
 *
 * Threading: camera + inference on their own executor/listener threads;
 * the snapshot is the only shared state (small array copy under a lock).
 * Nothing here ever touches Godot's render thread.
 */
class TrackingPlugin(godot: Godot) : GodotPlugin(godot) {

    private val TAG = "PocketVJTracking"
    private val MODEL_ASSET = "mediapipe/face_landmarker.task"
    private val MODEL_HAND = "mediapipe/hand_landmarker.task"
    // M8a spike (doc §13.9): EfficientDet-Lite0, INT8 — 4.6 MB against
    // float32's 13.8 MB, and int8 is the fast path on XNNPACK/CPU where §8
    // puts tracking. Answers part of open question #18.
    // M8a: swappable so the variant sweep costs an app restart, not a rebuild.
    // int8 measured ~110 ms/inference on the P8 — ~10x FaceLandmarker's ~15 ms
    // on the same phone, measured the same way, which is far too slow for the
    // model's size and the reason this switch exists: a quantized model whose
    // ops fall back off XNNPACK's fast path is the prime suspect.
    @Volatile private var crowdModel = "mediapipe/edl0_int8.tflite"
    // ⚠️ §8 budgets for a "1280x720 analysis stream" — but nothing ever ASKED
    // for one, so CameraX has been handing back its ~640x480 default since M0.
    // EfficientDet then downscales that to 320x320, which puts a person at 5 m
    // around 30 px tall: under what these detectors fire on. The operator
    // measured person-box range at ~1.5 m, and the landmark path's 0.8-1 m
    // (the M3 lever, open since Session 34) is the SAME untested cause.
    // THE range control, and the only one that is LIVE (no graph rebuild, so
    // no teardown and no lens-switch wedge risk). The P8's main sensor is
    // 50 MP while the analysis stream is ~640x480, so a 2-3x digital zoom is
    // near-free in quality terms — it crops a huge sensor down to a small
    // frame either way, and a person at 8 m gets the pixels they would have
    // had at 3 m. ⚠️ Zoom trades FIELD OF VIEW for reach: a win for a single
    // performer, a genuine tension for CROWD work where coverage is the point.
    @Volatile private var camera: androidx.camera.core.Camera? = null
    @Volatile private var zoomWanted = 1.0f
    @Volatile private var cameraOnly = false     // "camera" mode: publish, no inference
    @Volatile private var aeLocked = false
    @Volatile private var analysisRes = 720          // MEASURED best — doc §13.7.1a
    @Volatile private var crowdScore = 0.4f          // §13.6 crowd_min_conf

    // Snapshot layout — doc §4, indices are FROZEN (append-only forever).
    private val IDX_SEQ = 0
    private val IDX_MODE = 1          // 0 off · 1 landmark · 2 field
    private val IDX_PRESENCE = 2      // debounced (grace applied)
    private val IDX_PRESENCE_RAW = 3
    private val IDX_AGE_MS = 4
    private val IDX_HEAD_X = 5
    private val IDX_HEAD_Y = 6
    private val IDX_HEAD_Z = 7
    private val IDX_HEAD_SIZE = 8
    private val IDX_YAW = 9           // M1: constant 0.5 (rotation extraction is M2)
    private val IDX_PITCH = 10
    private val IDX_ROLL = 11
    private val IDX_CROWDED = 12
    private val IDX_N_FACES = 13
    private val IDX_HAND_X = 14       // M2b: the doc's reserved hand slots, filled
    private val IDX_HAND_Y = 15
    private val IDX_HAND_PRESENT = 16 // raw per-inference (no grace machinery yet)
    private val SNAPSHOT_SIZE = 18    // 17 reserved (second hand / gesture)
    private val LM_PALM = 9           // middle-finger MCP — the stable palm point

    // Landmark topology constants (FaceLandmarker 478-point canonical mesh).
    private val LM_NOSE_TIP = 1
    private val LM_EYE_OUTER_L = 33
    private val LM_EYE_OUTER_R = 263

    // §5.3 state machine, in inference ticks at the configured rate.
    private val ACQUIRE_TICKS = 8
    private val BASELINE_TICKS = 15
    private val GRACE_MS = 700L
    private val Z_SPAN = 0.35f        // ±35 % distance change spans head_z 0..1
    private val MAX_JUMP = 0.25f      // subject continuity gate, frame widths/inference

    private var landmarker: FaceLandmarker? = null
    private var handLandmarker: HandLandmarker? = null
    // M8a: the crowd spike's detector. LOGCAT ONLY — no snapshot, no GDScript
    // surface, nothing downstream. This measures whether C1 is viable (§13.7)
    // and is deliberately throwaway until the recall gate says go.
    private var crowdDetector: ObjectDetector? = null
    @Volatile private var crowdMode = false
    private var crowdMaxSeen = 0
    private var crowdScoreSum = 0.0
    private var crowdDetSum = 0
    @Volatile private var loggedRes = false
    @Volatile private var analysisFrames = 0L
    // M8b: the raw boxes, handed to GDScript's CrowdTracker. RAW CAMERA SPACE,
    // normalised 0..1, NEVER mirrored — §4.2's audience-view flip belongs at
    // output, and mirroring here would recreate the Session 34 churn once per
    // slot. Layout: [n, (x, y, size, conf) * n].
    @Volatile private var crowdRaw = FloatArray(1)
    @Volatile private var crowdLastN = 0
    @Volatile private var crowdLastConf = 0f
    @Volatile private var crowdFrameW = 0
    @Volatile private var crowdFrameH = 0
    @Volatile private var handsWanted = false
    @Volatile private var handsOnly = false   // M3 economy: no face graph
    private var cameraProvider: ProcessCameraProvider? = null
    private var analysisExecutor: ExecutorService? = null
    @Volatile private var running = false
    @Volatile private var lensFront = false

    // -- live-tunable knobs (any thread) --
    @Volatile private var inferenceHz = 15
    @Volatile private var useMediaPath = true     // doc §10 #4 probe; falls back on error
    @Volatile private var delegateGpu = false     // applies on next start()
    private val filters = OneEuroBank(6)          // x, y, tz, head_size, hand_x, hand_y
    @Volatile private var rebaselineAsked = false

    // -- listener-thread state (subject/presence/baseline) --
    private enum class St { ABSENT, ACQUIRING, PRESENT, GRACE }
    private var st = St.ABSENT
    private var stTicks = 0
    private var lastX = 0.5f          // matcher continuity — RAW camera space,
    private var lastY = 0.5f          // never the §4.2 audience-view mirror
    private var candX = -1f           // §5.2 acquisition candidate, raw space
    private var candY = -1f           // (-1 = no candidate seen yet)
    private var graceStartMs = 0L
    private val baseline = ArrayList<Float>(BASELINE_TICKS)
    private var zRef = 0f              // median t_z at acquisition (negative, cm-ish)
    private var frozen = FloatArray(3) { 0.5f }   // x, y, z held through GRACE/ABSENT

    // -- the snapshot (written by listener thread, read by getFrame) --
    private val snapLock = Any()
    private val snap = FloatArray(SNAPSHOT_SIZE)
    private var seq = 0L
    private var lastResultCamTs = 0L

    // ⚠️ MediaPipe delivers results on a THREAD POOL (Session 33's logs show
    // rotating tids), so the §5.3 state machine must run under one lock —
    // the M1 "subject lost" double-emit was this race.
    private val stateLock = Any()

    // -- camera publish (M6): the lens on the wall, zero-copy --
    // Doc §2.1's promised resolution: tracking OWNS the camera and PUBLISHES
    // it. A CameraX Preview use case renders into a Surface over a
    // SurfaceTexture latched onto the GL name GDScript allocated with
    // ExternalTexture — VideoLinkPlugin's receive pattern, camera-side. The
    // pixels never touch the CPU and never touch MediaPipe's path: ONE camera
    // client, two consumers, and the §2.1 exclusion becomes routing.
    //
    // ⚠️ THREADING: setPreviewTexture / pumpPreview / clearPreviewTexture MUST
    // be called from GDScript — that is the GL render thread with Godot's EGL
    // context current, and a SurfaceTexture belongs to the context that
    // creates it. `pub` prefix throughout to keep this path distinct from the
    // tracker VIEWER's `preview*` fields (CPU bytes, a different feature).
    private var pubSurfaceTexture: SurfaceTexture? = null
    private var pubSurface: Surface? = null
    @Volatile private var pubPreview: Preview? = null
    @Volatile private var pubWanted = false
    private val pubDirty = AtomicBoolean(false)
    @Volatile private var pubFrames = 0L
    @Volatile private var pubLastFrameMs = 0L
    // SurfaceTexture's 4x4 UV transform. ⚠️ CORRECTED (Session 36): this
    // carries ONLY the buffer's own crop/flip. M6 shipped believing sensor
    // orientation and the front-lens mirror lived in here too — they do not.
    // For a CameraX Preview those arrive through SurfaceRequest's
    // TransformationInfo, which the first cut never registered a listener for,
    // so the wall showed raw sensor orientation: the front lens sideways and
    // un-mirrored, which is exactly what the operator reported on device.
    private val pubXform = FloatArray(16).also { android.opengl.Matrix.setIdentityM(it, 0) }

    // The REAL transform, straight from CameraX. setTargetRotation() only sets
    // what these report; it never rotates the buffer, and nothing downstream
    // can recover the rotation from the ST matrix alone.
    @Volatile private var pubRotDeg = 0
    @Volatile private var pubCropL = 0
    @Volatile private var pubCropT = 0
    @Volatile private var pubCropR = 0
    @Volatile private var pubCropB = 0
    @Volatile private var pubBufW = 0
    @Volatile private var pubBufH = 0

    // -- tracker viewer (M2): pull-model — zero cost while the panel is shut --
    @Volatile private var viewerWanted = false
    private val previewLock = Any()
    private var previewBytes = ByteArray(0)
    private var previewW = 0
    private var previewH = 0
    private var previewRot = 0
    private var previewSeq = 0L
    private var lastPreviewMs = 0L
    private var debugLandmarks = FloatArray(0)   // chosen face, x/y pairs
    private var debugHand = FloatArray(0)        // first hand, x/y pairs

    // -- analyzer-thread throttle --
    private var lastInferMs = 0L

    // -- 1 Hz stats --
    @Volatile private var statLine = "idle"
    private var statMarkMs = 0L
    private var statAnalyzed = 0
    private var statResults = 0
    private var statConvertMs = 0L
    private var statLatencyMs = 0L

    override fun getPluginName(): String = "PocketVJTracking"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("tracking_started", String::class.java),
        SignalInfo("tracking_failed", String::class.java),
        SignalInfo("tracking_stopped"),
        SignalInfo("subject_acquired"),   // baseline captured — head_z is now live
        SignalInfo("subject_lost")        // grace expired
    )

    // ------------------------------------------------------------------ API

    @UsedByGodot
    fun start(mode: String, lens: String): String {
        val act = activity ?: return "no-activity"
        if (running) return "already-running"
        if (mode != "landmark" && mode != "crowd" && mode != "camera") return "bad-mode"
        if (ContextCompat.checkSelfPermission(act, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) return "no-permission"

        lensFront = lens == "front"
        val selector = if (lensFront) CameraSelector.DEFAULT_FRONT_CAMERA
                       else CameraSelector.DEFAULT_BACK_CAMERA

        crowdMode = mode == "crowd"
        // "camera": the deck's CAMERA source over CameraX with NO inference —
        // no detector, no graph, no analyzer. Godot's CameraServer/CameraFeed
        // API has no zoom, no exposure, no lens choice and no AE lock; CameraX
        // has all of them, and M6 already built the path to the deck. This is
        // that path without paying for tracking, and it also removes the last
        // CameraServer client, so the §2.1 two-client wedge stops being
        // reachable at all.
        cameraOnly = mode == "camera"
        loggedRes = false
        analysisFrames = 0L
        if (crowdMode) {
            // M8a spike. Person boxes ONLY — no face graph, no hand graph, no
            // snapshot writes: the point is a clean inference number for §13.7,
            // uncontaminated by the landmark path's work.
            try {
                val copts = ObjectDetector.ObjectDetectorOptions.builder()
                    .setBaseOptions(BaseOptions.builder()
                        .setModelAssetPath(crowdModel)
                        .setDelegate(if (delegateGpu) Delegate.GPU else Delegate.CPU)
                        .build())
                    .setRunningMode(RunningMode.LIVE_STREAM)
                    .setMaxResults(8)                       // §13.6 crowd_slots ceiling
                    .setScoreThreshold(crowdScore)          // §13.6 crowd_min_conf
                    .setCategoryAllowlist(listOf("person"))
                    .setResultListener { result, _ -> onCrowdResult(result) }
                    .setErrorListener { e ->
                        if (useMediaPath) {
                            useMediaPath = false
                            Log.w(TAG, "crowd: media path rejected -> bitmap: ${e.message}")
                        } else Log.e(TAG, "crowd detector error: ${e.message}")
                    }
                    .build()
                crowdDetector = ObjectDetector.createFromOptions(act, copts)
            } catch (e: Exception) {
                Log.e(TAG, "crowd model load failed: ${e.message}", e)
                return "model-missing"
            }
        }

        // Model first — a bad APK must fail before the camera is claimed.
        if (!cameraOnly && !crowdMode && !handsOnly) try {
            val base = BaseOptions.builder()
                .setModelAssetPath(MODEL_ASSET)
                .setDelegate(if (delegateGpu) Delegate.GPU else Delegate.CPU)
                .build()
            val opts = FaceLandmarker.FaceLandmarkerOptions.builder()
                .setBaseOptions(base)
                .setRunningMode(RunningMode.LIVE_STREAM)
                .setNumFaces(3)
                .setOutputFacialTransformationMatrixes(true)
                .setResultListener { result, _ -> onResult(result) }
                .setErrorListener { e ->
                    // A media-path input the graph can't digest lands here —
                    // flip to the bitmap fallback once, permanently (doc #4).
                    if (useMediaPath) {
                        useMediaPath = false
                        Log.w(TAG, "media input path rejected -> bitmap fallback: ${e.message}")
                    } else {
                        Log.e(TAG, "landmarker error: ${e.message}")
                    }
                }
                .build()
            landmarker = FaceLandmarker.createFromOptions(act, opts)
        } catch (e: Exception) {
            Log.e(TAG, "model load failed: ${e.message}", e)
            return "model-missing"
        }
        if (!cameraOnly && !crowdMode && (handsWanted || handsOnly)) {
            // Its own graph beside the face one — a failure costs hands, not
            // the session (unless hands are ALL there is: see below).
            try {
                val hopts = HandLandmarker.HandLandmarkerOptions.builder()
                    .setBaseOptions(BaseOptions.builder()
                        .setModelAssetPath(MODEL_HAND)
                        .setDelegate(if (delegateGpu) Delegate.GPU else Delegate.CPU)
                        .build())
                    .setRunningMode(RunningMode.LIVE_STREAM)
                    .setNumHands(2)
                    .setResultListener { result, _ -> onHandResult(result) }
                    .setErrorListener { e -> Log.e(TAG, "hand error: ${e.message}") }
                    .build()
                handLandmarker = HandLandmarker.createFromOptions(act, hopts)
            } catch (e: Exception) {
                Log.e(TAG, "hand model load failed (continuing faceless-handless): ${e.message}")
                handLandmarker = null
            }
        }
        if (handsOnly && handLandmarker == null) {
            // Economy mode with no hand graph is a session that tracks
            // nothing — refuse rather than burn the camera for silence.
            return "model-missing"
        }

        resetSubject("start")
        filters.reset()
        analysisExecutor = Executors.newSingleThreadExecutor()
        statMarkMs = SystemClock.uptimeMillis()
        lastInferMs = 0L

        val future = ProcessCameraProvider.getInstance(act)
        future.addListener({
            try {
                val provider = future.get()
                cameraProvider = provider
                // M2: the camera hands over RGBA_8888 directly — CameraX does
                // the YUV convert in its optimized path, MediaImageBuilder
                // accepts the frames (M1 proved it REJECTS YUV: "media image
                // must use RGBA_8888"), and the SAME bytes feed the tracker
                // viewer without a second conversion.
                // ⚠️ targetRotation is PINNED, never defaulted: Android 17's
                // desktop mode re-parents the app onto a landscape-natural
                // logical display (ROTATION_0 at the BenQ's size) the moment
                // an external display mirrors, which shifts CameraX's default
                // by 90° and feeds MediaPipe sideways frames (Session 34).
                // The app is landscape-locked on portrait-natural phones, so
                // the operator surface is always ROTATION_90.
                val wantH = analysisRes
                val wantW = when (wantH) { 1080 -> 1920; 480 -> 640; else -> 1280 }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .setTargetRotation(Surface.ROTATION_90)
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(wantW, wantH),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                            .build())
                    .build()
                if (!cameraOnly) analysis.setAnalyzer(analysisExecutor!!) { proxy -> analyze(proxy) }
                // M6: Preview is bound ALWAYS, streamed only while GDScript
                // holds a surface. Without a provider CameraX defers the
                // request and never configures that stream, so an unpublished
                // session costs what it always did — and the wall can light up
                // mid-set without a session rebuild (the lens-switch teardown
                // race is exactly what we are not re-entering here).
                // Rotation pinned for the same reason as the analyzer above.
                // ⚠️ Preview + ImageAnalysis is a stream COMBINATION and a device
                // only guarantees certain sets. Letting BOTH float is how you land
                // outside them — and CameraX's failure mode there is a bound-but-
                // SILENT analyzer, not an exception. Pin the preview so only one
                // side of the combination varies with analysis_res.
                val prev = Preview.Builder()
                    .setTargetRotation(Surface.ROTATION_90)
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(1280, 720),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                            .build())
                    .build()
                pubPreview = prev
                provider.unbindAll()
                camera = provider.bindToLifecycle(
                    ProcessLifecycleOwner.get(), selector, analysis, prev)
                val zs = camera?.cameraInfo?.zoomState?.value
                Log.i(TAG, "zoom range: ${zs?.minZoomRatio}..${zs?.maxZoomRatio}" +
                        " (wanted $zoomWanted)")
                applyZoom()
                if (pubWanted) attachPreviewSurface()   // re-arm across restarts
                running = true
                // ⚠️ bindToLifecycle can SUCCEED and still deliver no analysis
                // frames (unsupported stream combination, or a resolution the
                // RGBA path will not serve). That is a SILENT failure and it cost
                // a whole sweep with actors standing in a room on 2026-09-10.
                // Three seconds later, say so — loudly, and through the signal
                // so the UI can surface it too.
                if (!cameraOnly) {
                    val askedRes = analysisRes
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        if (running && analysisFrames == 0L) {
                            Log.e(TAG, "!! NO ANALYSIS FRAMES 3s after bind at " +
                                    "${askedRes}p — bind reported OK but the analyzer " +
                                    "is silent. Unsupported Preview+Analysis combination " +
                                    "at this resolution? Fall back to analysis_res=480.")
                            emitSignal("tracking_failed", "no-frames-at-${askedRes}p")
                        }
                    }, 3000L)
                }
                Log.i(TAG, "started: lens=$lens hz=$inferenceHz path=" +
                        (if (useMediaPath) "media" else "bitmap") +
                        " delegate=" + (if (delegateGpu) "gpu" else "cpu") +
                        (if (crowdMode) " model=$crowdModel" else "") +
                        (if (cameraOnly) " CAMERA-ONLY (no inference)" else ""))
                emitSignal("tracking_started",
                        if (cameraOnly) "camera" else if (crowdMode) "crowd" else "landmark")
            } catch (e: Exception) {
                Log.e(TAG, "camera bind failed: ${e.message}", e)
                teardown(silent = true)
                emitSignal("tracking_failed", "camera-lost")
            }
        }, ContextCompat.getMainExecutor(act))
        return "ok"
    }

    @UsedByGodot
    fun stop() = teardown(silent = false)

    @UsedByGodot
    fun isRunning(): Boolean = running

    /** The hot read — doc §4 layout. Empty array while not running. */
    @UsedByGodot
    fun getFrame(): FloatArray {
        if (!running) return FloatArray(0)
        synchronized(snapLock) { return snap.copyOf() }
    }

    /** Marshalling fallback (doc §10 #3): same values, pipe-joined. */
    @UsedByGodot
    fun getFrameStr(): String {
        if (!running) return ""
        val c: FloatArray
        synchronized(snapLock) { c = snap.copyOf() }
        return c.joinToString("|")
    }

    @UsedByGodot
    fun setFilter(minCutoff: Float, beta: Float) {
        filters.setParams(minCutoff.coerceIn(0.05f, 10f), beta.coerceIn(0f, 1f))
    }

    @UsedByGodot
    fun rebaseline() { rebaselineAsked = true }

    @UsedByGodot
    fun setInferenceRate(hz: Int) { inferenceHz = hz.coerceIn(5, 30) }

    /** "media" | "bitmap" — the doc §10 #4 probe switch. Live. */
    @UsedByGodot
    fun setInputPath(p: String) { useMediaPath = p == "media" }

    /** "cpu" | "gpu" — applies on the next start(). */
    @UsedByGodot
    fun setDelegate(d: String) { delegateGpu = d == "gpu" }

    /** M8a variant sweep: "edl0_int8" | "edl0_fp16" | "edl0_fp32" | "ssd".
     *  Applies at the next start(); an unknown name keeps the current one. */
    /**
     * Optical/digital zoom, LIVE — the one range control that needs no
     * session rebuild. Clamped to what the device actually reports; the
     * applied value is logged because a requested ratio is not a granted one.
     */
    @UsedByGodot
    fun setZoom(ratio: Float) {
        zoomWanted = ratio
        applyZoom()
    }

    /** What the camera actually granted: "applied|min|max". */
    @UsedByGodot
    fun getZoom(): String {
        val zs = camera?.cameraInfo?.zoomState?.value ?: return "1.0|1.0|1.0"
        return "%.2f|%.2f|%.2f".format(zs.zoomRatio, zs.minZoomRatio, zs.maxZoomRatio)
    }

    private fun applyZoom() {
        val cam = camera ?: return
        val zs = cam.cameraInfo.zoomState.value ?: return
        val r = zoomWanted.coerceIn(zs.minZoomRatio, zs.maxZoomRatio)
        activity?.runOnUiThread {
            try { cam.cameraControl.setZoomRatio(r) }
            catch (e: Exception) { Log.w(TAG, "zoom refused: ${e.message}") }
        }
    }

    /**
     * Exposure compensation, in the device's own EV steps. Live. Range comes
     * from getExposureRange() — it is device-specific and clamping silently
     * would hide a knob that does nothing.
     */
    @UsedByGodot
    fun setExposure(index: Int) {
        val cam = camera ?: return
        val r = cam.cameraInfo.exposureState.exposureCompensationRange
        try { cam.cameraControl.setExposureCompensationIndex(index.coerceIn(r.lower, r.upper)) }
        catch (e: Exception) { Log.w(TAG, "exposure refused: ${e.message}") }
    }

    /** "index|min|max|step_ev" — what the device actually supports. */
    @UsedByGodot
    fun getExposureRange(): String {
        val es = camera?.cameraInfo?.exposureState ?: return "0|0|0|0.0"
        val r = es.exposureCompensationRange
        return "%d|%d|%d|%.3f".format(
            es.exposureCompensationIndex, r.lower, r.upper,
            es.exposureCompensationStep.toFloat())
    }

    /**
     * ⚠️ THE ONE THAT MATTERS ON A WALL. Auto-exposure and auto-white-balance
     * hunt as people move through frame, so a projected camera image pulses
     * and colour-shifts. Locking holds the look steady for a set.
     * Implemented with startFocusAndMetering + disableAutoCancel, which needs
     * no experimental Camera2 interop; metering at frame centre.
     */
    @UsedByGodot
    fun setAeLock(on: Boolean): Boolean {
        val cam = camera ?: return false
        return try {
            if (on) {
                val f = SurfaceOrientedMeteringPointFactory(1f, 1f)
                val action = FocusMeteringAction.Builder(
                        f.createPoint(0.5f, 0.5f),
                        FocusMeteringAction.FLAG_AE or
                        FocusMeteringAction.FLAG_AWB or
                        FocusMeteringAction.FLAG_AF)
                    .disableAutoCancel()
                    .build()
                cam.cameraControl.startFocusAndMetering(action)
            } else {
                cam.cameraControl.cancelFocusAndMetering()
            }
            aeLocked = on
            Log.i(TAG, "AE/AWB lock: $on")
            true
        } catch (e: Exception) { Log.w(TAG, "AE lock refused: ${e.message}"); false }
    }

    /** Torch — a venue light source that is already in the rig. */
    @UsedByGodot
    fun setTorch(on: Boolean) {
        try { camera?.cameraControl?.enableTorch(on) }
        catch (e: Exception) { Log.w(TAG, "torch refused: ${e.message}") }
    }

    /** Analysis stream height: 480 | 720 | 1080. Applies at next start().
     *  §8 assumed 720 and nothing ever requested it — this is that lever. */
    @UsedByGodot
    fun setAnalysisRes(h: Int) { analysisRes = if (h == 480 || h == 1080) h else 720 }

    /** Detector confidence floor. Lower finds distant/marginal people at the
     *  cost of false boxes — the recall knob for the §13.7 range gate. */
    @UsedByGodot
    fun setCrowdScore(v: Float) { crowdScore = v.coerceIn(0.05f, 0.9f) }

    @UsedByGodot
    fun setCrowdModel(name: String) {
        crowdModel = when (name) {
            "edl0_int8" -> "mediapipe/edl0_int8.tflite"
            "edl0_fp16" -> "mediapipe/edl0_fp16.tflite"
            "edl0_fp32" -> "mediapipe/edl0_fp32.tflite"
            "ssd"       -> "mediapipe/ssd_mobilenet_v2.tflite"
            else -> crowdModel
        }
    }

    /** Hand tracking on/off — applies on the next start() (its own graph). */
    @UsedByGodot
    fun setHands(on: Boolean) {
        handsWanted = on
        // ⚠️ handsWanted used to gate only the BUILD, so toggling it off left the
        // already-built landmarker running and `debugHand` frozen at its last
        // value — the viewer kept drawing dots for a hand that was no longer
        // being tracked. Clear the debug data here and gate the dispatch below,
        // so "off" means off to every consumer at once.
        if (!on) synchronized(previewLock) { debugHand = FloatArray(0) }
    }

    /** Economy mode (M3): hand graph ONLY — the face landmarker is never
     *  built, the subject machine stays ABSENT, ModSource.HAND still runs.
     *  Applies at the next start(), like the delegate. Implies hands. */
    @UsedByGodot
    fun setHandsOnly(on: Boolean) { handsOnly = on }

    /** "state|analyzed_fps|result_fps|convert_ms|latency_ms|path|faces" */
    @UsedByGodot
    fun getStats(): String = statLine

    /** Crowd mode's live count for on-device feedback: "n|max|conf".
     *  The spike writes nothing to the snapshot by design (it must not disturb
     *  the fps number it measures) — which left the operator with NO way to see
     *  it working, and a viewer stuck on SEARCHING that read as a malfunction. */
    /** M8b: raw boxes for the tracker — [n, (x, y, size, conf) * n], RAW
     *  camera space, unmirrored. Empty outside crowd mode. */
    @UsedByGodot
    fun getCrowdRaw(): FloatArray = if (crowdMode) crowdRaw.copyOf() else FloatArray(1)

    @UsedByGodot
    fun getCrowdCount(): String {
        if (!crowdMode) return ""
        val n = crowdLastN
        return "%d|%d|%.2f".format(n, crowdMaxSeen, crowdLastConf)
    }

    // -- tracker viewer (M2) ------------------------------------------------

    /** Viewer open/closed — frames are only captured while true. */
    @UsedByGodot
    fun setViewer(on: Boolean) { viewerWanted = on }

    /** "w|h|rotation_degrees|seq" — seq unchanged ⇒ no new frame. */
    @UsedByGodot
    fun getPreviewInfo(): String {
        synchronized(previewLock) { return "$previewW|$previewH|$previewRot|$previewSeq" }
    }

    /** The latest RGBA_8888 frame, stride-packed. Empty until one arrives. */
    @UsedByGodot
    fun getPreviewRgba(): ByteArray {
        synchronized(previewLock) { return previewBytes.copyOf() }
    }

    /**
     * The CHOSEN subject's landmarks as x/y pairs, normalized to the
     * upright (rotation-applied) frame — the viewer's dots. LOCAL debug
     * only; the wire stays derived-values-only (doc §6).
     */
    @UsedByGodot
    fun getDebugLandmarks(): FloatArray {
        synchronized(previewLock) { return debugLandmarks.copyOf() }
    }

    /** First hand's 21 landmarks, same space — the viewer's hand dots. */
    @UsedByGodot
    fun getDebugHandLandmarks(): FloatArray {
        synchronized(previewLock) { return debugHand.copyOf() }
    }

    // --------------------------------------------------- camera publish (M6)

    /**
     * Arm the publish path over an ExternalTexture's GL name. GL THREAD ONLY.
     * Idempotent and re-armable: a Godot GL context recreation kills the name,
     * GDScript notices and calls again with the new one (NetSource's rearm
     * discipline). Returns false if the name is dead or the texture refuses —
     * the caller keeps its intent and retries.
     */
    @UsedByGodot
    fun setPreviewTexture(texId: Int, w: Int, h: Int): Boolean {
        if (texId <= 0 || w <= 0 || h <= 0) return false
        releasePubSurface()          // re-arm: the old ST is bound to a dead name
        return try {
            val st = SurfaceTexture(texId)
            st.setDefaultBufferSize(w, h)
            // Fires on an arbitrary thread — it may ONLY raise the flag; the
            // latch itself belongs to the GL thread (pumpPreview).
            st.setOnFrameAvailableListener { pubDirty.set(true) }
            pubSurfaceTexture = st
            pubSurface = Surface(st)
            pubWanted = true
            attachPreviewSurface()
            Log.i(TAG, "publish armed: tex=$texId ${w}x$h")
            true
        } catch (e: Exception) {
            Log.e(TAG, "publish arm failed: ${e.message}")
            releasePubSurface()
            false
        }
    }

    /**
     * Latch the newest camera frame onto the OES texture. GL THREAD ONLY,
     * called once per Godot frame BEFORE the frame renders. Returns true when
     * a new frame actually landed (false = nothing new, which is normal
     * whenever Godot outruns the camera).
     */
    @UsedByGodot
    fun pumpPreview(): Boolean {
        val st = pubSurfaceTexture ?: return false
        if (!pubDirty.compareAndSet(true, false)) return false
        return try {
            st.updateTexImage()
            st.getTransformMatrix(pubXform)
            pubFrames++
            pubLastFrameMs = SystemClock.uptimeMillis()
            true
        } catch (e: Exception) {
            // A dead context or a released texture lands here; the GDScript
            // rearm tick is what fixes it, so this must never throw upward.
            Log.w(TAG, "publish latch failed: ${e.message}")
            false
        }
    }

    /** The SurfaceTexture UV transform, row-major 16 floats (identity until
     *  the first latch). GDScript feeds it to the OES shader as a mat4. */
    @UsedByGodot
    fun getPreviewTransform(): FloatArray = pubXform.copyOf()

    /**
     * The publish transform CameraX actually reports:
     * "rot|mirror|cropL|cropT|cropR|cropB|bufW|bufH".
     * `rot` is the degrees the BUFFER must turn to sit upright on the operator
     * surface; `mirror` is 1 on the front lens (§4.2's audience view — the
     * same convention the landmarks already use, applied to the image so the
     * wall and the dots agree). Zeroed crop ⇒ no info yet, use the full frame.
     */
    @UsedByGodot
    fun getPublishTransform(): String =
        "%d|%d|%d|%d|%d|%d|%d|%d".format(
            pubRotDeg, if (lensFront) 1 else 0,
            pubCropL, pubCropT, pubCropR, pubCropB, pubBufW, pubBufH)

    /** "frames|age_ms|armed" — age is MILLISECONDS SINCE the last latch, never
     *  a timestamp (the JVM clock and ticks_msec share no epoch). */
    @UsedByGodot
    fun getPreviewStats(): String {
        val age = if (pubFrames > 0L) SystemClock.uptimeMillis() - pubLastFrameMs else -1L
        return "%d|%d|%d".format(pubFrames, age, if (pubWanted) 1 else 0)
    }

    /** Disarm and release. GL THREAD ONLY. The ExternalTexture and its GL name
     *  belong to GDScript and are never touched here. */
    @UsedByGodot
    fun clearPreviewTexture() {
        pubWanted = false
        detachPreviewSurface()
        releasePubSurface()
        Log.i(TAG, "publish disarmed")
    }

    private fun releasePubSurface() {
        try { pubSurface?.release() } catch (_: Exception) {}
        try { pubSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Exception) {}
        try { pubSurfaceTexture?.release() } catch (_: Exception) {}
        pubSurface = null
        pubSurfaceTexture = null
        pubDirty.set(false)
    }

    /**
     * Hand CameraX the surface. The provider callback can fire more than once
     * (CameraX re-requests after a session rebuild), so it reads the CURRENT
     * fields rather than closing over the ones armed today — a stale Surface
     * provided into a live session is a black wall nobody can debug.
     */
    private fun attachPreviewSurface() {
        val p = pubPreview ?: return          // not bound yet: start() re-attaches
        val act = activity ?: return
        act.runOnUiThread {
            try {
                p.setSurfaceProvider(ContextCompat.getMainExecutor(act)) { request ->
                    val st = pubSurfaceTexture
                    val s = pubSurface
                    if (st == null || s == null) {
                        request.willNotProvideSurface()
                    } else {
                        // Honour the resolution CameraX actually chose — the
                        // ExternalTexture's own size is only metadata (OES
                        // sampling is normalized), but the BUFFER must match
                        // or the frame arrives scaled and cropped.
                        val r = request.resolution
                        st.setDefaultBufferSize(r.width, r.height)
                        pubBufW = r.width
                        pubBufH = r.height
                        // ⚠️ REGISTERED BEFORE provideSurface. This is the only
                        // channel that carries the Preview's rotation and crop;
                        // without it the OES sample is raw sensor orientation.
                        request.setTransformationInfoListener(
                            ContextCompat.getMainExecutor(act)
                        ) { info ->
                            pubRotDeg = info.rotationDegrees
                            val c = info.cropRect
                            pubCropL = c.left; pubCropT = c.top
                            pubCropR = c.right; pubCropB = c.bottom
                            Log.i(TAG, "publish xform: rot=${info.rotationDegrees}" +
                                    " crop=[${c.left},${c.top},${c.right},${c.bottom}]" +
                                    " buf=${r.width}x${r.height} front=$lensFront")
                        }
                        request.provideSurface(s, ContextCompat.getMainExecutor(act)) { _ -> }
                        Log.i(TAG, "publish streaming: ${r.width}x${r.height}")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "publish attach failed: ${e.message}")
            }
        }
    }

    private fun detachPreviewSurface() {
        val p = pubPreview ?: return
        val act = activity ?: return
        act.runOnUiThread { try { p.setSurfaceProvider(null) } catch (_: Exception) {} }
    }

    // ------------------------------------------------------- analyzer thread

    private fun analyze(proxy: ImageProxy) {
        val t0 = SystemClock.uptimeMillis()
        try {
            val lm = landmarker
            val hl0 = handLandmarker
            val cd = crowdDetector
            if (lm == null && hl0 == null && cd == null) return
            if (t0 - lastInferMs < 1000L / inferenceHz) return  // throttle (finally closes)
            lastInferMs = t0

            val rot = proxy.imageInfo.rotationDegrees
            analysisFrames++
            crowdFrameW = proxy.width; crowdFrameH = proxy.height
            if (!loggedRes) {
                loggedRes = true
                Log.i(TAG, "analysis stream ACTUAL: ${proxy.width}x${proxy.height}" +
                        " (asked ${analysisRes}p) score=$crowdScore")
            }

            // Tracker viewer tap (M2): the frame is ALREADY RGBA_8888, so the
            // viewer costs one stride-packed copy, at most ~15 Hz, only while
            // the panel is open. Taken BEFORE detectAsync while the buffer is
            // certainly alive.
            if (viewerWanted && t0 - lastPreviewMs >= 100) {   // 10 Hz is plenty for a monitor
                lastPreviewMs = t0
                val plane = proxy.planes[0]
                val w = proxy.width; val h = proxy.height
                val rowStride = plane.rowStride
                val buf = plane.buffer
                synchronized(previewLock) {
                    val need = w * h * 4
                    if (previewBytes.size != need) previewBytes = ByteArray(need)
                    if (rowStride == w * 4) {
                        buf.position(0); buf.get(previewBytes, 0, need)
                    } else {
                        for (r in 0 until h) {
                            buf.position(r * rowStride)
                            buf.get(previewBytes, r * w * 4, w * 4)
                        }
                    }
                    previewW = w; previewH = h; previewRot = rot
                    previewSeq++
                }
            }

            val ipo = ImageProcessingOptions.builder().setRotationDegrees(rot).build()
            val mp: MPImage = if (useMediaPath) {
                val img = proxy.image ?: return
                MediaImageBuilder(img).build()
            } else {
                // Fallback: the M0 path minus the rotate-copy (rotation rides ipo).
                val bmp: Bitmap = proxy.toBitmap()
                BitmapImageBuilder(bmp).build()
            }
            synchronized(this) {
                statConvertMs += SystemClock.uptimeMillis() - t0
                statAnalyzed++
            }
            // ⚠️ MediaImage lifetime: detectAsync ingests the frame before
            // returning; the finally-close below is the documented-risk spot
            // (doc §10 #4). If the device shows corrupt frames or native
            // trouble on the media path, setInputPath("bitmap") is the switch.
            if (cd != null) cd.detectAsync(mp, ipo, t0) else lm?.detectAsync(mp, ipo, t0)
            val hl = handLandmarker
            if (hl != null && (handsWanted || handsOnly)) {
                // A second MPImage wrapper over the same RGBA frame — each
                // graph ingests during its own detectAsync. When the face
                // graph is absent (hands-only), hands take the first wrap.
                val mp2: MPImage = if (lm != null && useMediaPath) {
                    val img2 = proxy.image
                    if (img2 != null) MediaImageBuilder(img2).build() else mp
                } else mp
                hl.detectAsync(mp2, ipo, t0)
            }
        } catch (e: Exception) {
            if (useMediaPath) {
                useMediaPath = false
                Log.w(TAG, "media path threw -> bitmap fallback: ${e.message}")
            } else {
                Log.e(TAG, "analyze failed: ${e.message}")
            }
        } finally {
            proxy.close()
        }
    }

    // ------------------------------------------------- landmarker listener

    private fun onResult(result: FaceLandmarkerResult) = synchronized(stateLock) {
        val now = SystemClock.uptimeMillis()
        val camTs = result.timestampMs()

        // ---- §5.2 arbitration: sticky nearest-to-last while held, largest
        // face at the door — and the door has a debounce: the largest face
        // must HOLD (same spot within the jump gate) across consecutive
        // inferences before ACQUIRING starts. All matching runs in RAW
        // camera space; the §4.2 audience-view mirror happens at output
        // only (the M1 bug: mirrored lastX vs raw n.x() made any off-center
        // front-lens subject exceed MAX_JUMP and churn the lock).
        val faces = result.faceLandmarks()
        var best = -1
        var candStable = false
        if (faces.isNotEmpty()) {
            if (st == St.PRESENT || st == St.GRACE) {
                var bd = Float.MAX_VALUE
                for (i in faces.indices) {
                    val n = faces[i][LM_NOSE_TIP]
                    val d = hypot((n.x() - lastX).toDouble(), (n.y() - lastY).toDouble()).toFloat()
                    if (d < bd) { bd = d; best = i }
                }
                if (bd > MAX_JUMP) best = -1   // someone ELSE where ours was lost
            } else {
                var bs = -1f
                for (i in faces.indices) {
                    val l = faces[i][LM_EYE_OUTER_L]; val r = faces[i][LM_EYE_OUTER_R]
                    val s = abs(l.x() - r.x())
                    if (s > bs) { bs = s; best = i }
                }
                if (best >= 0) {
                    val n = faces[best][LM_NOSE_TIP]
                    val d = hypot((n.x() - candX).toDouble(), (n.y() - candY).toDouble()).toFloat()
                    candStable = candX >= 0f && d <= MAX_JUMP
                    candX = n.x(); candY = n.y()
                }
            }
        }
        if (best < 0) { candX = -1f; candY = -1f }
        val raw = best >= 0

        // ---- raw measurements for the chosen subject
        var x = 0f; var y = 0f; var size = 0f; var tz = 0f; var hasTz = false
        if (raw) {
            val f = faces[best]
            val n = f[LM_NOSE_TIP]
            lastX = n.x(); lastY = n.y()       // continuity in RAW space
            x = n.x(); y = n.y()
            if (lensFront) x = 1f - x          // §4.2: audience-view convention
            size = abs(f[LM_EYE_OUTER_L].x() - f[LM_EYE_OUTER_R].x())
            val mats = result.facialTransformationMatrixes()
            if (mats.isPresent && mats.get().size > best) {
                tz = mats.get()[best][14]      // column-major 4x4 translation z
                hasTz = true
            }
        }

        // Viewer dots (M2): the chosen face's full landmark set, x/y pairs.
        // Captured only while the panel is open; cleared on miss so stale
        // dots never hover over an empty frame.
        if (viewerWanted) {
            synchronized(previewLock) {
                if (raw) {
                    val f = faces[best]
                    if (debugLandmarks.size != f.size * 2) debugLandmarks = FloatArray(f.size * 2)
                    for (i in f.indices) {
                        var lx = f[i].x()
                        if (lensFront) lx = 1f - lx
                        debugLandmarks[i * 2] = lx
                        debugLandmarks[i * 2 + 1] = f[i].y()
                    }
                } else if (debugLandmarks.isNotEmpty()) {
                    debugLandmarks = FloatArray(0)
                }
            }
        }

        // ---- §5.3 state machine
        if (rebaselineAsked) {
            rebaselineAsked = false
            if (st == St.PRESENT) { st = St.ACQUIRING; baseline.clear(); stTicks = 0 }
        }
        var presence = 0f
        when (st) {
            St.ABSENT -> {
                // candStable: seen at the same spot twice running — a
                // one-frame phantom never opens the door (§5.2 debounce).
                if (raw && candStable) { st = St.ACQUIRING; stTicks = 0; baseline.clear() }
            }
            St.ACQUIRING -> {
                if (!raw) { st = St.ABSENT; baseline.clear() }
                else if (!candStable) {
                    // largest face JUMPED mid-acquire — a different person
                    // now fills the doorway; their clock starts over.
                    stTicks = 0; baseline.clear()
                } else {
                    stTicks++
                    if (stTicks >= ACQUIRE_TICKS && hasTz) baseline.add(tz)
                    if (baseline.size >= BASELINE_TICKS) {
                        val sorted = baseline.sorted()
                        zRef = sorted[sorted.size / 2]
                        filters.reset()        // §5.1: never warm-start a new subject
                        st = St.PRESENT
                        Log.i(TAG, "subject acquired: zRef=%.1f".format(zRef))
                        emitSignal("subject_acquired")
                    }
                }
            }
            St.PRESENT -> {
                presence = 1f
                if (!raw) { st = St.GRACE; graceStartMs = now }
            }
            St.GRACE -> {
                presence = 1f                  // §5.3: a blink is not a departure
                if (raw) st = St.PRESENT       // baseline kept
                else if (now - graceStartMs > GRACE_MS) {
                    st = St.ABSENT
                    presence = 0f
                    Log.i(TAG, "subject lost")
                    emitSignal("subject_lost")
                }
            }
        }

        // ---- filter + normalise (only while we truly see the subject;
        // GRACE/ABSENT hold the last filtered output — doc §5.2: freeze,
        // never decay)
        if (raw && st == St.PRESENT) {
            val fx = filters.filter(0, x, camTs)
            val fy = filters.filter(1, y, camTs)
            val fz = if (hasTz) filters.filter(2, tz, camTs) else zRef
            val rel = if (zRef != 0f) (fz - zRef) / zRef else 0f   // + = farther (signs cancel)
            frozen[0] = fx
            frozen[1] = fy
            frozen[2] = (0.5f + rel / (2f * Z_SPAN)).coerceIn(0f, 1f)
        }

        // ---- publish
        synchronized(snapLock) {
            seq++
            lastResultCamTs = camTs
            snap[IDX_SEQ] = seq.toFloat()
            snap[IDX_MODE] = 1f
            snap[IDX_PRESENCE] = presence
            snap[IDX_PRESENCE_RAW] = if (raw) 1f else 0f
            snap[IDX_AGE_MS] = (now - camTs).toFloat()
            snap[IDX_HEAD_X] = frozen[0]
            snap[IDX_HEAD_Y] = frozen[1]
            snap[IDX_HEAD_Z] = frozen[2]
            snap[IDX_HEAD_SIZE] = if (raw) filters.filter(3, size, camTs) else snap[IDX_HEAD_SIZE]
            snap[IDX_YAW] = 0.5f
            snap[IDX_PITCH] = 0.5f
            snap[IDX_ROLL] = 0.5f
            snap[IDX_CROWDED] = if (faces.size > 1) 1f else 0f
            snap[IDX_N_FACES] = faces.size.toFloat()
        }

        // ---- 1 Hz stats
        var line: String? = null
        synchronized(this) {
            statResults++
            statLatencyMs += now - camTs
            if (now - statMarkMs >= 1000) {
                val secs = (now - statMarkMs) / 1000.0
                val convAvg = if (statAnalyzed > 0) statConvertMs / statAnalyzed else 0
                val latAvg = if (statResults > 0) statLatencyMs / statResults else 0
                line = "%s|%.1f|%.1f|%d|%d|%s|%d".format(
                    st.name.lowercase(), statAnalyzed / secs, statResults / secs,
                    convAvg, latAvg, if (useMediaPath) "media" else "bitmap", faces.size)
                statAnalyzed = 0; statResults = 0
                statConvertMs = 0; statLatencyMs = 0
                statMarkMs = now
            }
        }
        if (line != null) {
            statLine = line!!
            Log.i(TAG, line!!)
        }
    }

    // ------------------------------------------- crowd listener (M8a spike)

    /**
     * Person boxes -> a 1 Hz logcat line, and nothing else. Deliberately no
     * snapshot write and no signal: M8a is a measurement, and anything that
     * touches the deck would contaminate the very fps number it exists to take.
     *
     * Line: crowd|analyzed_hz|results_hz|convert_ms|latency_ms|path|n|max_n|avg_score|tallest
     *   n         persons THIS inference           max_n   most seen in the window
     *   avg_score mean confidence over the window  tallest largest box height / frame
     * `tallest` is §13.3's `size` channel in embryo — the distance proxy that
     * replaces the z §4.1 refuses to invent for a box.
     */
    private fun onCrowdResult(result: ObjectDetectorResult) {
        val now = SystemClock.uptimeMillis()
        val camTs = result.timestampMs()
        val dets = result.detections()
        val n = dets.size
        var tallest = 0f
        var scoreSum = 0.0
        val fh = if (crowdFrameH > 0) crowdFrameH.toFloat() else 1f
        for (d in dets) {
            val b = d.boundingBox()
            val hFrac = (b.bottom - b.top) / fh
            if (hFrac > tallest) tallest = hFrac
            val cats = d.categories()
            if (cats.isNotEmpty()) scoreSum += cats[0].score().toDouble()
        }
        crowdLastN = n
        crowdLastConf = if (n > 0) (scoreSum / n).toFloat() else 0f
        // pack for the tracker: centre + height fraction (§13.3's `size`, the
        // distance proxy that replaces the z §4.1 refuses to invent for a box)
        val fw = if (crowdFrameW > 0) crowdFrameW.toFloat() else 1f
        val packed = FloatArray(1 + n * 4)
        packed[0] = n.toFloat()
        var pi = 1
        for (d in dets) {
            val b = d.boundingBox()
            packed[pi++] = ((b.left + b.right) * 0.5f) / fw
            packed[pi++] = ((b.top + b.bottom) * 0.5f) / fh
            packed[pi++] = (b.bottom - b.top) / fh
            packed[pi++] = if (d.categories().isNotEmpty()) d.categories()[0].score() else 0f
        }
        crowdRaw = packed
        // ⚠️ THE SNAPSHOT MUST TICK IN CROWD MODE TOO. The M8a spike wrote
        // NOTHING here on purpose — a measurement must not disturb the fps
        // number it takes — but GDScript drives everything off `seq` advancing,
        // so with the snapshot frozen the CrowdTracker was never fed: the
        // Kotlin-side viewer showed "1 seen" while the GDScript readout showed
        // "CROWD 0" and the shader drew nothing. That constraint is spent now
        // M8a has its numbers; M8b is a feature and has to reach the deck.
        synchronized(snapLock) {
            seq++
            snap[IDX_SEQ] = seq.toFloat()
            snap[IDX_MODE] = 3f                       // 0 off · 1 landmark · 2 field · 3 crowd
            snap[IDX_PRESENCE] = if (n > 0) 1f else 0f
            snap[IDX_PRESENCE_RAW] = if (n > 0) 1f else 0f
            snap[IDX_AGE_MS] = (now - camTs).toFloat()
            snap[IDX_N_FACES] = n.toFloat()           // detections this inference
        }
        var line: String? = null
        synchronized(this) {
            statResults++
            statLatencyMs += now - camTs
            crowdDetSum += n
            crowdScoreSum += scoreSum
            if (n > crowdMaxSeen) crowdMaxSeen = n
            if (now - statMarkMs >= 1000) {
                val secs = (now - statMarkMs) / 1000.0
                val convAvg = if (statAnalyzed > 0) statConvertMs / statAnalyzed else 0
                val latAvg = if (statResults > 0) statLatencyMs / statResults else 0
                val scoreAvg = if (crowdDetSum > 0) crowdScoreSum / crowdDetSum else 0.0
                line = "crowd|%.1f|%.1f|%d|%d|%s|%d|%d|%.2f|%.2f".format(
                    statAnalyzed / secs, statResults / secs, convAvg, latAvg,
                    if (useMediaPath) "media" else "bitmap",
                    n, crowdMaxSeen, scoreAvg, tallest)
                statAnalyzed = 0; statResults = 0
                statConvertMs = 0; statLatencyMs = 0
                crowdMaxSeen = 0; crowdScoreSum = 0.0; crowdDetSum = 0
                statMarkMs = now
            }
        }
        if (line != null) {
            statLine = line!!
            Log.i(TAG, line!!)
        }
    }

    // ------------------------------------------------- hand listener (M2b)

    private fun onHandResult(result: HandLandmarkerResult) = synchronized(stateLock) {
        val camTs = result.timestampMs()
        val hands = result.landmarks()
        val has = hands.isNotEmpty()
        var hx = 0f; var hy = 0f
        if (has) {
            // Two hands may arrive; the snapshot follows the HIGHER one —
            // the raise-your-arm modulation wants the raised arm.
            var pick = 0
            for (i in hands.indices) {
                if (hands[i][LM_PALM].y() < hands[pick][LM_PALM].y()) pick = i
            }
            val palm = hands[pick][LM_PALM]
            hx = palm.x(); hy = palm.y()
            if (lensFront) hx = 1f - hx
            hx = filters.filter(4, hx, camTs)
            hy = filters.filter(5, hy, camTs)
        }
        synchronized(snapLock) {
            seq++
            snap[IDX_HAND_PRESENT] = if (has) 1f else 0f
            if (has) { snap[IDX_HAND_X] = hx; snap[IDX_HAND_Y] = hy }
        }
        // Hands-only (M3 economy): the face listener never runs, so the
        // 1 Hz stats line is emitted here — same shape, state "hands",
        // trailing count is HANDS seen, not faces.
        if (landmarker == null) {
            val now = SystemClock.uptimeMillis()
            var line: String? = null
            synchronized(this) {
                statResults++
                statLatencyMs += now - camTs
                if (now - statMarkMs >= 1000) {
                    val secs = (now - statMarkMs) / 1000.0
                    val convAvg = if (statAnalyzed > 0) statConvertMs / statAnalyzed else 0
                    val latAvg = if (statResults > 0) statLatencyMs / statResults else 0
                    line = "hands|%.1f|%.1f|%d|%d|%s|%d".format(
                        statAnalyzed / secs, statResults / secs, convAvg, latAvg,
                        if (useMediaPath) "media" else "bitmap", hands.size)
                    statAnalyzed = 0; statResults = 0
                    statConvertMs = 0; statLatencyMs = 0
                    statMarkMs = now
                }
            }
            if (line != null) {
                statLine = line!!
                Log.i(TAG, line!!)
            }
        }
        if (viewerWanted) {
            synchronized(previewLock) {
                if (has) {
                    var total = 0
                    for (h in hands) total += h.size
                    if (debugHand.size != total * 2) debugHand = FloatArray(total * 2)
                    var j = 0
                    for (h in hands) for (p in h) {
                        var lx = p.x()
                        if (lensFront) lx = 1f - lx
                        debugHand[j++] = lx
                        debugHand[j++] = p.y()
                    }
                } else if (debugHand.isNotEmpty()) {
                    debugHand = FloatArray(0)
                }
            }
        }
    }

    // ---------------------------------------------------------------- misc

    private fun resetSubject(why: String) {
        st = St.ABSENT
        stTicks = 0
        candX = -1f; candY = -1f
        baseline.clear()
        zRef = 0f
        frozen = FloatArray(3) { 0.5f }
        Log.i(TAG, "subject state reset ($why)")
    }

    /**
     * ⚠️ Teardown DETACHES the session synchronously and closes it elsewhere.
     * The first version queued the whole teardown on the UI thread; a lens
     * switch (stop + immediate start) then had the queued close land AFTER
     * the NEW session was built — closing the new landmarker's guts and
     * wedging the app (Session 33, the lens-switch freeze). Now the fields
     * are nulled on the CALLING thread (a later start() can never collide),
     * unbindAll goes to the UI thread with a CAPTURED provider reference,
     * and the potentially-blocking landmarker.close() runs on a throwaway
     * worker so no thread anyone cares about waits on the graph.
     */
    private fun teardown(silent: Boolean) {
        val wasRunning = running
        running = false
        val lm = landmarker; landmarker = null
        val hlm = handLandmarker; handLandmarker = null
        val cdet = crowdDetector; crowdDetector = null
        camera = null
        cameraOnly = false
        aeLocked = false
        crowdMode = false
        val prov = cameraProvider; cameraProvider = null
        val exec = analysisExecutor; analysisExecutor = null
        // The Preview dies with the session; pubWanted and the SurfaceTexture
        // SURVIVE — they belong to GDScript's ExternalTexture, and start()
        // re-attaches. Tearing them down here would blank the wall on every
        // lens switch and orphan the texture GDScript still holds.
        pubPreview = null
        activity?.runOnUiThread { try { prov?.unbindAll() } catch (_: Exception) {} }
        Thread({
            exec?.shutdown()
            try { lm?.close() } catch (_: Exception) {}
            try { hlm?.close() } catch (_: Exception) {}
            try { cdet?.close() } catch (_: Exception) {}
            Log.i(TAG, "session closed")
        }, "TrackingTeardown").start()
        synchronized(stateLock) { resetSubject("stop") }
        statLine = "idle"
        if (wasRunning && !silent) emitSignal("tracking_stopped")
        Log.i(TAG, "stopped")
    }

    override fun onMainPause() {
        super.onMainPause()
        // §9: backgrounded = torn down; GDScript owns restart policy.
        if (running) teardown(silent = false)
    }
}
