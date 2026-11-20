"""D1 — the depth-to-field reduction, as pure Python with NO TouchDesigner and
NO numpy imports.

§12.2's T1: a monocular depth map of the phone's own SRT stream, reduced to the
SAME five field channels the phone publishes over OSC (§4, idx 5-9), so the two
can be put side by side on one live scene. That comparison IS the calibration
session §10 #6 asked for — where they disagree is the finding.

WHY THIS FILE EXISTS SEPARATELY FROM THE TD NETWORK
---------------------------------------------------
The same reason CrowdTracker went to GDScript rather than Kotlin at M8b: this
is pure arithmetic with no device in it, so it can be PROVEN against synthetic
frames before a GPU, a phone or a venue is involved. `build_depth_field.py`
wires the TOP chain that computes the moments on the GPU; the algebra that
turns those four moments into the five frozen channels is HERE, imported by the
Script CHOP inside TD and by `verify_depth_field.py` out here. One
implementation, two callers, no drift.

THE MOMENT IDENTITY IS THE WHOLE TRICK
--------------------------------------
A GPU can reduce an image to a mean cheaply (one Analyze TOP) and to almost
nothing else cheaply. So the network never computes a centroid or a variance —
it computes FOUR MEANS in one RGBA pass:

    m0   = mean(w)                    w = the per-pixel weight
    mx   = mean(w * x)
    my   = mean(w * y)
    msq  = mean(w * (x*x + y*y))

and this file recovers the rest on the CPU from those four numbers:

    cx        = mx / m0
    cy        = my / m0
    var_x+y   = msq/m0 - (cx*cx + cy*cy)      <- E[X^2] - E[X]^2, per axis, summed

That is one GLSL TOP + one Analyze TOP for centroid AND variance together,
at any resolution, instead of a multi-pass moment chain. `verify_depth_field.py`
checks this one-pass identity against a two-pass reference that computes the
variance about the measured centroid the honest way — because the identity is
the kind of algebra that is right on paper and wrong by a transposed term.

DEPTH CONVENTION
----------------
Depth Anything outputs RELATIVE INVERSE depth (disparity): **larger = NEARER**,
normalised 0..1 by the .tox. Everything below assumes that. If a depth source
ever arrives the other way up, invert at the source, not here.

WHAT THE DEPTH TIER CHANGES, AND WHAT IT MUST NOT
-------------------------------------------------
§12.4 is explicit that `occupied_volume` gets to mean what it always wanted to:
a body at 1 m counts more than one at 6 m. So `depth_weighted` (default on)
sets w = d rather than w = 1 inside the mask, and the centroid and variance
inherit that weighting for free. `depth_weighted=False` gives the plain masked
fraction the phone computes, which is the apples-to-apples setting for the
side-by-side. NAMES AND RANGES DO NOT MOVE either way (§4): five channels,
all 0-1, frozen to the Kinect patch.
"""

# --- defaults -------------------------------------------------------------
# These are the calibration surface. `motion_gain` carries §4's OPEN verbatim:
# 8.0 is a placeholder for a depth-difference energy just as it was for a
# luma-difference one, and the phone-vs-TD run is what replaces it.
NEAR_THRESH = 0.35      # disparity below this is background, weight 0
DEPTH_WEIGHTED = True   # §12.4: nearness-weighted occupancy
VOLUME_GAIN = 1.0       # 1.0 until the side-by-side sets it. Never guess it here.
MOTION_GAIN = 8.0       # §4 idx 6, placeholder, same as the phone's
VARIANCE_NORM = 6.0     # §4 idx 9: uniform over the frame reads ~1.0
EMPTY_VOLUME = 0.005    # §4 empty-mask rule: below this, hold
PRESENCE_FLOOR = 0.01   # §4 field_presence_floor
MOTION_DECAY = 0.85     # per frame, while empty
MOTION_ENVELOPE = True  # see the note below — required when the depth source
                        # updates slower than the host cooks
GRACE_MS = 900          # presence grace, matching the phone's


