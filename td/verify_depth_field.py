"""Headless proof for the D1 depth->field reduction (§12.2 T1).

    python3 td/verify_depth_field.py

Zero dependencies, no TouchDesigner, no GPU, no phone, no venue. The same
argument as CrowdTracker at M8b: this is pure arithmetic, so it gets PROVEN
against synthetic frames rather than eyeballed against a live scene where a
wrong constant and a wrong flip look identical.

What it actually checks, in order of how likely each is to be the bug:

  1. THE MOMENT IDENTITY. The GPU chain computes var via E[X^2]-E[X]^2 in one
     pass. The reference computes it about the measured centroid in two. If
     the identity is transposed, dropped or mis-normalised, these disagree.
  2. THE Y FLIP. §4 idx 8 says centroid_y 0 = TOP. TD's vUV.t is 0 at the
     BOTTOM. This repo shipped four derived transforms wrong in one session
     (Session 36 §6), so the flip gets an explicit test with an unambiguous
     asymmetric frame, not a centred blob that cannot disprove it.
  3. THE EMPTY-MASK RULE. Centroid and variance HOLD, motion DECAYS. Three
     different behaviours in one rule; the easy mistake is applying one.
  4. The normalisation constant: a frame full of subject reads ~1.0 variance.
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from depth_field import (  # noqa: E402
    DepthFieldReducer, moments, motion_mean, reduce_reference, clamp01,
)

_checks = 0
_fails = 0


def ck(label, cond):
    global _checks, _fails
    _checks += 1
    if cond:
        print("  ✓ %s" % label)
    else:
        _fails += 1
        print("  ✗ %s" % label)


def near(a, b, tol=1e-6):
    return abs(a - b) <= tol


# --- synthetic frames -----------------------------------------------------
W = H = 64


def blank(v=0.0):
    return [v] * (W * H)


def blob(cx, cy, r, depth=0.9, base=0.0):
    """A disc of `depth` at (cx, cy) in 0-1 coords, y=0 at TOP."""
    px = blank(base)
    for j in range(H):
        y = (j + 0.5) / H
        for i in range(W):
            x = (i + 0.5) / W
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                px[j * W + i] = depth
    return px


def rect(x0, y0, x1, y1, depth=0.9, base=0.0):
    px = blank(base)
    for j in range(H):
        y = (j + 0.5) / H
        for i in range(W):
            x = (i + 0.5) / W
            if x0 <= x <= x1 and y0 <= y <= y1:
                px[j * W + i] = depth
    return px


def run(px, prev=None, **kw):
    """Frame -> the five channels, THROUGH the GPU decomposition."""
    m0, mx, my, msq = moments(px, W, H, kw.get("near_thresh", 0.35),
                              kw.get("depth_weighted", True))
    mo = motion_mean(px, prev if prev else px, W, H,
                     kw.get("near_thresh", 0.35), kw.get("depth_weighted", True))
    r = kw.pop("reducer", None) or DepthFieldReducer(**kw)
    return r.step(m0, mx, my, msq, mo, kw.get("now_ms", 0)), r


# --- 1. the moment identity ----------------------------------------------
def t_moment_identity():
    print("\n[moment identity — one-pass E[X^2]-E[X]^2 vs two-pass reference]")
    cases = [
        ("centred disc", blob(0.5, 0.5, 0.2)),
        ("off-centre disc", blob(0.25, 0.7, 0.12)),
        ("wide bar", rect(0.05, 0.45, 0.95, 0.55)),
        ("tall bar", rect(0.45, 0.05, 0.55, 0.95)),
        ("two discs", None),
        ("graded depth wedge", None),
    ]
    two = blob(0.2, 0.5, 0.1)
    b2 = blob(0.8, 0.5, 0.1)
    for k in range(W * H):
        two[k] = max(two[k], b2[k])
    cases[4] = ("two discs", two)
    wedge = blank()
    for j in range(H):
        for i in range(W):
            wedge[j * W + i] = 0.3 + 0.7 * ((i + 0.5) / W)
    cases[5] = ("graded depth wedge", wedge)

    for name, px in cases:
        got, _ = run(px)
        ref = reduce_reference(px, W, H)
        ck("%s: occupied_volume" % name,
           near(got["occupied_volume"], ref["occupied_volume"], 1e-9))
        ck("%s: centroid_x" % name, near(got["centroid_x"], ref["centroid_x"], 1e-9))
        ck("%s: centroid_y" % name, near(got["centroid_y"], ref["centroid_y"], 1e-9))
        ck("%s: spatial_variance" % name,
           near(got["spatial_variance"], ref["spatial_variance"], 1e-9))


# --- 2. the y flip --------------------------------------------------------
def t_y_orientation():
    print("\n[orientation — §4 idx 8: centroid_y 0 = TOP]")
    # Deliberately asymmetric and unambiguous: a bar across the TOP EIGHTH.
    top = rect(0.0, 0.0, 1.0, 0.125)
    bot = rect(0.0, 0.875, 1.0, 1.0)
    gt, _ = run(top)
    gb, _ = run(bot)
    ck("a bar at the TOP of the frame reads centroid_y < 0.15",
       gt["centroid_y"] < 0.15)
    ck("a bar at the BOTTOM reads centroid_y > 0.85", gb["centroid_y"] > 0.85)
    ck("top and bottom are not the same value (a flip cannot hide here)",
       abs(gt["centroid_y"] - gb["centroid_y"]) > 0.7)
    # and x, for symmetry of argument
    left = rect(0.0, 0.0, 0.125, 1.0)
    gl, _ = run(left)
    ck("a bar on the LEFT reads centroid_x < 0.15", gl["centroid_x"] < 0.15)


# --- 3. the empty-mask rule ----------------------------------------------
def t_empty_rule():
    print("\n[empty-mask rule — hold centroid+variance, DECAY motion (§4)]")
    r = DepthFieldReducer()
    seen, _ = run(blob(0.25, 0.75, 0.2), prev=blank(), reducer=r, now_ms=0)
    ck("a real subject is seen", seen["occupied_volume"] > 0.02)
    held_x, held_y = seen["centroid_x"], seen["centroid_y"]
    held_v = seen["spatial_variance"]
    ck("motion registered on the frame it appeared", seen["motion_energy"] > 0.0)

    empty, _ = run(blank(), prev=blob(0.25, 0.75, 0.2), reducer=r, now_ms=100)
    ck("empty frame: occupied_volume falls to 0", empty["occupied_volume"] == 0.0)
    ck("empty frame: centroid_x HOLDS (does not snap to 0.5)",
       near(empty["centroid_x"], held_x))
    ck("empty frame: centroid_y HOLDS", near(empty["centroid_y"], held_y))
    ck("empty frame: spatial_variance HOLDS", near(empty["spatial_variance"], held_v))
    ck("held centroid is NOT 0.5 (the test would be vacuous if it were)",
       abs(held_x - 0.5) > 0.1)

    # The decay must be MONOTONE and must TERMINATE. A geometric decay with a
    # float floor does both; a decay without the floor asymptotes forever and
    # leaves a channel that is never quite zero, which downstream reads as a
    # room that never quite empties.
    m_prev = empty["motion_energy"]
    monotone = True
    frames = 0
    while m_prev > 0.0 and frames < 300:
        frames += 1
        empty, _ = run(blank(), prev=blank(), reducer=r, now_ms=100 + frames * 16)
        m = empty["motion_energy"]
        if m >= m_prev:
            monotone = False
        m_prev = m
    ck("motion decays monotonically every frame while empty", monotone)
    ck("motion reaches EXACTLY 0, not a float tail (%d frames, %.2f s @60fps)"
       % (frames, frames / 60.0), m_prev == 0.0)
    ck("and gets there inside 2 s @60fps — an empty room reads empty promptly",
       frames <= 120)


def t_presence_grace():
    print("\n[presence grace — same 900 ms window the phone uses]")
    r = DepthFieldReducer(grace_ms=900)
    s, _ = run(blob(0.5, 0.5, 0.25), reducer=r, now_ms=1000)
    ck("presence rises with a subject", s["presence"] == 1.0)
    s, _ = run(blank(), reducer=r, now_ms=1500)
    ck("presence HOLDS inside the grace window", s["presence"] == 1.0)
    s, _ = run(blank(), reducer=r, now_ms=2500)
    ck("presence drops after the grace window", s["presence"] == 0.0)
    cold = DepthFieldReducer()
    s, _ = run(blank(), reducer=cold, now_ms=0)
    ck("presence starts at 0, never 1 (a cold reducer has seen nobody)",
       s["presence"] == 0.0)


# --- 4. the normalisation constant ---------------------------------------
def t_variance_norm():
    print("\n[variance normalisation — §4 idx 9: full frame reads ~1.0]")
    full = blank(1.0)
    g, _ = run(full)
    ck("a frame uniformly full of subject reads spatial_variance ~1.0 (got %.3f)"
       % g["spatial_variance"], abs(g["spatial_variance"] - 1.0) < 0.02)
    tight = blob(0.5, 0.5, 0.03)
    gt, _ = run(tight)
    ck("a tight blob reads near 0 (got %.4f)" % gt["spatial_variance"],
       gt["spatial_variance"] < 0.02)
    ck("spread orders correctly", gt["spatial_variance"] < g["spatial_variance"])
    for name, px in [("full", full), ("tight", tight), ("bar", rect(0, 0.4, 1, 0.6))]:
        gg, _ = run(px)
        for k, v in gg.items():
            ck("%s: %s in 0..1" % (name, k), 0.0 <= v <= 1.0)


# --- 5. what the depth tier is FOR (§12.4) -------------------------------
def t_depth_weighting():
    print("\n[§12.4 — nearness weighting: a body at 1 m outweighs one at 6 m]")
    # same silhouette area, different depth: near subject left, far subject right
    px = blank()
    for j in range(H):
        for i in range(W):
            x = (i + 0.5) / W
            y = (j + 0.5) / H
            if (x - 0.25) ** 2 + (y - 0.5) ** 2 <= 0.15 ** 2:
                px[j * W + i] = 0.95          # near
            elif (x - 0.75) ** 2 + (y - 0.5) ** 2 <= 0.15 ** 2:
                px[j * W + i] = 0.45          # far, still above threshold
    wq, _ = run(px, depth_weighted=True)
    mq, _ = run(px, depth_weighted=False)
    ck("depth-weighted centroid leans toward the NEAR subject (%.3f < 0.5)"
       % wq["centroid_x"], wq["centroid_x"] < 0.48)
    ck("mask-only centroid sits between them (%.3f ~ 0.5)" % mq["centroid_x"],
       abs(mq["centroid_x"] - 0.5) < 0.02)
    ck("mask-only occupancy is the LARGER (every masked pixel counts 1.0)",
       mq["occupied_volume"] > wq["occupied_volume"])
    ck("the two agree on vertical placement (weighting is horizontal here)",
       abs(wq["centroid_y"] - mq["centroid_y"]) < 0.02)

    # background rejection: a far wall must not become a subject
    wall = blank(0.20)
    gw, _ = run(wall)
    ck("a uniform FAR wall (0.20 < near_thresh) reads occupied_volume 0",
       gw["occupied_volume"] == 0.0)
    gw2, _ = run(blank(0.50))
    ck("a uniform NEAR field does read as occupied", gw2["occupied_volume"] > 0.0)


def t_motion():
    print("\n[motion energy — whole-frame difference, §4 idx 6 gain]")
    a = blob(0.3, 0.5, 0.15)
    b = blob(0.7, 0.5, 0.15)
    still, _ = run(a, prev=a)
    ck("a perfectly still subject reads motion 0", still["motion_energy"] == 0.0)
    moved, _ = run(b, prev=a)
    ck("a subject that jumped reads motion > 0", moved["motion_energy"] > 0.0)
    small, _ = run(blob(0.34, 0.5, 0.15), prev=a)
    ck("a small move reads LESS than a large one",
       small["motion_energy"] < moved["motion_energy"])
    hot, _ = run(b, prev=a, motion_gain=1000.0)
    ck("motion_energy clamps at 1.0 under an absurd gain",
       hot["motion_energy"] == 1.0)


def t_motion_envelope():
    print("\n[motion envelope — the 60 Hz host / 16 Hz model mismatch]")
    # Reproduce the live defect: one frame of real movement, then frames that
    # carry NO new depth (identical to the previous one).
    a = blob(0.3, 0.5, 0.15)
    b = blob(0.7, 0.5, 0.15)

    raw = DepthFieldReducer(motion_envelope=False)
    r0, _ = run(b, prev=a, reducer=raw)
    r1, _ = run(b, prev=b, reducer=raw)
    ck("without the envelope, a repeated frame drops motion straight to 0 "
       "(%.3f -> %.3f)" % (r0["motion_energy"], r1["motion_energy"]),
       r0["motion_energy"] > 0.0 and r1["motion_energy"] == 0.0)

    env = DepthFieldReducer(motion_envelope=True)
    e0, _ = run(b, prev=a, reducer=env)
    e1, _ = run(b, prev=b, reducer=env)
    e2, _ = run(b, prev=b, reducer=env)
    ck("with the envelope, a repeated frame HOLDS a decayed value, not 0",
       0.0 < e1["motion_energy"] < e0["motion_energy"])
    ck("and keeps decaying while nothing new arrives",
       e2["motion_energy"] < e1["motion_energy"])
    ck("a fresh burst re-arms the envelope upward", (
        run(a, prev=b, reducer=env)[0]["motion_energy"] > e2["motion_energy"]))

    # The envelope must not become a floor that never releases.
    m = e2["motion_energy"]
    frames = 0
    while m > 0.0 and frames < 300:
        frames += 1
        m = run(b, prev=b, reducer=env)[0]["motion_energy"]
    ck("the envelope still reaches EXACTLY 0 when movement stops (%d frames)"
       % frames, m == 0.0)
    ck("still in 0..1", 0.0 <= e0["motion_energy"] <= 1.0)


def main():
    t_moment_identity()
    t_y_orientation()
    t_empty_rule()
    t_presence_grace()
    t_variance_norm()
    t_depth_weighting()
    t_motion()
    t_motion_envelope()
    print("\n%s  %d/%d checks passed" % (
        "FAIL" if _fails else "PASS", _checks - _fails, _checks))
    return 1 if _fails else 0


if __name__ == "__main__":
    sys.exit(main())
