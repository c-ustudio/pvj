package com.pocketvj

import java.io.ByteArrayOutputStream

/**
 * Minimal single-program MPEG-TS muxer for the video link's TouchDesigner leg
 * (docs/VIDEO_LINK_SPEC.md §5 Stage 1 item 2: MPEG-TS-over-SRT to/from TD).
 *
 * Exactly one H.264 elementary stream and nothing else: PAT + PMT repeated on
 * every keyframe (and at least every PSI_INTERVAL_US), one PES packet per
 * access unit with PTS only (the encoder produces no B-frames — §6.6 — so
 * DTS == PTS and is omitted), PCR on the video PID at every access-unit
 * start. Hand-rolled on purpose: the alternative is a whole container
 * library for what is ~200 lines of fixed framing, and this codebase's
 * packetizers (DDP, framing v1) are all hand-rolled and measured.
 *
 * THREADING: not thread-safe; owned by the one tx thread, like the socket it
 * feeds (VideoLinkPlugin's one-thread-of-control rule).
 *
 * The caller glues SPS/PPS ahead of every IDR before packetize() — the same
 * manual csd glue the raw-NAL wire does — so a decoder joining mid-stream
 * configures from the first keyframe it sees.
 */
class TsMuxer {

    companion object {
        const val TS_PACKET = 188
        const val PMT_PID = 0x1000
        const val VIDEO_PID = 0x0100
        const val PES_STREAM_ID_VIDEO = 0xE0
        /** PAT/PMT cadence floor — receivers lock fast even mid-GOP. */
        const val PSI_INTERVAL_US = 400_000L
        /** PCR leads PTS by this much (90 kHz ticks): decoders want the clock
         *  reference at or before the presentation stamps that ride with it. */
        const val PCR_BEHIND_PTS_90K = 9_000L      // 100 ms
        const val PTS_WRAP_MASK = (1L shl 33) - 1  // 33-bit MPEG timestamps

        /** H.264 access-unit delimiter, prepended per AU: ffmpeg-family
         *  demuxers (TD's ingest) resync AU boundaries on it. */
        private val AUD = byteArrayOf(0, 0, 0, 1, 0x09, 0xF0.toByte())

        /** CRC-32/MPEG-2: poly 0x04C11DB7, init all-ones, no reflection, no
         *  final xor — PSI sections carry it, and a wrong CRC is a silently
         *  discarded PAT/PMT (a black stream, not an error). */
        private fun crc32(data: ByteArray, off: Int, len: Int): Int {
            var crc = -1
            for (i in off until off + len) {
                crc = crc xor ((data[i].toInt() and 0xFF) shl 24)
                repeat(8) {
                    crc = if (crc and Int.MIN_VALUE != 0) {
                        (crc shl 1) xor 0x04C11DB7
                    } else {
                        crc shl 1
                    }
                }
            }
            return crc
        }

        /** table body -> full 188-byte PSI packet payload template
         *  (pointer_field + section + CRC), stuffed with 0xFF. */
        private fun psiSection(body: ByteArray): ByteArray {
            val crc = crc32(body, 0, body.size)
            val s = ByteArray(body.size + 4)
            body.copyInto(s)
            s[body.size] = (crc ushr 24).toByte()
            s[body.size + 1] = (crc ushr 16).toByte()
            s[body.size + 2] = (crc ushr 8).toByte()
            s[body.size + 3] = crc.toByte()
            return s
        }

        // PAT: program 1 -> PMT_PID. section_length counts everything after
        // its own field including the CRC.
        private val PAT_SECTION = psiSection(byteArrayOf(
            0x00,                                    // table_id: PAT
            0xB0.toByte(), 0x0D,                     // syntax=1, section_length=13
            0x00, 0x01,                              // transport_stream_id
            0xC1.toByte(),                           // version 0, current_next=1
            0x00, 0x00,                              // section 0 of 0
            0x00, 0x01,                              // program_number 1
            (0xE0 or (PMT_PID ushr 8)).toByte(),     // reserved(3) + PMT PID hi
            (PMT_PID and 0xFF).toByte(),
        ))

        // PMT: one stream, type 0x1B (H.264), PCR on the video PID.
        private val PMT_SECTION = psiSection(byteArrayOf(
            0x02,                                    // table_id: PMT
            0xB0.toByte(), 0x12,                     // syntax=1, section_length=18
            0x00, 0x01,                              // program_number 1
            0xC1.toByte(),                           // version 0, current_next=1
            0x00, 0x00,                              // section 0 of 0
            (0xE0 or (VIDEO_PID ushr 8)).toByte(),   // PCR_PID = video PID
            (VIDEO_PID and 0xFF).toByte(),
            0xF0.toByte(), 0x00,                     // program_info_length 0
            0x1B,                                    // stream_type: H.264
            (0xE0 or (VIDEO_PID ushr 8)).toByte(),   // elementary PID
            (VIDEO_PID and 0xFF).toByte(),
            0xF0.toByte(), 0x00,                     // ES_info_length 0
        ))
    }

