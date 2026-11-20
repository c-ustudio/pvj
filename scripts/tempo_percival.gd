class_name TempoPercival
extends RefCounted
## Percival & Tzanetakis (2014) tempo estimation — "Streamlined Tempo Estimation Based
## on Autocorrelation and Cross-correlation With Pulses", IEEE/ACM TASLP 22(12).
## Structure follows Essentia's PercivalBpmEstimator; see TEMPO_PERCIVAL_SPEC.md §2.
##
## ⚠️ IMPLEMENTED FROM THE PUBLISHED METHOD. Essentia is AGPL-3.0-or-later and is not
## linked, vendored or copied — only the algorithm, which is not copyrightable.
##
## ⚠️ RUNS ON A WORKER THREAD. ~3,400 FFTs of size 1024 per 10 s of audio, in GDScript,
## on a phone already decoding 1080p into two SubViewports. This is not a workaround:
## EssentiaTD (Brito's TouchDesigner plugins over Essentia) also runs BPM extraction in
## batch on a background thread while only onset detection is real-time. Nothing here
## touches the scene tree — pass a plain PackedFloat32Array in, get a Dictionary out.
##
##   var r := TempoPercival.new().analyse(pcm, mix_rate)
##   # -> {ok, bpm, conf, lag, frames, ms}

const FFT := preload("res://scripts/fft.gd")

## ⚠️ DECIMATED TO 22.05 kHz, and the frame halved to match. A 512-point FFT at
## 22.05 kHz spans the SAME TIME and gives the SAME frequency resolution (43 Hz/bin)
## as 1024 at 44.1 kHz — so this is not a quality trade, it is the same analysis for
## ~0.45x the cost per frame. Nothing is lost: the OSS looks no higher than 8 kHz and
## 22.05 kHz leaves Nyquist at 11 kHz.
##
## That saving is what buys the 20 s window (WINDOW_SEC): twice the audio, twice the
## votes in the accumulator, at slightly LESS total cost than the old 10 s run.
const DECIMATE := 2              ## input sample-rate divisor
const FRAME := 512               ## OSS analysis window, at the decimated rate
const HOP := 128                 ## keeps the OSS at ~172 Hz, same as before
## ⚠️ Sized by TIME SPAN, not by copying Essentia's sample count. Essentia pairs
## OSS_FRAME 2048 with hop 128 (344 Hz OSS) = a 5.95 s periodicity window. With HOP
## 256 the OSS runs at 172 Hz, where 2048 samples would span 11.9 s — longer than the
## 10 s buffer, so it could never fill and every analysis returned NOT ENOUGH AUDIO.
## 1024 at 172 Hz restores the same ~5.95 s window, which is what matters musically
## (~12 beats at 120 BPM). Change this if HOP changes.
const OSS_FRAME := 1024          ## periodicity window over the OSS
const OSS_HOP := 128
const BPM_MIN := 50.0
const BPM_MAX := 210.0
## Generalized autocorrelation exponent. Plain autocorrelation is the c = 2 case;
## 0.5 flattens the spectral tilt before the inverse transform and SHARPENS the lag
## peaks, which is the single most important difference from the naive ACF engine.
const GEN_ACF_C := 0.5
const OSS_LP := 0.7              ## one-pole lowpass on the OSS (Essentia: IIR)
const MAX_PEAKS := 10
const ACC_SIGMA := 10.0          ## Gaussian spread per frame estimate, in lag bins
## ⚠️ STANDS IN FOR THE SVM OCTAVE CLASSIFIER, which is deliberately not implemented
## (its trained weights live in Essentia's source). Log-normal, in octaves. This is
## the WEAKEST point of the port: octave errors are the classic failure mode and the
## SVM is the stage the paper added to fix them. A consistent half/double result
## implicates THIS, not the OSS or the autocorrelation.
const PRIOR_CENTRE := 120.0
const PRIOR_SIGMA := 0.9

var _win: PackedFloat32Array = PackedFloat32Array()