# ⚠️ WHY MOTION IS AN ENVELOPE AND NOT AN INSTANTANEOUS DIFFERENCE
# ----------------------------------------------------------------
# §4 idx 6 defines motion_energy as the frame-to-frame difference, and on the
# phone that is exactly right: every cook IS a new inference, so consecutive
# frames always carry new information.
#
# TD does not work that way. The host cooks at 60 Hz while a monocular depth
# model delivers ~16 Hz, so 44 frames in every 60 diff a depth map against an
# IDENTICAL copy of itself and read exactly 0. Measured live: the channel
# alternated 1.0, 0.0, 0.69, 0.0 — a spike train, not an energy. Anything
# downstream that samples it (a keyframe, a threshold, a trigger lane) reads
# whichever face of the alternation it happens to land on.
#
# So the raw difference is fed through a peak-hold with the same decay the
# empty-mask rule already uses: `m = max(raw, previous * decay)`. Frames with
# no new depth hold the envelope instead of punching a hole in it. The RANGE
# and the NAME are unchanged, which is all §4 actually freezes — and an
# envelope is closer to what "energy" means to a VJ patch than an
# instantaneous delta ever was. Set `motion_envelope=False` for the literal
# §4 definition when the source really does update every cook.


def clamp01(v):
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


class DepthFieldReducer:
    """Four GPU moments + one motion mean in, five frozen channels out.

    Stateful ON PURPOSE: §4's empty-mask rule says the centroid and the
    variance HOLD their last value when the frame empties rather than snapping
    to 0.5, because a centroid of nothing is noise and a jump to centre reads
    downstream as a person teleporting. That rule needs memory, so this is a
    class and not a function.
    """

    def __init__(self, **kw):
        self.near_thresh = kw.get("near_thresh", NEAR_THRESH)
        self.depth_weighted = kw.get("depth_weighted", DEPTH_WEIGHTED)
        self.volume_gain = kw.get("volume_gain", VOLUME_GAIN)
        self.motion_gain = kw.get("motion_gain", MOTION_GAIN)
        self.variance_norm = kw.get("variance_norm", VARIANCE_NORM)
        self.empty_volume = kw.get("empty_volume", EMPTY_VOLUME)
        self.presence_floor = kw.get("presence_floor", PRESENCE_FLOOR)
        self.motion_decay = kw.get("motion_decay", MOTION_DECAY)
        self.motion_envelope = kw.get("motion_envelope", MOTION_ENVELOPE)
        self.grace_ms = kw.get("grace_ms", GRACE_MS)
        self.reset()

    def reset(self):
        # Held values start at centre/zero — the only frame where 0.5 is not a
        # lie is the one before anything has ever been seen.
        self._cx = 0.5
        self._cy = 0.5
        self._var = 0.0
        self._motion = 0.0
        self._presence = 0.0
        self._last_seen_ms = None

    # -- the one entry point ------------------------------------------------
    def step(self, m0, mx, my, msq, motion_raw, now_ms=0):
        """m0/mx/my/msq: the Analyze TOP's RGBA. motion_raw: mean |w - w_prev|.

        Returns the five FROZEN channels plus `presence`, all 0-1.
        """
        volume = clamp01(m0 * self.volume_gain)
        occupied = volume >= self.empty_volume

        if occupied:
            inv = 1.0 / m0                      # m0 > 0 is implied by the branch
            cx = mx * inv
            cy = my * inv
            # E[X^2]+E[Y^2] - (E[X]^2+E[Y]^2). Float error can push a
            # single-pixel blob's variance a hair below zero; that is not a
            # negative variance, it is 0.
            var_sum = msq * inv - (cx * cx + cy * cy)
            if var_sum < 0.0:
                var_sum = 0.0
            self._cx = clamp01(cx)
            self._cy = clamp01(cy)
            self._var = clamp01(var_sum * self.variance_norm)
            m = clamp01(motion_raw * self.motion_gain)
            # peak-hold: a frame carrying no new depth holds the envelope
            # rather than punching a hole in it. See the note at the top.
            if self.motion_envelope:
                held = self._motion * self.motion_decay
                self._motion = m if m > held else held
                # The same float floor the empty-mask rule uses. Without it a
                # geometric decay asymptotes forever and the envelope becomes a
                # floor that never releases — a room that never quite stops
                # moving.
                if self._motion < 1e-4:
                    self._motion = 0.0
            else:
                self._motion = m
        else:
            # HOLD centroid + variance (they keep their last value untouched),
            # DECAY motion. Not the same rule for all five, by §4's design.
            self._motion *= self.motion_decay
            if self._motion < 1e-4:
                self._motion = 0.0

        # presence: grace-windowed, with occupied_volume as the detector
        if volume >= self.presence_floor:
            self._presence = 1.0
            self._last_seen_ms = now_ms
        elif self._last_seen_ms is None:
            self._presence = 0.0
        elif (now_ms - self._last_seen_ms) > self.grace_ms:
            self._presence = 0.0

        return {
            "occupied_volume": volume,
            "motion_energy": self._motion,
            "centroid_x": self._cx,
            "centroid_y": self._cy,
            "spatial_variance": self._var,
            "presence": self._presence,
        }


