package com.pocketvj

import java.io.ByteArrayOutputStream

/**
 * Minimal MPEG-TS demuxer for the video link's TouchDesigner leg — the
 * receive-side mirror of TsMuxer, but built for SOMEONE ELSE'S mux:
 * TouchDesigner's Video Stream Out chooses its own PIDs, so PAT → PMT →
 * first H.264 elementary PID is discovered from the stream, never assumed.
 *
 * Scope is deliberately narrow: one program, the first stream_type 0x1B
 * entry, PES payloads reassembled on PUSI boundaries and handed to the
 * caller as Annex-B access-unit payloads — exactly the byte shape the
 * Receiver's handlePayload already speaks (it scans start codes and
 * harvests SPS/PPS itself, so TS PTS is deliberately ignored, same as the
 * raw-NAL wire). Audio PIDs, PCR, and continuity counters are skipped —
 * a lost packet shows up as a corrupt slice the decoder conceals, the
 * same cost the raw wire pays.
 *
 * THREADING: not thread-safe; owned by the one net thread, like the
 * socket it drains (the plugin's one-thread-of-control rule).
 */
class TsDemuxer {

    companion object {
        const val TS_PACKET = 188
        const val SYNC: Byte = 0x47
        /** PES reassembly cap — a runaway PES without PUSI boundaries must
         *  not eat the heap. Matches the wire's payload cap. */
        const val MAX_PES_BYTES = 2 shl 20
    }

    // Discovered layout (reset() forgets it — a fresh dial is a fresh mux).
    private var pmtPid = -1
    private var videoPid = -1
    // ISO 13818-1 permits one exact duplicate per packet (same continuity
    // counter); appending it twice corrupts the AU mid-payload (executed
    // proof in the review). Video PID only — PSI re-sends are idempotent.
    private var lastVideoCc = -1

    // Byte-stream alignment: SRT usually delivers whole 7×188 datagrams,
    // but nothing in the contract says so — carry partial packets across
    // feed() calls and resync on a bad sync byte.
    private val carry = ByteArray(TS_PACKET)
    private var carryLen = 0

    // PES reassembly (video PID only): buffer between PUSI boundaries.
    private val pes = ByteArrayOutputStream(256 * 1024)
    private var pesOpen = false

    fun reset() {
        pmtPid = -1
        videoPid = -1
        lastVideoCc = -1
        carryLen = 0
        pes.reset()
        pesOpen = false
    }

    /**
     * Feed raw received bytes; `onAu` fires once per completed PES payload
     * (one access unit on every mux that sets data_alignment, TD included).
     */
    fun feed(data: ByteArray, len: Int, onAu: (ByteArray) -> Unit) {
        var off = 0
        // Finish a carried partial packet first.
        if (carryLen > 0) {
            val need = TS_PACKET - carryLen
            val take = minOf(need, len)
            System.arraycopy(data, 0, carry, carryLen, take)
            carryLen += take
            off = take
            if (carryLen < TS_PACKET) return
            carryLen = 0
            packet(carry, 0, onAu)
        }
        while (off + TS_PACKET <= len) {
            if (data[off] != SYNC) {
                // Resync: slide to the next sync byte. Costs at most one
                // packet of data; a mid-stream join lands here once.
                off++
                continue
            }
            packet(data, off, onAu)
            off += TS_PACKET
        }
        if (off < len) {
            carryLen = len - off
            System.arraycopy(data, off, carry, 0, carryLen)
        }
    }

    private fun packet(p: ByteArray, o: Int, onAu: (ByteArray) -> Unit) {
        if (p[o] != SYNC) return
        val pid = ((p[o + 1].toInt() and 0x1F) shl 8) or (p[o + 2].toInt() and 0xFF)
        val pusi = (p[o + 1].toInt() and 0x40) != 0
        val afc = (p[o + 3].toInt() ushr 4) and 0x3
        if (afc == 0 || afc == 2) return          // no payload
        var body = o + 4
        if (afc == 3) {                            // adaptation field first
            val afLen = p[o + 4].toInt() and 0xFF
            body = o + 5 + afLen
            if (body >= o + TS_PACKET) return      // stuffing-only packet
        }
        val end = o + TS_PACKET
        when {
            pid == 0x0000 -> parsePat(p, body, end, pusi)
            pid == pmtPid -> parsePmt(p, body, end, pusi)
            pid == videoPid -> {
                val cc = p[o + 3].toInt() and 0x0F
                if (cc == lastVideoCc) return      // ISO-legal duplicate: drop
                lastVideoCc = cc
                video(p, body, end, pusi, onAu)
            }
        }
    }

