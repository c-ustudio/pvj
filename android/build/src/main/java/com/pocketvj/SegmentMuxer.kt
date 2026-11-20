package com.pocketvj

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.io.File
import java.nio.ByteBuffer

/**
 * The MediaMuxer half of set recording: one recording, N segment files, and now
 * TWO tracks (H.264 video + AAC audio) rather than one.
 *
 * ⚠️ THIS OBJECT EXISTS BECAUSE OF TWO MediaMuxer RULES, both easy to violate by
 * accident and both of which corrupt the file rather than throwing somewhere
 * obvious:
 *   1. It is NOT thread-safe, and there are now two encoders draining on two
 *      different threads. Every muxer touch goes through this lock.
 *   2. A track cannot be added after start(). So a segment cannot open until
 *      EVERY track it will carry has published its output format — the video
 *      drain can no longer open the file the moment its own format arrives.
 *
 * ⚠️ THE SEGMENT ORIGIN IS SHARED, and that is the sync-critical detail. A roll
 * is triggered by a video keyframe, so that keyframe's PTS is the origin BOTH
 * tracks rebase against. Rebasing each track against its own first sample would
 * hand the two tracks a different zero in every segment — audio stepping further
 * out of sync at each boundary, which is exactly the failure that only shows up
 * an hour into a set.
 */
object SegmentMuxer {
    private const val TAG = "PocketVJRec"

    private val lock = Any()
    private var muxer: MediaMuxer? = null
    private var dir: File? = null
    private var videoTrack = -1
    private var audioTrack = -1
    private var videoFormat: MediaFormat? = null
    private var audioFormat: MediaFormat? = null
    private var wantAudio = false
    private var open = false

    /** Shared per-segment zero. -1 until this segment's first video sample. */
    private var originUs = -1L

    @Volatile var segmentIndex = 0; private set
    @Volatile var lastFile = ""; private set
    @Volatile var bytes = 0L; private set
    @Volatile var videoFrames = 0; private set
    @Volatile var audioFrames = 0; private set
    @Volatile var droppedAudio = 0; private set
    @Volatile var lastError = ""

    fun begin(outDir: File, audioWanted: Boolean) {
        synchronized(lock) {
            dir = outDir
            wantAudio = audioWanted
            videoTrack = -1; audioTrack = -1
            videoFormat = null; audioFormat = null
            segmentIndex = 0; bytes = 0L
            videoFrames = 0; audioFrames = 0; droppedAudio = 0
            originUs = -1L
            open = false
            lastError = ""
            heldAudio.clear()
            heldAudioBytes = 0
        }
    }

    fun isOpen(): Boolean = synchronized(lock) { open }

    fun hasAudioTrack(): Boolean = synchronized(lock) { audioTrack >= 0 }

    fun publishVideoFormat(fmt: MediaFormat) {
        synchronized(lock) { if (videoFormat == null) videoFormat = fmt }
    }

    fun publishAudioFormat(fmt: MediaFormat) {
        synchronized(lock) { if (audioFormat == null) audioFormat = fmt }
    }

    /** Open segment 1 once every expected track has a format. */
    fun maybeOpen(): Boolean {
        synchronized(lock) {
            if (open) return true
            if (videoFormat == null) return false
            if (wantAudio && audioFormat == null) return false
            return openLocked()
        }
    }

    /**
     * Audio never produced a format — open video-only instead.
     *
     * ⚠️ Without this the whole recording is hostage to the audio encoder: rule 2
     * above means a missing audio format blocks the muxer forever, so a mic that
     * fails to start would silently produce ZERO video as well. A silent
     * recording is half a feature; no recording is none of one.
     */
    fun dropAudioAndOpen(): Boolean {
        synchronized(lock) {
            if (open) return true
            if (!wantAudio) return false
            wantAudio = false
            droppedAudio += heldAudio.size
            heldAudio.clear()
            heldAudioBytes = 0
            if (lastError.isEmpty()) lastError = "audio-timeout"
            Log.w(TAG, "audio format never arrived — opening video-only")
            return openLocked()
        }
    }

    /**
     * Write one video sample, optionally rolling to a new segment first. The
     * roll and the write share one critical section so no audio sample can land
     * between the new file opening and its origin being established.
     */
    fun writeVideo(buf: ByteBuffer, info: MediaCodec.BufferInfo, roll: Boolean): Boolean {
        synchronized(lock) {
            if (roll && open) {
                closeLocked()
                if (!openLocked()) return false
            }
            if (!open || videoTrack < 0) return false
            val setsOrigin = originUs < 0
            if (setsOrigin) originUs = info.presentationTimeUs
            val ok = writeLocked(videoTrack, buf, info)
            if (ok) videoFrames++
            // The origin only exists now, so anything the audio drain handed us
            // before this can finally be placed against it.
            if (setsOrigin) flushHeldAudioLocked()
            return ok
        }
    }

