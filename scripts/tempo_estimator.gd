extends Node
## TempoDetect (autoload) — estimates the room's tempo from the mic, on demand.
##
## Powers the DETECT button in the manual-BPM dialog. It PROPOSES a number; it never
## applies one. Nothing here calls BeatClock.set_bpm() — only the performer pressing
## SET does that. That confirmation step IS the safety model: three confidence
## measures have failed to separate a right answer from a wrong one, so a human stays
## in the loop (AUTO_BPM_SPEC.md).
##
## ⚠️ THREE ENGINES RUN SIDE BY SIDE, so they can be compared on identical audio in a
## single device session instead of three:
##
##   IOI    onset timestamps -> interval histogram -> median of 20 per-second
##          candidates. Instant, no FFT, no thread, no buffer requirement — which is
##          why it stays: it is the FALLBACK that answers when the others cannot.
##   COMB   SpectrumAnalyzer envelope, folded at each candidate period, scored on how
##          sharply energy lands on one phase.
##   PERC   Percival/MTG-UPF: its OWN FFT from raw PCM -> generalized autocorrelation
##          -> pulse trains. Most accurate measured so far (~1%, reproducible).
##
## ⚠️ ACF WAS REMOVED, not disabled. Measured against a known 130 BPM it returned
## 68.8, 69.6, 75.0, 84.8, 85.6, 85.6 and 149.9 — 15-48% off — while reporting
## conf=1.00 on EVERY press. Its peak-vs-search-range-mean normalisation saturates
## immediately because an autocorrelation naturally decays with lag, so the peak always
## towers over the mean. An engine that is wrong is tolerable; one that is wrong and
## claims certainty is worse than none, because it poisons any agreement measure built
## on top of it.
##
## ⚠️ THE THREE INPUTS ARE DELIBERATELY DIFFERENT — onset EVENTS, a spectrum-analyser
## ENVELOPE, and raw PCM. That diversity is the point: Zapata/Davies/Gomez (MTG-UPF,
## Essentia's BeatTrackerMultiFeature) get their confidence from how much independent
## trackers AGREE, not from any tracker judging itself — which is the one thing four
## internal confidence measures have failed to do here. On the 130 test PERC and COMB
## agreed near 129 and were right; IOI sat at 134 and was the outlier. Agreement alone
## picked the winner.
##
## ⚠️ THIS FILE IS THE SWAP SEAM. The UI knows exactly one thing:
##     estimate() -> {ok, bpm, samples, reason}
## Everything below it is replaceable.
##
## ⚠️ REUSES GlobalBus. The onset stream is a read-only signal subscription and the
## spectrum is a bus effect CHAINED on the existing mic bus — neither opens a second
## mic client, which would starve audio reactivity and set recording.

## Engine keys. ⚠️ Deliberately strings, not an enum — `enum Engine` shadows Godot's
## native Engine class and will not compile. They also double as the dialog's button
## labels, so the UI and the estimator cannot drift apart.
const ENGINES := ["ioi", "comb", "perc"]
## Which engine estimate() proposes when the caller does not name one. The fallback
## lever: set to "ioi" to return to the measured, shipped algorithm.
const DEFAULT_ENGINE := "perc"

# --- shared tempo search range + prior ------------------------------------
const BPM_LO := 60.0
const BPM_HI := 200.0
## Log-normal prior centred on 120 BPM. This replaces the old hard 90-180 fold band:
## instead of forcing every answer into one octave (which pushed genuine 79-85 BPM
## material up to 158-170), it just makes tempi near 120 cheaper to believe. A strong
## peak at 75 can still win.
const PRIOR_CENTRE := 120.0
const PRIOR_SIGMA := 0.9        ## in octaves

# --- envelope (COMB) -----------------------------------------------------
## Fixed-rate bins, NOT per-frame samples. ⚠️ _process runs at the render rate and
## jitters with vsync; autocorrelation needs uniform spacing or the lag axis is a lie.
## Flux is accumulated into 10 ms bins by timestamp, so the envelope is 100 Hz
## regardless of frame rate — ~50x the data rate of the onset stream.
const ENV_HZ := 100.0
const ENV_SEC := 12.0
const ENV_BINS := int(ENV_HZ * ENV_SEC)
const BANDS := 24               ## log-spaced analysis bands
const BAND_LO_HZ := 40.0
const BAND_HI_HZ := 8000.0
const MIN_ENV_FILL := 400       ## bins needed before COMB will answer (~4 s)