# --- the CPU twin of the GPU pass ----------------------------------------
# Used by the verifier, and by anyone who wants to sanity-check a captured
# frame without TD. Deliberately a plain loop: it is the SLOW, OBVIOUS route
# whose only job is to disagree with the fast one when the fast one is wrong.

def weight(d, near_thresh, depth_weighted):
    if d < near_thresh:
        return 0.0
    return d if depth_weighted else 1.0


def moments(depth, w, h, near_thresh=NEAR_THRESH, depth_weighted=DEPTH_WEIGHTED):
    """What the GLSL TOP + Analyze TOP produce: four MEANS over the frame.

    `depth` is a flat row-major list of floats, row 0 = TOP of the image
    (§4 idx 8: centroid_y 0 = top).
    """
    m0 = mx = my = msq = 0.0
    for j in range(h):
        y = (j + 0.5) / h
        row = j * w
        for i in range(w):
            wt = weight(depth[row + i], near_thresh, depth_weighted)
            if wt == 0.0:
                continue
            x = (i + 0.5) / w
            m0 += wt
            mx += wt * x
            my += wt * y
            msq += wt * (x * x + y * y)
    n = float(w * h)
    return m0 / n, mx / n, my / n, msq / n


def motion_mean(depth, prev, w, h, near_thresh=NEAR_THRESH,
                depth_weighted=DEPTH_WEIGHTED):
    """mean |w - w_prev| over the whole frame — the second Analyze TOP.

    Note it is over the WHOLE frame, not inside the mask: a person walking into
    an empty region is motion, and a mask-only difference cannot see the half
    of that event that happens outside the current mask.
    """
    tot = 0.0
    for k in range(w * h):
        a = weight(depth[k], near_thresh, depth_weighted)
        b = weight(prev[k], near_thresh, depth_weighted)
        tot += abs(a - b)
    return tot / float(w * h)


def reduce_reference(depth, w, h, **kw):
    """The five channels computed the SLOW, INDEPENDENT way.

    Two passes, variance taken about the measured centroid — no E[X^2]-E[X]^2
    identity anywhere. This exists purely so the verifier has something that
    can disagree with `DepthFieldReducer.step`.
    """
    near = kw.get("near_thresh", NEAR_THRESH)
    dw = kw.get("depth_weighted", DEPTH_WEIGHTED)
    vol_gain = kw.get("volume_gain", VOLUME_GAIN)
    var_norm = kw.get("variance_norm", VARIANCE_NORM)

    tw = 0.0
    sx = 0.0
    sy = 0.0
    for j in range(h):
        y = (j + 0.5) / h
        row = j * w
        for i in range(w):
            wt = weight(depth[row + i], near, dw)
            if wt == 0.0:
                continue
            tw += wt
            sx += wt * (i + 0.5) / w
            sy += wt * y
    if tw <= 0.0:
        return None
    cx = sx / tw
    cy = sy / tw

    acc = 0.0
    for j in range(h):
        y = (j + 0.5) / h
        row = j * w
        for i in range(w):
            wt = weight(depth[row + i], near, dw)
            if wt == 0.0:
                continue
            x = (i + 0.5) / w
            acc += wt * ((x - cx) ** 2 + (y - cy) ** 2)
    var_sum = acc / tw

    return {
        "occupied_volume": clamp01((tw / float(w * h)) * vol_gain),
        "centroid_x": clamp01(cx),
        "centroid_y": clamp01(cy),
        "spatial_variance": clamp01(var_sum * var_norm),
    }