    // 4-bit continuity counters, one per PID with payload.
    private var ccPat = 0
    private var ccPmt = 0
    private var ccVideo = 0
    private var lastPsiPtsUs = Long.MIN_VALUE

    /** Fresh connection = fresh mux state: counters restart and the first AU
     *  re-announces PAT/PMT regardless of cadence. */
    fun reset() {
        ccPat = 0
        ccPmt = 0
        ccVideo = 0
        lastPsiPtsUs = Long.MIN_VALUE
    }

    /**
     * One access unit -> the complete TS byte run for it (PSI when due, then
     * the PES-wrapped AU). `au` is Annex-B (start-coded) H.264, csd already
     * glued ahead of IDRs by the caller.
     */
    fun packetize(au: ByteArray, ptsUs: Long, isKey: Boolean): ByteArray {
        val out = ByteArrayOutputStream(au.size + au.size / TS_PACKET * 4 + 1024)
        val pts90 = (ptsUs * 9L / 100L) and PTS_WRAP_MASK
        // The backwards-PTS clause keeps the PSI floor honest if the caller's
        // clock ever rebases without reset() — otherwise lastPsiPtsUs sits in
        // the future and the cadence silently degrades to once-per-GOP.
        if (isKey || lastPsiPtsUs == Long.MIN_VALUE ||
                ptsUs - lastPsiPtsUs >= PSI_INTERVAL_US ||
                ptsUs < lastPsiPtsUs) {
            lastPsiPtsUs = ptsUs
            writePsi(out, 0x0000, PAT_SECTION, ccPat); ccPat = (ccPat + 1) and 0xF
            writePsi(out, PMT_PID, PMT_SECTION, ccPmt); ccPmt = (ccPmt + 1) and 0xF
        }
        writePes(out, au, pts90, isKey)
        return out.toByteArray()
    }

    private fun writePsi(out: ByteArrayOutputStream, pid: Int, section: ByteArray, cc: Int) {
        val pkt = ByteArray(TS_PACKET)
        pkt[0] = 0x47
        pkt[1] = (0x40 or (pid ushr 8)).toByte()     // PUSI=1
        pkt[2] = (pid and 0xFF).toByte()
        pkt[3] = (0x10 or cc).toByte()               // payload only
        pkt[4] = 0x00                                // pointer_field
        section.copyInto(pkt, 5)
        for (i in 5 + section.size until TS_PACKET) pkt[i] = 0xFF.toByte()
        out.write(pkt, 0, TS_PACKET)
    }

