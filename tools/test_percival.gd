extends SceneTree
## ⚠️ THROWAWAY TEST — exercises scripts/tempo_percival.gd on SYNTHETIC audio with a
## known tempo, before spending an export+install cycle on the phone.
##
## Synthetic clicks are the easiest possible input: if the engine cannot recover the
## tempo of a clean impulse train it will certainly not recover Arca's. A pass here
## is necessary, not sufficient — real music is the actual test.
##
##   godot --headless --script tools/test_percival.gd

const Percival := preload("res://scripts/tempo_percival.gd")

const SR := 44100.0
const SECS := 20.0   # matches TempoDetect.PERC_SEC


func _init() -> void:
	var fails := 0
	for bpm: float in [90.0, 120.0, 130.0, 85.0, 174.0]:
		fails += _t(bpm, 0.0)
	# With noise, to check it is not relying on silence between clicks.
	fails += _t(128.0, 0.05)
	fails += _t_noise_only()
	print("PERCIVAL TEST: %s (%d failures)" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(fails)


func _t(bpm: float, noise: float) -> int:
	var pcm := _clicks(bpm, noise)
	var r := Percival.new().analyse(pcm, SR)
	if not bool(r["ok"]):
		print("  %6.1f BPM -> FAILED (%s)" % [bpm, str(r["reason"])])
		return 1
	var got: float = r["bpm"]
	# Accept the true tempo OR a clean octave of it — the SVM octave classifier is
	# deliberately not implemented (TEMPO_PERCIVAL_SPEC.md §3), so half/double is a
	# KNOWN weakness and must not be scored as a total failure here.
	var err := absf(got - bpm) / bpm
	var err2 := absf(got - bpm * 2.0) / (bpm * 2.0)
	var errh := absf(got - bpm * 0.5) / (bpm * 0.5)
	var best := minf(err, minf(err2, errh))
	var tag := "exact" if best == err else ("DOUBLE" if best == err2 else "HALF")
	var ok := best < 0.04
	print("  %6.1f BPM noise=%.2f -> %7.2f  conf %.2f  oct x%.1f  frames %-4d %6d ms  [%s %.1f%%]  %s"
		% [bpm, noise, got, float(r["conf"]), float(r.get("oct", 1.0)), int(r["frames"]),
		   int(r["ms"]), tag, best * 100.0, "ok" if ok else "FAIL"])
	return 0 if ok else 1


## Noise with no pulse must NOT come back confident — the dangerous failure mode.
func _t_noise_only() -> int:
	var n := int(SR * SECS)
	var pcm := PackedFloat32Array()
	pcm.resize(n)
	seed(4242)
	for i: int in n:
		pcm[i] = (randf() * 2.0 - 1.0) * 0.2
	var r := Percival.new().analyse(pcm, SR)
	var conf := float(r.get("conf", 0.0))
	var ok := (not bool(r["ok"])) or conf < 0.5
	print("  white noise      -> %s conf %.2f  %s"
		% [("%.1f" % float(r.get("bpm", 0.0))) if bool(r["ok"]) else "--", conf,
		   "ok" if ok else "FAIL (confident on noise)"])
	return 0 if ok else 1


## Impulse train at `bpm`: each click is a short exponentially-decaying noise burst,
## so it has broadband content for the spectral flux to see.
func _clicks(bpm: float, noise: float) -> PackedFloat32Array:
	var n := int(SR * SECS)
	var pcm := PackedFloat32Array()
	pcm.resize(n)
	seed(1234)
	if noise > 0.0:
		for i: int in n:
			pcm[i] = (randf() * 2.0 - 1.0) * noise
	var period := SR * 60.0 / bpm
	var t := 0.0
	while t < float(n):
		var start := int(t)
		for k: int in 900:
			var idx := start + k
			if idx >= n:
				break
			var env := exp(-float(k) / 120.0)
			pcm[idx] += (randf() * 2.0 - 1.0) * env
		t += period
	return pcm
