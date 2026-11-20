package com.pocketvj

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Bundle
import android.os.StatFs
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Records OutputWorld — the finished projected image, post warp/mask/FX — to
 * MP4 using the hardware H.264/HEVC encoder. SET_RECORDING_SPEC.md approach A.
 *
 * The encoder is just another consumer of the texture the projector bridge
 * already blits: a GlBlitter target created on MediaCodec's input Surface
 * instead of on the projector's SurfaceView, fed from the same onGLDrawFrame.
 *
 * ⚠️ THE HARD PART IS STORAGE, NOT THE ENCODER. The spike measured 0.51 ms of
 * encoder swap against a 16.6 ms frame budget — encoding is nearly free. But
 * MP4 finalization writes the `moov` atom at stop(), so IF THE DISK IS FULL AT
 * THAT MOMENT THE WHOLE RECORDING IS UNPLAYABLE. Stopping early against a
 * reserve is therefore not a nicety; it is the mechanism that makes "save what
 * we have" work at all. Two independent guards enforce it:
 *   - GDScript polls free space at 1 Hz and stops gracefully with UI warning;
 *   - the drain thread re-checks against `reserveBytes` itself, so a stalled or
 *     broken UI thread cannot cost a recording.
 *
 * Segmenting (default 5 min) rolls to a new file WITHOUT restarting the encoder,
 * so no frame is dropped at a boundary. It caps what any single failure can lose
 * and sidesteps MediaMuxer's ~4 GiB ceiling (MPEG4Writer uses 32-bit chunk
 * offsets).
 *
 * AUDIO (AudioEncoder + SegmentMuxer) is a second track in the same files. The
 * muxer moved out into SegmentMuxer when it gained that track: two encoder
 * threads cannot share a MediaMuxer without a lock, and a segment can no longer
 * open on the video format alone.
 *
 * THREADING mirrors EglBridge: EGL/GL only on Godot's render thread inside
 * drawFrame(); the muxer drains on its own thread so file I/O never lands in the
 * render-thread cost.
 */
object SurfaceRecorder {
    private const val TAG = "PocketVJRec"
    private const val STAT_PERIOD_NS = 5_000_000_000L

    /** How long to wait for the audio encoder's format before recording mute. */
    private const val AUDIO_FORMAT_TIMEOUT_NS = 3_000_000_000L

    /** Cap on video held back while waiting for that format (~1 s at 12 Mbps). */
    private const val STASH_MAX_BYTES = 4 * 1024 * 1024

    // -- published state (any thread) --
    private val lock = Any()
    private val doneLock = Any()
    private var pendingSurface: Surface? = null
    private var generation = 0
    @Volatile private var texId = 0
    @Volatile private var texW = 0
    @Volatile private var texH = 0
    @Volatile private var flipY = true
    @Volatile private var stopRequested = false

    // -- encoder --
    private var codec: MediaCodec? = null
    private var drainThread: Thread? = null
    private var outDir: File? = null
    private var segmentSeconds = 300
    private var reserveBytes = 512L * 1024 * 1024
    @Volatile private var audioWanted = false
    @Volatile private var eosSignalled = false
    @Volatile private var releasePending = false
    @Volatile private var rollRequested = false
    @Volatile private var lastError: String = ""

    // -- drain completion latch (video + audio must BOTH finish before moov) --
    @Volatile private var videoDrainDone = false
    @Volatile private var audioDrainDone = true
    private var finished = false

    // -- GL-thread state --
    private var boundGeneration = -1
    private var target: GlBlitter.Target? = null
    private var failedGeneration = -1

    /**
     * t0 of the whole recording, in nanoTime. Video PTS is measured from it, and
     * AudioEncoder anchors to it too — ONE clock for both tracks is what makes
     * them line up at all. Volatile because the audio feeder thread reads it.
     */
    @Volatile private var startNs = 0L

    private var statFrames = 0
    private var statSwapNs = 0L
    private var statSwapMaxNs = 0L
    private var statMarkNs = 0L
    private var runFrames = 0
    private var runSwapNs = 0L
    private var runSwapMaxNs = 0L
    private var runStartNs = 0L

    fun setSourceTexture(id: Int, w: Int, h: Int) {
        texId = id; texW = w; texH = h
    }

    fun setFlipY(flip: Boolean) { flipY = flip }