# --- IOI engine (the shipped algorithm, unchanged) ------------------------
const CAND_WINDOW_SEC := 12.0
const CAND_PERIOD_SEC := 1.0
const CAND_HISTORY := 20
const MIN_ONSETS := 6
const MIN_IOI := 20
const TOL := 0.06
const MAX_LAG := 3
const IOI_MIN := 0.2
const IOI_MAX := 2.0
const FOLD_LO_BPM := 90.0
const FOLD_HI_BPM := 180.0
const MIN_SAMPLES := 8

var _onsets: Array[float] = []
var _cands: Array[float] = []
var _accum: float = 0.0

var _env: Array[float] = []        ## onset-strength envelope, ENV_HZ bins
var _bands_prev: Array[float] = []
var _bin_index: int = -1
var _bin_accum: float = 0.0
var _band_edges: Array[float] = []


func _ready() -> void:
	GlobalBus.beat.connect(_on_onset)
	_env.resize(ENV_BINS)
	_env.fill(0.0)
	_bands_prev.resize(BANDS)
	_bands_prev.fill(0.0)
	# Log-spaced edges: pitch, not Hz, is what musical energy is spaced by.
	for i: int in BANDS + 1:
		var t := float(i) / float(BANDS)
		_band_edges.append(BAND_LO_HZ * pow(BAND_HI_HZ / BAND_LO_HZ, t))


func _on_onset() -> void:
	_onsets.append(_now())


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(delta: float) -> void:
	_pump_envelope()
	_accum += delta
	if _accum < CAND_PERIOD_SEC:
		return
	_accum = 0.0
	var cutoff := _now() - CAND_WINDOW_SEC
	while not _onsets.is_empty() and _onsets[0] < cutoff:
		_onsets.pop_front()
	var c := _ioi_candidate()
	if c > 0.0:
		_cands.append(c)
	elif not _cands.is_empty():
		# Silence drops the OLDEST candidate rather than holding stale ones — else a
		# stopped track leaves a full history and DETECT proposes music that is no
		# longer playing.
		_cands.pop_front()
	while _cands.size() > CAND_HISTORY:
		_cands.pop_front()


## Spectral flux -> fixed-rate envelope. Sums only the POSITIVE change per band:
## energy appearing is an onset, energy decaying is not, and counting both would make
## every sustained note read as a beat.
func _pump_envelope() -> void:
	var sp := GlobalBus.spectrum()
	if sp == null:
		return
	var flux := 0.0
	for b: int in BANDS:
		var mag := sp.get_magnitude_for_frequency_range(_band_edges[b], _band_edges[b + 1],
			AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_AVERAGE).length()
		# Log domain: loudness is multiplicative, so a linear difference would let one
		# loud band dominate the whole envelope.
		var d := log(mag + 1e-6) - log(_bands_prev[b] + 1e-6)
		if d > 0.0:
			flux += d
		_bands_prev[b] = mag
	var idx := int(_now() * ENV_HZ)
	if _bin_index < 0:
		_bin_index = idx
	if idx == _bin_index:
		_bin_accum += flux
		return
	# Bin boundary crossed — commit, then zero-fill any bins we skipped so the time
	# axis stays uniform even if a frame took longer than one bin.
	_env.push_back(_bin_accum)
	for _skip: int in mini(idx - _bin_index - 1, ENV_BINS):
		_env.push_back(0.0)
	while _env.size() > ENV_BINS:
		_env.pop_front()
	_bin_index = idx
	_bin_accum = flux


# ── THE SWAP SEAM ────────────────────────────────────────────────────────────
## Propose a tempo, or explain why not. The ONLY thing the UI calls.
func estimate() -> Dictionary:
	return estimate_all()[DEFAULT_ENGINE]


