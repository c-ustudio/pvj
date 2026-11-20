package com.pocketvj

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * The AAC track for set recording.
 *
 * ⚠️ THE SOURCE IS GODOT'S EXISTING MIC CAPTURE, NOT A NATIVE AudioRecord, and
 * that is a deliberate choice rather than a shortcut. `scripts/audio_bus.gd`
 * already holds an AudioStreamMicrophone open for audio reactivity (beat switch,
 * level-driven FX). Opening a second capture client inside the same process
 * risks Android's concurrent-capture policy starving one of the two — and the
 * loser would be the shipped, verified reactivity feature, failing SILENTLY in
 * the middle of a set. One mic client, fanned out in GDScript, has no such mode.
 * It also means the recording carries exactly the signal the visuals reacted to.
 *
 * v1 records the DEFAULT INPUT DEVICE (the phone mic) as mono. No input-source
 * selection — a USB-C audio adapter already presents as that default input, so
 * line-in largely works incidentally; picking it explicitly is a later job.
 *
 * TIMEBASE. PTS is anchored ONCE to the video clock and then advanced purely by
 * SAMPLE COUNT. Stamping each chunk with its arrival time instead would import
 * every scheduling hiccup on the main thread into the audio track as jitter.
 * Gaps are not guessed at either: Godot's AudioEffectCapture reports exactly how
 * many frames it discarded on overrun, and GDScript passes that count through as
 * `padFrames`, so an underrun is filled with precisely the silence that was lost
 * rather than a threshold-tuned estimate.
 */
object AudioEncoder {
    private const val TAG = "PocketVJRec"
    private const val MIME = "audio/mp4a-latm"

    /** ~1 s of 60 Hz chunks. Past this the encoder is not keeping up at all. */
    private const val QUEUE_CAP = 64

    private class Chunk(val pcm: ByteArray, val frames: Int, val padFrames: Int)

    private var codec: MediaCodec? = null
    private val queue = ArrayBlockingQueue<Chunk>(QUEUE_CAP)
    private var feeder: Thread? = null
    private var drainThread: Thread? = null

    @Volatile private var running = false
    @Volatile private var stopping = false
    @Volatile private var sampleRate = 48000
    @Volatile private var basePtsUs = -1L
    @Volatile private var samplesWritten = 0L
    @Volatile private var pendingPadFrames = 0

    @Volatile var droppedChunks = 0; private set
    @Volatile var paddedFrames = 0L; private set
    @Volatile var lastError = ""; private set

    fun isRunning(): Boolean = running

    fun summary(): String =
        "audio %.1fs (%d samples) | %d padded | %d chunks dropped%s".format(
            if (sampleRate > 0) samplesWritten.toDouble() / sampleRate else 0.0,
            samplesWritten, paddedFrames, droppedChunks,
            if (lastError.isEmpty()) "" else " | $lastError")

