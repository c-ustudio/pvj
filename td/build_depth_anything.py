"""D1 8b — a DepthAnything TOP for TouchDesigner via onnxruntime-DirectML.

Run from a Text DAT in TD, or over the tdmcp bridge:

    exec(open(r'<repo>/td/build_depth_anything.py').read(), globals())
    build(repo=r'<repo>')

Builds `/project1/pvj_depth_anything`: any TOP in, a relative depth map out
(single-channel depth replicated to RGB so it is legible in a viewer; the
reduction in `pvj_depth_field` reads .r).
⚠️ Built over the bridge — TD needs a manual SAVE to persist it.

WHY NOT THE TENSORRT .tox
-------------------------
`olegchomp/TDDepthAnything` is installed on this machine and does not run on
it: no engine was ever built, its venv is pinned to cu118/TRT 9, this box is
an RTX 5080 (Blackwell, sm_120), and its extension calls the TRT 9 binding API
that TRT 10 removed. Rather than chase that, this drives the ONNX **already on
disk** through onnxruntime-DirectML — no CUDA toolkit, no engine build, no
architecture pin, and it runs on any DX12 GPU including AMD and Intel. For a
tool meant to ship to other people's machines, vendor-neutral is not a
consolation prize; it is the requirement. TensorRT stays available as a later
speed option if one venue's rig ever needs it.

⚠️ TWO MEASURED FACTS THAT ARE NOT GUESSABLE (2026-09-10, RTX 5080 laptop)
--------------------------------------------------------------------------
1. **DirectML adapter 0 IS NOT THE FAST GPU HERE.** device_id 0 is the AMD
   890M iGPU at **448 ms** (2.2 fps); device_id 1 is the RTX 5080 at **34 ms**
   (29 fps). Thirteen times. onnxruntime defaults to 0, so the default is the
   iGPU and the honest-looking conclusion would have been "DirectML is too
   slow for real time" — which is false by 13x. Confirmed by watching
   nvidia-smi: device 1 drives the NVIDIA to 88%, device 0 never moves it.
   Same family as `delegate=gpu` reporting success while producing nothing
   (Session 36 §3): a configured value is not a measured one.
   ⚠️ **The id is per-machine. Re-measure on any new rig; never assume 1.**

2. **SMALLER INPUT IS SLOWER.** Measured both ascending and descending, 25
   warmup runs, median of 30:

       238x238   37.3 ms      322x322   59.8 ms
       406x406   88.9 ms      518x518   34.0 ms   <- the largest is the fastest

   518 is Depth Anything V2's native shape (37x14 patches) and hits an
   optimised kernel path; off-native shapes fall into a generic one. 406 costs
   2.6x MORE than 518 for 40% fewer pixels. **Input size is not a cost dial.**
   Same shape of finding as M8a's "1080p is a regression" — the intuition
   points the wrong way in both, and only a sweep says so.
"""

COMP = "/project1/pvj_depth_anything"

