class_name FFT
extends RefCounted
## Iterative radix-2 FFT / IFFT over PackedFloat32Array pairs (re, im).
##
## Godot exposes no FFT to GDScript. AudioEffectSpectrumAnalyzer exists but is a
## VISUALISER — its magnitudes are smoothed, which blunts exactly the transient a
## spectral-flux onset detector needs (see TEMPO_PERCIVAL_SPEC.md §1). The Percival
## engine therefore computes its own spectrum from raw PCM, and this is that.
##
## Deliberately dependency-free and static so it can be exercised off-device:
##   var re := PackedFloat32Array([...]); var im := ...
##   FFT.transform(re, im, false)
##
## ⚠️ Size must be a power of two. Everything here is in-place.

## Precomputed bit-reversal and twiddles, keyed by size. ⚠️ Load-bearing for speed:
## the Percival OSS does ~3,400 transforms of the same size per analysis, so
## recomputing sin/cos per call would dominate the runtime.
static var _rev_cache: Dictionary = {}
static var _tw_cache: Dictionary = {}


static func is_pow2(n: int) -> bool:
	return n > 0 and (n & (n - 1)) == 0


## In-place FFT (inverse = false) or IFFT (inverse = true, scaled by 1/n).
static func transform(re: PackedFloat32Array, im: PackedFloat32Array, inverse: bool) -> void:
	var n := re.size()
	if n < 2 or not is_pow2(n) or im.size() != n:
		return

	# --- bit-reversal permutation ---
	var rev: PackedInt32Array = _rev_cache.get(n, PackedInt32Array())
	if rev.is_empty():
		rev = _build_rev(n)
		_rev_cache[n] = rev
	for i: int in n:
		var j: int = rev[i]
		if j > i:
			var tr := re[i]; re[i] = re[j]; re[j] = tr
			var ti := im[i]; im[i] = im[j]; im[j] = ti

	# --- butterflies ---
	# Twiddles are stored for the FORWARD transform; the inverse just flips the sign
	# of the imaginary part, so one table serves both.
	var tw: PackedFloat32Array = _tw_cache.get(n, PackedFloat32Array())
	if tw.is_empty():
		tw = _build_tw(n)
		_tw_cache[n] = tw
	var sign := 1.0 if inverse else -1.0
	var size := 2
	var tw_off := 0
	while size <= n:
		var half := size >> 1
		var step := n / size
		var i := 0
		while i < n:
			var k := 0
			for j: int in range(i, i + half):
				var wr := tw[tw_off + k * 2]
				var wi := tw[tw_off + k * 2 + 1] * sign
				var jh := j + half
				var xr := re[jh] * wr - im[jh] * wi
				var xi := re[jh] * wi + im[jh] * wr
				re[jh] = re[j] - xr
				im[jh] = im[j] - xi
				re[j] += xr
				im[j] += xi
				k += step
			i += size
		tw_off += n
		size <<= 1

	if inverse:
		var inv := 1.0 / float(n)
		for i2: int in n:
			re[i2] *= inv
			im[i2] *= inv


## Magnitude spectrum of a real signal, bins 0..n/2 inclusive.
## Convenience for the OSS: the caller supplies a windowed real frame.
static func magnitude(real_frame: PackedFloat32Array) -> PackedFloat32Array:
	var n := real_frame.size()
	var out := PackedFloat32Array()
	if not is_pow2(n):
		return out
	var re := real_frame.duplicate()
	var im := PackedFloat32Array()
	im.resize(n)
	transform(re, im, false)
	out.resize(n / 2 + 1)
	for i: int in out.size():
		out[i] = sqrt(re[i] * re[i] + im[i] * im[i])
	return out


static func _build_rev(n: int) -> PackedInt32Array:
	var rev := PackedInt32Array()
	rev.resize(n)
	var bits := 0
	var t := n
	while t > 1:
		bits += 1
		t >>= 1
	for i: int in n:
		var x := i
		var r := 0
		for _b: int in bits:
			r = (r << 1) | (x & 1)
			x >>= 1
		rev[i] = r
	return rev


## Twiddles for every stage, concatenated: stage `size` occupies one block of n
## floats (n/2 complex pairs, only the first n/(2*step) of which are read).
static func _build_tw(n: int) -> PackedFloat32Array:
	var tw := PackedFloat32Array()
	var stages := 0
	var s := 2
	while s <= n:
		stages += 1
		s <<= 1
	tw.resize(stages * n)
	var off := 0
	s = 2
	while s <= n:
		var half := s >> 1
		var step := n / s
		for k: int in range(0, half * step, step):
			var ang := -TAU * float(k) / float(n)
			tw[off + k * 2] = cos(ang)
			tw[off + k * 2 + 1] = sin(ang)
		off += n
		s <<= 1
	return tw
