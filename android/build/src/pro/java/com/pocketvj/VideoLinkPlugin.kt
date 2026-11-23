package com.pocketvj

import android.graphics.SurfaceTexture
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import org.godotengine.godot.Dictionary
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import io.github.thibaultbee.srtdroid.core.Srt
import io.github.thibaultbee.srtdroid.core.enums.SockOpt
import io.github.thibaultbee.srtdroid.core.enums.SockStatus
import io.github.thibaultbee.srtdroid.core.enums.Transtype
import io.github.thibaultbee.srtdroid.core.models.SrtSocket
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * PocketVJ video-link Stage 1 transport (docs/VIDEO_LINK_SPEC.md §5 Stage 1) —
 * the receive path (milestone 1) and the send path (milestone 2) in one
 * plugin instance. Full duplex comes later, so the two paths deliberately
 * share NOTHING mutable: separate threads, sockets, codecs, stats.
 *
 * RECEIVE: TCP listener → MediaCodec H.264 hardware decode → SurfaceTexture
 * latched onto the GL texture GDScript allocated with ExternalTexture. The
 * pixels never touch the CPU: the decoder renders into its output Surface's
 * buffer queue and updateTexImage() rebinds the newest buffer onto the OES
 * texture Godot is already sampling. This becomes NetSource's Stage 1 body —
 * the ~224 ms Stage 0 loop (SESSION_27_NOTES, §9-M7) is the number it exists
 * to beat.
 *
 * SEND (v1, readback-fed — §3.4/§6.6): NetSender's 720p SubViewport readback
 * arrives through push_frame() as tightly-packed RGB8 and lands in a 1-deep
 * latest-wins mailbox (drop, never buffer — the jpeg worker's policy, encoder
 * edition). One worker converts it into the encoder's flexible-YUV input
 * (fixed-point BT.601 limited range, vendor strides honored), hardware-encodes
 * (CBR, no B-frames, short GOP), and CONNECTS OUT to the receiving peer's
 * 4853 listener speaking framing v1. The v2 GPU-blit (createInputSurface +
 * EGL) deletes the readback+convert whole — this CPU path is the staged
 * stepping stone, same philosophy as MJPEG→H.264 itself.
 *
 * ── FRAMING v1 (wire format — must stay byte-exact with every sender) ─────
 * One TCP connection per sender; the sender pushes, this end listens:
 *   u32 big-endian payload length, then that many bytes: one Annex-B NAL
 *   unit, start code included. SPS and PPS are sent first. A sender that
 *   glues a whole access unit (SPS+PPS+IDR) into one payload is tolerated —
 *   the scanner walks start codes, not payload boundaries. A length outside
 *   (0, 2 MiB] means the framing itself is lost, and a length-prefixed
 *   stream cannot resync: drop the connection, keep the listener.
 *
 * ── THREADING ─────────────────────────────────────────────────────────────
 *   GL render thread  @UsedByGodot calls land here (GDScript runs inside
 *                     GodotLib.step() on this thread, EGL context current) —
 *                     which is exactly where SurfaceTexture must be created
 *                     and updateTexImage'd. Also the per-frame latch in
 *                     onGLDrawFrame / pump_frame().
 *   PVJLink-Net       accept loop + framing reads + codec feed. Owns the
 *                     codec's whole create/feed/release lifecycle, so the
 *                     not-thread-safe MediaCodec has ONE thread of control.
 *   PVJLink-Codec     HandlerThread for the async codec callbacks. Output
 *                     buffers are released render=true immediately — the
 *                     Surface itself drops excess frames (Android Q+), which
 *                     IS the zero-queue policy; do not "fix" it with pacing.
 *   PVJLink-Enc       the whole send path: convert → encode (sync-mode
 *                     MediaCodec, so the encoder too has ONE thread of
 *                     control) → frame → TCP write. The socket write lives
 *                     HERE on purpose: a stalling peer (full send buffer)
 *                     stalls this thread, the mailbox keeps latest-wins
 *                     dropping, and push_frame never blocks — the mailbox is
 *                     the pressure valve. The valve only works because
 *                     SO_SNDBUF is capped small (SEND_BUF_BYTES): auto-tuned,
 *                     the kernel buffers whole SECONDS of CBR before write()
 *                     ever blocks, and that backlog is latency no stat can
 *                     see. A write blocked past WRITE_STALL_TIMEOUT_MS
 *                     (frozen peer: kernel ACKs, app never reads, no
 *                     IOException ever) is cut from outside by
 *                     checkWriteStall — see it for why that is the only
 *                     lever a Java socket offers. A dropped connection
 *                     redials every 2 s while started.
 *
 * Failure discipline mirrors the GDScript link modules: a dead sender or a
 * malformed payload never kills the listener — log throttled, drop, keep
 * listening. Fully passive until start_receive(): no threads, no sockets,
 * no codec, and the per-frame hook is a null check.
 */
class VideoLinkPlugin(godot: Godot) : GodotPlugin(godot) {

    private val TAG = "PocketVJVideoLink"

    // Receiver slot names, shared with GDScript verbatim (NetSource._slot()).
    private val SLOT_TCP = "tcp"
    private val SLOT_SRT = "srt"

    // Whole-object swap per start/stop: a restart can only ever see a complete
    // old receiver or a complete new one, never a half-reset field set.
    //
    // TWO SLOTS (SEQUENCER_2_SPEC §3.5, Stage 3), keyed by TRANSPORT because
    // that is what the two real layers already are: a peer phone framing raw
    // NALs over TCP, and TD serving MPEG-TS over SRT. They share nothing — own
    // socket, own MediaCodec, own SurfaceTexture, own Stats — so the registry
    // is two fields rather than a map: no allocation and no lock on the GL
    // thread, which latches both every frame.
    //
    // ⚠️ The slots are INDEPENDENT: start_receive no longer tears down an SRT
    // pull, and start_receive_srt no longer tears down a TCP listener. Each
    // start replaces ONLY its own slot. Single-NetSource callers are unaffected
    // (one instance only ever drives one transport — `_h264_srt` empty or not),
    // which is what lets this land before the GDScript side grows its second
    // instance.
    @Volatile private var receiverTcp: Receiver? = null
    @Volatile private var receiverSrt: Receiver? = null
    private val statsTcp = Stats()
    private val statsSrt = Stats()

    /** Slot names as GDScript spells them. Anything else is a caller bug and
     *  is refused loudly rather than silently aimed at a default slot. */
    private fun isSlot(slot: String): Boolean = slot == SLOT_TCP || slot == SLOT_SRT

    // Send path — same whole-object-swap discipline, nothing shared with the
    // receiver above. At most ONE of sender/gpuSender exists at a time (both
    // start doors call stop_send() first): one destination, one encoder, one
    // wire — whichever FEED the start asked for.
    @Volatile private var sender: Sender? = null
    @Volatile private var gpuSender: GpuSender? = null
    private val sendStats = SendStats()
    @Volatile private var encBuildFails = 0L   // log throttle; races only blur the throttle

    // GPU-feed source texture, published by GDScript (set_send_texture) and
    // read on the GL thread each drawFrame — the EglBridge/SurfaceRecorder
    // publish pattern, link edition. The GLuint is NOT stable (Godot recreates
    // render targets), so GDScript polls and re-publishes on change; a stale
    // id here just blits garbage for the frame or two until the re-publish.
    @Volatile private var sendTexId = 0
    @Volatile private var sendTexW = 0
    @Volatile private var sendTexH = 0
    @Volatile private var sendFlipY = true   // Godot viewport textures are bottom-up

    // Wire framing for the NEXT start_send_gpu: "tcp" = raw-NAL framing v1
    // (phone↔phone, §6.6), "srt" = MPEG-TS over SRT caller (the TD leg,
    // Stage 1 item 2). A plugin-level pref instead of a start_send_gpu
    // parameter so every existing call site keeps its exact signature —
    // GDScript probes set_send_transport by CALLING it (the has_method
    // lesson) and a pre-M3 APK answers null.
    @Volatile private var sendTransport = "tcp"

    // srtdroid native init: once per process, first SRT connect pays it.
    private val srtStarted = AtomicBoolean(false)