INFER_SCRIPT = '''# DepthAnything via onnxruntime-DirectML. See build_depth_anything.py.
#
# ⚠️ INFERENCE RUNS ON A WORKER THREAD, AND THAT IS NOT AN OPTIMISATION.
# Measured 2026-09-10: run() takes 34 ms standalone but ~267 ms when called
# from onCook while TD is rendering — it blocks on TD's own queued GPU work.
# Synchronously, the whole show drops 60 -> 26.7 fps. Off-thread, the main
# thread pays only the readback and the copy, and the depth map simply
# arrives when it arrives. §8's law: the GPU is the contended resource, so
# never make the show's frame wait on it.
#
# The worker owns the ORT session and never touches a TD par or op — TD's
# Python API is main-thread only. Pars are read in onCook and handed over in
# a plain dict.
import sys
import threading
import numpy as np

MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32).reshape(3, 1, 1)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32).reshape(3, 1, 1)

_L = threading.Lock()
_EV = threading.Event()
_W = {
    "thread": None, "stop": False,
    "job": None,        # latest input, overwritten — a QUEUE would build a
                        # backlog and show depth from ten seconds ago
    "out": None,        # latest finished depth, bottom-up RGBA
    "cfg": None,
    "status": "idle", "ms": 0.0, "n": 0, "dev": -1, "probe": "", "busy": False,
}


def _open_session(ort, onnx, want, sample):
    """Open the ORT session, MEASURING which DirectML adapter is the fast one.

    ⚠️ THE ADAPTER INDEX MEANS DIFFERENT GPUs IN DIFFERENT PROCESSES.
    Measured 2026-09-10 on one machine, one model, minutes apart:

        standalone python:  device 0 = 448 ms   device 1 =  34 ms
        inside TouchDesigner: device 0 =  49 ms   device 1 = 502 ms

    The order is INVERTED. A number benchmarked in a scratch script and then
    wired in is not a measurement of the thing that ships — it ran the show's
    depth on the iGPU for ten times the cost while the status line read
    "dev 1", which is exactly the shape of Session 36's five lying readouts.

    So `Deviceid = -1` (the default) probes the adapters HERE, in this
    process, with this model, and keeps the fastest. Any explicit id is
    honoured as-is for when someone knows better.
    """
    import time
    so = ort.SessionOptions()
    so.log_severity_level = 3

    def build(dev):
        return ort.InferenceSession(
            onnx, so, providers=[("DmlExecutionProvider", {"device_id": dev})])

    if want >= 0:
        return build(want), want

    x = np.ascontiguousarray(sample.transpose(2, 0, 1))
    x = ((x - MEAN) / STD)[np.newaxis, ...].astype(np.float32)
    best = None
    report = []
    for dev in range(4):
        try:
            s2 = build(dev)
            s2.run(None, {"pixel_values": x})          # warm up / compile
            t0 = time.perf_counter()
            for _ in range(3):
                s2.run(None, {"pixel_values": x})
            dt = (time.perf_counter() - t0) / 3.0
            report.append("%d:%.0fms" % (dev, dt * 1000))
            if best is None or dt < best[0]:
                best = (dt, s2, dev)
            else:
                del s2
        except Exception:
            report.append("%d:x" % dev)
    with _L:
        _W["probe"] = " ".join(report)
    if best is None:
        raise RuntimeError("no usable DirectML adapter: " + " ".join(report))
    return best[1], best[2]


def _worker():
    import time
    sess = None
    key = None
    while not _W["stop"]:
        _EV.wait(0.5)
        _EV.clear()
        while True:
            with _L:
                job = _W["job"]
                _W["job"] = None
                cfg = _W["cfg"]
                _W["busy"] = job is not None
            if job is None or cfg is None:
                break
            try:
                k = (cfg["onnx"], cfg["dev"])
                if sess is None or key != k:
                    if cfg["venv"] and cfg["venv"] not in sys.path:
                        # APPENDED, never inserted: TD's own numpy must keep
                        # winning. The venv carries a newer one and two numpys
                        # in one process is a crash.
                        sys.path.append(cfg["venv"])
                    import onnxruntime as ort
                    sess, chosen = _open_session(ort, k[0], k[1], job)
                    # ⚠️ Cache against the REQUESTED key, not the chosen one.
                    # With Deviceid = -1 (auto) the request is (onnx, -1) and
                    # the result is (onnx, 0), so keying on the result meant
                    # `key != k` on every single frame — it re-probed all four
                    # adapters, every frame, for ~7 s a job. Throughput read
                    # 0.1 Hz while the per-run timer still said 222 ms,
                    # because the probe happened OUTSIDE the timed region.
                    key = k
                    with _L:
                        _W["dev"] = chosen
                t0 = time.perf_counter()
                x = np.ascontiguousarray(job.transpose(2, 0, 1))
                x = ((x - MEAN) / STD)[np.newaxis, ...].astype(np.float32)
                d = sess.run(None, {"pixel_values": x})[0][0]
                if cfg["norm"] == "minmax":
                    lo = float(d.min())
                    hi = float(d.max())
                    d = (d - lo) / (hi - lo) if hi > lo else np.zeros_like(d)
                h, w = d.shape
                o = np.empty((h, w, 4), dtype=np.float32)
                # Depth in R (what pvj_depth_field reads), mirrored to G/B so a
                # viewer shows a grey depth map instead of a red one.
                o[:, :, 0] = d
                o[:, :, 1] = d
                o[:, :, 2] = d
                o[:, :, 3] = 1.0
                o = np.ascontiguousarray(o[::-1])       # back to TD bottom-up
                with _L:
                    _W["out"] = o
                    _W["ms"] = (time.perf_counter() - t0) * 1000.0
                    _W["n"] += 1
                    _W["status"] = "ok"
            except Exception as e:
                with _L:
                    _W["status"] = "FAILED: " + str(e)[:160]
                sess = None
                key = None
            finally:
                with _L:
                    _W["busy"] = False


def _ensure_worker():
    if _W["thread"] is None or not _W["thread"].is_alive():
        _W["stop"] = False
        t = threading.Thread(target=_worker, daemon=True)
        _W["thread"] = t
        t.start()


def onCook(scriptOp):
    c = op("..")
    _ensure_worker()

    # ⚠️ HOLD THE LOCK FOR AS LITTLE AS POSSIBLE, AND NEVER OVER REAL WORK.
    # The first cut built the 3 MB input copy INSIDE this lock, 33 times a
    # second. Python locks are not fair: the worker was starved so badly it
    # completed 2 inferences in 20 seconds while cheerfully reporting
    # "248 ms/infer" — the per-run timer was honest, the throughput was 100x
    # worse, and nothing in the readout said so. Measure the RATE, not the
    # duration of the part you happened to instrument.
    with _L:
        out = _W["out"]
        status = _W["status"]
        ms = _W["ms"]
        n = _W["n"]
        dev = _W["dev"]
        probe = _W["probe"]
        busy = _W["busy"] or _W["job"] is not None

    if out is not None:
        scriptOp.copyNumpyArray(out)

    if not c.par.Active.eval() or not c.par.Onnxpath.eval():
        c.par.Status = "inactive"
        return

    # Only hand over a new frame every Nth cook. The worker is already
    # asynchronous, so this is a GPU-budget dial, not a stall guard.
    every = max(1, int(c.par.Everynframes.eval()))
    if int(absTime.frame) % every != 0:
        return

    # If the worker is still on the last frame there is nothing useful to do:
    # skip the GPU readback too, not just the handoff. A queue here would only
    # build a backlog and show depth from ten seconds ago.
    if busy:
        c.par.Status = "%s  %.0f ms/infer  n=%d  dev %d [%s]  busy" % (
            status, ms, n, dev, probe)
        return

    src = scriptOp.inputs[0] if scriptOp.inputs else None
    if src is None:
        c.par.Status = "no input"
        return
    a = src.numpyArray(delayed=True)
    if a is None:
        return
    # ⚠️ TD hands back arrays BOTTOM-UP (row 0 = bottom). The model was trained
    # on upright photographs, so it is flipped going in and flipped back on the
    # way out. Feeding it upside down does not error — it returns quietly wrong
    # depth, which is the worst kind. Verified by eye on a known scene.
    job = np.ascontiguousarray(a[::-1, :, :3])   # the copy is OUTSIDE the lock
    with _L:
        _W["job"] = job
        _W["cfg"] = {
            "onnx": c.par.Onnxpath.eval(),
            "venv": c.par.Venvpath.eval(),
            "dev": int(c.par.Deviceid.eval()),
            "norm": c.par.Normalize.eval(),
        }
    _EV.set()
    # ⚠️ Reports the device actually IN USE and the probe that chose it —
    # never the value in the par. A configured value is not a measured one.
    c.par.Status = "%s  %.0f ms/infer  n=%d  dev %d [%s]  every %d" % (
        status, ms, n, dev, probe, every)
    return
'''