    fun isRecording(): Boolean = codec != null && !stopRequested

    /** The shared A/V t0. 0 until the GL thread has bound the encoder surface. */
    fun videoOriginNs(): Long = startNs

    /**
     * Compact state for the UI, polled at ~1 Hz:
     *   rec|<elapsed_s>|<bytes>|<bytes_per_sec>|<segment_count>|<dir>|<error>|<audio>
     * or idle|0|0|0|0||<error>|0
     *
     * bytes_per_sec is MEASURED, not derived from the configured bitrate — VBR
     * output moves a lot with content complexity, so the remaining-time figure
     * the user sees has to be built on what is actually being written.
     */
    fun stats(): String {
        if (codec == null) return "idle|0|0|0|0||$lastError|0"
        val secs = if (runStartNs > 0) (System.nanoTime() - runStartNs) / 1e9 else 0.0
        val bytes = SegmentMuxer.bytes
        val bps = if (secs > 0.5) (bytes / secs).toLong() else 0L
        return "rec|%.1f|%d|%d|%d|%s|%s|%d".format(
            secs, bytes, bps, SegmentMuxer.segmentIndex, outDir?.absolutePath ?: "",
            lastError, if (SegmentMuxer.hasAudioTrack()) 1 else 0)
    }

    /**
     * Free bytes on the filesystem holding `path`. StatFs throws on a path that
     * does not exist yet — and the recordings dir won't, before the first ever
     * recording — so walk up to the nearest existing ancestor.
     */
    fun freeBytes(path: String): Long = statOf(path)?.availableBytes ?: -1L

    fun totalBytes(path: String): Long = statOf(path)?.totalBytes ?: -1L

    private fun statOf(path: String): StatFs? {
        var f: File? = File(path)
        while (f != null) {
            if (f.exists()) {
                return try { StatFs(f.absolutePath) } catch (e: Exception) {
                    Log.w(TAG, "StatFs(${f.absolutePath}) failed: ${e.message}"); null
                }
            }
            f = f.parentFile
        }
        return null
    }

    /**
     * Configure + start the encoders, create the set directory, publish the input
     * Surface. Called from the UI thread; the GL thread picks it up next frame.
     * @return "ok:<dir>:<codec-caps>" or an error token.
     */
    fun start(
        baseDir: String, w: Int, h: Int, fps: Int, bitrateKbps: Int, mime: String,
        segmentSecs: Int, reserve: Long,
        audioEnabled: Boolean, audioRate: Int, audioBitrateKbps: Int,
    ): String {
        if (codec != null) return "already-recording"
        lastError = ""
        eosSignalled = false; releasePending = false; stopRequested = false
        rollRequested = false
        videoDrainDone = false
        finished = false
        segmentSeconds = if (segmentSecs < 30) 30 else segmentSecs
        reserveBytes = reserve
        audioWanted = audioEnabled
        audioDrainDone = !audioEnabled
        startNs = 0L

        val free = freeBytes(baseDir)
        if (free in 0 until reserve) return "no-space:${free / 1048576}MB"

        val caps = describeEncoder(mime, w, h, fps)
        try {
            val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val dir = File(baseDir, "set_$stamp")
            if (!dir.exists() && !dir.mkdirs()) return "mkdir-failed:${dir.absolutePath}"
            outDir = dir
            SegmentMuxer.begin(dir, audioEnabled)

            val fmt = MediaFormat.createVideoFormat(mime, w, h).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                setInteger(MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            }
            val c = MediaCodec.createEncoderByType(mime)
            c.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val input = c.createInputSurface()
            c.start()
            codec = c

            if (audioEnabled) {
                val a = AudioEncoder.start(audioRate, audioBitrateKbps)
                if (a != "ok") {
                    // Record mute rather than not at all.
                    Log.w(TAG, "audio unavailable ($a) — recording video only")
                    audioWanted = false
                    audioDrainDone = true
                    lastError = "audio-off"
                    SegmentMuxer.begin(dir, false)
                }
            }

            synchronized(lock) { pendingSurface = input; generation++ }
            startDrain()

            Log.i(TAG, "REC START: ${dir.absolutePath}")
            Log.i(TAG, "REC ENCODER: $caps, ${bitrateKbps}kbps, segment ${segmentSeconds}s, " +
                    "reserve ${reserve / 1048576}MB, free ${free / 1048576}MB, " +
                    "audio=${if (audioWanted) "${audioRate}Hz/${audioBitrateKbps}kbps" else "off"}")
            return "ok:${dir.absolutePath}:$caps"
        } catch (e: Exception) {
            Log.e(TAG, "start failed: ${e.message}", e)
            hardRelease()
            return "start-failed:${e.message}"
        }
    }

