"""D1 — build the depth->field reduction network inside TouchDesigner.

Run it from a Text DAT in TD, or over the tdmcp bridge:

    exec(open(r'<repo>/td/build_depth_field.py').read())
    build(repo=r'<repo>')

Idempotent: it deletes and rebuilds `/project1/pvj_depth_field` every time, so
re-running after an edit to `td/depth_field.py` re-syncs the maths.
⚠️ TD must still be SAVED by hand afterwards, like every bridge edit (td/TODO.md).

WHAT THIS IS
------------
§12.2's T1: monocular depth of the phone's own SRT stream, reduced to the SAME
five field channels the phone publishes (§4 idx 5-9), so the two can be put
side by side. It is deliberately AGNOSTIC about where depth comes from — feed
it a DepthAnything TOP, a Kinect, or a noise TOP for a bench test. The depth
estimator is off-the-shelf; this reduction is the PocketVJ-specific part, and
it is the part that had to be right.

THE COST ARGUMENT
-----------------
The naive route reduces a 1280x720 depth map to a centroid and a variance with
a multi-pass moment chain. This does it with TWO Analyze TOPs at 128x128:

  wsrc     GLSL: per-pixel weight w (mask, or depth-weighted per §12.4)
  moments  GLSL: RGBA = (w, w*x, w*y, w*(x*x + y*y))
  analyze  -> ONE 1x1 pixel carrying all four means
  motion   GLSL: |w - w_prev| via a Feedback TOP
  analyze  -> one more 1x1

and `depth_field.py` recovers centroid + variance from those four numbers on
the CPU (E[X^2]-E[X]^2, proven in verify_depth_field.py). Work resolution is a
par because the moments of a body-sized blob do not need 720p — 128x128 is
16k pixels against 920k, and the centroid of a person moves by well under one
pixel of that grid per frame.

⚠️ THE Y FLIP IS THE TRAP. TD's vUV.t is 0 at the BOTTOM; §4 idx 8 freezes
centroid_y at 0 = TOP. The flip happens ONCE, in the moments shader, and
`verify_depth_field.py` has an explicit asymmetric test for it because this
repo shipped four derived transforms wrong in a single session.
"""

COMP = "/project1/pvj_depth_field"

# --- the shaders ----------------------------------------------------------

WSRC_GLSL = """// D1 weight pass: depth -> per-pixel weight.
// uParams = (near_thresh, depth_weighted, use_luma, unused)
uniform vec4 uParams;
out vec4 fragColor;
void main() {
	vec4 c = texture(sTD2DInputs[0], vUV.st);
	// DepthAnything writes single-channel depth in R (g,b are ZERO), so a
	// luminance mix would be wrong for it. Luma is for COLOUR bench sources
	// standing in for a depth map.
	float d = (uParams.z > 0.5) ? dot(c.rgb, vec3(0.299, 0.587, 0.114)) : c.r;
	// Depth Anything outputs relative INVERSE depth: larger = NEARER.
	float w = (d < uParams.x) ? 0.0 : ((uParams.y > 0.5) ? d : 1.0);
	fragColor = TDOutputSwizzle(vec4(w, w, w, 1.0));
}
"""

MOMENTS_GLSL = """// D1 moment pass: weight -> the four quantities one Analyze TOP can average.
//   R = w            -> mean gives m0
//   G = w * x        -> mean gives mx
//   B = w * y        -> mean gives my
//   A = w * (x^2+y^2)-> mean gives msq, and msq/m0 - (cx^2+cy^2) = var_x+var_y
out vec4 fragColor;
void main() {
	float w = texture(sTD2DInputs[0], vUV.st).r;
	float x = vUV.s;
	// ⚠️ THE FLIP. vUV.t is 0 at the BOTTOM in TD; §4 idx 8 says
	// centroid_y 0 = TOP. Once, here, and nowhere else.
	float y = 1.0 - vUV.t;
	fragColor = TDOutputSwizzle(vec4(w, w * x, w * y, w * (x * x + y * y)));
}
"""

MOTION_GLSL = """// D1 motion pass: |w - w_prev|, over the WHOLE frame.
// Not inside the mask: a person walking into an empty region is motion, and a
// mask-only difference is blind to the half of that event outside the mask.
out vec4 fragColor;
void main() {
	float a = texture(sTD2DInputs[0], vUV.st).r;
	float b = texture(sTD2DInputs[1], vUV.st).r;
	float m = abs(a - b);
	fragColor = TDOutputSwizzle(vec4(m, m, m, 1.0));
}
"""

# --- the Script CHOP ------------------------------------------------------