## All engines, for side-by-side logging on the same audio.
##
## ⚠️ PERC is NOT computed here. It takes ~1 s of FFTs and would stall the deck; it
## runs on a worker thread via start_percival() and reports through percival_ready.
## What it returns here is the LAST completed run, or a pending/idle marker.
func estimate_all() -> Dictionary:
	return {"ioi": _est_ioi(), "comb": _est_comb(), "perc": _perc_last()}


# ── engine D: Percival, on a worker thread ───────────────────────────────────
# TEMPO_PERCIVAL_SPEC.md. Everything else here answers instantly from data already
# collected; this one has to do real work, so it is the only asynchronous engine.

signal percival_ready(result: Dictionary)

## Audio analysed per run. ⚠️ The decimation in tempo_percival.gd bought this: twice
## the window at slightly LESS total cost than the old 10 s run. Must not exceed
## GlobalBus.PCM_RING_SEC or pcm_tail() can never satisfy it.
const PERC_SEC := 20.0

var _perc_thread: Thread = null
var _perc_result: Dictionary = {}
var _perc_running: bool = false


## Kick off a Percival analysis. Returns false if it could not start (already running,
## or not enough audio buffered yet). The result arrives on percival_ready.
func start_percival() -> bool:
	if _perc_running:
		return false
	var pcm := GlobalBus.pcm_tail(PERC_SEC)
	if pcm.is_empty():
		_perc_result = {"ok": false, "bpm": 0.0, "conf": 0.0,
			"reason": "NEED %.0f s AUDIO (HAVE %.1f)" % [PERC_SEC, GlobalBus.pcm_seconds()]}
		return false
	var sr := AudioServer.get_mix_rate()
	_perc_running = true
	_perc_thread = Thread.new()
	# ⚠️ The thread gets a COPY of the samples (pcm_tail slices), so it never touches
	# the live ring the audio thread is appending to.
	_perc_thread.start(_perc_worker.bind(pcm, sr))
	return true


func percival_running() -> bool:
	return _perc_running


func _perc_worker(pcm: PackedFloat32Array, sr: float) -> void:
	var r := TempoPercival.new().analyse(pcm, sr)
	_perc_done.call_deferred(r)


## Back on the main thread: join the worker and publish.
func _perc_done(r: Dictionary) -> void:
	if _perc_thread != null:
		_perc_thread.wait_to_finish()
		_perc_thread = null
	_perc_running = false
	_perc_result = r
	percival_ready.emit(r)


func _perc_last() -> Dictionary:
	if _perc_running:
		return {"ok": false, "bpm": 0.0, "conf": 0.0, "reason": "ANALYSING…"}
	if _perc_result.is_empty():
		return {"ok": false, "bpm": 0.0, "conf": 0.0, "reason": "NOT RUN YET"}
	return _perc_result


func sample_count() -> int:
	return _cands.size()


# ── engine A: IOI histogram (the shipped, measured algorithm) ────────────────

func _est_ioi() -> Dictionary:
	if _cands.size() < MIN_SAMPLES:
		return _no("NOT ENOUGH AUDIO — TAP OR TYPE", _cands.size())
	# Median, not mean: the candidate stream contains wild excursions (measured up to
	# 167 on a 130 track) and a mean would follow them.
	return {"ok": true, "bpm": _median(_cands), "samples": _cands.size(),
		"conf": 0.0, "reason": ""}


func _ioi_candidate() -> float:
	if _onsets.size() < MIN_ONSETS:
		return 0.0
	var raw := _intervals()
	if raw.size() < MIN_IOI:
		return 0.0
	var folded: Array[float] = []
	for t: float in raw:
		folded.append(_fold(t))
	var period := _mode(folded)
	return 60.0 / period if period > 0.0 else 0.0


func _intervals() -> Array[float]:
	var out: Array[float] = []
	for lag: int in range(1, MAX_LAG + 1):
		for i: int in range(_onsets.size() - lag):
			var d := _onsets[i + lag] - _onsets[i]
			if d >= IOI_MIN and d <= IOI_MAX:
				out.append(d)
	return out


func _fold(t: float) -> float:
	var lo := 60.0 / FOLD_HI_BPM
	var hi := 60.0 / FOLD_LO_BPM
	var v := t
	var guard := 0
	while v < lo and guard < 8:
		v *= 2.0
		guard += 1
	while v > hi and guard < 8:
		v *= 0.5
		guard += 1
	return v