    /**
     * Ask the GL thread to stop feeding and signal end-of-stream. Returns
     * immediately; the muxer is finalized on the drain threads and the EGL target
     * released on a later GL frame. `reason` is recorded for the UI.
     */
    fun stop(reason: String = ""): String {
        if (codec == null) return "not-recording"
        if (reason.isNotEmpty() && lastError.isEmpty()) lastError = reason
        stopRequested = true
        AudioEncoder.signalStop()
        val secs = if (runStartNs > 0) (System.nanoTime() - runStartNs) / 1e9 else 0.0
        val summary = ("REC STOP: %s | %.1fs, %d segments | fed %d frames (%.1f fps) | " +
                "swap avg %.2f ms max %.2f ms | %.1f MB (%.1f MB/min)%s%s").format(
            outDir?.absolutePath ?: "?", secs, SegmentMuxer.segmentIndex, runFrames,
            if (secs > 0) runFrames / secs else 0.0,
            if (runFrames > 0) runSwapNs / 1e6 / runFrames else 0.0, runSwapMaxNs / 1e6,
            SegmentMuxer.bytes / 1e6,
            if (secs > 0) SegmentMuxer.bytes / 1e6 / (secs / 60.0) else 0.0,
            if (audioWanted) " | ${AudioEncoder.summary()}" else " | audio off",
            if (lastError.isEmpty()) "" else " | $lastError")
        Log.i(TAG, summary)
        return summary
    }

    fun onGodotContextRecreated() {
        target = null
        boundGeneration = -1
        failedGeneration = -1
    }

    // --- GL thread ---------------------------------------------------------

    fun drawFrame() {
        val gen: Int
        val surf: Surface?
        synchronized(lock) { gen = generation; surf = pendingSurface }

        if (gen != boundGeneration) {
            GlBlitter.release(target); target = null
            boundGeneration = gen
            if (surf != null && surf.isValid && gen != failedGeneration) {
                target = GlBlitter.acquireTarget(surf, "encoder")
                if (target == null) {
                    failedGeneration = gen
                    lastError = "egl-init-failed"
                } else {
                    val now = System.nanoTime()
                    startNs = now; runStartNs = now
                    runFrames = 0; runSwapNs = 0; runSwapMaxNs = 0
                    statFrames = 0; statSwapNs = 0; statSwapMaxNs = 0; statMarkNs = now
                }
            }
        }

        // The drain threads finished the muxer; the EGL target and codec are ours
        // to release (EGL objects belong to this thread).
        if (releasePending) {
            releasePending = false
            GlBlitter.release(target); target = null
            synchronized(lock) { pendingSurface = null; generation++ }
            boundGeneration = generation
            hardRelease()
            return
        }

        val t = target ?: return
        if (!t.alive) { GlBlitter.release(t); target = null; return }
        if (texId == 0) return

        if (stopRequested) {
            if (!eosSignalled) {
                eosSignalled = true
                try {
                    codec?.signalEndOfInputStream()
                    Log.i(TAG, "EOS signalled after $runFrames frames")
                } catch (e: Exception) {
                    Log.w(TAG, "signalEndOfInputStream: ${e.message}")
                }
            }
            return
        }

        val swapNs = GlBlitter.blit(t, texId, flipY, System.nanoTime() - startNs)
        if (swapNs < 0) return

        // Time inside the encoder's swap IS the back-pressure meter: a codec
        // that cannot keep up fills its BufferQueue and blocks us right here.
        statFrames++; statSwapNs += swapNs
        if (swapNs > statSwapMaxNs) statSwapMaxNs = swapNs
        runFrames++; runSwapNs += swapNs
        if (swapNs > runSwapMaxNs) runSwapMaxNs = swapNs

        val now = System.nanoTime()
        if (now - statMarkNs >= STAT_PERIOD_NS) {
            val secs = (now - statMarkNs) / 1e9
            Log.i(TAG, ("blit %.1f fps · swap avg %.2f ms (max %.2f) · seg %d · " +
                    "%d video / %d audio · %.1f MB · tex=%d %dx%d -> %dx%d").format(
                statFrames / secs, statSwapNs / 1e6 / statFrames, statSwapMaxNs / 1e6,
                SegmentMuxer.segmentIndex, SegmentMuxer.videoFrames,
                SegmentMuxer.audioFrames, SegmentMuxer.bytes / 1e6,
                texId, texW, texH, t.w, t.h))
            statFrames = 0; statSwapNs = 0; statSwapMaxNs = 0; statMarkNs = now
        }
    }