    fun start(rate: Int, bitrateKbps: Int): String {
        if (running) return "already-running"
        sampleRate = if (rate in 8000..48000) rate else 48000
        basePtsUs = -1L
        samplesWritten = 0L
        pendingPadFrames = 0
        droppedChunks = 0
        paddedFrames = 0L
        lastError = ""
        stopping = false
        queue.clear()
        return try {
            val fmt = MediaFormat.createAudioFormat(MIME, sampleRate, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 32768)
            }
            val c = MediaCodec.createEncoderByType(MIME)
            c.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            c.start()
            codec = c
            running = true
            startFeeder()
            startDrain()
            Log.i(TAG, "REC AUDIO: AAC-LC mono ${sampleRate}Hz ${bitrateKbps}kbps")
            "ok"
        } catch (e: Exception) {
            Log.e(TAG, "audio start failed: ${e.message}", e)
            lastError = "audio-start:${e.message}"
            release()
            "audio-start-failed:${e.message}"
        }
    }

    /**
     * Interleaved float32 STEREO PCM straight out of Godot's capture buffer,
     * downmixed to mono here rather than in GDScript — PackedVector2Array's
     * to_byte_array() is a memcpy, so no per-sample GDScript loop lands on the
     * main thread at 60 Hz.
     */
    fun push(f32Stereo: ByteArray, frames: Int, padFrames: Int) {
        if (!running || stopping) return
        if (!queue.offer(Chunk(f32Stereo, frames, padFrames))) {
            // A real hole in the audio: the feeder has been stalled ~1 s.
            droppedChunks++
        }
    }

    /** Drain what is queued, then send EOS. Returns immediately. */
    fun signalStop() {
        stopping = true
    }

    fun release() {
        running = false
        stopping = false
        try { feeder?.interrupt() } catch (_: Exception) {}
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
        feeder = null
        drainThread = null
        queue.clear()
    }

    // --- feeder thread ------------------------------------------------------

    private fun startFeeder() {
        val t = Thread({
            try {
                while (running) {
                    val chunk = queue.poll(50, TimeUnit.MILLISECONDS)
                    if (chunk == null) {
                        if (stopping) break
                        continue
                    }
                    feed(chunk)
                    if (stopping && queue.isEmpty()) break
                }
                queueEos()
            } catch (e: InterruptedException) {
                // release() during teardown
            } catch (e: Exception) {
                Log.e(TAG, "audio feed failed: ${e.message}", e)
                if (lastError.isEmpty()) lastError = "audio-feed:${e.message}"
                queueEos()
            }
        }, "PocketVJRecAudioFeed")
        t.start()
        feeder = t
    }

    private fun feed(chunk: Chunk) {
        // The audio clock hangs off the video clock, so there is nothing to
        // anchor to until the GL thread has established it. Chunks captured
        // before the first blit are genuinely earlier than the recording.
        val origin = SurfaceRecorder.videoOriginNs()
        if (origin <= 0L) return

        if (basePtsUs < 0L) {
            basePtsUs = (System.nanoTime() - origin) / 1000L
            Log.i(TAG, "REC AUDIO ORIGIN: +%.1f ms after video t0".format(basePtsUs / 1000.0))
        }

        // Frames owed as silence: what the capture ring discarded, plus anything
        // writePcm could not hand to the encoder. Both are real holes, and BOTH
        // have to be filled or the track ends up shorter than the picture and
        // every later sound plays early — a drift that only becomes obvious an
        // hour into a set. Capped so a persistently stalled encoder cannot be
        // answered with an ever-growing wall of silence.
        val owed = chunk.padFrames + pendingPadFrames
        pendingPadFrames = 0
        if (owed > 0) {
            val pad = minOf(owed, sampleRate / 2)
            writePcm(ByteArray(pad * 2), pad)
            paddedFrames += pad
            Log.w(TAG, "audio gap — padded $pad frames of silence " +
                    "(${"%.1f".format(pad * 1000.0 / sampleRate)} ms)")
        }

        val avail = chunk.pcm.size / 8          // 2 channels x 4 bytes
        val n = if (chunk.frames < avail) chunk.frames else avail
        if (n <= 0) return
        writePcm(toMono16(chunk.pcm, n), n)
    }

    private fun toMono16(f32Stereo: ByteArray, frames: Int): ByteArray {
        val src = ByteBuffer.wrap(f32Stereo).order(ByteOrder.nativeOrder()).asFloatBuffer()
        val out = ByteArray(frames * 2)
        var j = 0
        for (i in 0 until frames) {
            val mixed = (src.get(i * 2) + src.get(i * 2 + 1)) * 0.5f
            var v = (mixed * 32767f).toInt()
            if (v > 32767) v = 32767
            if (v < -32768) v = -32768
            out[j++] = (v and 0xFF).toByte()             // little-endian, as
            out[j++] = ((v shr 8) and 0xFF).toByte()     // ENCODING_PCM_16BIT wants
        }
        return out
    }

    private fun writePcm(pcm: ByteArray, frames: Int) {
        val c = codec ?: return
        var off = 0
        while (off < pcm.size) {
            // 100 ms, not 20: this is a dedicated feeder thread with a queue in
            // front of it, so waiting here costs nothing, while giving up costs
            // samples. A 20 ms wait was measured losing 6 chunks over 5.5 min.
            val idx = try {
                c.dequeueInputBuffer(100_000)
            } catch (e: Exception) {
                Log.e(TAG, "dequeueInputBuffer: ${e.message}")
                return
            }
            if (idx < 0) {
                val lost = (pcm.size - off) / 2
                pendingPadFrames += lost
                droppedChunks++
                Log.w(TAG, "no audio input buffer — $lost frames deferred as silence")
                return
            }
            val buf = c.getInputBuffer(idx) ?: return
            buf.clear()
            val n = minOf(buf.capacity(), pcm.size - off)
            buf.put(pcm, off, n)
            val ptsUs = basePtsUs + samplesWritten * 1_000_000L / sampleRate
            c.queueInputBuffer(idx, 0, n, ptsUs, 0)
            samplesWritten += n / 2
            off += n
        }
    }

    private fun queueEos() {
        val c = codec ?: return
        try {
            val idx = c.dequeueInputBuffer(500_000)
            if (idx >= 0) {
                val ptsUs = basePtsUs.coerceAtLeast(0L) +
                        samplesWritten * 1_000_000L / sampleRate
                c.queueInputBuffer(idx, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                Log.i(TAG, "audio EOS queued after $samplesWritten samples")
            } else {
                Log.w(TAG, "no input buffer for audio EOS")
            }
        } catch (e: Exception) {
            Log.w(TAG, "audio EOS failed: ${e.message}")
        }
    }

    // --- drain thread -------------------------------------------------------

    private fun startDrain() {
        val t = Thread({
            val info = MediaCodec.BufferInfo()
            var eosWaitStartNs = 0L
            try {
                while (true) {
                    val c = codec ?: break
                    val idx = c.dequeueOutputBuffer(info, 10_000)

                    // Same bound as the video drain: if the encoder dies the EOS
                    // never arrives, and a thread spinning here would keep the
                    // muxer open and the whole recording unfinalized.
                    if (stopping) {
                        if (eosWaitStartNs == 0L) eosWaitStartNs = System.nanoTime()
                        else if (System.nanoTime() - eosWaitStartNs > 5_000_000_000L) {
                            Log.w(TAG, "no audio EOS 5 s after stop — giving up")
                            if (lastError.isEmpty()) lastError = "audio-eos-timeout"
                            break
                        }
                    }

                    if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        SegmentMuxer.publishAudioFormat(c.outputFormat)
                        SegmentMuxer.maybeOpen()
                        Log.i(TAG, "audio format: ${c.outputFormat}")
                    } else if (idx >= 0) {
                        val buf = c.getOutputBuffer(idx)
                        val isConfig =
                            (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        if (buf != null && !isConfig && info.size > 0) {
                            SegmentMuxer.writeAudio(buf, info)
                        }
                        c.releaseOutputBuffer(idx, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            Log.i(TAG, "audio drain saw EOS")
                            break
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "audio drain failed: ${e.message}", e)
                if (lastError.isEmpty()) lastError = "audio-drain:${e.message}"
            }
            Log.i(TAG, "REC AUDIO DONE: ${summary()}")
            SurfaceRecorder.onAudioDrainFinished()
        }, "PocketVJRecAudioDrain")
        t.start()
        drainThread = t
    }
}