## pcm: mono samples. sr: mix rate. Returns {ok, bpm, conf, lag, frames, ms, reason}.
func analyse(pcm_in: PackedFloat32Array, sr_in: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	if sr_in <= 0.0:
		return {"ok": false, "bpm": 0.0, "conf": 0.0, "reason": "NOT ENOUGH AUDIO",
			"frames": 0, "ms": 0}
	# ⚠️ Decimate FIRST — every downstream cost scales with the sample count. Averaging
	# pairs rather than dropping samples is a cheap anti-alias; a plain decimation would
	# fold 11-22 kHz content down onto the band the flux actually reads.
	var pcm := _decimate(pcm_in, DECIMATE)
	var sr := sr_in / float(DECIMATE)
	if pcm.size() < FRAME * 8:
		return {"ok": false, "bpm": 0.0, "conf": 0.0, "reason": "NOT ENOUGH AUDIO",
			"frames": 0, "ms": 0}

	var oss := _onset_strength(pcm)
	if oss.size() < OSS_FRAME:
		return {"ok": false, "bpm": 0.0, "conf": 0.0, "reason": "NOT ENOUGH AUDIO",
			"frames": oss.size(), "ms": Time.get_ticks_msec() - t0}

	# OSS sample rate follows the audio hop, not the frame.
	var oss_hz := sr / float(HOP)
	var lag_min := int(oss_hz * 60.0 / BPM_MAX)
	var lag_max := int(oss_hz * 60.0 / BPM_MIN)
	if lag_max >= OSS_FRAME / 2:
		lag_max = OSS_FRAME / 2 - 1
	if lag_min < 1 or lag_min >= lag_max:
		return {"ok": false, "bpm": 0.0, "conf": 0.0, "reason": "BAD LAG RANGE",
			"frames": oss.size(), "ms": Time.get_ticks_msec() - t0}

	# Accumulate one Gaussian per OSS frame, at that frame's winning lag.
	var acc := PackedFloat32Array()
	acc.resize(lag_max + 1)
	var frames := 0
	var pos := 0
	while pos + OSS_FRAME <= oss.size():
		var lag := _frame_lag(oss.slice(pos, pos + OSS_FRAME), lag_min, lag_max, oss_hz)
		if lag > 0:
			_add_gaussian(acc, lag, ACC_SIGMA)
			frames += 1
		pos += OSS_HOP

	if frames == 0:
		return {"ok": false, "bpm": 0.0, "conf": 0.0, "reason": "NO PULSE FOUND",
			"frames": 0, "ms": Time.get_ticks_msec() - t0}

	# Winner across the whole buffer, weighted by the tempo prior.
	var best := -1.0
	var best_lag := -1
	var total := 0.0
	for l: int in range(lag_min, lag_max + 1):
		var w := acc[l] * _prior(60.0 * oss_hz / float(l))
		total += w
		if w > best:
			best = w
			best_lag = l
	if best_lag <= 0:
		return {"ok": false, "bpm": 0.0, "conf": 0.0, "reason": "NO PULSE FOUND",
			"frames": frames, "ms": Time.get_ticks_msec() - t0}

	# Parabolic refinement — integer lag bins are coarse at fast tempi.
	var refined := float(best_lag)
	if best_lag > lag_min and best_lag < lag_max:
		var y0 := acc[best_lag - 1]
		var y1 := acc[best_lag]
		var y2 := acc[best_lag + 1]
		var den := y0 - 2.0 * y1 + y2
		if absf(den) > 1e-9:
			refined += clampf(0.5 * (y0 - y2) / den, -1.0, 1.0)

	# Confidence: how concentrated the accumulator is on the winner. A tempo the
	# frames agree on gives one tall spike; a guess spreads energy everywhere.
	var mean := total / float(lag_max - lag_min + 1)
	var conf := clampf((best / maxf(mean, 1e-9) - 1.0) / 8.0, 0.0, 1.0)

	# ⚠️ OCTAVE DECISION LAST, ON EVIDENCE ALONE. Stands in for the SVM classifier the
	# paper uses and this port omits (its trained weights live in Essentia's source).
	var mult := _octave_decide(oss, refined, lag_min, lag_max)
	refined /= mult

	return {"ok": true, "bpm": 60.0 * oss_hz / refined, "conf": conf, "lag": refined,
		"oct": mult, "frames": frames, "ms": Time.get_ticks_msec() - t0, "reason": ""}


## Choose between half / true / double, scoring each on the OSS itself.
##
## ⚠️ THE PRIOR IS DELIBERATELY NOT APPLIED HERE. It is what pins a genuine 174 BPM to
## 87 — log2(174/120) weights the fast candidate 0.84 against the slow one's 0.97, so a
## prior-weighted comparison can never recover a fast tempo. The prior keeps its
## per-frame job (stopping the harmonic-weight collapse that halved 120 and 130); it
## just does not get the final word on octave.
##
## ⚠️ AND NOT ON PULSE-TRAIN SCORE EITHER. That metric structurally favours SLOWER
## candidates: on a click train at period T, a 2T candidate lands its fundamental, its
## double AND its dotted term all on real beats (2.0H) while the true candidate's dotted
## term falls off-beat (1.5H). Re-using it here would reproduce the exact bug it caused.
##
## The asymmetry that DOES separate them is what each candidate misses versus wastes:
##
##   precision  mean energy AT pulse positions   -> punishes DOUBLE (hits empty slots)
##   recall     share of TOTAL energy captured   -> punishes HALF (misses every other beat)
##   score      precision * recall
##
## On an ideal click train: true 1.0*1.0 = 1.0, half 1.0*0.5 = 0.5, double 0.5*1.0 = 0.5.
## The true tempo beats BOTH neighbours, which neither of the other metrics does.
func _octave_decide(oss: PackedFloat32Array, lag: float, lag_min: int, lag_max: int) -> float:
	var total := 0.0
	for v: float in oss:
		total += v
	if total <= 0.0:
		return 1.0
	var best_mult := 1.0
	var best_score := -1.0
	for mult: float in [0.5, 1.0, 2.0]:
		var l := lag / mult          # mult 2.0 => half the lag => double the tempo
		if l < float(lag_min) or l > float(lag_max) or l < 2.0:
			continue
		var hit := 0.0
		var pulses := 0
		var pos := 0.0
		while pos < float(oss.size()):
			# ±1 bin window: beats do not land exactly on bin centres, and without
			# this the score would measure quantisation rather than rhythm.
			var c := int(pos)
			for d: int in [-1, 0, 1]:
				var i := c + d
				if i >= 0 and i < oss.size():
					hit += oss[i]
			pulses += 1
			pos += l
		if pulses == 0:
			continue
		var precision := hit / float(pulses)
		var recall := minf(hit / total, 1.0)   # the window can double-count; cap it
		var score := precision * recall
		if score > best_score:
			best_score = score
			best_mult = mult
	return best_mult


## Step 1 — Onset Strength Signal.
## spectrum -> x(1/N) -> x1000 -> +1 -> log -> half-rectified L1 flux -> lowpass.
## ⚠️ The lowpass is applied AFTER differencing. Smoothing the input instead (which is
## what a visualiser-grade analyser does) destroys the transient the flux exists to
## find — that is the suspected cause of the ACF engine's instability.
func _onset_strength(pcm: PackedFloat32Array) -> PackedFloat32Array:
	_ensure_window()
	var out := PackedFloat32Array()
	var half := FRAME / 2 + 1
	# ⚠️ BUFFERS REUSED ACROSS FRAMES. FFT.magnitude() allocates two arrays per call,
	# and this loop runs thousands of times per analysis — the allocation traffic alone
	# was a measurable share of the runtime. Everything here is allocated once.
	var re := PackedFloat32Array(); re.resize(FRAME)
	var im := PackedFloat32Array(); im.resize(FRAME)
	var mag := PackedFloat32Array(); mag.resize(half)
	var prev := PackedFloat32Array(); prev.resize(half)
	var have_prev := false
	var pos := 0
	var lp := 0.0
	var inv_n := 1.0 / float(FRAME)
	while pos + FRAME <= pcm.size():
		for i: int in FRAME:
			re[i] = pcm[pos + i] * _win[i]
			im[i] = 0.0
		FFT.transform(re, im, false)
		for i: int in half:
			# log of the scaled magnitude, per Essentia's chain: x(1/N), x1000, +1, log
			mag[i] = log(sqrt(re[i] * re[i] + im[i] * im[i]) * inv_n * 1000.0 + 1.0)
		if have_prev:
			var flux := 0.0
			for i: int in half:
				var d := mag[i] - prev[i]
				if d > 0.0:      # half-rectified: energy appearing, not decaying
					flux += d
			lp += (flux - lp) * (1.0 - OSS_LP)
			out.append(lp)
		for i: int in half:
			prev[i] = mag[i]
		have_prev = true
		pos += HOP
	return out


## Average-and-drop decimation. Cheap anti-alias — a plain "take every Nth sample"
## would fold the discarded high band down onto the range the flux reads.
func _decimate(src: PackedFloat32Array, factor: int) -> PackedFloat32Array:
	if factor <= 1:
		return src
	var n := src.size() / factor
	var out := PackedFloat32Array()
	out.resize(n)
	for i: int in n:
		var s := 0.0
		var base := i * factor
		for k: int in factor:
			s += src[base + k]
		out[i] = s / float(factor)
	return out


## One OSS frame -> the lag its pulse train best explains, or -1.
func _frame_lag(seg: PackedFloat32Array, lag_min: int, lag_max: int, oss_hz: float) -> int:
	var acf := _generalized_acf(seg)
	if acf.is_empty():
		return -1
	_enhance_harmonics(acf, lag_min, lag_max)
	var peaks := _top_peaks(acf, lag_min, lag_max, MAX_PEAKS)
	if peaks.is_empty():
		return -1
	return _evaluate_pulse_trains(seg, peaks, oss_hz)


## Generalized autocorrelation: IFFT(|FFT(x)|^c), c = GEN_ACF_C.
## Zero-padded to 2N so the correlation is linear rather than circular.
func _generalized_acf(seg: PackedFloat32Array) -> PackedFloat32Array:
	var n := seg.size()
	var m := n * 2
	var re := PackedFloat32Array()
	var im := PackedFloat32Array()
	re.resize(m)
	im.resize(m)
	# Mean-remove: autocorrelating a strictly positive signal just finds its DC term.
	var mean := 0.0
	for v: float in seg:
		mean += v
	mean /= float(n)
	for i: int in n:
		re[i] = seg[i] - mean
	FFT.transform(re, im, false)
	for i: int in m:
		var p := sqrt(re[i] * re[i] + im[i] * im[i])
		re[i] = pow(p, GEN_ACF_C * 2.0)   # |FFT|^(2c): c=0.5 -> |FFT|^1
		im[i] = 0.0
	FFT.transform(re, im, true)
	return re.slice(0, n)


## Reinforce lags that also have support at their multiples, so a true tempo beats
## its own half and double instead of losing to them at random.
func _enhance_harmonics(acf: PackedFloat32Array, lag_min: int, lag_max: int) -> void:
	var src := acf.duplicate()
	for l: int in range(lag_min, lag_max + 1):
		var s := src[l]
		for h: int in [2, 3, 4]:
			var hl := l * h
			if hl < src.size():
				s += src[hl] / float(h)
		acf[l] = s


func _top_peaks(acf: PackedFloat32Array, lag_min: int, lag_max: int, want: int) -> Array[int]:
	var found: Array[int] = []
	for l: int in range(lag_min + 1, lag_max):
		if acf[l] > acf[l - 1] and acf[l] >= acf[l + 1] and acf[l] > 0.0:
			found.append(l)
	found.sort_custom(func(a: int, b: int) -> bool: return acf[a] > acf[b])
	return found.slice(0, mini(want, found.size()))


## The step a plain ACF peak-pick lacks: score each candidate lag by cross-correlating
## the OSS with an ideal PULSE TRAIN at that period, over every phase.
##
## ⚠️ THE HARMONIC WEIGHTS ARE THE OCTAVE DISAMBIGUATOR, and the first cut of this
## file omitted them — a flat train, phases sampled every lag/8, no variance term.
## Essentia scores each candidate using its OWN harmonic structure:
##
##     fundamental   weight 1.0   at  phase + b*period
##     double        weight 0.5   at  phase + b*period*2
##     1.5x (dotted) weight 0.5   at  phase + b*period*3/2      for b in 0..3
##
## A candidate at the true tempo collects support from its double and its dotted
## position; a half-time candidate does not. Without this the two are nearly
## indistinguishable, which is very likely a bigger cause of the synthetic 174 -> 87
## collapse than the deliberately-omitted SVM.
##
## Two scores are combined, both normalised across candidates:
##   mag  the best phase's accumulated magnitude — "is there energy on this grid"
##   var  the variance of magnitude across phases — "does it matter WHICH phase",
##        i.e. is the signal actually pulsed at this period rather than uniformly busy
const PULSES := 4                 ## pulses per train (Essentia: b in 0..3)


## ⚠️ THE PRIOR IS APPLIED HERE, PER FRAME — not only at the final accumulator.
## Measured regression that forced this: with the harmonic weights above, a click
## train at period T scores HIGHER at half-tempo. A 2T candidate lands its
## fundamental (2T, 4T…), its double (4T, 8T…) AND its 1.5x (3T, 6T…) all on real
## beats — 2.0H — while the true T candidate's 1.5x term falls OFF-beat, giving 1.5H.
## Synthetic 120 and 130 both collapsed to half. Weighting only the accumulator could
## not recover it: by then every frame had already voted half-time, so there were no
## votes at T left to prefer. The per-frame choice has to be tempo-aware, which is
## part of what the omitted SVM would otherwise be doing.
func _evaluate_pulse_trains(seg: PackedFloat32Array, candidates: Array[int], oss_hz: float) -> int:
	var n := seg.size()
	var mags: Array[float] = []
	var vars: Array[float] = []
	var sum_mag := 0.0
	var sum_var := 0.0

	for lag: int in candidates:
		if lag <= 0:
			mags.append(0.0)
			vars.append(0.0)
			continue
		var best_mag := 0.0
		var acc := 0.0
		var acc2 := 0.0
		var phases := 0
		# ⚠️ EVERY phase, not a sample. Cheap here (lag is ~40-200 bins) and the
		# variance term is meaningless if the phase axis is under-sampled.
		for phase: int in lag:
			var s := 0.0
			for b: int in PULSES:
				var i0 := phase + b * lag
				if i0 < n:
					s += seg[i0]
				var i1 := phase + b * lag * 2
				if i1 < n:
					s += seg[i1] * 0.5
				var i2 := phase + (b * lag * 3) / 2
				if i2 < n:
					s += seg[i2] * 0.5
			best_mag = maxf(best_mag, s)
			acc += s
			acc2 += s * s
			phases += 1
		mags.append(best_mag)
		var mean := acc / float(maxi(phases, 1))
		vars.append(maxf(acc2 / float(maxi(phases, 1)) - mean * mean, 0.0))
		sum_mag += best_mag
		sum_var += vars[vars.size() - 1]

	# Normalised combo, per Essentia: comboScores[i] = mag[i]/sum(mag) + var[i]/sum(var)
	var best := -INF
	var best_lag := -1
	for i: int in candidates.size():
		var lag := candidates[i]
		if lag <= 0:
			continue
		var c := mags[i] / maxf(sum_mag, 1e-9) + vars[i] / maxf(sum_var, 1e-9)
		c *= _prior(60.0 * oss_hz / float(lag))
		if c > best:
			best = c
			best_lag = lag
	return best_lag


func _add_gaussian(acc: PackedFloat32Array, centre: int, sigma: float) -> void:
	var lo := maxi(0, centre - int(sigma * 3.0))
	var hi := mini(acc.size() - 1, centre + int(sigma * 3.0))
	for i: int in range(lo, hi + 1):
		var d := float(i - centre) / sigma
		acc[i] += exp(-0.5 * d * d)


func _prior(bpm: float) -> float:
	if bpm <= 0.0:
		return 0.0
	var oct := log(bpm / PRIOR_CENTRE) / log(2.0)
	return exp(-0.5 * pow(oct / PRIOR_SIGMA, 2.0))


func _ensure_window() -> void:
	if _win.size() == FRAME:
		return
	_win.resize(FRAME)
	for i: int in FRAME:
		# Hamming, per Essentia's chain.
		_win[i] = 0.54 - 0.46 * cos(TAU * float(i) / float(FRAME - 1))


## ⚠️ HOP NOTE. The paper and Essentia use hop 128 (a 344 Hz OSS at 44.1 kHz). This
## starts at 256 (172 Hz) because hop 128 is ~3,400 FFTs per 10 s in GDScript and the
## first build must return at all before it can be tuned. `ms` is reported on every
## analysis: if there is headroom, drop HOP to 128 and re-measure. Halving the hop
## doubles both the cost and the lag resolution.
static func _note_hop() -> void:
	pass