    private fun parsePat(p: ByteArray, start: Int, end: Int, pusi: Boolean) {
        if (!pusi) return                          // whole PAT fits one packet
        var i = start + 1 + (p[start].toInt() and 0xFF)   // pointer_field
        if (i + 8 > end || p[i] != 0.toByte()) return
        val sectionLen = ((p[i + 1].toInt() and 0x0F) shl 8) or (p[i + 2].toInt() and 0xFF)
        var entry = i + 8                          // first program entry
        val stop = minOf(i + 3 + sectionLen - 4, end)     // minus CRC
        while (entry + 4 <= stop) {
            val program = ((p[entry].toInt() and 0xFF) shl 8) or (p[entry + 1].toInt() and 0xFF)
            val pid = ((p[entry + 2].toInt() and 0x1F) shl 8) or (p[entry + 3].toInt() and 0xFF)
            if (program != 0) {                    // 0 = network PID, skip
                pmtPid = pid
                return
            }
            entry += 4
        }
    }

    private fun parsePmt(p: ByteArray, start: Int, end: Int, pusi: Boolean) {
        if (!pusi) return                          // whole PMT fits one packet
        var i = start + 1 + (p[start].toInt() and 0xFF)   // pointer_field
        if (i + 12 > end || p[i] != 0x02.toByte()) return
        val sectionLen = ((p[i + 1].toInt() and 0x0F) shl 8) or (p[i + 2].toInt() and 0xFF)
        val stop = minOf(i + 3 + sectionLen - 4, end)     // minus CRC
        val progInfoLen = ((p[i + 10].toInt() and 0x0F) shl 8) or (p[i + 11].toInt() and 0xFF)
        var entry = i + 12 + progInfoLen
        while (entry + 5 <= stop) {
            val type = p[entry].toInt() and 0xFF
            val pid = ((p[entry + 1].toInt() and 0x1F) shl 8) or (p[entry + 2].toInt() and 0xFF)
            val esLen = ((p[entry + 3].toInt() and 0x0F) shl 8) or (p[entry + 4].toInt() and 0xFF)
            if (type == 0x1B) {                    // H.264
                if (videoPid != pid) {
                    videoPid = pid
                    pes.reset()
                    pesOpen = false
                }
                return
            }
            entry += 5 + esLen
        }
    }

    private fun video(p: ByteArray, start: Int, end: Int, pusi: Boolean, onAu: (ByteArray) -> Unit) {
        if (pusi) {
            flush(onAu)
            pesOpen = true
        }
        if (!pesOpen) return                       // mid-PES join: wait for a PUSI
        if (pes.size() + (end - start) > MAX_PES_BYTES) {
            // Runaway (PUSI lost?): drop and resync on the next PUSI.
            pes.reset()
            pesOpen = false
            return
        }
        pes.write(p, start, end - start)
    }

    /** Strip the PES header off the accumulated buffer and emit the ES bytes. */
    private fun flush(onAu: (ByteArray) -> Unit) {
        if (!pesOpen || pes.size() == 0) {
            pes.reset()
            return
        }
        val b = pes.toByteArray()
        pes.reset()
        // 00 00 01 <stream_id> <len:2> <flags:2> <header_len:1> <header...>
        if (b.size < 9 || b[0] != 0.toByte() || b[1] != 0.toByte() || b[2] != 1.toByte()) return
        val streamId = b[3].toInt() and 0xFF
        if (streamId < 0xE0 || streamId > 0xEF) return    // video stream ids only
        val headerLen = b[8].toInt() and 0xFF
        val payloadStart = 9 + headerLen
        if (payloadStart >= b.size) return
        onAu(b.copyOfRange(payloadStart, b.size))
    }
}
