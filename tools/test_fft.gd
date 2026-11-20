extends SceneTree

const FFT := preload("res://scripts/fft.gd")
## ⚠️ THROWAWAY TEST — verifies scripts/fft.gd before the Percival engine builds on it.
## A subtly wrong FFT would silently poison the OSS, the autocorrelation and every
## number downstream, so this runs first.
##   godot --headless --script tools/test_fft.gd

func _init() -> void:
	var fails := 0
	fails += _t_roundtrip(64)
	fails += _t_roundtrip(1024)
	fails += _t_sine(1024, 8)
	fails += _t_sine(1024, 137)
	fails += _t_dc(256)
	fails += _t_parseval(512)
	fails += _t_autocorr_delta(256)
	print("FFT TEST: %s (%d failures)" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(fails)


## IFFT(FFT(x)) must return x.
func _t_roundtrip(n: int) -> int:
	var re := PackedFloat32Array()
	var im := PackedFloat32Array()
	re.resize(n); im.resize(n)
	seed(12345)
	var orig := PackedFloat32Array()
	for i: int in n:
		var v := randf() * 2.0 - 1.0
		re[i] = v
		orig.append(v)
	FFT.transform(re, im, false)
	FFT.transform(re, im, true)
	var worst := 0.0
	for i: int in n:
		worst = maxf(worst, absf(re[i] - orig[i]))
	var ok := worst < 1e-4
	print("  roundtrip n=%-5d worst err %.9f  %s" % [n, worst, "ok" if ok else "FAIL"])
	return 0 if ok else 1


## A pure sine at bin k must put all its energy in bin k.
func _t_sine(n: int, k: int) -> int:
	var f := PackedFloat32Array()
	f.resize(n)
	for i: int in n:
		f[i] = sin(TAU * float(k) * float(i) / float(n))
	var mag := FFT.magnitude(f)
	var peak := 0
	for i: int in mag.size():
		if mag[i] > mag[peak]:
			peak = i
	# energy outside the peak bin should be negligible
	var leak := 0.0
	for i: int in mag.size():
		if absi(i - k) > 1:
			leak = maxf(leak, mag[i])
	var ok := peak == k and leak < mag[peak] * 0.01
	print("  sine n=%d k=%-4d -> peak bin %-4d leak %.9f  %s" % [n, k, peak, leak, "ok" if ok else "FAIL"])
	return 0 if ok else 1


## Constant signal -> all energy in bin 0.
func _t_dc(n: int) -> int:
	var f := PackedFloat32Array()
	f.resize(n)
	f.fill(1.0)
	var mag := FFT.magnitude(f)
	var ok := absf(mag[0] - float(n)) < 1e-2 and mag[1] < 1e-2
	print("  dc   n=%-5d bin0 %.2f (want %d) bin1 %.9f  %s" % [n, mag[0], n, mag[1], "ok" if ok else "FAIL"])
	return 0 if ok else 1


## Parseval: sum|x|^2 == (1/n) sum|X|^2. Catches scaling errors the other tests miss.
func _t_parseval(n: int) -> int:
	var re := PackedFloat32Array(); var im := PackedFloat32Array()
	re.resize(n); im.resize(n)
	seed(999)
	var e_time := 0.0
	for i: int in n:
		var v := randf() * 2.0 - 1.0
		re[i] = v
		e_time += v * v
	FFT.transform(re, im, false)
	var e_freq := 0.0
	for i: int in n:
		e_freq += re[i] * re[i] + im[i] * im[i]
	e_freq /= float(n)
	var ok := absf(e_time - e_freq) / maxf(e_time, 1e-9) < 1e-3
	print("  parseval n=%-4d time %.4f  freq %.4f  %s" % [n, e_time, e_freq, "ok" if ok else "FAIL"])
	return 0 if ok else 1


## The path the Percival engine actually uses: autocorrelation via IFFT(|FFT|^2).
## A periodic impulse train must autocorrelate to peaks at multiples of its period.
func _t_autocorr_delta(n: int) -> int:
	const PERIOD := 16
	var re := PackedFloat32Array(); var im := PackedFloat32Array()
	re.resize(n); im.resize(n)
	for i: int in n:
		re[i] = 1.0 if i % PERIOD == 0 else 0.0
	FFT.transform(re, im, false)
	for i: int in n:
		var p := re[i] * re[i] + im[i] * im[i]
		re[i] = p
		im[i] = 0.0
	FFT.transform(re, im, true)
	# lag PERIOD should be a strong peak; lag PERIOD/2 should not be
	var ok := re[PERIOD] > re[PERIOD / 2] * 4.0 and re[PERIOD] > 0.0
	print("  autocorr period=%d -> acf[%d]=%.2f acf[%d]=%.2f  %s"
		% [PERIOD, PERIOD, re[PERIOD], PERIOD / 2, re[PERIOD / 2], "ok" if ok else "FAIL"])
	return 0 if ok else 1
