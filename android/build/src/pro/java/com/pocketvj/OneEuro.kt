package com.pocketvj

import kotlin.math.PI
import kotlin.math.abs

/**
 * One Euro filter (Casiez et al., CHI 2012) — docs/MEDIAPIPE_MODULE.md §5.1.
 *
 * Speed-adaptive low-pass: still input gets a heavy cutoff (rock solid),
 * fast input raises the cutoff (responsive). Timestamps come from the
 * CAMERA frame (§5.1) so inference-scheduling jitter never enters dx.
 */
class OneEuro(
    @Volatile var minCutoff: Float = 1.0f,
    @Volatile var beta: Float = 0.02f,
    private val dCutoff: Float = 1.0f,
) {
    private var hasPrev = false
    private var prevT = 0L         // ms
    private var prevX = 0f
    private var prevDx = 0f

    fun reset() { hasPrev = false }

    private fun alpha(cutoff: Float, dtSec: Float): Float {
        val tau = 1.0f / (2.0f * PI.toFloat() * cutoff)
        return 1.0f / (1.0f + tau / dtSec)
    }

    fun filter(x: Float, tMs: Long): Float {
        if (!hasPrev) {
            hasPrev = true
            prevT = tMs
            prevX = x
            prevDx = 0f
            return x
        }
        val dt = ((tMs - prevT).coerceAtLeast(1L)) / 1000.0f
        prevT = tMs
        val dx = (x - prevX) / dt
        val edx = prevDx + alpha(dCutoff, dt) * (dx - prevDx)
        prevDx = edx
        val cutoff = minCutoff + beta * abs(edx)
        val out = prevX + alpha(cutoff, dt) * (x - prevX)
        prevX = out
        return out
    }
}

/**
 * A bank of filters sharing live-tunable parameters — one per continuous
 * channel. reset() on mode change / acquisition / camera restart (§5.1:
 * a warm filter drags the previous subject into the new one's first second).
 */
class OneEuroBank(size: Int) {
    private val filters = Array(size) { OneEuro() }

    fun setParams(minCutoff: Float, beta: Float) {
        for (f in filters) { f.minCutoff = minCutoff; f.beta = beta }
    }

    fun reset() { for (f in filters) f.reset() }

    fun filter(i: Int, x: Float, tMs: Long): Float = filters[i].filter(x, tMs)
}