FIELD_SCRIPT = '''# D1 field reduction — the CPU half.
# The four GPU moments + the motion mean in; the five FROZEN §4 channels out.
# All the arithmetic lives in the `depth_field` Text DAT beside this one, which
# `build_depth_field.py` syncs from td/depth_field.py in the repo — so the maths
# proven by verify_depth_field.py is literally the maths running here.

df = mod('depth_field')

_state = {'r': None, 'key': None}


def _reducer():
    c = op('..')
    key = (c.par.Nearthresh.eval(), c.par.Depthweighted.eval(),
           c.par.Volumegain.eval(), c.par.Motiongain.eval())
    if _state['r'] is None or _state['key'] != key:
        _state['r'] = df.DepthFieldReducer(
            near_thresh=c.par.Nearthresh.eval(),
            depth_weighted=bool(c.par.Depthweighted.eval()),
            volume_gain=c.par.Volumegain.eval(),
            motion_gain=c.par.Motiongain.eval())
        _state['key'] = key
    return _state['r']


def onCook(scriptOp):
    scriptOp.clear()
    # ⚠️ READ FROM scriptOp.inputs, NEVER by op('name'). A Script CHOP that
    # fetches its sources by path creates NO cook dependency: TD never pulls
    # them, the Analyze TOPs never cook, and this CHOP happily publishes the
    # last values it ever saw. It looks perfect — the channels are there, the
    # numbers are plausible, TD holds 60 fps because the GPU work is not
    # running — and it is frozen. Measured: 0 cooks in 304 frames.
    # Same family as Session 36's five lying readouts: gate on cooks, not on
    # whether the numbers look reasonable.
    if len(scriptOp.inputs) < 2:
        return
    mo = scriptOp.inputs[0]
    mt = scriptOp.inputs[1]
    if mo.numSamples < 1 or mt.numSamples < 1:
        return

    def ch(c, name, default=0.0):
        try:
            return float(c[name][0])
        except Exception:
            return default

    m0 = ch(mo, 'r')
    mx = ch(mo, 'g')
    my = ch(mo, 'b')
    msq = ch(mo, 'a')
    motion = ch(mt, 'r')

    out = _reducer().step(m0, mx, my, msq, motion, absTime.seconds * 1000.0)
    # ⚠️ CHANNEL NAMES ARE THE CONTRACT (§4, §6). A consumer swapping the phone
    # for this network must not have to rename anything.
    for name in ('occupied_volume', 'motion_energy', 'centroid_x',
                 'centroid_y', 'spatial_variance', 'presence'):
        scriptOp.appendChan(name)[0] = out[name]
    return
'''