def build(repo=None, parent_path="/project1",
          onnx=r"C:\path\to\depth_anything_v2_vits.onnx",
          venv=r"C:\path\to\td_depth_venv\Lib\site-packages",
          device_id=-1, insize=518):
    par = op(parent_path)
    old = par.op("pvj_depth_anything")
    if old:
        old.destroy()

    c = par.create(baseCOMP, "pvj_depth_anything")
    c.nodeX, c.nodeY = 0, -700

    p = c.appendCustomPage("Depth Anything")
    p.appendFile("Onnxpath", label="ONNX Model")[0].val = onnx
    p.appendFolder("Venvpath", label="Venv site-packages")[0].val = venv
    # -1 = probe and pick the fastest IN THIS PROCESS. See _open_session.
    p.appendInt("Deviceid", label="DirectML Device (-1 auto)")[0].val = device_id
    p.appendToggle("Active", label="Active")[0].val = True
    p.appendInt("Everynframes", label="Infer Every N Frames")[0].val = 2
    p.appendInt("Insize", label="Input Size")[0].val = insize
    p.appendMenu("Normalize", label="Normalize")[0].menuNames = ["none", "minmax"]
    c.par.Normalize.val = "minmax"
    p.appendStr("Sourcetop", label="Source TOP").val = ""
    p.appendStr("Status", label="Status").val = "(not run)"
    c.par.Everynframes.normMin, c.par.Everynframes.normMax = 1, 8
    c.par.Deviceid.normMin, c.par.Deviceid.normMax = -1, 3

    src_top = c.create(inTOP, "in1")
    src_top.nodeX, src_top.nodeY = -700, 0

    sel = c.create(selectTOP, "src")
    sel.nodeX, sel.nodeY = -550, 0
    sel.par.top.expr = "parent().par.Sourcetop.eval() or op('in1').path"

    pre = c.create(resolutionTOP, "pre")
    pre.nodeX, pre.nodeY = -400, 0
    pre.inputConnectors[0].connect(sel)
    pre.par.outputresolution = "custom"
    # ⚠️ 518 is the model's NATIVE shape and the FASTEST. Shrinking this to
    # save GPU makes it slower — measured, see the module docstring.
    pre.par.resolutionw.expr = "parent().par.Insize"
    pre.par.resolutionh.expr = "parent().par.Insize"
    pre.par.outputaspect = "resolution"
    pre.par.format = "rgba32float"

    dat = c.create(textDAT, "infer_script")
    dat.nodeX, dat.nodeY = -230, 170
    dat.text = INFER_SCRIPT

    st = c.create(scriptTOP, "infer")
    st.nodeX, st.nodeY = -230, 0
    st.inputConnectors[0].connect(pre)
    st.par.callbacks = dat
    st.par.format = "rgba32float"

    nl = c.create(nullTOP, "out_depth")
    nl.nodeX, nl.nodeY = -60, 0
    nl.inputConnectors[0].connect(st)

    o = c.create(outTOP, "out1")
    o.nodeX, o.nodeY = 100, 0
    o.inputConnectors[0].connect(nl)

    c.par.opviewer.expr = "op('out_depth')"
    return {"comp": c.path, "ops": len(c.children)}