    override fun getPluginName(): String = "PocketVJVideoLink"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        // Emitted when the DECODED size differs from what start_receive was
        // told. GDScript answers by set_size()-ing the ExternalTexture —
        // metadata only, OES sampling is normalized, nothing tears meanwhile.
        SignalInfo("frame_geometry", Int::class.javaObjectType, Int::class.javaObjectType)
    )

    // Method names are snake_case against Kotlin convention ON PURPOSE:
    // Godot exposes @UsedByGodot methods under their exact JVM name (no case
    // coercion), and the GDScript side of this codebase speaks snake_case.

    /**
     * Bind TCP `port` and decode whatever connects into `textureId`
     * (ExternalTexture.get_external_texture_id()). width/height are the
     * ExternalTexture's size — the decoder's configure hint and the reference
     * frame_geometry compares against. Returns false when the port refuses to
     * bind (already taken, no network) — the caller checks this BEFORE asking
     * a peer to stream here, same contract as NetSource.is_listening().
     * Safe to call again to move ports: the old receiver is torn down first.
     *
     * ⚠️ Call from GDScript only. It must run on the render thread with
     * Godot's EGL context current, because SurfaceTexture attaches to the
     * texture name in whatever context is current at construction.
     */
    @UsedByGodot
    fun start_receive(port: Int, textureId: Int, width: Int, height: Int): Boolean {
        // Refusals BEFORE teardown (the net_sender lesson): a bad ask must
        // not cost the healthy receiver it failed to replace.
        if (textureId <= 0) {
            Log.e(TAG, "start_receive: bad texture id $textureId")
            return false
        }
        stop_receive_slot(SLOT_TCP)   // this slot only — an SRT pull keeps running
        val server = try {
            ServerSocket().apply {
                reuseAddress = true   // a quick stop/start must not trip on TIME_WAIT
                bind(InetSocketAddress(port))
            }
        } catch (e: IOException) {
            Log.e(TAG, "start_receive: cannot bind TCP $port: ${e.message}")
            return false
        }
        statsTcp.reset()
        val r = Receiver(server, null, textureId, width, height, statsTcp)
        receiverTcp = r
        r.start()
        Log.i(TAG, "listening on TCP $port -> texture $textureId (${width}x$height)")
        return true
    }

    /**
     * SRT pull (the TD leg, M3 S1): WE are the caller — dial `host:port`
     * (TD's Video Stream Out SRT listener) and decode its MPEG-TS into
     * `textureId`, ringing the srt_arm doorbell on `ctrlPort` before every
     * dial (TD's listener is single-shot per Active cycle). Same render-
     * thread construction rule as start_receive — the SurfaceTexture attach
     * needs Godot's context current. Returns false only on bad args; a dead
     * or unreachable TD is a LOST layer that heals via the dial loop, the
     * same repeat-ask contract every other wire here leans on.
     */
    @UsedByGodot
    fun start_receive_srt(host: String, port: Int, ctrlPort: Int,
                          textureId: Int, width: Int, height: Int): Boolean {
        // Refusals BEFORE teardown (the net_sender lesson): a bad ask must
        // not cost the healthy receiver it failed to replace.
        val h = host.trim()
        if (h.isEmpty() || port <= 0 || port > 65535 || ctrlPort <= 0 || ctrlPort > 65535) {
            Log.e(TAG, "start_receive_srt: bad target '$host':$port ctrl $ctrlPort")
            return false
        }
        if (textureId <= 0) {
            Log.e(TAG, "start_receive_srt: bad texture id $textureId")
            return false
        }
        stop_receive_slot(SLOT_SRT)   // this slot only — a TCP listener keeps running
        statsSrt.reset()
        val r = Receiver(null, SrtPullTarget(h, port, ctrlPort), textureId, width, height,
                         statsSrt)
        receiverSrt = r
        r.start()
        Log.i(TAG, "pulling SRT $h:$port (arm via $ctrlPort) -> texture $textureId (${width}x$height)")
        return true
    }

    /**
     * Idempotent teardown: sockets, codec, Surface, SurfaceTexture — in that
     * order (the codec must die before the Surface it renders into). The
     * ExternalTexture and its GL name belong to GDScript and are not touched:
     * the last latched frame stays visible, the same freeze-not-black policy
     * as NetSource.stop().
     */
    @UsedByGodot
    fun stop_receive() {
        // Legacy door: BOTH slots. A pre-Stage-3 caller meant "stop receiving",
        // and there was only one thing to stop — honour that reading exactly.
        // Slot-aware callers use stop_receive_slot and keep their sibling up.
        stop_receive_slot(SLOT_TCP)
        stop_receive_slot(SLOT_SRT)
    }

    /**
     * Tear down ONE slot ("tcp" or "srt"), leaving the other running — the
     * door a two-NetSource GDScript uses so instance A's stop cannot take
     * instance B's layer down with it. Idempotent and unknown-slot-safe.
     */
    @UsedByGodot
    fun stop_receive_slot(slot: String) {
        if (!isSlot(slot)) {
            Log.e(TAG, "stop_receive_slot: unknown slot '$slot'")
            return
        }
        val r: Receiver?
        if (slot == SLOT_TCP) {
            r = receiverTcp
            receiverTcp = null
        } else {
            r = receiverSrt
            receiverSrt = null
        }
        r?.shutdown()
    }

    /**
     * True while a receiver exists — server socket bound, threads up. Goes
     * false on stop_receive, INCLUDING the self-teardown in onGLSurfaceCreated:
     * this is the one way GDScript can OBSERVE that teardown (nothing signals
     * it), so NetSource's rearm tick polls this instead of guessing from
     * frame ages — a merely-quiet stream must never get its listener churned.
     */
    @UsedByGodot
    fun is_receiving(): Boolean = receiverTcp != null || receiverSrt != null

    /**
     * Per-slot truth, and the one NetSource's rearm tick must use once two of
     * them exist: the aggregate above would report a healthy SRT pull as
     * "receiving" to a TCP instance whose listener had actually died, and the
     * rearm that instance is owed would never fire.
     */
    @UsedByGodot
    fun is_receiving_slot(slot: String): Boolean = when (slot) {
        SLOT_TCP -> receiverTcp != null
        SLOT_SRT -> receiverSrt != null
        else -> false
    }

    /**
     * fps / decode_ms / kbps as floats, frames_ok / frames_dropped as ints.
     * last_frame_msec is milliseconds SINCE the last decoded frame (-1 =
     * never) — an age, not a timestamp, because the JVM clock and
     * Time.get_ticks_msec() share no epoch; GDScript subtracts it from its
     * own clock if it wants one.
     */
    @UsedByGodot
    fun get_stats(): Dictionary =
        // Legacy door: whichever slot is actually up, TCP first. With one
        // receiver running — every pre-Stage-3 caller — this is the same
        // dictionary it always returned.
        if (receiverTcp != null) statsTcp.snapshot()
        else if (receiverSrt != null) statsSrt.snapshot()
        else statsTcp.snapshot()

    /** One slot's counters, unsmeared by the other. */
    @UsedByGodot
    fun get_stats_slot(slot: String): Dictionary = when (slot) {
        SLOT_SRT -> statsSrt.snapshot()
        else -> statsTcp.snapshot()
    }

    /**
     * Optional latency trim: latch the newest decoded frame NOW instead of at
     * end-of-frame. onGLDrawFrame runs AFTER GodotLib.step(), so a frame
     * latched there is only sampled one engine frame later; calling this from
     * _process() (same thread, context current, before this frame renders)
     * buys that frame back (~16 ms at 60). Harmless when idle or called
     * alongside the hook — the atomic flag makes the second latch a no-op.
     */
    @UsedByGodot
    fun pump_frame() {
        // Both slots: one call from GDScript's _process buys the frame back for
        // every layer, and latch() is a no-op on a slot with nothing new.
        receiverTcp?.latch()
        receiverSrt?.latch()
    }

    // --- Send path API (milestone 2) --------------------------------------

    /**
     * Start the h264 send path: encoder up now, connection dialed on the
     * send thread (redial every 2 s while started — a peer that isn't
     * listening YET is the normal boot order, not an error). Returns false
     * only for what is knowable synchronously: bad arguments or an encoder
     * that refuses to build; "connect refused" is logcat's story later.
     * Calling while sending REPLACES the destination (NetSender's §6.6
     * single-destination contract) — old connection closed, new one dialed,
     * and the far end's fresh-decoder-per-connection rule gets its fresh
     * SPS/PPS from the reconnect. width/height must be even (4:2:0 chroma
     * is 2x2 blocks). No GL dependency — any thread is safe, GDScript's
     * render thread is who actually calls.
     */
    @UsedByGodot
    fun start_send(host: String, port: Int, width: Int, height: Int,
                   fps: Float, bitrateBps: Int): Boolean {
        stop_send()
        val h = host.trim()
        if (h.isEmpty() || port <= 0 || port > 65535) {
            Log.e(TAG, "start_send: bad destination '$host':$port")
            return false
        }
        if (width <= 0 || height <= 0 || width % 2 != 0 || height % 2 != 0) {
            Log.e(TAG, "start_send: bad geometry ${width}x$height (must be even)")
            return false
        }
        if (!fps.isFinite() || fps <= 0f || bitrateBps <= 0) {
            Log.e(TAG, "start_send: bad rate fps=$fps bitrate=$bitrateBps")
            return false
        }
        val clampedFps = fps.coerceIn(1f, 120f)
        val codec = buildEncoder(width, height, clampedFps, bitrateBps)?.codec ?: return false
        sendStats.reset()
        val s = Sender(codec, h, port, width, height, clampedFps, bitrateBps)
        sender = s
        s.start()
        Log.i(TAG, "sending to TCP $h:$port (${width}x$height @$clampedFps, $bitrateBps bps)")
        return true
    }

    /**
     * Hand over one captured frame: tightly-packed RGB8 (w*h*3 bytes — the
     * GDScript side converts the viewport's RGBA8 readback before the JNI
     * hop, NetSender's push_frame contract). Runs synchronously on the
     * calling GDScript thread, so it does exactly one thing: a latest-wins
     * mailbox swap. Never blocks, never queues — a busy worker means the
     * PREVIOUS frame dies, counted in frames_dropped. A push with no sender
     * up is silently ignored (NetSender's tick can outrun stop by a frame).
     */
    @UsedByGodot
    fun push_frame(rgb: ByteArray, width: Int, height: Int) {
        sender?.push(rgb, width, height)
    }

    /**
     * Start the h264 send path on the v2 GPU feed (spec §5 Stage 1 send v2,
     * milestone 2.5(b)): the encoder takes a Surface input and the render
     * thread GPU-blits the source texture into it — no readback, no RGB→YUV
     * convert, no per-frame CPU at all. Same wire, same connect-out/redial
     * contract, same synchronous-refusal semantics as start_send. The frame
     * source is whatever set_send_texture last published; until that arrives
     * (or after a GL context loss invalidates it) the encoder simply starves,
     * which upstream reads as fps 0 — the capture-never-started shape, not an
     * error. Replaces any active send of EITHER feed.
     */
    @UsedByGodot
    fun start_send_gpu(host: String, port: Int, width: Int, height: Int,
                       fps: Float, bitrateBps: Int): Boolean {
        stop_send()
        val h = host.trim()
        if (h.isEmpty() || port <= 0 || port > 65535) {
            Log.e(TAG, "start_send_gpu: bad destination '$host':$port")
            return false
        }
        if (width <= 0 || height <= 0 || width % 2 != 0 || height % 2 != 0) {
            Log.e(TAG, "start_send_gpu: bad geometry ${width}x$height (must be even)")
            return false
        }
        if (!fps.isFinite() || fps <= 0f || bitrateBps <= 0) {
            Log.e(TAG, "start_send_gpu: bad rate fps=$fps bitrate=$bitrateBps")
            return false
        }
        val clampedFps = fps.coerceIn(1f, 120f)
        val built = buildEncoder(width, height, clampedFps, bitrateBps, surfaceInput = true)
                ?: return false
        sendStats.reset()
        val transport = sendTransport
        val s = GpuSender(built.codec, built.inputSurface!!, h, port,
                width, height, clampedFps, bitrateBps, transport)
        gpuSender = s
        s.start()
        Log.i(TAG, "sending to ${transport.uppercase()} $h:$port " +
                "(${width}x$height @$clampedFps, $bitrateBps bps, GPU feed)")
        return true
    }

    /**
     * Publish the GPU feed's source texture — the GLuint of NetSender's
     * SubViewport render target (RenderingServer.texture_get_native_handle on
     * the viewport's OWN texture RID; the ViewportTexture resource is a proxy
     * that answers 0 — pipeline.gd's projector lesson). Godot recreates
     * render targets at will, so the GDScript side polls the handle at its
     * capture cadence and re-publishes on change; between recreate and
     * re-publish the blit reads a dead name, which is a frame of garbage at
     * worst, never a crash. Safe on any thread (volatile publish); the GL
     * thread consumes.
     */
    @UsedByGodot
    fun set_send_texture(textureId: Int, width: Int, height: Int) {
        sendTexId = textureId
        sendTexW = width
        sendTexH = height
        Log.i(TAG, "send source texture: id=$textureId ${width}x$height")
    }

    /** Escape hatch if the far end shows the stream upside down —
     *  PresentationPlugin.setOutputFlipY, link edition. Default true (Godot
     *  viewport textures are bottom-up, same as the projector/recorder). */
    @UsedByGodot
    fun set_send_flip(flip: Boolean) {
        sendFlipY = flip
    }

    /**
     * §9-M8: the SRT latency window (the ARQ/retransmission buffer), BOTH
     * directions — the send caller and the receive caller dial with it
     * alike. SRT negotiates each leg to max(both ends), so this phone-side
     * value rules the TD legs; the baked 120 ms measured as their dominant
     * latency term (RTT ~706 ms loopback) and a clean LAN wants 20–40.
     * Applies to the NEXT dial — a live socket keeps its window. Returns
     * true so GDScript can probe existence by null (the JNI lesson: never
     * has_method, never typeof).
     */
    @UsedByGodot
    fun set_srt_latency(ms: Int): Boolean {
        val v = ms.coerceIn(10, 4000)
        srtLatencyMs = v
        Log.i(TAG, "SRT latency window: $v ms (applies to the next dial)")
        return true
    }

    /**
     * Pick the wire for the NEXT send start: "tcp" (raw-NAL framing v1, the
     * default and the phone↔phone wire) or "srt" (MPEG-TS over an SRT
     * caller — the TouchDesigner leg). Returns false on an unknown name —
     * refuse, never fall back, same contract as NetSender's codec check: a
     * requester that asked for a transport this build has never heard of
     * aimed its port at THAT framing, and either other framing blasted at it
     * is bytes into a parser that cannot say no. SRT is GPU-feed only; the
     * CPU sender is the frozen 22ae379 baseline and stays untouched.
     */
    @UsedByGodot
    fun set_send_transport(transport: String): Boolean {
        if (transport != "tcp" && transport != "srt") {
            Log.e(TAG, "set_send_transport: unknown transport '$transport'")
            return false
        }
        sendTransport = transport
        return true
    }

    /**
     * Idempotent teardown, in a stated order: (1) running flag down and the
     * mailbox woken, (2) socket closed — which aborts a blocking connect()
     * or a write() stalled on a full send buffer mid-syscall, (3) send
     * thread joined, (4) the thread's own finally releases the encoder
     * (stop before release) and re-closes the socket; the encoder is
     * released by the one thread that ever fed it.
     */
    @UsedByGodot
    fun stop_send() {
        sender?.let {
            sender = null
            it.shutdown()
        }
        gpuSender?.let {
            gpuSender = null
            it.shutdown()
        }
    }

    /**
     * fps / convert_ms / encode_ms / kbps as floats, frames_sent /
     * frames_dropped as ints — the exact keys NetSender's h264 get_stats()
     * forwards. Same honest-decay window as the receive stats: the roll runs
     * on this ~1 Hz poll, so fps/kbps walk to zero when the stream stops.
     * frames_dropped counts every casualty of the drop policy: mailbox
     * overwrites, encoder starvation, frames encoded while disconnected,
     * pre-IDR frames a fresh connection can't use.
     *
     * Doubles as the send path's watchdog tick: at ~1 Hz this poll notices a
     * write wedged against a frozen peer even when capture has stopped
     * feeding push_frame (checkWriteStall — the other caller — rides the
     * capture cadence and dies with it).
     */
    @UsedByGodot
    fun get_send_stats(): Dictionary {
        sender?.checkWriteStall()
        gpuSender?.checkWriteStall()
        return sendStats.snapshot()
    }

    // --- Godot render-thread hooks ----------------------------------------

    override fun onGLDrawFrame(gl: GL10?) {
        // Safety-net latch for any frame pump_frame() didn't collect.
        receiverTcp?.latch()
        receiverSrt?.latch()
        // The GPU send feed: pace + blit into the encoder surface. Runs after
        // GodotLib.step(), so it ships the frame Godot JUST drew — the same
        // one-frame-fresh position the projector/recorder blit holds.
        gpuSender?.drawFrame()
    }

    override fun onGLSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        // Godot's GL context was (re)created: the ExternalTexture's GL name is
        // gone and the SurfaceTexture is attached to a dead context — nothing
        // here is salvageable. Tear down; GDScript re-calls start_receive with
        // the fresh texture id when it sees freshness go LOST.
        if (receiverTcp != null || receiverSrt != null) {
            // EVERY slot's SurfaceTexture is attached to the dead context, so
            // both go — is_receiving_slot() is how each GDScript instance
            // observes its own teardown and rearms with a fresh texture id.
            Log.w(TAG, "GL context recreated — receivers torn down, restart needed")
            stop_receive()
        }
        // The GPU sender SURVIVES: the encoder's input Surface is a
        // BufferQueue, not a GL object. Only the GlBlitter target is dead —
        // drop the reference (PresentationPlugin's hook owns the actual EGL
        // teardown, and target destruction is safe in either firing order);
        // the next drawFrame re-acquires on the fresh shared context. The
        // source GLuint died with the context too, but that is GDScript's
        // poll-and-republish to notice, same as any render-target churn.
        gpuSender?.onContextLost()
    }

    // --- The one-lifecycle receiver ---------------------------------------

    /** SRT caller mode's destination (the TD leg): the video listener we
     *  dial and the control port whose srt_arm doorbell must precede EVERY
     *  dial — TD's Video Stream Out serves one client session per Active
     *  cycle and re-arms only on that verb (SESSION_30 contract). */
    private class SrtPullTarget(val host: String, val port: Int, val ctrlPort: Int)

    private inner class Receiver(
        private val server: ServerSocket?,          // TCP listener mode (framing v1)
        private val srt: SrtPullTarget?,            // SRT caller mode (MPEG-TS, TD leg)
        textureId: Int,
        private val texW: Int,
        private val texH: Int,
        // Its slot's counters. A constructor property rather than the old outer
        // field, so every `stats.` in this body below binds per-instance — the
        // two slots can no longer smear each other's fps/kbps.
        private val stats: Stats,
    ) {
        // The listener only flips a flag: AOSP delivers onFrameAvailable on an
        // arbitrary thread and updateTexImage there would be the classic race.
        private val frameAvailable = AtomicBoolean(false)

        // Constructed in start_receive's stack frame = on the render thread
        // with Godot's context current — the one place attachment is legal.
        private val surfaceTexture = SurfaceTexture(textureId).apply {
            setOnFrameAvailableListener { frameAvailable.set(true) }
        }
        private val surface = Surface(surfaceTexture)

        @Volatile private var running = true
        private val socketLock = Any()
        private var client: Socket? = null              // guarded by socketLock
        private var srtClient: SrtSocket? = null        // guarded by socketLock
        private var ctrlSock: Socket? = null            // guarded by socketLock; the arm doorbell
        private val netThread = Thread(::netLoop, "PVJLink-Net")

        // Codec state: PVJLink-Net thread only, except the volatile handle the
        // callbacks compare against to ignore a codec they have outlived.
        @Volatile private var codec: MediaCodec? = null
        private var codecThread: HandlerThread? = null
        private var sps: ByteArray? = null
        private var pps: ByteArray? = null
        @Volatile private var codecDead = false          // set by onError, cleared by rebuild
        @Volatile private var lastCodecFailMs = 0L
        private var lastPtsUs = 0L
        private val freeInputs = ArrayBlockingQueue<Int>(INPUT_QUEUE_DEPTH)
        private val inFlight = ConcurrentHashMap<Long, Long>()   // ptsUs -> enqueue nanos

        // frame_geometry dedupe — codec callback thread only.
        private var geomW = 0
        private var geomH = 0

        // Throttled-log counters, one per failure family (NetSource's
        // pattern: first occurrence loud, then every Nth).
        private var senderFails = 0L      // net thread
        private var badPayloads = 0L      // net thread
        private var buildFails = 0L       // net thread
        @Volatile private var decodeErrors = 0L   // codec thread

        fun start() = netThread.start()

        /** GL render thread only — rebinds the newest decoded buffer onto the
         *  OES texture Godot samples. */
        fun latch() {
            if (!frameAvailable.getAndSet(false)) return
            try {
                surfaceTexture.updateTexImage()
            } catch (e: RuntimeException) {
                // Released mid-latch during teardown — nothing to do.
            }
        }

        /** GL render thread. Joins the net thread — it unblocks the moment the
         *  sockets close, so this is milliseconds, and it guarantees the codec
         *  is released (net thread's finally) before its Surface dies here. */
        fun shutdown() {
            running = false
            server?.let { closeQuietly(it) }
            synchronized(socketLock) {
                client?.let { closeQuietly(it) }
                srtClient?.let { closeQuietly(it) }
                ctrlSock?.let { closeQuietly(it) }
            }
            // The srt dial loop sleeps (arm settle, backoff poll) — closing
            // sockets alone cannot wake those, and an uninterrupted arm
            // connect + settle can outlive the join below.
            netThread.interrupt()
            try {
                netThread.join(2000)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            if (netThread.isAlive) {
                // Never observed; better to leak one codec to GC than have two
                // threads fight over release().
                Log.w(TAG, "net thread did not exit — abandoning codec teardown")
            }
            surface.release()
            surfaceTexture.setOnFrameAvailableListener(null)
            surfaceTexture.release()
        }

        // --- PVJLink-Net thread -------------------------------------------

        private fun netLoop() {
            if (srt != null) {
                srtLoop(srt)
                return
            }
            val srv = server ?: return
            try {
                while (running) {
                    val sock = try {
                        srv.accept()
                    } catch (e: IOException) {
                        break   // only shutdown() closes the server socket
                    }
                    synchronized(socketLock) {
                        if (!running) {
                            closeQuietly(sock)
                            return
                        }
                        client = sock
                    }
                    // A new connection is a new stream: parameter sets and
                    // decoder state from the previous sender are meaningless.
                    releaseCodec()
                    sps = null
                    pps = null
                    codecDead = false
                    Log.i(TAG, "sender connected: ${sock.inetAddress.hostAddress}")
                    try {
                        serve(sock)
                    } catch (e: IOException) {
                        senderFails++
                        if (senderFails == 1L || senderFails % 20L == 0L) {
                            Log.w(TAG, "sender dropped: ${e.message} " +
                                    "($senderFails so far) — still listening")
                        }
                    } finally {
                        closeQuietly(sock)
                        synchronized(socketLock) { client = null }
                    }
                }
            } finally {
                releaseCodec()
            }
        }

        /** SRT caller mode, the TD leg: doorbell (srt_arm on the control
         *  port) → dial → drain TS datagrams through the demuxer into the
         *  same handlePayload the raw wire feeds. Dial backoff is the
         *  send-path rule (srtdroid leaks ~2 JNI global refs per dial), and
         *  EVERY redial re-rings the doorbell — that is the whole contract
         *  with TD's single-shot listener, and it makes a mid-session wedge
         *  self-healing: recv times out, we drop, re-arm, re-dial. */
        private fun srtLoop(t: SrtPullTarget) {
            val demux = TsDemuxer()
            var fails = 0L
            var lastDialMs = 0L
            try {
                while (running) {
                    val backoff = minOf(
                        CONNECT_RETRY_MS shl minOf(fails, 5L).toInt(),
                        SRT_RETRY_CAP_MS)
                    val now = SystemClock.elapsedRealtime()
                    if (now - lastDialMs < backoff) {
                        try {
                            Thread.sleep(RETRY_POLL_MS)
                        } catch (e: InterruptedException) {
                            Thread.currentThread().interrupt()
                            return
                        }
                        continue
                    }
                    lastDialMs = now
                    if (!sendSrtArm(t)) {
                        fails++
                        continue
                    }
                    val s: SrtSocket
                    try {
                        if (srtStarted.compareAndSet(false, true)) Srt.startUp()
                        s = SrtSocket()
                    } catch (e: Throwable) {
                        // UnsatisfiedLinkError included — cannot change until
                        // an APK does; backoff keeps the log and leak tame.
                        fails++
                        if (fails == 1L || fails % 15L == 0L) {
                            Log.e(TAG, "SRT unavailable: $e ($fails so far)")
                        }
                        continue
                    }
                    synchronized(socketLock) {
                        if (!running) {
                            closeQuietly(s)
                            return
                        }
                        srtClient = s
                    }
                    try {
                        s.setSockFlag(SockOpt.TRANSTYPE, Transtype.LIVE)
                        s.setSockFlag(SockOpt.PAYLOADSIZE, SRT_CHUNK_BYTES)
                        s.setSockFlag(SockOpt.LATENCY, srtLatencyMs)
                        s.setSockFlag(SockOpt.CONNTIMEO, CONNECT_TIMEOUT_MS)
                        // A live 60 fps stream is never quiet this long: a
                        // recv outliving this is TD wedged or gone — drop,
                        // re-arm, re-dial (the serve() idle rule, SRT edition).
                        s.setSockFlag(SockOpt.RCVTIMEO, CLIENT_IDLE_TIMEOUT_MS)
                        s.connect(t.host, t.port)
                    } catch (e: Exception) {
                        fails++
                        if (fails == 1L || fails % 15L == 0L) {
                            Log.w(TAG, "SRT dial ${t.host}:${t.port} failed: ${e.message} " +
                                    "($fails so far) — backing off up to ${SRT_RETRY_CAP_MS / 1000} s")
                        }
                        synchronized(socketLock) {
                            closeQuietly(s)
                            if (srtClient === s) srtClient = null
                        }
                        continue
                    }
                    // fails is NOT reset here: a connect that succeeds but
                    // never delivers data (wedged TD accepting then starving)
                    // must still walk the backoff, or the dial-leak cap is
                    // bypassed by the accept-drop cycle. First DATA resets it.
                    // A new connection is a new stream (and a new mux).
                    releaseCodec()
                    sps = null
                    pps = null
                    codecDead = false
                    demux.reset()
                    Log.i(TAG, "SRT stream up from ${t.host}:${t.port} (MPEG-TS)")
                    try {
                        serveSrt(s, demux) { fails = 0 }
                    } catch (e: Exception) {
                        senderFails++
                        if (senderFails == 1L || senderFails % 20L == 0L) {
                            Log.w(TAG, "SRT stream dropped: ${e.message} " +
                                    "($senderFails so far) — re-arming and redialing")
                        }
                    } finally {
                        synchronized(socketLock) {
                            closeQuietly(s)
                            if (srtClient === s) srtClient = null
                        }
                    }
                }
            } finally {
                releaseCodec()
            }
        }

        private fun serveSrt(s: SrtSocket, demux: TsDemuxer, onFirstData: () -> Unit) {
            var gotData = false
            var idleMs = 0L
            while (running) {
                val buf = try {
                    s.recv(SRT_RECV_BYTES)
                } catch (e: Exception) {
                    // srtdroid maps an RCVTIMEO expiry into the same exception
                    // family as a genuine failure (srt returns -1 for both) —
                    // ask the socket which it was. CONNECTED with no data is a
                    // healthy-but-idle sender (TD's timeline paused, encoder
                    // producing nothing): HOLD instead of dropping, or every
                    // idle timeout becomes a drop → re-arm → redial churn
                    // against TD's single-shot listener and srtdroid's
                    // per-dial JNI leak. A dead peer reads BROKEN/CLOSED and
                    // still routes to the drop path.
                    if (running && s.sockState == SockStatus.CONNECTED) {
                        idleMs += CLIENT_IDLE_TIMEOUT_MS
                        if (idleMs == CLIENT_IDLE_TIMEOUT_MS.toLong() ||
                                idleMs % (CLIENT_IDLE_TIMEOUT_MS * 15L) == 0L) {
                            Log.i(TAG, "SRT stream idle ${idleMs / 1000} s " +
                                    "(sender paused?) — holding the connection")
                        }
                        continue
                    }
                    throw e
                }
                if (buf.isEmpty()) continue
                idleMs = 0L
                if (!gotData) {
                    gotData = true
                    onFirstData()
                }
                stats.addBytes(buf.size)
                demux.feed(buf, buf.size) { au -> handlePayload(au) }
            }
        }

        /** Ring TD's doorbell: one JSON line on the control port, then a
         *  settle for its two-frame re-arm. Failure is a failed dial — TD
         *  gone means the arm channel is gone too. The socket registers
         *  under socketLock so shutdown() can cut a blocked connect (its
         *  2 s timeout plus the settle could otherwise outlive the join). */
        private fun sendSrtArm(t: SrtPullTarget): Boolean {
            val c = Socket()
            synchronized(socketLock) {
                if (!running) {
                    closeQuietly(c)
                    return false
                }
                ctrlSock = c
            }
            try {
                c.connect(InetSocketAddress(t.host, t.ctrlPort), CONNECT_TIMEOUT_MS)
                c.getOutputStream().write("{\"t\": \"srt_arm\"}\n".toByteArray())
                c.getOutputStream().flush()
            } catch (e: Exception) {
                return false
            } finally {
                synchronized(socketLock) {
                    if (ctrlSock === c) ctrlSock = null
                }
                closeQuietly(c)
            }
            return try {
                Thread.sleep(SRT_ARM_SETTLE_MS)
                true
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                false
            }
        }

        private fun serve(sock: Socket) {
            // NoDelay: a NAL every ~42 ms at 24 fps is exactly the traffic
            // Nagle was built to batch, and batching is latency.
            sock.tcpNoDelay = true
            // A live stream is never this quiet. A read outliving the timeout
            // is a sender that died without FIN (WiFi drop) — and it must not
            // squat the single-client listener forever: time out, drop,
            // re-accept.
            sock.soTimeout = CLIENT_IDLE_TIMEOUT_MS
            val input = DataInputStream(BufferedInputStream(sock.getInputStream(), 64 * 1024))
            while (running) {
                val len = input.readInt()   // u32 BE — DataInputStream is big-endian natively
                if (len <= 0 || len > MAX_PAYLOAD_BYTES) {
                    // Framing lost; a length-prefixed stream cannot resync.
                    // IOException routes to the drop-connection path — the
                    // sender reconnects with fresh SPS/PPS.
                    throw IOException("bad payload length $len")
                }
                val payload = ByteArray(len)
                input.readFully(payload)
                stats.addBytes(len + 4)
                handlePayload(payload)
            }
        }

        private fun handlePayload(payload: ByteArray) {
            val nals = scanStartCodes(payload)
            if (nals.isEmpty()) {
                // Length framing parsed but no Annex-B start code inside: not
                // our wire format. The framing itself is still in sync, so
                // skip the payload rather than the connection.
                badPayloads++
                stats.drop()
                if (badPayloads == 1L || badPayloads % 100L == 0L) {
                    Log.w(TAG, "payload without start code ($badPayloads so far)")
                }
                return
            }
            val hasVcl = harvest(payload, nals)

            if (codecDead) {
                // The callback thread flagged a decoder error. Rebuild from
                // the cached parameter sets; the picture heals at the next
                // IDR (short-GOP senders make that soon).
                releaseCodec()
                codecDead = false
            }
            var c = codec
            if (c == null) {
                val s = sps
                val p = pps
                if (s == null || p == null) {
                    // Picture data before SPS+PPS is undecodable by definition.
                    if (hasVcl) stats.drop()
                    return
                }
                c = buildCodec(s, p)
                if (c == null) {
                    if (hasVcl) stats.drop()
                    return
                }
            }
            submit(c, payload)
        }

        /** (start-code index, first payload byte index) for every NAL found —
         *  both 3- and 4-byte start codes. Capped (spec §6.6): a real access
         *  unit is a handful of NALs, a multi-slice IDR at worst a few dozen —
         *  but a 2 MiB payload of wall-to-wall `00 00 01` passes the length
         *  guard and would box ~700k pairs here, tens of MB of allocation per
         *  payload on a phone mid-show. Past the cap the framing is lost in
         *  all but name, so it routes to the same path as a bad length: the
         *  IOException drops the connection, the listener survives. */
        private fun scanStartCodes(p: ByteArray): List<Pair<Int, Int>> {
            val out = ArrayList<Pair<Int, Int>>(4)
            var i = 0
            while (i + 3 <= p.size) {
                if (p[i] == ZERO && p[i + 1] == ZERO) {
                    val skip = when {
                        p[i + 2] == ONE -> 3
                        i + 4 <= p.size && p[i + 2] == ZERO && p[i + 3] == ONE -> 4
                        else -> 0
                    }
                    if (skip > 0) {
                        out.add(i to i + skip)
                        if (out.size > MAX_NALS_PER_PAYLOAD) {
                            throw IOException(
                                "payload with >$MAX_NALS_PER_PAYLOAD NAL units — framing lost")
                        }
                        i += skip
                        continue
                    }
                }
                i++
            }
            return out
        }

        /** Cache SPS/PPS out of the payload; true if it carries picture data.
         *  A mid-stream parameter-set change still reaches the decoder in-band
         *  via submit() — this cache only feeds (re)configuration. */
        private fun harvest(p: ByteArray, nals: List<Pair<Int, Int>>): Boolean {
            var vcl = false
            for ((k, nal) in nals.withIndex()) {
                val off = nal.second
                if (off >= p.size) continue   // start code at the very end, no payload byte
                val end = if (k + 1 < nals.size) nals[k + 1].first else p.size
                when (p[off].toInt() and 0x1F) {
                    NAL_SPS -> sps = p.copyOfRange(off, end)
                    NAL_PPS -> pps = p.copyOfRange(off, end)
                    NAL_IDR, NAL_NON_IDR -> vcl = true
                }
            }
            return vcl
        }

        private fun buildCodec(s: ByteArray, p: ByteArray): MediaCodec? {
            // After a decoder error, don't thrash rebuilds against a stream
            // that keeps killing it — one attempt per retry window.
            val now = SystemClock.elapsedRealtime()
            if (lastCodecFailMs != 0L && now - lastCodecFailMs < CODEC_RETRY_MS) return null
            try {
                val format = MediaFormat.createVideoFormat(MIME, texW, texH).apply {
                    // csd straight from the wire, start codes included —
                    // MediaCodec's documented Annex-B form (csd-0 = SPS,
                    // csd-1 = PPS). The decoder takes the real geometry from
                    // the SPS; texW/texH are only the configure hint.
                    setByteBuffer("csd-0", ByteBuffer.wrap(START_CODE + s))
                    setByteBuffer("csd-1", ByteBuffer.wrap(START_CODE + p))
                    setInteger(MediaFormat.KEY_PRIORITY, 0)   // 0 = realtime
                }
                val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format)
                val c = if (name != null) MediaCodec.createByCodecName(name)
                        else MediaCodec.createDecoderByType(MIME)
                // KEY_LOW_LATENCY only AFTER choosing the decoder: in the
                // format up front, findDecoderForFormat would reject every
                // decoder lacking the feature instead of falling back to a
                // merely-fast one.
                if (Build.VERSION.SDK_INT >= 30 && c.codecInfo.getCapabilitiesForType(MIME)
                        .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
                    format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                } else {
                    Log.w(TAG, "decoder has no low-latency feature — running without")
                }
                val ht = HandlerThread("PVJLink-Codec").apply { start() }
                // Registered before configure so a failure below still finds
                // everything through releaseCodec() in the catch.
                codec = c
                codecThread = ht
                c.setCallback(codecCallback, Handler(ht.looper))
                c.configure(format, surface, null, 0)
                c.start()
                Log.i(TAG, "decoder up: ${c.name}, hint ${texW}x$texH")
                return c
            } catch (e: Exception) {
                buildFails++
                lastCodecFailMs = now
                if (buildFails == 1L || buildFails % 20L == 0L) {
                    Log.e(TAG, "decoder build failed: ${e.message} ($buildFails so far)")
                }
                releaseCodec()
                return null
            }
        }

        private fun submit(c: MediaCodec, payload: ByteArray) {
            val idx = try {
                freeInputs.poll(INPUT_WAIT_MS, TimeUnit.MILLISECONDS)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                null
            }
            if (idx == null) {
                // Decoder starved us for over a frame period: drop. Losing a
                // P-frame smears until the next IDR — still better than input
                // queueing, which is latency you can never spend down
                // (NetSource's latest-wins policy, decoder edition).
                stats.drop()
                return
            }
            try {
                val ib = c.getInputBuffer(idx) ?: return
                if (payload.size > ib.capacity()) {
                    stats.drop()
                    c.queueInputBuffer(idx, 0, 0, 0, 0)   // hand the buffer back empty
                    return
                }
                ib.clear()
                ib.put(payload)
                val pts = nextPts()
                inFlight[pts] = System.nanoTime()
                // Non-VCL payloads (SEI, bare parameter sets) produce no
                // output, so their entries never come back — cap, don't leak.
                if (inFlight.size > IN_FLIGHT_CAP) inFlight.clear()
                c.queueInputBuffer(idx, 0, payload.size, pts, 0)
            } catch (e: IllegalStateException) {
                // Codec died between poll and queue; onError already flagged
                // the rebuild — this payload is the casualty.
                stats.drop()
            }
        }

        /** Strictly increasing pts (µs). The wall clock is the natural value;
         *  the +1 fallback covers two payloads inside one microsecond. */
        private fun nextPts(): Long {
            val now = System.nanoTime() / 1000
            lastPtsUs = if (now > lastPtsUs) now else lastPtsUs + 1
            return lastPtsUs
        }

        /** Net thread only (the codec's single thread of control). stop()
         *  before release() so the callback thread quiesces first. */
        private fun releaseCodec() {
            val c = codec
            codec = null   // callbacks compare against this and stand down
            if (c != null) {
                try {
                    c.stop()
                } catch (e: IllegalStateException) {
                    // Already dead — release still reclaims it.
                }
                try {
                    c.release()
                } catch (e: RuntimeException) {
                    Log.w(TAG, "codec release failed: ${e.message}")
                }
            }
            codecThread?.quitSafely()
            codecThread = null
            freeInputs.clear()
            inFlight.clear()
        }

        // --- PVJLink-Codec thread (async callbacks) -----------------------

        private val codecCallback = object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(c: MediaCodec, index: Int) {
                if (c !== codec) return   // late callback from a released codec
                freeInputs.offer(index)   // capacity exceeds any codec's buffer count
            }

            override fun onOutputBufferAvailable(
                c: MediaCodec, index: Int, info: MediaCodec.BufferInfo,
            ) {
                if (c !== codec) return
                // render=true immediately, never held, never paced: display-
                // ASAP is the point, and the Surface drops excess frames on
                // its own (Q+ default we deliberately keep).
                try {
                    c.releaseOutputBuffer(index, true)
                } catch (e: IllegalStateException) {
                    return   // released under us mid-teardown
                }
                val t0 = inFlight.remove(info.presentationTimeUs)
                stats.frameOut(if (t0 != null) (System.nanoTime() - t0) / 1e6 else -1.0)
            }

            override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
                if (c !== codec) return
                decodeErrors++
                if (decodeErrors == 1L || decodeErrors % 20L == 0L) {
                    Log.e(TAG, "decoder error: ${e.message} ($decodeErrors so far) — rebuilding")
                }
                lastCodecFailMs = SystemClock.elapsedRealtime()
                codecDead = true   // the net thread rebuilds from cached SPS/PPS
                stats.drop()
            }

            override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {
                if (c !== codec) return
                // Display size = the crop rect when present: coded size is
                // 16-aligned (720 codes clean, 1080 codes as 1088) and the
                // crop is what's real. String keys because the KEY_CROP_*
                // constants are API 33, but decoders have emitted these exact
                // strings since KitKat.
                val w = if (format.containsKey("crop-right"))
                    format.getInteger("crop-right") - format.getInteger("crop-left") + 1
                else format.getInteger(MediaFormat.KEY_WIDTH)
                val h = if (format.containsKey("crop-bottom"))
                    format.getInteger("crop-bottom") - format.getInteger("crop-top") + 1
                else format.getInteger(MediaFormat.KEY_HEIGHT)
                Log.i(TAG, "stream geometry ${w}x$h (texture hint ${texW}x$texH)")
                if ((w != texW || h != texH) && (w != geomW || h != geomH)) {
                    geomW = w
                    geomH = h
                    // Any-thread-safe: emitSignal dispatches to the render
                    // thread internally before it touches GDScript.
                    emitSignal("frame_geometry", w, h)
                }
            }
        }

        private fun closeQuietly(c: Closeable) {
            try {
                c.close()
            } catch (e: IOException) {
                // Teardown path — nothing useful to do with it.
            }
        }
    }

    // --- The send path (milestone 2) --------------------------------------

    /** buildEncoder's result: the Surface exists only in surface-input mode,
     *  created between configure and start as MediaCodec requires. */
    private class BuiltEncoder(val codec: MediaCodec, val inputSurface: Surface?)

    /** One encoded access unit in GpuSender's drain→tx mailbox. Lives at
     *  class level because Kotlin prohibits nested classes inside an inner
     *  class — same shape as SurfaceRecorder.Stashed otherwise. */
    private class Au(val bytes: ByteArray, val isKey: Boolean, val ptsUs: Long)

    /** Build + start the H.264 encoder. Null (with a throttled log) means
     *  refused — start_send turns that into `false`, the in-thread rebuild
     *  into a retry next window. Low-latency shape per spec §6.6 and the M2
     *  research: CBR gated on real support, no B-frames, 1 s GOP + on-demand
     *  sync frames instead of intra-refresh (KEY_INTRA_REFRESH_PERIOD is
     *  feature-gated and undocumented on this hardware; a short GOP is
     *  dependable everywhere), KEY_LATENCY as a pipeline-depth REQUEST whose
     *  granted value is read back and logged, never trusted.
     *
     *  surfaceInput picks the v2 GPU feed (milestone 2.5(b)): COLOR_FormatSurface
     *  + createInputSurface, the render thread blits, and the whole CPU
     *  convert path simply does not exist. Both feeds share every other
     *  format decision — one encoder shape, two ways of filling it. */
    private fun buildEncoder(w: Int, h: Int, fps: Float, bitrateBps: Int,
                             surfaceInput: Boolean = false): BuiltEncoder? {
        var c: MediaCodec? = null
        try {
            val format = MediaFormat.createVideoFormat(MIME, w, h).apply {
                // CPU feed: flexible YUV + getInputImage is the vendor-proof
                // input (the plane objects carry the REAL strides). GPU feed:
                // COLOR_FormatSurface, and the strides stop being our problem
                // entirely — the BufferQueue hands the encoder its own layout.
                setInteger(MediaFormat.KEY_COLOR_FORMAT,
                        if (surfaceInput)
                            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
                        else
                            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, ENC_GOP_SECONDS)
            }
            // Frame rate joins AFTER selection: findEncoderForFormat is
            // documented to reject formats that carry one.
            val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            c = if (name != null) MediaCodec.createByCodecName(name)
                else MediaCodec.createEncoderByType(MIME)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, Math.round(fps))
            val encCaps = c.codecInfo.getCapabilitiesForType(MIME).encoderCapabilities
            if (encCaps != null && encCaps.isBitrateModeSupported(
                            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)) {
                // CBR is what keeps per-frame NAL sizes flat, so the TCP send
                // never bursts past the fps drain rate.
                format.setInteger(MediaFormat.KEY_BITRATE_MODE,
                        MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            } else {
                Log.w(TAG, "encoder has no CBR mode — frame sizes will breathe with the scene")
            }
            // Already the default and AVC hardware essentially never emits
            // B-frames unasked — but the wire contract says none, so SAY none.
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)   // 0 = realtime
            // NOT KEY_LOW_LATENCY — that key is decoder-only by definition
            // (the receive path uses it correctly); this is the encoder twin.
            format.setInteger(MediaFormat.KEY_LATENCY, 1)
            c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val granted = try {
                val f = c.inputFormat
                if (f.containsKey(MediaFormat.KEY_LATENCY))
                    f.getInteger(MediaFormat.KEY_LATENCY) else -1
            } catch (e: Exception) {
                -1
            }
            // Ordering is MediaCodec law: createInputSurface sits strictly
            // between configure and start.
            val surf = if (surfaceInput) c.createInputSurface() else null
            c.start()
            Log.i(TAG, "encoder up: ${c.name}, ${w}x$h @$fps, $bitrateBps bps, " +
                    "granted latency=$granted (-1 = not reported)" +
                    if (surfaceInput) ", surface input" else "")
            return BuiltEncoder(c, surf)
        } catch (e: Exception) {
            encBuildFails++
            val n = encBuildFails
            if (n == 1L || n % 20L == 0L) {
                Log.e(TAG, "encoder build failed: ${e.message} ($n so far)")
            }
            try {
                c?.release()
            } catch (e2: RuntimeException) {
                // Half-built codec fighting release — nothing more to reclaim.
            }
            return null
        }
    }

    /**
     * One send lifecycle: mailbox → convert → encode → framing v1 → TCP.
     * Mirrors Receiver's shape — whole-object per start/stop, one worker
     * thread owning the codec and the socket, drop-never-buffer everywhere.
     * The sender CONNECTS to the receiving peer's listener (spec §6.6: same
     * connection shape as the PC test sender) and a successful connect is
     * NOT ownership — the far end accepts serially, so early bytes may wait
     * in its kernel backlog; they are the correct first bytes (SPS/PPS,
     * then IDR) whenever it gets to us.
     */
    private inner class Sender(
        initialCodec: MediaCodec,
        private val host: String,
        private val port: Int,
        private val frameW: Int,
        private val frameH: Int,
        private val fps: Float,
        private val bitrateBps: Int,
    ) {
        // The mailbox is push_frame's WHOLE cross-thread surface: 1-deep,
        // latest wins. An occupied slot means the worker is behind — the old
        // frame dies, counted, and nothing ever queues (NetSender's jpeg
        // policy, encoder edition).
        private val mailboxLock = Object()
        private var mailbox: ByteArray? = null   // guarded by mailboxLock

        @Volatile private var running = true
        private val socketLock = Any()
        private var socket: Socket? = null       // guarded by socketLock (shutdown aborts through it)
        private val encThread = Thread(::encLoop, "PVJLink-Enc")

        // Write-stall watchdog: nonzero while PVJLink-Enc is inside a blocking
        // socket write (it sets/clears; checkWriteStall on other threads only
        // reads and compares — see it for the whole story).
        @Volatile private var writeStartMs = 0L
        private var writeStalls = 0L             // log throttle; races only blur the throttle

        // Render thread only (push_frame's caller): bad-frame log throttle.
        private var badFrames = 0L

        // Everything below: PVJLink-Enc thread only. initialCodec is handed
        // over sequentially (written before Thread.start's happens-before),
        // so the codec keeps ONE thread of control for its whole life.
        private var codec: MediaCodec? = initialCodec
        private var out: DataOutputStream? = null
        private var csd: ByteArray? = null       // SPS+PPS, Annex-B, exactly as the encoder emitted
        private var awaitingKey = true
        private var lastPtsUs = 0L
        private var lastConnectMs = 0L           // 0 = dial immediately
        private var lastBuildMs = 0L
        private var connectFails = 0L
        private var peerLosses = 0L
        private var encoderDeaths = 0L
        private val ptsInFlight = HashMap<Long, Long>()   // ptsUs -> queue nanos (encode_ms)
        private val outInfo = MediaCodec.BufferInfo()
        private var outScratch = ByteArray(0)    // grows to steady state, then allocation-free

        // Conversion workspace, allocated once: tightly-packed I420 planes
        // ours to fill fast, then copied into the codec's Image honoring its
        // strides. uvRow is the NV12 fast path's interleave scratch.
        private val chromaW = frameW / 2
        private val chromaH = frameH / 2
        private val yPlane = ByteArray(frameW * frameH)
        private val uPlane = ByteArray(chromaW * chromaH)
        private val vPlane = ByteArray(chromaW * chromaH)
        private val uvRow = ByteArray(frameW)

        fun start() = encThread.start()

        /** Any thread (in practice the GL render thread, inside push_frame).
         *  A geometry/size mismatch is dropped here, not shipped: the encoder
         *  was configured for exactly frameW x frameH RGB8. */
        fun push(rgb: ByteArray, w: Int, h: Int) {
            checkWriteStall()   // capture cadence doubles as the stall clock
            if (w != frameW || h != frameH || rgb.size != frameW * frameH * 3) {
                badFrames++
                sendStats.drop()
                if (badFrames == 1L || badFrames % 100L == 0L) {
                    Log.w(TAG, "push_frame ${w}x$h/${rgb.size}B does not match " +
                            "started ${frameW}x$frameH RGB8 — dropped ($badFrames so far)")
                }
                return
            }
            synchronized(mailboxLock) {
                if (mailbox != null) sendStats.drop()   // latest wins
                mailbox = rgb
                mailboxLock.notify()
            }
        }

        /** Any thread — in practice push_frame's capture cadence plus the
         *  ~1 Hz stats poll (which keeps watch even when capture stops). Java
         *  sockets have no write deadline: against a peer whose kernel keeps
         *  ACKing while its frozen app never reads (Android's cached-app
         *  freezer — a backgrounded receiver, screen locked), write() blocks
         *  FOREVER, no IOException ever comes, and PVJLink-Enc is wedged in
         *  the syscall — no encode, no redial, is_active() lying upstream.
         *  The receive path's idle timeout has no send-side twin, so this is
         *  it: closing the socket out from under the write is the one
         *  documented, thread-safe way to break it — the write throws, the
         *  enc thread runs onPeerLost, and the ordinary redial path takes it
         *  from there. */
        fun checkWriteStall() {
            val t = writeStartMs
            if (t == 0L || SystemClock.elapsedRealtime() - t < WRITE_STALL_TIMEOUT_MS) return
            synchronized(socketLock) {
                val s = socket ?: return
                if (s.isClosed) return   // already cut — the write is about to throw
                writeStalls++
                if (writeStalls == 1L || writeStalls % 20L == 0L) {
                    Log.w(TAG, "send write stalled ${WRITE_STALL_TIMEOUT_MS} ms+ " +
                            "($writeStalls so far) — cutting the socket to unwedge the send thread")
                }
                closeQuietly(s)
            }
        }

        /** GL render thread (stop_send). Order per the stop_send doc. */
        fun shutdown() {
            running = false
            synchronized(mailboxLock) {
                mailbox = null
                mailboxLock.notify()
            }
            synchronized(socketLock) { socket?.let { closeQuietly(it) } }
            try {
                encThread.join(4000)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            if (encThread.isAlive) {
                // Never observed; better to leak one codec to GC than have
                // two threads fight over release() (Receiver's rule).
                Log.w(TAG, "send thread did not exit — abandoning encoder teardown")
            }
        }

        // --- PVJLink-Enc thread -------------------------------------------

        private fun encLoop() {
            try {
                while (running) {
                    var c = codec
                    if (c == null) {
                        c = rebuildEncoder()
                        if (c == null) {
                            // Broken encoder: frames still land in the mailbox
                            // and die HERE as drops — never queued, and
                            // push_frame never feels it.
                            takeFrame(RETRY_POLL_MS)?.let { sendStats.drop() }
                            continue
                        }
                    }
                    if (!ensureConnected()) {
                        // Between redials the story is the same: dead on
                        // arrival, counted, gone.
                        takeFrame(RETRY_POLL_MS)?.let { sendStats.drop() }
                        continue
                    }
                    // With output owed, hover near the encoder (~one encode is
                    // 5-6 ms on this hardware) instead of a whole idle wait.
                    val frame = takeFrame(
                            if (ptsInFlight.isEmpty()) ENC_IDLE_WAIT_MS else ENC_PIPE_WAIT_MS)
                    if (frame != null) feed(c, frame)
                    if (codec === c) drain(c)   // feed may have killed it
                }
            } finally {
                // The one thread of control releases what it controlled.
                releaseEncoder()
                disconnect()
            }
        }

        private fun takeFrame(waitMs: Long): ByteArray? {
            synchronized(mailboxLock) {
                if (mailbox == null && running) {
                    try {
                        mailboxLock.wait(waitMs)
                    } catch (e: InterruptedException) {
                        Thread.currentThread().interrupt()
                    }
                }
                val f = mailbox
                mailbox = null
                return f
            }
        }

        /** True when a connection is up; dials (rate-limited to one attempt
         *  per CONNECT_RETRY_MS) when not. §6.6 stream rules on success:
         *  parameter sets first, then an on-demand IDR so the receiver's
         *  fresh decoder heals NOW, not at the next GOP boundary. */
        private fun ensureConnected(): Boolean {
            if (out != null) return true
            val now = SystemClock.elapsedRealtime()
            if (now - lastConnectMs < CONNECT_RETRY_MS) return false
            lastConnectMs = now
            val s = Socket()
            synchronized(socketLock) {
                if (!running) {
                    closeQuietly(s)
                    return false
                }
                socket = s   // published so shutdown() can abort a blocking connect
            }
            try {
                // NoDelay: a NAL every ~42 ms at 24 fps is exactly the traffic
                // Nagle was built to batch, and batching is latency. (The
                // BufferedOutputStream below isn't Nagle-by-another-name: it
                // is flushed per payload, one syscall per frame.)
                s.tcpNoDelay = true
                // Cap the kernel send buffer BEFORE connect (SEND_BUF_BYTES —
                // see it for the arithmetic): left to auto-tune, the mailbox's
                // drop policy sits behind a multi-megabyte reservoir and a
                // path slower than the CBR rate becomes seconds of invisible
                // latency instead of visible drops.
                s.sendBufferSize = SEND_BUF_BYTES
                s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
                val o = DataOutputStream(BufferedOutputStream(s.getOutputStream(), 64 * 1024))
                csd?.let {
                    writeStartMs = SystemClock.elapsedRealtime()
                    try {
                        o.writeInt(it.size)   // u32 BE — DataOutputStream is big-endian natively
                        o.write(it, 0, it.size)
                        o.flush()
                    } finally {
                        writeStartMs = 0L
                    }
                    sendStats.addBytes(it.size + 4)
                }
                out = o
                awaitingKey = true
                codec?.let { requestSyncFrame(it) }
                connectFails = 0   // next outage gets a loud first log again
                Log.i(TAG, "connected to $host:$port — streaming")
                return true
            } catch (e: IOException) {
                connectFails++
                if (connectFails == 1L || connectFails % 15L == 0L) {
                    Log.w(TAG, "connect to $host:$port failed: ${e.message} " +
                            "($connectFails so far) — retrying every ${CONNECT_RETRY_MS / 1000} s")
                }
                synchronized(socketLock) {
                    closeQuietly(s)
                    if (socket === s) socket = null
                }
                return false
            }
        }

        private fun feed(c: MediaCodec, frame: ByteArray) {
            try {
                val idx = c.dequeueInputBuffer(ENC_INPUT_WAIT_US)
                if (idx < 0) {
                    // Encoder starved us past two frame periods: drop —
                    // latest-wins has no queue to hide this in, by design.
                    sendStats.drop()
                    return
                }
                // Capacity read BEFORE getInputImage (which invalidates the
                // ByteBuffer view): queueInputBuffer needs a size, and the
                // vendor's strides may pad past the tight w*h*3/2.
                val cap = c.getInputBuffer(idx)?.capacity() ?: 0
                val image = c.getInputImage(idx)
                if (image == null) {
                    // Contractually impossible in ByteBuffer mode with
                    // flexible YUV; hand the buffer back rather than wedge.
                    c.queueInputBuffer(idx, 0, 0, 0, 0)
                    sendStats.drop()
                    return
                }
                val t0 = System.nanoTime()
                convert(frame, image)
                sendStats.convert((System.nanoTime() - t0) / 1e6)
                val pts = nextPts()
                ptsInFlight[pts] = System.nanoTime()
                // Entries whose output never comes back would leak — cap,
                // don't leak (Receiver's inFlight rule).
                if (ptsInFlight.size > IN_FLIGHT_CAP) ptsInFlight.clear()
                c.queueInputBuffer(idx, 0, cap, pts, 0)
            } catch (e: IllegalStateException) {
                sendStats.drop()
                onCodecDied(e)
            }
        }

        private fun drain(c: MediaCodec) {
            // First dequeue waits one encode's-worth, and only when output is
            // owed; the sweep after it never waits — a tail wait here would
            // eat into the frame period.
            var timeout = if (ptsInFlight.isEmpty()) 0L else ENC_DRAIN_WAIT_US
            while (running) {
                val idx = try {
                    c.dequeueOutputBuffer(outInfo, timeout)
                } catch (e: IllegalStateException) {
                    onCodecDied(e)
                    return
                }
                timeout = 0L
                when {
                    idx >= 0 -> handleOutput(c, idx)
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> cacheCsd(c.outputFormat)
                    idx == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> { /* ignorable with getOutputBuffer */ }
                    else -> return   // TRY_AGAIN — the pipe is drained
                }
            }
        }

        private fun handleOutput(c: MediaCodec, idx: Int) {
            val size = outInfo.size
            val flags = outInfo.flags
            val ptsUs = outInfo.presentationTimeUs
            var ok = size > 0
            if (ok) {
                if (outScratch.size < size) outScratch = ByteArray(size)
                val buf = c.getOutputBuffer(idx)
                if (buf == null) {
                    ok = false
                } else {
                    buf.position(outInfo.offset)
                    buf.get(outScratch, 0, size)
                }
            }
            try {
                c.releaseOutputBuffer(idx, false)
            } catch (e: IllegalStateException) {
                onCodecDied(e)
                return
            }
            if (!ok) return
            if (flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                // SPS+PPS, start codes ALREADY included — encoder csd is
                // Annex-B as emitted (the receive side's add-a-start-code
                // habit is decoder-configure lore; adding one here would
                // double it). Cached, never counted as a frame: it rides at
                // the head of every connection and glued to every IDR.
                csd = outScratch.copyOf(size)
                return
            }
            val t0 = ptsInFlight.remove(ptsUs)
            val o = out
            if (o == null) {
                // Encoded with nobody connected (the redial window): a
                // casualty of the drop policy, not an error.
                sendStats.drop()
                return
            }
            val key = flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
            if (awaitingKey && !key) {
                // A fresh connection is a fresh decoder on the far end
                // (§6.6); P-frames from before its first IDR reference
                // pictures it never saw.
                sendStats.drop()
                return
            }
            // SPS+PPS glued ahead of every IDR, one payload — §6.6 tolerates
            // a whole access unit per payload, and this is what keeps the
            // "ideally with every IDR" clause true without re-configuring
            // the codec (KEY_PREPEND_HEADER's documented failure mode is a
            // hard configure fail on some vendors; the manual glue is the
            // works-everywhere version).
            val head = if (key) csd else null
            val len = size + (head?.size ?: 0)
            if (len > MAX_PAYLOAD_BYTES) {
                // The receiver's framing guard kills the CONNECTION for an
                // oversized length; dropping the frame here is strictly
                // cheaper. CBR at these bitrates never comes close.
                sendStats.drop()
                return
            }
            try {
                writeStartMs = SystemClock.elapsedRealtime()
                try {
                    o.writeInt(len)
                    if (head != null) o.write(head, 0, head.size)
                    o.write(outScratch, 0, size)
                    o.flush()
                } finally {
                    writeStartMs = 0L
                }
                awaitingKey = false
                sendStats.addBytes(len + 4)
                sendStats.frameOut(if (t0 != null) (System.nanoTime() - t0) / 1e6 else -1.0)
            } catch (e: IOException) {
                sendStats.drop()
                onPeerLost(e)
            }
        }

        /** Strictly increasing pts (µs) — Receiver's nextPts, verbatim. */
        private fun nextPts(): Long {
            val now = System.nanoTime() / 1000
            lastPtsUs = if (now > lastPtsUs) now else lastPtsUs + 1
            return lastPtsUs
        }

        private fun requestSyncFrame(c: MediaCodec) {
            try {
                c.setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                })
            } catch (e: IllegalStateException) {
                // Dying codec — the next dequeue notices properly.
            }
        }

        /** csd-0 (SPS) + csd-1 (PPS) from INFO_OUTPUT_FORMAT_CHANGED — the
         *  same bytes as the BUFFER_FLAG_CODEC_CONFIG output, Annex-B with
         *  start codes; cache whichever source lands first. */
        private fun cacheCsd(format: MediaFormat) {
            val c0 = format.getByteBuffer("csd-0") ?: return
            val d0 = c0.duplicate()
            val d1 = format.getByteBuffer("csd-1")?.duplicate()
            val n0 = d0.remaining()
            val n1 = d1?.remaining() ?: 0
            val bytes = ByteArray(n0 + n1)
            d0.get(bytes, 0, n0)
            d1?.get(bytes, n0, n1)
            csd = bytes
        }

        private fun onPeerLost(e: IOException) {
            peerLosses++
            if (peerLosses == 1L || peerLosses % 20L == 0L) {
                Log.w(TAG, "receiver dropped: ${e.message} ($peerLosses so far) " +
                        "— redialing every ${CONNECT_RETRY_MS / 1000} s")
            }
            disconnect()
            lastConnectMs = SystemClock.elapsedRealtime()   // full window before the redial
        }

        private fun onCodecDied(e: Exception) {
            encoderDeaths++
            if (encoderDeaths == 1L || encoderDeaths % 20L == 0L) {
                Log.e(TAG, "encoder died: ${e.message} ($encoderDeaths so far) — rebuilding")
            }
            releaseEncoder()
            lastBuildMs = SystemClock.elapsedRealtime()   // full window before the rebuild
        }

        /** One rebuild attempt per window (Receiver's CODEC_RETRY_MS). A
         *  fresh encoder mints fresh parameter sets, so the cached csd dies
         *  with the old one and the far end holds out for the new IDR. */
        private fun rebuildEncoder(): MediaCodec? {
            val now = SystemClock.elapsedRealtime()
            if (now - lastBuildMs < CODEC_RETRY_MS) return null
            lastBuildMs = now
            val c = buildEncoder(frameW, frameH, fps, bitrateBps)?.codec ?: return null
            codec = c
            csd = null
            awaitingKey = true
            return c
        }

        /** PVJLink-Enc only (or its join()ed aftermath): stop before release
         *  so the codec quiesces first — Receiver's order. */
        private fun releaseEncoder() {
            val c = codec ?: return
            codec = null
            try {
                c.stop()
            } catch (e: IllegalStateException) {
                // Already dead — release still reclaims it.
            }
            try {
                c.release()
            } catch (e: RuntimeException) {
                Log.w(TAG, "encoder release failed: ${e.message}")
            }
            ptsInFlight.clear()
        }

        private fun disconnect() {
            synchronized(socketLock) {
                socket?.let { closeQuietly(it) }
                socket = null
            }
            out = null
            awaitingKey = true
        }

        // --- RGB8 → flexible YUV (fixed-point BT.601 limited range) -------

        /** Pass 1 fills our tightly-packed I420 workspace from the RGB8
         *  frame — one walk over 2x2 blocks, so chroma is a true 4-tap
         *  average and every coefficient path stays provably in 0..255 (no
         *  clamps: Y lands in 16..235, chroma in 16..240 by construction).
         *  Pass 2 copies the workspace into the codec's Image honoring the
         *  vendor's strides. Hand-rolled Kotlin is the bring-up config
         *  (~15-30 ms at 720p, pipelines fine at 24 fps); the libyuv shim is
         *  the ship config when this is load-bearing, and the v2 GPU blit
         *  deletes the conversion entirely. */
        private fun convert(rgb: ByteArray, image: Image) {
            val w = frameW
            val h = frameH
            var uv = 0
            var by = 0
            while (by < h) {
                var s0 = by * w * 3          // top row of the 2x2, byte index
                var s1 = s0 + w * 3          // bottom row
                var d0 = by * w              // Y plane indices
                var d1 = d0 + w
                var bx = 0
                while (bx < w) {
                    val r0 = rgb[s0].toInt() and 0xFF
                    val g0 = rgb[s0 + 1].toInt() and 0xFF
                    val b0 = rgb[s0 + 2].toInt() and 0xFF
                    val r1 = rgb[s0 + 3].toInt() and 0xFF
                    val g1 = rgb[s0 + 4].toInt() and 0xFF
                    val b1 = rgb[s0 + 5].toInt() and 0xFF
                    val r2 = rgb[s1].toInt() and 0xFF
                    val g2 = rgb[s1 + 1].toInt() and 0xFF
                    val b2 = rgb[s1 + 2].toInt() and 0xFF
                    val r3 = rgb[s1 + 3].toInt() and 0xFF
                    val g3 = rgb[s1 + 4].toInt() and 0xFF
                    val b3 = rgb[s1 + 5].toInt() and 0xFF
                    yPlane[d0] = (((66 * r0 + 129 * g0 + 25 * b0 + 128) shr 8) + 16).toByte()
                    yPlane[d0 + 1] = (((66 * r1 + 129 * g1 + 25 * b1 + 128) shr 8) + 16).toByte()
                    yPlane[d1] = (((66 * r2 + 129 * g2 + 25 * b2 + 128) shr 8) + 16).toByte()
                    yPlane[d1 + 1] = (((66 * r3 + 129 * g3 + 25 * b3 + 128) shr 8) + 16).toByte()
                    val ar = (r0 + r1 + r2 + r3 + 2) shr 2
                    val ag = (g0 + g1 + g2 + g3 + 2) shr 2
                    val ab = (b0 + b1 + b2 + b3 + 2) shr 2
                    uPlane[uv] = (((-38 * ar - 74 * ag + 112 * ab + 128) shr 8) + 128).toByte()
                    vPlane[uv] = (((112 * ar - 94 * ag - 18 * ab + 128) shr 8) + 128).toByte()
                    uv++
                    s0 += 6
                    s1 += 6
                    d0 += 2
                    d1 += 2
                    bx += 2
                }
                by += 2
            }
            val planes = image.planes
            writeLuma(planes[0])
            writeChroma(planes[1], planes[2])
        }

        private fun writeLuma(p: Image.Plane) {
            val buf = p.buffer
            val rs = p.rowStride
            if (p.pixelStride == 1) {
                if (rs == frameW) {
                    buf.position(0)
                    buf.put(yPlane, 0, frameW * frameH)   // tight: one bulk put
                } else {
                    for (r in 0 until frameH) {
                        buf.position(r * rs)
                        buf.put(yPlane, r * frameW, frameW)
                    }
                }
                return
            }
            // Never seen in the wild for luma, but the flexible contract
            // technically allows it — absolute puts, slow and correct.
            val ps = p.pixelStride
            for (r in 0 until frameH) {
                var pos = r * rs
                var i = r * frameW
                val end = i + frameW
                while (i < end) {
                    if (pos < buf.limit()) buf.put(pos, yPlane[i])
                    pos += ps
                    i++
                }
            }
        }

        private fun writeChroma(u: Image.Plane, v: Image.Plane) {
            val ub = u.buffer
            val vb = v.buffer
            if (u.pixelStride == 2 && v.pixelStride == 2 && aliased(ub, vb)) {
                // NV12 (the Exynos/Tensor c2 layout): the U view's odd bytes
                // ARE the V plane, so one interleaved bulk write per row
                // covers both. rowStride re-read per frame — vendor's choice,
                // free to differ from 2*chromaW even when 1280 aligns today.
                val rs = u.rowStride
                val rowLen = chromaW * 2
                for (r in 0 until chromaH) {
                    var i = r * chromaW
                    var o = 0
                    while (o < rowLen) {
                        uvRow[o] = uPlane[i]
                        uvRow[o + 1] = vPlane[i]
                        o += 2
                        i++
                    }
                    val pos = r * rs
                    // The U view usually ends one byte short of the final V —
                    // clamp the bulk put to its limit and land the tail
                    // through the aliased V view (v offset = u offset - 1).
                    val n = minOf(rowLen, ub.limit() - pos)
                    ub.position(pos)
                    ub.put(uvRow, 0, n)
                    var o2 = n
                    while (o2 < rowLen) {
                        val vpos = pos + o2 - 1
                        if (vpos < vb.limit()) vb.put(vpos, uvRow[o2])
                        o2++
                    }
                }
                return
            }
            // Planar (I420-style) or anything stranger: per-plane writes that
            // touch ONLY their own samples, so U's pass can't clobber V's.
            writeChromaPlane(u, uPlane)
            writeChromaPlane(v, vPlane)
        }

        /** NV12 detection by experiment, not vendor lore: poke V[0] through
         *  the V view, look for it at U view byte 1 (the views alias one byte
         *  apart when the layout is truly semi-planar UV). Two probe values
         *  so a coincidence can't pass; no restore needed — convert
         *  overwrites every chroma byte right after. NV21 (VU order) fails
         *  the probe and lands on the generic path, correctly. */
        private fun aliased(ub: ByteBuffer, vb: ByteBuffer): Boolean {
            if (ub.limit() < 2 || vb.limit() < 1) return false
            vb.put(0, 0x5A.toByte())
            if (ub.get(1) != 0x5A.toByte()) return false
            vb.put(0, 0xA5.toByte())
            return ub.get(1) == 0xA5.toByte()
        }

        private fun writeChromaPlane(p: Image.Plane, src: ByteArray) {
            val buf = p.buffer
            val rs = p.rowStride
            val ps = p.pixelStride
            if (ps == 1) {
                for (r in 0 until chromaH) {
                    buf.position(r * rs)
                    buf.put(src, r * chromaW, chromaW)
                }
                return
            }
            // Absolute (position-less) puts: bulk-writing a gap-filled row
            // here would clobber the sibling plane's samples in the gaps.
            for (r in 0 until chromaH) {
                var pos = r * rs
                var i = r * chromaW
                val end = i + chromaW
                while (i < end) {
                    if (pos < buf.limit()) buf.put(pos, src[i])
                    pos += ps
                    i++
                }
            }
        }

        private fun closeQuietly(c: Closeable) {
            try {
                c.close()
            } catch (e: IOException) {
                // Teardown path — nothing useful to do with it.
            }
        }
    }

    /**
     * One GPU-fed send lifecycle (milestone 2.5(b), spec §5 Stage 1 send v2):
     * render-thread blit → Surface-input encoder → framing v1 → TCP. Same
     * wire, same destination contract as Sender; what changed is that no
     * frame pixel ever crosses to the CPU — the two stages the §9-M7 loop
     * kept counting (readback, RGB→YUV convert) do not exist here.
     *
     * ── THREADING ────────────────────────────────────────────────────────
     *   GL render thread  drawFrame() from onGLDrawFrame: reconciles the
     *                     encoder Surface into a GlBlitter target (generation
     *                     handoff — SurfaceRecorder's pattern verbatim),
     *                     paces to `fps` with NetSender's accumulator rule,
     *                     blits, stamps PTS via eglPresentationTimeANDROID.
     *                     Also shutdown(): GDScript runs on this thread, and
     *                     EGL target release belongs here.
     *   PVJLink-Drain     owns the codec (the one thread of control after the
     *                     constructor handoff): dequeues output, caches csd,
     *                     honors sync-frame requests, rebuilds a dead encoder
     *                     (new input Surface, re-published through the same
     *                     generation door). NEVER touches the socket — its
     *                     job is to keep the encoder's output queue empty so
     *                     back-pressure can never reach the render thread's
     *                     swap. Encoded frames land in a 1-deep latest-wins
     *                     mailbox; an overwrite is a drop, counted, and flags
     *                     needSync — the receiver's decoder just lost a
     *                     reference frame, so the stream must heal on an IDR,
     *                     exactly the fresh-connection rule applied mid-flow.
     *   PVJLink-Tx        socket lifecycle, verbatim from Sender: connect
     *                     out, SEND_BUF_BYTES cap, redial every 2 s, csd at
     *                     connection head, csd glued to every IDR, write-
     *                     stall watchdog cutting a wedged write from outside.
     *                     A stalled tx costs mailbox drops, never queue depth.
     *
     * WHY THE DRAIN/TX SPLIT EXISTS: with a Surface input there is no
     * push_frame mailbox in front of the encoder — if output buffers sat
     * unreleased while a write blocked, the BufferQueue would fill and
     * eglSwapBuffers would block GODOT'S RENDER THREAD inside ~100 ms (4-8
     * output buffers at 60 fps). Sender could put the write on the encode
     * thread because its drop point was upstream; here the drop point IS the
     * encoded-frame mailbox, so the write must live behind it.
     */
    private inner class GpuSender(
        initialCodec: MediaCodec,
        initialSurface: Surface,
        private val host: String,
        private val port: Int,
        private val frameW: Int,
        private val frameH: Int,
        private val fps: Float,
        private val bitrateBps: Int,
        transport: String,
    ) {
        @Volatile private var running = true

        // Wire selection is fixed for this sender's whole life (whole-object
        // swap: a transport change is a stop_send + fresh start).
        private val useSrt = transport == "srt"

        // -- Surface handoff (any thread publishes, GL thread reconciles) --
        private val surfaceLock = Any()
        private var pendingSurface: Surface? = initialSurface
        private var generation = 1
        @Volatile private var lastError = ""

        // -- GL-thread state --
        private var boundGeneration = -1
        private var target: GlBlitter.Target? = null
        private var failedGeneration = -1
        private var startNs = 0L           // PTS origin, set when the target binds
        private var nextDueNs = 0L         // fps accumulator (NetSender's rule)
        private val intervalNs = (1e9 / fps.toDouble()).toLong()
        private var statFrames = 0
        private var statSwapNs = 0L
        private var statSwapMaxNs = 0L
        private var statMarkNs = 0L

        // -- PTS → blit-time map, GL thread writes, drain thread removes.
        // encode_ms = queue(blit) → output, the same meaning the CPU feed
        // reports, so the TX row's en<Y> stays comparable across feeds.
        private val ptsInFlight = ConcurrentHashMap<Long, Long>()

        // -- encoded-frame mailbox (drain fills, tx empties, latest wins) --
        private val mailboxLock = Object()
        private var mailbox: Au? = null            // guarded by mailboxLock

        // -- drain-thread state --
        private var codec: MediaCodec? = initialCodec
        private var lastBuildMs = 0L
        private var encoderDeaths = 0L
        @Volatile private var syncRequested = true  // first frames must start clean
        private val outInfo = MediaCodec.BufferInfo()

        // -- tx-thread state (socket discipline verbatim from Sender) --
        private val socketLock = Any()
        private var socket: Socket? = null          // shutdown aborts through it
        private var out: DataOutputStream? = null
        // SRT twin of the pair above (useSrt only): srtSock under socketLock
        // for the same abort-from-any-thread lever, srtUp is the tx thread's
        // own "connected" flag (out's role). The muxer is tx-thread-only.
        private var srtSock: SrtSocket? = null
        private var srtUp = false
        private val muxer = if (useSrt) TsMuxer() else null
        // Reusable send slice: srtdroid's JNI Get/ReleaseByteArrayElements
        // touch the WHOLE array per send() call, so sending 1316-byte windows
        // of a 150 KB IDR run straight from the mux buffer is O(n²) memcpy
        // (~34 MB per keyframe). Tx-thread-only, like the muxer.
        private val srtChunk = ByteArray(if (useSrt) SRT_CHUNK_BYTES else 0)
        @Volatile private var csd: ByteArray? = null  // drain writes, tx reads
        @Volatile private var awaitingKey = true      // tx owns; drain's drops route via syncRequested
        private var lastConnectMs = 0L
        private var connectFails = 0L
        private var peerLosses = 0L
        @Volatile private var writeStartMs = 0L
        private var writeStalls = 0L

        private val drainThread = Thread(::drainLoop, "PVJLink-Drain")
        private val txThread = Thread(::txLoop, "PVJLink-Tx")

        fun start() {
            drainThread.start()
            txThread.start()
        }

        /** Any thread — get_send_stats' ~1 Hz poll plus every drawFrame, so a
         *  wedged write is noticed at frame cadence. Sender.checkWriteStall
         *  verbatim: cutting the socket out from under a blocked write is the
         *  one lever a Java socket offers. The SRT twin gets the same cut,
         *  belt-and-braces under its bounded SNDTIMEO. */
        fun checkWriteStall() {
            val t = writeStartMs
            if (t == 0L || SystemClock.elapsedRealtime() - t < WRITE_STALL_TIMEOUT_MS) return
            synchronized(socketLock) {
                // Re-check under the lock: between the unlocked read above and
                // here, the tx thread may have finished the old write and
                // redialed — cutting then would kill the healthy NEW socket.
                val t2 = writeStartMs
                if (t2 == 0L || SystemClock.elapsedRealtime() - t2 < WRITE_STALL_TIMEOUT_MS) return
                val cut: Closeable = if (useSrt) (srtSock ?: return)
                                     else (socket ?: return).takeIf { !it.isClosed } ?: return
                writeStalls++
                if (writeStalls == 1L || writeStalls % 20L == 0L) {
                    Log.w(TAG, "send write stalled ${WRITE_STALL_TIMEOUT_MS} ms+ " +
                            "($writeStalls so far) — cutting the socket to unwedge the tx thread")
                }
                closeQuietly(cut)
            }
        }

        /** GL context died. EGL objects are already invalid (GlBlitter's own
         *  context-recreated hook destroys them in bulk); just forget ours so
         *  the next drawFrame re-acquires on the fresh shared context. The
         *  encoder and its input Surface survive — a BufferQueue is not a GL
         *  object. */
        fun onContextLost() {
            target = null
            boundGeneration = -1
            failedGeneration = -1
        }

        /** GL render thread (stop_send). Stated order, Sender's contract
         *  adapted: (1) running down + mailbox woken, (2) socket closed to
         *  abort a blocking connect/write, (3) both threads joined — drain's
         *  finally releases the codec it owns, (4) EGL target released HERE,
         *  the thread EGL objects belong to. */
        fun shutdown() {
            running = false
            synchronized(mailboxLock) {
                mailbox = null
                mailboxLock.notify()
            }
            synchronized(socketLock) {
                socket?.let { closeQuietly(it) }
                srtSock?.let { closeQuietly(it) }
            }
            try {
                txThread.join(4000)
                drainThread.join(4000)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            if (txThread.isAlive || drainThread.isAlive) {
                Log.w(TAG, "send threads did not exit — abandoning encoder teardown")
            }
            GlBlitter.release(target)
            target = null
            synchronized(surfaceLock) { pendingSurface = null; generation++ }
        }

        // --- GL render thread ---------------------------------------------

        fun drawFrame() {
            checkWriteStall()   // frame cadence doubles as the stall clock

            val gen: Int
            val surf: Surface?
            synchronized(surfaceLock) { gen = generation; surf = pendingSurface }

            if (gen != boundGeneration) {
                GlBlitter.release(target)
                target = null
                boundGeneration = gen
                if (surf != null && surf.isValid && gen != failedGeneration) {
                    target = GlBlitter.acquireTarget(surf, "linktx")
                    if (target == null) {
                        failedGeneration = gen
                        lastError = "egl-init-failed"
                        Log.e(TAG, "GPU feed: cannot wrap encoder surface (gen $gen)")
                    } else {
                        val now = System.nanoTime()
                        startNs = now
                        nextDueNs = 0L
                        statFrames = 0; statSwapNs = 0; statSwapMaxNs = 0
                        statMarkNs = now
                    }
                }
            }

            val t = target ?: return
            if (!t.alive) {
                // The codec died and took its Surface — the drain thread's
                // rebuild republishes; reconcile picks it up next frame.
                GlBlitter.release(t)
                target = null
                return
            }
            val texId = sendTexId
            if (texId == 0) return   // no source published yet — encoder starves, fps reads 0

            // NetSender's capture accumulator, nanosecond edition: one blit
            // per elapsed interval, catch-up capped at one — after a stall,
            // a burst of blits would just be N encodes of the same pixels.
            val now = System.nanoTime()
            if (nextDueNs == 0L) nextDueNs = now
            if (now < nextDueNs) return
            nextDueNs += intervalNs
            if (now > nextDueNs) nextDueNs = now

            val ptsNs = now - startNs
            val swapNs = GlBlitter.blit(t, texId, sendFlipY, ptsNs)
            if (swapNs < 0) return
            ptsInFlight[ptsNs / 1000] = now
            // Entries whose output never comes back would leak — cap, don't
            // leak (Sender's rule, concurrent edition).
            if (ptsInFlight.size > IN_FLIGHT_CAP) ptsInFlight.clear()

            statFrames++
            statSwapNs += swapNs
            if (swapNs > statSwapMaxNs) statSwapMaxNs = swapNs
            if (now - statMarkNs >= 5_000_000_000L) {
                val secs = (now - statMarkNs) / 1e9
                // Swap time is the back-pressure meter (GlBlitter's contract):
                // if the drain thread ever falls behind, it shows HERE first.
                Log.i(TAG, "GPU feed: blit %.1f fps · swap avg %.2f ms (max %.2f) · tex=%d".format(
                        statFrames / secs, statSwapNs / 1e6 / statFrames,
                        statSwapMaxNs / 1e6, texId))
                statFrames = 0; statSwapNs = 0; statSwapMaxNs = 0
                statMarkNs = now
            }
        }

        // --- PVJLink-Drain thread -----------------------------------------

        private fun drainLoop() {
            try {
                while (running) {
                    val c = codec
                    if (c == null) {
                        if (!rebuildEncoder()) Thread.sleep(RETRY_POLL_MS)
                        continue
                    }
                    if (syncRequested) {
                        syncRequested = false
                        try {
                            c.setParameters(Bundle().apply {
                                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                            })
                        } catch (e: IllegalStateException) {
                            // Dying codec — the dequeue below notices properly.
                        }
                    }
                    val idx = try {
                        c.dequeueOutputBuffer(outInfo, DRAIN_POLL_US)
                    } catch (e: IllegalStateException) {
                        onCodecDied(c, e)
                        continue
                    }
                    when {
                        idx >= 0 -> handleOutput(c, idx)
                        idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> cacheCsd(c.outputFormat)
                        // TRY_AGAIN / BUFFERS_CHANGED: nothing owed, loop.
                    }
                }
            } finally {
                // The one thread of control releases what it controlled.
                codec?.let { releaseCodec(it) }
                codec = null
            }
        }

        private fun handleOutput(c: MediaCodec, idx: Int) {
            val size = outInfo.size
            val flags = outInfo.flags
            val ptsUs = outInfo.presentationTimeUs
            var au: Au? = null
            if (size > 0) {
                val buf = c.getOutputBuffer(idx)
                if (buf != null) {
                    if (flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        // SPS+PPS exactly as emitted, Annex-B — Sender's rule:
                        // cached, never counted as a frame.
                        val a = ByteArray(size)
                        buf.position(outInfo.offset)
                        buf.get(a)
                        csd = a
                    } else {
                        // Copied out because the buffer goes back to the codec
                        // NOW — holding it hostage to the socket is exactly
                        // the back-pressure chain this thread exists to break.
                        // ~8 KB average at 4 Mbps/60 fps; GC noise, not churn.
                        val a = ByteArray(size)
                        buf.position(outInfo.offset)
                        buf.get(a)
                        au = Au(a, flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0, ptsUs)
                    }
                }
            }
            try {
                c.releaseOutputBuffer(idx, false)
            } catch (e: IllegalStateException) {
                onCodecDied(c, e)
                return
            }
            val a = au ?: return
            synchronized(mailboxLock) {
                if (mailbox != null) {
                    // Tx is behind (redial window, slow peer): latest wins,
                    // and the receiver just lost a frame later P-frames
                    // reference. Unless the REPLACEMENT is itself an IDR the
                    // stream is broken until one arrives — heal on request,
                    // not on the GOP clock.
                    sendStats.drop()
                    if (!a.isKey) syncRequested = true
                }
                mailbox = a
                mailboxLock.notify()
            }
        }

        /** csd from INFO_OUTPUT_FORMAT_CHANGED — Sender.cacheCsd verbatim. */
        private fun cacheCsd(format: MediaFormat) {
            val c0 = format.getByteBuffer("csd-0") ?: return
            val d0 = c0.duplicate()
            val d1 = format.getByteBuffer("csd-1")?.duplicate()
            val n0 = d0.remaining()
            val n1 = d1?.remaining() ?: 0
            val bytes = ByteArray(n0 + n1)
            d0.get(bytes, 0, n0)
            d1?.get(bytes, n0, n1)
            csd = bytes
        }

        private fun onCodecDied(c: MediaCodec, e: Exception) {
            encoderDeaths++
            if (encoderDeaths == 1L || encoderDeaths % 20L == 0L) {
                Log.e(TAG, "GPU-feed encoder died: ${e.message} ($encoderDeaths so far) — rebuilding")
            }
            releaseCodec(c)
            codec = null
            csd = null
            ptsInFlight.clear()
            lastBuildMs = SystemClock.elapsedRealtime()   // full window before the rebuild
        }

        /** One rebuild attempt per CODEC_RETRY_MS window. A fresh encoder is
         *  a fresh input Surface: published through the generation door, the
         *  GL thread re-targets next frame, and the far end holds out for the
         *  fresh csd's IDR — the whole surface-feed pipeline heals in place. */
        private fun rebuildEncoder(): Boolean {
            val now = SystemClock.elapsedRealtime()
            if (now - lastBuildMs < CODEC_RETRY_MS) return false
            lastBuildMs = now
            val built = buildEncoder(frameW, frameH, fps, bitrateBps,
                    surfaceInput = true) ?: return false
            codec = built.codec
            syncRequested = true
            synchronized(surfaceLock) {
                pendingSurface = built.inputSurface
                generation++
            }
            return true
        }

        private fun releaseCodec(c: MediaCodec) {
            try {
                c.stop()
            } catch (e: IllegalStateException) {
                // Already dead — release still reclaims it.
            }
            try {
                c.release()
            } catch (e: RuntimeException) {
                Log.w(TAG, "GPU-feed encoder release failed: ${e.message}")
            }
        }

        // --- PVJLink-Tx thread --------------------------------------------

        private fun txLoop() {
            try {
                while (running) {
                    if (!ensureConnected()) {
                        // Between redials: undeliverable frames die in the
                        // mailbox as drain-side overwrites — take and count
                        // the one that's waiting so the drop is visible NOW.
                        takeAu(RETRY_POLL_MS)?.let { sendStats.drop() }
                        continue
                    }
                    val a = takeAu(TX_IDLE_WAIT_MS) ?: continue
                    if (awaitingKey && !a.isKey) {
                        // Fresh connection = fresh decoder on the far end
                        // (§6.6); P-frames before its first IDR reference
                        // pictures it never saw.
                        sendStats.drop()
                        continue
                    }
                    write(a)
                }
            } finally {
                disconnect()
            }
        }

        private fun takeAu(waitMs: Long): Au? {
            synchronized(mailboxLock) {
                if (mailbox == null && running) {
                    try {
                        mailboxLock.wait(waitMs)
                    } catch (e: InterruptedException) {
                        Thread.currentThread().interrupt()
                    }
                }
                val a = mailbox
                mailbox = null
                return a
            }
        }

        /** Sender.ensureConnected verbatim (NoDelay, SEND_BUF_BYTES before
         *  connect, csd head, sync-frame ask routed to the drain thread). */
        private fun ensureConnected(): Boolean {
            if (useSrt) return srtEnsureConnected()
            if (out != null) return true
            val now = SystemClock.elapsedRealtime()
            if (now - lastConnectMs < CONNECT_RETRY_MS) return false
            lastConnectMs = now
            val s = Socket()
            synchronized(socketLock) {
                if (!running) {
                    closeQuietly(s)
                    return false
                }
                socket = s
            }
            try {
                s.tcpNoDelay = true
                s.sendBufferSize = SEND_BUF_BYTES
                s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
                val o = DataOutputStream(BufferedOutputStream(s.getOutputStream(), 64 * 1024))
                csd?.let {
                    writeStartMs = SystemClock.elapsedRealtime()
                    try {
                        o.writeInt(it.size)
                        o.write(it, 0, it.size)
                        o.flush()
                    } finally {
                        writeStartMs = 0L
                    }
                    sendStats.addBytes(it.size + 4)
                }
                out = o
                awaitingKey = true
                syncRequested = true   // the drain thread's codec, the drain thread's ask
                connectFails = 0
                Log.i(TAG, "connected to $host:$port — streaming (GPU feed)")
                return true
            } catch (e: IOException) {
                connectFails++
                if (connectFails == 1L || connectFails % 15L == 0L) {
                    Log.w(TAG, "connect to $host:$port failed: ${e.message} " +
                            "($connectFails so far) — retrying every ${CONNECT_RETRY_MS / 1000} s")
                }
                synchronized(socketLock) {
                    closeQuietly(s)
                    if (socket === s) socket = null
                }
                return false
            }
        }

        private fun write(a: Au) {
            if (useSrt) {
                srtWrite(a)
                return
            }
            val o = out ?: return
            // csd glued ahead of every IDR (Sender's manual glue — the
            // works-everywhere version of KEY_PREPEND_HEADER).
            val head = if (a.isKey) csd else null
            val len = a.bytes.size + (head?.size ?: 0)
            if (len > MAX_PAYLOAD_BYTES) {
                sendStats.drop()
                return
            }
            try {
                writeStartMs = SystemClock.elapsedRealtime()
                try {
                    o.writeInt(len)
                    if (head != null) o.write(head, 0, head.size)
                    o.write(a.bytes, 0, a.bytes.size)
                    o.flush()
                } finally {
                    writeStartMs = 0L
                }
                awaitingKey = false
                sendStats.addBytes(len + 4)
                val t0 = ptsInFlight.remove(a.ptsUs)
                sendStats.frameOut(if (t0 != null) (System.nanoTime() - t0) / 1e6 else -1.0)
            } catch (e: IOException) {
                sendStats.drop()
                onPeerLost(e)
            }
        }

        /** ensureConnected, SRT edition (the TD leg): same retry gate, same
         *  socketLock publish-then-configure shape, an srtdroid caller in
         *  place of the TCP connect. No csd head-of-stream write — the TS
         *  mux re-announces SPS/PPS ahead of every IDR instead, so a decoder
         *  configures from the first keyframe whenever it joins. */
        private fun srtEnsureConnected(): Boolean {
            if (srtUp) return true
            val now = SystemClock.elapsedRealtime()
            // Exponential backoff, SRT only (TCP keeps its flat 2 s): srtdroid
            // 1.9.5 leaks ~2 JNI global refs per dial (glue.cpp allocates a
            // CallbackContext per connect and only the never-fired connect
            // callback frees it), so a flat 2 s redial against a down receiver
            // overflows ART's global-ref table in ~14-28 h — an overnight-
            // installation abort. Capped backoff makes the leak rate harmless;
            // connectFails resets on success so recovery re-dials fast.
            val backoff = minOf(
                CONNECT_RETRY_MS shl minOf(connectFails, 5L).toInt(),
                SRT_RETRY_CAP_MS)
            if (now - lastConnectMs < backoff) return false
            lastConnectMs = now
            val s: SrtSocket
            try {
                if (srtStarted.compareAndSet(false, true)) Srt.startUp()
                s = SrtSocket()
            } catch (e: Throwable) {
                // Throwable on purpose: UnsatisfiedLinkError from an APK
                // without the srtdroid native lib lands here, and that answer
                // cannot change until a build does.
                connectFails++
                if (connectFails == 1L || connectFails % 15L == 0L) {
                    Log.e(TAG, "SRT unavailable: $e ($connectFails so far)")
                }
                return false
            }
            synchronized(socketLock) {
                if (!running) {
                    closeQuietly(s)
                    return false
                }
                srtSock = s
            }
            try {
                s.setSockFlag(SockOpt.TRANSTYPE, Transtype.LIVE)
                s.setSockFlag(SockOpt.PAYLOADSIZE, SRT_CHUNK_BYTES)
                s.setSockFlag(SockOpt.LATENCY, srtLatencyMs)
                s.setSockFlag(SockOpt.CONNTIMEO, CONNECT_TIMEOUT_MS)
                // Bounded blocking send: the mailbox already implements the
                // drop policy, so a wedged peer costs at most this long per
                // attempt before the IOException routes to onPeerLost.
                s.setSockFlag(SockOpt.SNDTIMEO, SRT_SND_TIMEOUT_MS)
                s.connect(host, port)
                muxer?.reset()
                srtUp = true
                awaitingKey = true
                syncRequested = true   // the drain thread's codec, the drain thread's ask
                connectFails = 0
                Log.i(TAG, "connected to SRT $host:$port — streaming (GPU feed, MPEG-TS)")
                return true
            } catch (e: Exception) {
                // Exception, not IOException — same tx-thread-survival rule
                // as srtWrite's catch.
                connectFails++
                if (connectFails == 1L || connectFails % 15L == 0L) {
                    Log.w(TAG, "SRT connect to $host:$port failed: ${e.message} " +
                            "($connectFails so far) — backing off up to ${SRT_RETRY_CAP_MS / 1000} s")
                }
                synchronized(socketLock) {
                    closeQuietly(s)
                    if (srtSock === s) srtSock = null
                }
                return false
            }
        }

        /** write(), SRT edition: csd glued ahead of IDRs exactly like the raw
         *  wire, then TS-muxed and sent in SRT_CHUNK_BYTES slices (7×188 —
         *  live mode's whole-payload datagrams). */
        private fun srtWrite(a: Au) {
            val s = synchronized(socketLock) { srtSock } ?: return
            val m = muxer ?: return
            val head = if (a.isKey) csd else null
            val payload = if (head != null) {
                val p = ByteArray(head.size + a.bytes.size)
                head.copyInto(p)
                a.bytes.copyInto(p, head.size)
                p
            } else {
                a.bytes
            }
            if (payload.size > MAX_PAYLOAD_BYTES) {
                sendStats.drop()
                return
            }
            val ts = m.packetize(payload, a.ptsUs, a.isKey)
            try {
                writeStartMs = SystemClock.elapsedRealtime()
                try {
                    var off = 0
                    while (off < ts.size) {
                        val n = minOf(SRT_CHUNK_BYTES, ts.size - off)
                        ts.copyInto(srtChunk, 0, off, off + n)
                        s.send(srtChunk, 0, n)
                        off += n
                    }
                } finally {
                    writeStartMs = 0L
                }
                awaitingKey = false
                sendStats.addBytes(ts.size)
                val t0 = ptsInFlight.remove(a.ptsUs)
                sendStats.frameOut(if (t0 != null) (System.nanoTime() - t0) / 1e6 else -1.0)
            } catch (e: Exception) {
                // Exception, not IOException: the srtdroid binding's throw
                // surface is not IOException-only, and anything escaping here
                // would kill PVJLink-Tx silently with running still true.
                sendStats.drop()
                onPeerLost(e as? IOException ?: IOException(e))
            }
        }

        private fun onPeerLost(e: IOException) {
            peerLosses++
            if (peerLosses == 1L || peerLosses % 20L == 0L) {
                Log.w(TAG, "receiver dropped: ${e.message} ($peerLosses so far) " +
                        "— redialing every ${CONNECT_RETRY_MS / 1000} s")
            }
            disconnect()
            lastConnectMs = SystemClock.elapsedRealtime()
        }

        private fun disconnect() {
            synchronized(socketLock) {
                socket?.let { closeQuietly(it) }
                socket = null
                srtSock?.let { closeQuietly(it) }
                srtSock = null
            }
            out = null
            srtUp = false
            awaitingKey = true
        }

        private fun closeQuietly(c: Closeable) {
            try {
                c.close()
            } catch (e: IOException) {
                // Teardown path — nothing useful to do with it.
            }
        }
    }

    // --- Stats (NetSource's fields and its honest-decay window) -----------

    private class Stats {
        private val lock = Any()
        private var framesOk = 0
        private var framesDropped = 0
        private var decodeMs = 0.0
        private var fps = 0.0
        private var kbps = 0.0
        private var winStart = 0L
        private var winFrames = 0
        private var winBytes = 0L
        private var lastFrameMs = -1L   // elapsedRealtime of last decoded frame

        fun reset() = synchronized(lock) {
            framesOk = 0
            framesDropped = 0
            decodeMs = 0.0
            fps = 0.0
            kbps = 0.0
            winStart = SystemClock.elapsedRealtime()
            winFrames = 0
            winBytes = 0
            lastFrameMs = -1L
        }

        fun addBytes(n: Int) = synchronized(lock) {
            winBytes += n
            roll()
        }

        /** decMs < 0 = decode time unknown for this frame (pts bookkeeping
         *  missed it) — keep the last honest number rather than lie with 0. */
        fun frameOut(decMs: Double) = synchronized(lock) {
            framesOk++
            winFrames++
            if (decMs >= 0) decodeMs = decMs
            lastFrameMs = SystemClock.elapsedRealtime()
            roll()
        }

        fun drop() = synchronized(lock) { framesDropped++ }

        /** The roll also runs here, on the caller's ~1 Hz poll — that is what
         *  walks fps/kbps down to zero when the stream stops, which is what
         *  makes them honest (NetSource's window policy, verbatim). */
        fun snapshot(): Dictionary {
            val d = Dictionary()
            synchronized(lock) {
                roll()
                d["fps"] = fps
                d["decode_ms"] = decodeMs
                d["kbps"] = kbps
                d["frames_ok"] = framesOk
                d["frames_dropped"] = framesDropped
                d["last_frame_msec"] = if (lastFrameMs < 0) -1
                    else (SystemClock.elapsedRealtime() - lastFrameMs).toInt()
            }
            return d
        }

        // Callers hold `lock`.
        private fun roll() {
            val now = SystemClock.elapsedRealtime()
            val elapsed = now - winStart
            if (elapsed < 1000) return
            fps = winFrames * 1000.0 / elapsed
            kbps = winBytes * 8.0 / elapsed
            winStart = now
            winFrames = 0
            winBytes = 0
        }
    }

    // --- Send stats (same window policy, the sender's fields) -------------

    private class SendStats {
        private val lock = Any()
        private var framesSent = 0
        private var framesDropped = 0
        private var convertMs = 0.0
        private var encodeMs = 0.0
        private var fps = 0.0
        private var kbps = 0.0
        private var winStart = 0L
        private var winFrames = 0
        private var winBytes = 0L

        fun reset() = synchronized(lock) {
            framesSent = 0
            framesDropped = 0
            convertMs = 0.0
            encodeMs = 0.0
            fps = 0.0
            kbps = 0.0
            winStart = SystemClock.elapsedRealtime()
            winFrames = 0
            winBytes = 0
        }

        fun drop() = synchronized(lock) { framesDropped++ }

        fun convert(ms: Double) = synchronized(lock) { convertMs = ms }

        fun addBytes(n: Int) = synchronized(lock) {
            winBytes += n
            roll()
        }

        /** encMs < 0 = encode time unknown for this frame (pts bookkeeping
         *  missed it) — keep the last honest number rather than lie with 0. */
        fun frameOut(encMs: Double) = synchronized(lock) {
            framesSent++
            winFrames++
            if (encMs >= 0) encodeMs = encMs
            roll()
        }

        /** The roll also runs on the ~1 Hz poll — fps/kbps walk to zero when
         *  the stream stops (Stats' window policy, verbatim). */
        fun snapshot(): Dictionary {
            val d = Dictionary()
            synchronized(lock) {
                roll()
                d["fps"] = fps
                d["convert_ms"] = convertMs
                d["encode_ms"] = encodeMs
                d["kbps"] = kbps
                d["frames_sent"] = framesSent
                d["frames_dropped"] = framesDropped
            }
            return d
        }

        // Callers hold `lock`.
        private fun roll() {
            val now = SystemClock.elapsedRealtime()
            val elapsed = now - winStart
            if (elapsed < 1000) return
            fps = winFrames * 1000.0 / elapsed
            kbps = winBytes * 8.0 / elapsed
            winStart = now
            winFrames = 0
            winBytes = 0
        }
    }

    private companion object {
        const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC

        /** Framing guard: a whole 720p intra frame is tens of KB — anything
         *  past 2 MiB is a lost framing sync or a hostile header (NetSource's
         *  1 MB cap, H.264 edition). */
        const val MAX_PAYLOAD_BYTES = 2 shl 20

        /** A 24 fps stream delivers every ~42 ms; 4 s of silence on an open
         *  socket is a sender that died without FIN. */
        const val CLIENT_IDLE_TIMEOUT_MS = 4000

        /** Most NAL units one payload may scan to (spec §6.6) — see
         *  scanStartCodes for why more is lost framing, not a big frame. */
        const val MAX_NALS_PER_PAYLOAD = 64

        /** How long submit() waits for a free input buffer before dropping —
         *  a bit over two frame periods at 24 fps. */
        const val INPUT_WAIT_MS = 100L

        /** One decoder (re)build attempt per window after a failure. */
        const val CODEC_RETRY_MS = 2000L

        const val INPUT_QUEUE_DEPTH = 64
        const val IN_FLIGHT_CAP = 128

        // --- Send path ----------------------------------------------------

        /** Redial cadence for a refused or dropped connection while started. */
        const val CONNECT_RETRY_MS = 2000L
        const val CONNECT_TIMEOUT_MS = 2000

        // SRT wire (the TD leg, Stage 1 item 2).
        /** 7×188 TS packets per SRT datagram — live mode's recommended
         *  whole-payload size (and what ffmpeg/TD expect). */
        const val SRT_CHUNK_BYTES = 7 * 188
        /** SRT receiver-latency ask; the far end may negotiate it up. §8
         *  gives the phone→TD leg 150 ms total, so the ARQ window got 120 —
         *  which §9-M8 then measured as the TD legs' DOMINANT latency term
         *  (RTT ~706 ms; SRT pins each leg to max(both ends), so this value
         *  rules regardless of TD-side settings). Now the default only:
         *  srtLatencyMs below is the live knob. */
        const val SRT_LATENCY_MS = 120
        /** The live window, set from GDScript ([link] srt_latency_ms) via
         *  set_srt_latency. Read at dial time — a running socket keeps the
         *  window it negotiated. @Volatile: written from the GL thread
         *  (GDScript), read from the net threads. */
        @Volatile var srtLatencyMs: Int = SRT_LATENCY_MS
        /** Bounded blocking send — the mailbox owns the drop policy, this
         *  just keeps one attempt from outliving the stall watchdog. */
        const val SRT_SND_TIMEOUT_MS = 1000
        /** Redial backoff ceiling (srtdroid's per-dial JNI leak, see
         *  srtEnsureConnected). */
        const val SRT_RETRY_CAP_MS = 60_000L
        /** Receive-side recv unit: one SRT live datagram (7×188 + headroom). */
        const val SRT_RECV_BYTES = 1500
        /** Doorbell → dial settle: TD's srt_arm re-arm is two TD FRAMES, so
         *  the margin is frame-rate-bound — 300 ms still covers a TD grinding
         *  at 10 fps, and the cost is per-dial, not per-frame. */
        const val SRT_ARM_SETTLE_MS = 300L

        /** SO_SNDBUF cap — the mailbox's enforcement arm. Android's tcp_wmem
         *  auto-tunes the send buffer to megabytes, and write() — the only
         *  backpressure PVJLink-Enc feels — would not block until SECONDS of
         *  CBR video sat queued beyond the drop policy's reach, every stat
         *  healthy (addBytes counts kernel-accepted, not delivered). The
         *  kernel doubles the requested value, so 64 KiB is ~128 KiB
         *  effective: ~260 ms at 4 Mbps, an IDR still fits whole, and a slow
         *  path degrades as visible frame drops, never as smuggled latency. */
        const val SEND_BUF_BYTES = 64 * 1024

        /** A blocking send write older than this is a peer that is gone in
         *  every way but TCP's: its kernel ACKs (so no IOException, ever)
         *  while its frozen app never reads (Android's cached-app freezer —
         *  a backgrounded receiver with the screen locked). The receive
         *  path's CLIENT_IDLE_TIMEOUT_MS, send edition. */
        const val WRITE_STALL_TIMEOUT_MS = 4000L

        /** Short GOP: fast join/recovery without intra-refresh (which is
         *  feature-gated and undocumented on this hardware); an on-demand
         *  sync frame per (re)connect covers the rest. */
        const val ENC_GOP_SECONDS = 1

        /** How long feed() waits for a free encoder input before dropping —
         *  the receive path's patience, encoder edition. */
        const val ENC_INPUT_WAIT_US = 100_000L

        /** First drain dequeue when output is owed: about one hardware
         *  encode (~5-6 ms at 720p on this silicon), never a frame period. */
        const val ENC_DRAIN_WAIT_US = 10_000L

        /** Mailbox waits: idle vs output-owed hover, and the between-redials
         *  poll that keeps swallowing (counting) undeliverable frames. */
        const val ENC_IDLE_WAIT_MS = 100L
        const val ENC_PIPE_WAIT_MS = 5L
        const val RETRY_POLL_MS = 100L

        /** GPU feed (milestone 2.5(b)): the drain thread's dequeue timeout.
         *  Short enough that a stop or a sync-frame request is honored within
         *  ~a frame period at 60 fps; long enough that an idle encoder costs
         *  ~60 wakeups/s of nothing, not a spin. */
        const val DRAIN_POLL_US = 15_000L

        /** GPU feed: how long the tx thread parks on an empty mailbox. Purely
         *  a wakeup bound — mailboxLock.notify() ends the wait the moment an
         *  encoded frame lands. */
        const val TX_IDLE_WAIT_MS = 100L

        // H.264 nal_unit_type values (Annex-B byte & 0x1F).
        const val NAL_NON_IDR = 1
        const val NAL_IDR = 5
        const val NAL_SPS = 7
        const val NAL_PPS = 8

        val START_CODE = byteArrayOf(0, 0, 0, 1)
        const val ZERO: Byte = 0
        const val ONE: Byte = 1
    }
}