    // --- encoder / muxer half ---------------------------------------------

    /**
     * Video encoded before the muxer could open, held rather than dropped.
     *
     * ⚠️ WHY THIS EXISTS: with one track the muxer opened on
     * INFO_OUTPUT_FORMAT_CHANGED, which precedes any data buffer, so nothing was
     * ever in flight first. With two tracks the file cannot open until the AUDIO
     * format also arrives, and the video encoder does not wait — releasing those
     * buffers would silently eat the first frames of every recording AND could
     * leave the first written sample a non-keyframe.
     */
    private class Stashed(val data: ByteArray, val ptsUs: Long, val flags: Int)

    private val stash = ArrayList<Stashed>()
    private var stashBytes = 0

    private fun stashVideo(buf: ByteBuffer, info: MediaCodec.BufferInfo) {
        if (stashBytes + info.size > STASH_MAX_BYTES) return
        val a = ByteArray(info.size)
        buf.position(info.offset)
        buf.limit(info.offset + info.size)
        buf.get(a)
        stash.add(Stashed(a, info.presentationTimeUs, info.flags))
        stashBytes += info.size
    }

    private fun flushStash() {
        if (stash.isEmpty()) return
        val info = MediaCodec.BufferInfo()
        for (s in stash) {
            info.set(0, s.data.size, s.ptsUs, s.flags)
            SegmentMuxer.writeVideo(ByteBuffer.wrap(s.data), info, false)
        }
        Log.i(TAG, "flushed ${stash.size} held video frames (${stashBytes / 1024} KB)")
        stash.clear()
        stashBytes = 0
    }