def build(repo=None, parent_path="/project1", work_res=128):
    """Create /project1/pvj_depth_field from scratch. Returns a status dict."""
    import os

    par = op(parent_path)
    old = par.op("pvj_depth_field")
    if old:
        old.destroy()

    c = par.create(baseCOMP, "pvj_depth_field")
    c.nodeX, c.nodeY = 0, -400

    # --- custom pars: the calibration surface ----------------------------
    p = c.appendCustomPage("Depth Field")
    p.appendFloat("Nearthresh", label="Near Threshold")[0].val = 0.35
    p.appendToggle("Depthweighted", label="Depth Weighted")[0].val = True
    p.appendToggle("Uselum", label="Input Is Colour")[0].val = False
    p.appendFloat("Volumegain", label="Volume Gain")[0].val = 1.0
    p.appendFloat("Motiongain", label="Motion Gain")[0].val = 8.0
    p.appendInt("Workres", label="Work Res")[0].val = work_res
    p.appendStr("Sourcetop", label="Source TOP").val = ""
    c.par.Nearthresh.normMin, c.par.Nearthresh.normMax = 0.0, 1.0
    c.par.Volumegain.normMin, c.par.Volumegain.normMax = 0.0, 8.0
    c.par.Motiongain.normMin, c.par.Motiongain.normMax = 0.0, 32.0

    # --- the maths module, synced from the repo --------------------------
    dat = c.create(textDAT, "depth_field")
    dat.nodeX, dat.nodeY = -600, 300
    src = None
    if repo:
        path = os.path.join(repo, "td", "depth_field.py")
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                src = f.read()
    if src is None:
        raise RuntimeError(
            "depth_field.py not found — pass repo=<path to PocketVJ-v0.2>. "
            "The .toe must carry the SAME maths the verifier proved; a "
            "hand-typed copy is how the two drift.")
    dat.text = src

    # --- TOP chain --------------------------------------------------------
    src_top = c.create(inTOP, "in_depth")
    src_top.nodeX, src_top.nodeY = -800, 0

    sel = c.create(selectTOP, "src")
    sel.nodeX, sel.nodeY = -650, 0
    # Source TOP par wins if set; otherwise the comp's input.
    sel.par.top.expr = ("parent().par.Sourcetop.eval() or "
                        "op('in_depth').path")

    fit = c.create(resolutionTOP, "fit1")
    fit.nodeX, fit.nodeY = -500, 0
    fit.inputConnectors[0].connect(sel)
    fit.par.outputresolution = "custom"
    fit.par.resolutionw.expr = "parent().par.Workres"
    fit.par.resolutionh.expr = "parent().par.Workres"
    fit.par.outputaspect = "resolution"

    wsrc = c.create(glslTOP, "wsrc")
    wsrc.nodeX, wsrc.nodeY = -350, 0
    wsrc.inputConnectors[0].connect(fit)
    wdat = c.create(textDAT, "wsrc_glsl")
    wdat.nodeX, wdat.nodeY = -350, 150
    wdat.text = WSRC_GLSL
    wsrc.par.pixeldat = wdat
    wsrc.par.format = "rgba32float"
    # GLSL TOP uniforms are a SEQUENCE: bump the count, then fill block 0.
    wsrc.par.vec = 1
    wsrc.par.vec0name = "uParams"
    wsrc.par.vec0valuex.expr = "parent().par.Nearthresh"
    wsrc.par.vec0valuey.expr = "1 if parent().par.Depthweighted else 0"
    wsrc.par.vec0valuez.expr = "1 if parent().par.Uselum else 0"
    wsrc.par.vec0valuew = 0

    mom = c.create(glslTOP, "moments")
    mom.nodeX, mom.nodeY = -180, 80
    mom.inputConnectors[0].connect(wsrc)
    mdat = c.create(textDAT, "moments_glsl")
    mdat.nodeX, mdat.nodeY = -180, 230
    mdat.text = MOMENTS_GLSL
    mom.par.pixeldat = mdat
    mom.par.format = "rgba32float"

    fb = c.create(feedbackTOP, "wprev")
    fb.nodeX, fb.nodeY = -350, -160
    # A Feedback TOP needs BOTH: the input defines resolution and format, the
    # Target par names the TOP whose PREVIOUS frame comes out. Wiring only the
    # par gives "Not enough sources specified".
    fb.inputConnectors[0].connect(wsrc)
    fb.par.top = wsrc

    mot = c.create(glslTOP, "motion")
    mot.nodeX, mot.nodeY = -180, -100
    mot.inputConnectors[0].connect(wsrc)
    mot.inputConnectors[1].connect(fb)
    mtdat = c.create(textDAT, "motion_glsl")
    mtdat.nodeX, mtdat.nodeY = -180, -250
    mtdat.text = MOTION_GLSL
    mot.par.pixeldat = mtdat
    mot.par.format = "rgba32float"

    an_m = c.create(analyzeTOP, "mean_moments")
    an_m.nodeX, an_m.nodeY = -20, 80
    an_m.inputConnectors[0].connect(mom)
    an_m.par.op = "average"   # analyzeTOP calls it `op`, not `function`

    an_t = c.create(analyzeTOP, "mean_motion")
    an_t.nodeX, an_t.nodeY = -20, -100
    an_t.inputConnectors[0].connect(mot)
    an_t.par.op = "average"

    # --- CHOP side --------------------------------------------------------
    tc_m = c.create(toptoCHOP, "moments_chop")
    tc_m.nodeX, tc_m.nodeY = 140, 80
    tc_m.par.top = an_m
    tc_m.par.downloadtype = "nextframe"

    tc_t = c.create(toptoCHOP, "motion_chop")
    tc_t.nodeX, tc_t.nodeY = 140, -100
    tc_t.par.top = an_t
    tc_t.par.downloadtype = "nextframe"

    sc = c.create(scriptCHOP, "field")
    sc.nodeX, sc.nodeY = 300, 0
    # ⚠️ WIRED, not fetched by name — this is what makes the whole upstream
    # TOP chain cook. See the note in FIELD_SCRIPT.
    sc.inputConnectors[0].connect(tc_m)
    sc.inputConnectors[1].connect(tc_t)
    sdat = c.create(textDAT, "field_script")
    sdat.nodeX, sdat.nodeY = 300, 160
    sdat.text = FIELD_SCRIPT
    sc.par.callbacks = sdat

    nl = c.create(nullCHOP, "out_field")
    nl.nodeX, nl.nodeY = 460, 0
    nl.inputConnectors[0].connect(sc)
    nl.par.cooktype = "always"

    c.par.opviewer.expr = "op('out_field')"
    return {"comp": c.path, "ops": len(c.children)}