    /**
     * Write one audio sample.
     *
     * ⚠️ Samples produced before the segment has an origin are HELD, not
     * dropped. The AAC format arrives well before the video one (the encoder
     * needs a single input buffer, the video encoder needs a frame), so the
     * muxer cannot open for the ~150-200 ms in between — and video for that same
     * window is already being held by SurfaceRecorder. Discarding the audio half
     * would open every recording with picture and no sound. Measured on the 9a
     * before this: audio start_time 0.191 s against video 0.000 s.
     *
     * A sample that predates an origin that DOES exist is still dropped: audio
     * lags video by the capture latency, so at a segment boundary the tail of
     * the previous segment arrives after the new file opened. Clamping those to
     * 0 instead would pile several onto one PTS and hand MediaMuxer a
     * non-monotonic track.
     */
    fun writeAudio(buf: ByteBuffer, info: MediaCodec.BufferInfo): Boolean {
        synchronized(lock) {
            if (!open || originUs < 0) {
                holdAudioLocked(buf, info)
                return false
            }
            if (audioTrack < 0 || info.presentationTimeUs < originUs) {
                droppedAudio++
                return false
            }
            val ok = writeLocked(audioTrack, buf, info)
            if (ok) audioFrames++
            return ok
        }
    }

    /** Close the current segment. This is what writes `moov` — see SurfaceRecorder. */
    fun finish() {
        synchronized(lock) { closeLocked() }
    }

    // --- audio held until the segment has an origin -------------------------

    private class Held(val data: ByteArray, val ptsUs: Long, val flags: Int)

    /** ~4 s of 128 kbps AAC. Past this something is wrong; stop growing. */
    private const val HELD_AUDIO_MAX = 64 * 1024

    private val heldAudio = ArrayList<Held>()
    private var heldAudioBytes = 0

    private fun holdAudioLocked(buf: ByteBuffer, info: MediaCodec.BufferInfo) {
        if (!wantAudio || heldAudioBytes + info.size > HELD_AUDIO_MAX) {
            droppedAudio++
            return
        }
        val a = ByteArray(info.size)
        buf.position(info.offset)
        buf.limit(info.offset + info.size)
        buf.get(a)
        heldAudio.add(Held(a, info.presentationTimeUs, info.flags))
        heldAudioBytes += info.size
    }

    private fun flushHeldAudioLocked() {
        if (heldAudio.isEmpty()) return
        if (audioTrack < 0) {
            droppedAudio += heldAudio.size
        } else {
            val info = MediaCodec.BufferInfo()
            var written = 0
            for (h in heldAudio) {
                if (h.ptsUs < originUs) { droppedAudio++; continue }
                info.set(0, h.data.size, h.ptsUs, h.flags)
                if (writeLocked(audioTrack, ByteBuffer.wrap(h.data), info)) {
                    audioFrames++
                    written++
                }
            }
            Log.i(TAG, "flushed $written held audio samples " +
                    "(${heldAudio.size - written} predated the segment origin)")
        }
        heldAudio.clear()
        heldAudioBytes = 0
    }

    // --- internals (all called with the lock held) --------------------------

    private fun openLocked(): Boolean {
        val vf = videoFormat ?: return false
        return try {
            segmentIndex++
            val f = File(dir, "part%02d.mp4".format(segmentIndex))
            val mx = MediaMuxer(f.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            videoTrack = mx.addTrack(vf)
            audioTrack = if (wantAudio) audioFormat?.let { mx.addTrack(it) } ?: -1 else -1
            mx.start()
            muxer = mx
            open = true
            originUs = -1L
            lastFile = f.absolutePath
            Log.i(TAG, "segment $segmentIndex open: ${f.name} " +
                    "(video track $videoTrack, audio track $audioTrack)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "openSegment failed: ${e.message}", e)
            lastError = "segment-open:${e.message}"
            open = false
            false
        }
    }

    private fun closeLocked() {
        val mx = muxer ?: return
        muxer = null
        open = false
        try {
            mx.stop()   // writes moov — the file is only playable after this
        } catch (e: Exception) {
            Log.e(TAG, "muxer stop failed: ${e.message}", e)
            if (lastError.isEmpty()) lastError = "muxer-stop:${e.message}"
        }
        try { mx.release() } catch (_: Exception) {}
        Log.i(TAG, "segment $segmentIndex closed: $lastFile " +
                "(${bytes / 1_000_000} MB, $videoFrames video / $audioFrames audio samples)")
    }

    private fun writeLocked(track: Int, buf: ByteBuffer, info: MediaCodec.BufferInfo): Boolean {
        val saved = info.presentationTimeUs
        return try {
            info.presentationTimeUs = saved - originUs
            buf.position(info.offset)
            buf.limit(info.offset + info.size)
            muxer!!.writeSampleData(track, buf, info)
            bytes += info.size
            true
        } catch (e: Exception) {
            // Disk filled between storage checks, or the muxer died.
            Log.e(TAG, "writeSampleData failed: ${e.message}")
            lastError = "write-failed:${e.message}"
            false
        } finally {
            info.presentationTimeUs = saved
        }
    }
}