    private fun startDrain() {
        val t = Thread({
            val info = MediaCodec.BufferInfo()
            var segStartNs = System.nanoTime()
            var lastSpaceCheckNs = 0L
            var eosWaitStartNs = 0L
            var videoFormatNs = 0L
            stash.clear(); stashBytes = 0
            try {
                while (true) {
                    val c = codec ?: break
                    val idx = c.dequeueOutputBuffer(info, 10_000)

                    if (stopRequested) AudioEncoder.signalStop()

                    // EOS is the normal way out of this loop. If the encoder died
                    // it will never come, and without a bound this thread spins
                    // forever and releasePending never fires — the recorder would
                    // wedge with no way back short of restarting the app.
                    if (eosSignalled) {
                        if (eosWaitStartNs == 0L) eosWaitStartNs = System.nanoTime()
                        else if (System.nanoTime() - eosWaitStartNs > 5_000_000_000L) {
                            Log.w(TAG, "no EOS 5 s after signal — finalizing anyway")
                            if (lastError.isEmpty()) lastError = "eos-timeout"
                            break
                        }
                    }

                    // Audio was asked for but never produced a format. Open the
                    // file without it rather than lose the video too.
                    if (!SegmentMuxer.isOpen() && videoFormatNs > 0L &&
                        System.nanoTime() - videoFormatNs > AUDIO_FORMAT_TIMEOUT_NS
                    ) {
                        if (SegmentMuxer.dropAudioAndOpen()) {
                            lastError = "audio-timeout"
                            flushStash()
                        }
                    }

                    // Hard storage floor, independent of the UI thread. If this
                    // fires we still have `reserveBytes` of room to write moov.
                    val nowNs = System.nanoTime()
                    if (nowNs - lastSpaceCheckNs > 2_000_000_000L) {
                        lastSpaceCheckNs = nowNs
                        val dir = outDir
                        if (dir != null && !stopRequested) {
                            val free = freeBytes(dir.absolutePath)
                            if (free in 0 until reserveBytes) {
                                Log.w(TAG, "storage floor hit (${free / 1048576}MB free) — stopping")
                                lastError = "disk-full"
                                stopRequested = true
                            }
                        }
                    }

                    // Segment roll: ask for a keyframe, then swap muxers on it so
                    // every part starts on an IDR and is independently playable.
                    if (!rollRequested && !stopRequested && SegmentMuxer.isOpen() &&
                        (nowNs - segStartNs) / 1_000_000_000L >= segmentSeconds
                    ) {
                        rollRequested = true
                        try {
                            c.setParameters(Bundle().apply {
                                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                            })
                        } catch (e: Exception) {
                            Log.w(TAG, "request sync frame: ${e.message}")
                        }
                    }

                    when {
                        idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            videoFormatNs = System.nanoTime()
                            SegmentMuxer.publishVideoFormat(c.outputFormat)
                            Log.i(TAG, "encoder format: ${c.outputFormat}")
                            if (SegmentMuxer.maybeOpen()) flushStash()
                        }
                        idx >= 0 -> {
                            val buf = c.getOutputBuffer(idx)
                            val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                            val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0

                            if (buf != null && !isConfig && info.size > 0) {
                                if (!SegmentMuxer.isOpen()) {
                                    stashVideo(buf, info)
                                } else {
                                    val roll = rollRequested && isKey
                                    if (!SegmentMuxer.writeVideo(buf, info, roll)) {
                                        // Disk filled between checks, or the
                                        // muxer died.
                                        lastError = SegmentMuxer.lastError
                                            .ifEmpty { "write-failed" }
                                        stopRequested = true
                                    } else if (roll) {
                                        segStartNs = System.nanoTime()
                                        rollRequested = false
                                    }
                                }
                            }
                            c.releaseOutputBuffer(idx, false)
                            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                Log.i(TAG, "drain saw EOS")
                                break
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "drain failed: ${e.message}", e)
                if (lastError.isEmpty()) lastError = "drain:${e.message}"
            }
            videoDrainDone = true
            finishIfBothDone()
        }, "PocketVJRecDrain")
        t.start()
        drainThread = t
    }

    /** Called by AudioEncoder's drain thread when its EOS has been processed. */
    fun onAudioDrainFinished() {
        audioDrainDone = true
        finishIfBothDone()
    }

    /**
     * moov is written HERE, and only once both encoders have stopped producing.
     * Closing the muxer while the audio drain is still writing would truncate
     * the audio track or crash inside MediaMuxer.
     */
    private fun finishIfBothDone() {
        synchronized(doneLock) {
            if (finished || !videoDrainDone || !audioDrainDone) return
            finished = true
            SegmentMuxer.finish()
            if (lastError.isEmpty() && SegmentMuxer.lastError.isNotEmpty()) {
                lastError = SegmentMuxer.lastError
            }
            Log.i(TAG, "REC FILES DONE: ${outDir?.absolutePath} — " +
                    "${SegmentMuxer.segmentIndex} segment(s), " +
                    "${SegmentMuxer.videoFrames} video frames, " +
                    "${SegmentMuxer.audioFrames} audio samples, " +
                    "${"%.1f".format(SegmentMuxer.bytes / 1e6)} MB" +
                    (if (SegmentMuxer.droppedAudio > 0)
                        " | ${SegmentMuxer.droppedAudio} audio samples dropped" else "") +
                    (if (lastError.isEmpty()) "" else " | $lastError"))
            releasePending = true      // hand back to the GL thread
        }
    }

    /** Release the codecs. GL thread, after the drains finished. */
    private fun hardRelease() {
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
        AudioEncoder.release()
        drainThread = null
        stash.clear(); stashBytes = 0
        stopRequested = false
        eosSignalled = false
        rollRequested = false
    }

    /** What the encoder says about itself — logged before configure(). */
    private fun describeEncoder(mime: String, w: Int, h: Int, fps: Int): String {
        return try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val info = list.codecInfos.firstOrNull { ci ->
                ci.isEncoder && ci.supportedTypes.any { it.equals(mime, true) }
            } ?: return "no-encoder-for-$mime"
            val vc = info.getCapabilitiesForType(mime).videoCapabilities
            "${info.name}:sizeRate=${vc.areSizeAndRateSupported(w, h, fps.toDouble())}"
        } catch (e: Exception) {
            "caps-query-failed:${e.message}"
        }
    }
}