func _mode(vals: Array[float]) -> float:
	if vals.is_empty():
		return 0.0
	var best_i := -1
	var best := 0
	for i: int in vals.size():
		var c := 0
		for j: int in vals.size():
			if absf(vals[j] - vals[i]) <= vals[i] * TOL:
				c += 1
		if c > best:
			best = c
			best_i = i
	if best_i < 0:
		return 0.0
	var sum := 0.0
	var cnt := 0
	for j: int in vals.size():
		if absf(vals[j] - vals[best_i]) <= vals[best_i] * TOL:
			sum += vals[j]
			cnt += 1
	return sum / float(cnt)



# ── engine C: phase-folding comb (Option 3) ──────────────────────────────────

## Folds the envelope at each candidate period and measures how sharply energy
## concentrates at ONE phase. A different question from PERC's autocorrelation, so it
## fails differently — which is why both are worth measuring.
func _est_comb() -> Dictionary:
	var e := _env_rect()
	if e.is_empty():
		return _no("NOT ENOUGH AUDIO — TAP OR TYPE", 0)
	const PHASES := 16
	var best_bpm := 0.0
	var best := -INF
	var acc := 0.0
	var n := 0
	# Sweep BPM directly rather than integer lags — folding takes a float period, so
	# resolution is not limited by the bin rate.
	var bpm := BPM_LO
	while bpm <= BPM_HI:
		var period_bins := 60.0 / bpm * ENV_HZ
		var bins: Array[float] = []
		bins.resize(PHASES)
		bins.fill(0.0)
		for i: int in e.size():
			var ph := int(fmod(float(i), period_bins) / period_bins * float(PHASES)) % PHASES
			bins[ph] += e[i]
		var mx := 0.0
		var sm := 0.0
		for v: float in bins:
			mx = maxf(mx, v)
			sm += v
		var mean := sm / float(PHASES)
		var peakiness := mx / maxf(mean, 1e-9)
		var w := peakiness * _prior(bpm)
		acc += w
		n += 1
		if w > best:
			best = w
			best_bpm = bpm
		bpm += 1.0
	if n == 0 or best_bpm <= 0.0:
		return _no("NO TEMPO FOUND", 0)
	var mean_all := acc / float(n)
	var conf := clampf((best / maxf(mean_all, 1e-9) - 1.0) / 1.0, 0.0, 1.0)
	return {"ok": true, "bpm": best_bpm, "samples": e.size(), "conf": conf, "reason": ""}


# ── shared helpers ───────────────────────────────────────────────────────────

## Log-normal weight in OCTAVES. Makes tempi near PRIOR_CENTRE cheaper to believe
## without forbidding anything, unlike the IOI engine's hard fold band.
func _prior(bpm: float) -> float:
	if bpm <= 0.0:
		return 0.0
	var oct := log(bpm / PRIOR_CENTRE) / log(2.0)
	return exp(-0.5 * pow(oct / PRIOR_SIGMA, 2.0))


## Filled part of the envelope, rectified (never negative).
func _env_rect() -> Array[float]:
	var out: Array[float] = []
	for v: float in _env:
		if v > 0.0:
			out.append(v)
		else:
			out.append(0.0)
	if _nonzero(out) < MIN_ENV_FILL:
		return [] as Array[float]
	return out


## Mean-removed envelope — autocorrelation of a strictly positive signal is dominated
## by its DC component and would peak at lag 0 regardless of any rhythm.
func _env_centred() -> Array[float]:
	var e := _env_rect()
	if e.is_empty():
		return e
	var m := 0.0
	for v: float in e:
		m += v
	m /= float(e.size())
	var out: Array[float] = []
	for v: float in e:
		out.append(v - m)
	return out


func _nonzero(a: Array[float]) -> int:
	var k := 0
	for v: float in a:
		if v > 0.0:
			k += 1
	return k


func _no(reason: String, samples: int) -> Dictionary:
	return {"ok": false, "bpm": 0.0, "samples": samples, "conf": 0.0, "reason": reason}


func _median(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	var m := s.size() / 2
	return s[m] if s.size() % 2 == 1 else (s[m - 1] + s[m]) * 0.5