    private fun writePes(out: ByteArrayOutputStream, au: ByteArray, pts90: Long, isKey: Boolean) {
        // PES header: PTS only, PES_packet_length 0 (legal for video and the
        // only honest value — an AU can exceed the 16-bit field).
        val pes = ByteArray(9 + 5 + AUD.size + au.size)
        pes[0] = 0x00; pes[1] = 0x00; pes[2] = 0x01
        pes[3] = PES_STREAM_ID_VIDEO.toByte()
        pes[4] = 0x00; pes[5] = 0x00                 // PES_packet_length 0
        pes[6] = 0x84.toByte()                       // '10', data_alignment=1
        pes[7] = 0x80.toByte()                       // PTS only
        pes[8] = 0x05                                // PES_header_data_length
        pes[9] = (0x21 or (((pts90 ushr 29) and 0x0E)).toInt()).toByte()
        pes[10] = ((pts90 ushr 22) and 0xFF).toByte()
        pes[11] = (0x01 or ((pts90 ushr 14) and 0xFE).toInt()).toByte()
        pes[12] = ((pts90 ushr 7) and 0xFF).toByte()
        pes[13] = (0x01 or ((pts90 shl 1) and 0xFE).toInt()).toByte()
        AUD.copyInto(pes, 14)
        au.copyInto(pes, 14 + AUD.size)

        var off = 0
        var first = true
        while (off < pes.size) {
            val pkt = ByteArray(TS_PACKET)
            pkt[0] = 0x47
            pkt[1] = ((if (first) 0x40 else 0x00) or (VIDEO_PID ushr 8)).toByte()
            pkt[2] = (VIDEO_PID and 0xFF).toByte()
            var payloadCapacity = TS_PACKET - 4
            var bodyStart = 4
            if (first) {
                // Adaptation field with PCR (+ random_access on keyframes).
                // Clamped, not masked, near zero: a stream whose PTS starts at
                // 0 must not be BORN 100 ms before the 33-bit wrap point —
                // legal modulo arithmetic, but a receiver comparing linearly
                // at join time sees a 95443 s backwards jump in its first
                // frames. Costs a ~100 ms PCR flatline at each genuine wrap
                // (once per 26.5 h), which no receiver notices.
                val pcr = if (pts90 < PCR_BEHIND_PTS_90K) 0L
                          else pts90 - PCR_BEHIND_PTS_90K
                pkt[3] = (0x30 or ccVideo).toByte()  // adaptation + payload
                pkt[4] = 7                           // adaptation_field_length
                pkt[5] = (0x10 or (if (isKey) 0x40 else 0x00)).toByte()
                pkt[6] = ((pcr ushr 25) and 0xFF).toByte()
                pkt[7] = ((pcr ushr 17) and 0xFF).toByte()
                pkt[8] = ((pcr ushr 9) and 0xFF).toByte()
                pkt[9] = ((pcr ushr 1) and 0xFF).toByte()
                pkt[10] = (((pcr and 1L).toInt() shl 7) or 0x7E).toByte()
                pkt[11] = 0x00                       // pcr_extension
                payloadCapacity -= 8
                bodyStart = 12
            } else {
                pkt[3] = (0x10 or ccVideo).toByte()  // payload only (for now)
            }
            ccVideo = (ccVideo + 1) and 0xF
            val remaining = pes.size - off
            if (remaining < payloadCapacity) {
                // Short final packet: grow (or create) the adaptation field
                // with stuffing so the payload ends exactly at byte 188.
                val gap = payloadCapacity - remaining
                if (first) {
                    // Extend the PCR adaptation field: stuffing goes after
                    // the PCR bytes, before the payload.
                    pkt[4] = (7 + gap).toByte()
                    for (i in 12 until 12 + gap) pkt[i] = 0xFF.toByte()
                    bodyStart = 12 + gap
                } else {
                    pkt[3] = (0x30 or (pkt[3].toInt() and 0x0F)).toByte()
                    if (gap == 1) {
                        pkt[4] = 0x00                // length-0 field = 1 byte
                        bodyStart = 5
                    } else {
                        pkt[4] = (gap - 1).toByte()
                        pkt[5] = 0x00                // no flags
                        for (i in 6 until 4 + gap) pkt[i] = 0xFF.toByte()
                        bodyStart = 4 + gap
                    }
                }
                pes.copyInto(pkt, bodyStart, off, off + remaining)
                off += remaining
            } else {
                pes.copyInto(pkt, bodyStart, off, off + payloadCapacity)
                off += payloadCapacity
            }
            first = false
            out.write(pkt, 0, TS_PACKET)
        }
    }
}
