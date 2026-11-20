extends Node
## ⚠️ THROWAWAY SPIKE v2 — AUTO_BPM_SPEC.md. DELETE BEFORE SHIPPING.
##
## Still LOGS ONLY: never calls BeatClock.set_bpm(), never touches the deck, never
## writes a file, opens no mic client of its own (reads GlobalBus.beat, which is
## single-consumer here — a second AudioEffectCapture would starve reactivity).
## Removal is deleting this file and its one line in project.godot's [autoload].
##
## ── WHY v2 ────────────────────────────────────────────────────────────────────
## v1 (3885b3a) measured on device: it found 130.4 against a true 130 and held
## sd 0.8 for ten seconds, so the tempo IS in the onset stream. It failed on two
## specific things, both addressed here:
##
##   1. conf DID NOT DISCRIMINATE. It was supporters/total — a share of the pie,
##      not "is there a peak". Correct-vs-wrong medians came out 0.34 vs 0.32,
##      and a gate at 0.45 reached only 64% precision (a coin flip). Worse, it was
##      unbounded at low interval counts: conf=1.00 on TWO agreeing intervals.
##   2. NO COMMITMENT. Every second was independent, so brief evidence swings
##      became reported tempo swings — including seven consecutive seconds at 167
##      on a 130 track. Offline tests proved smoothing cannot fix this: a 15 s
##      rolling median still left sd 11.1.
##
## ── WHAT CHANGED ──────────────────────────────────────────────────────────────
##   HARD GATE   ioi >= MIN_IOI or the state is IDLE and nothing is emitted. This
##               alone kills the conf=1.00-on-2-intervals artefact.
##   SHARPNESS   peak support measured against the histogram's OWN BACKGROUND
##               (median support), so a flat distribution scores ~1 and a real
##               peak scores 3-10. This is the discriminator v1 lacked: Arca's
##               flat histogram and the techno's real peak scored IDENTICALLY
##               under supporters/total.
##   AGREEMENT   does the candidate persist across recent seconds
##   LOCK        a three-state machine that COMMITS, with hysteresis, so a
##               short-lived challenger cannot move a good lock
##
## ⚠️ THE COMPONENTS ARE LOGGED SEPARATELY, NOT JUST THE VERDICT. sharp, agree and
## ioi appear on every line alongside conf. If this weighting is wrong we re-derive
## a better one OFFLINE from the captured logs — no rebuild, no second device
## session. "Validated, not just computed" needs the raw parts to stay visible.
##
## ⚠️ READING THE LOG: a lock stage makes ANY estimator look better by eye, because
## the number stops moving. Stability is not correctness — if it locks to 167 it
## will sit there just as confidently as at 130. That is why the locked value and
## the live candidate are printed SIDE BY SIDE. Judge it on
##   (a) does the LOCKED value match ground truth, and
##   (b) does beatless material stay OUT of LOCKED.
## Not on "did it stop wobbling".
##
##   adb -s <dev> logcat -s godot:* | grep BPMSpike
##
##   [BPMSpike] LOCKED bpm=130.4 conf=0.82 held=14s | cand=131.1 sharp=4.2 agree=0.83 ioi=91
##   [BPMSpike] SEARCH cand=118.6 conf=0.11 sharp=1.3 agree=0.33 ioi=64 n=31
##   [BPMSpike] IDLE   ioi=6 n=4 lvl=0.94

const ENABLED := true

# --- tuning (all of it here, so a re-tune is a one-line ask) --------------
const WINDOW_SEC := 12.0       ## was 6.0 — roughly doubles interval counts so the ioi gate can bite
const REPORT_SEC := 1.0
const MIN_ONSETS := 6
const MIN_IOI := 20            ## ⚠️ HARD GATE. Below this: IDLE, emit nothing.
const TOL := 0.06              ## mode tolerance, RELATIVE
const MAX_LAG := 3             ## intervals at lag 1..N (a missed onset hides the period from lag 1)
const IOI_MIN := 0.2
const IOI_MAX := 2.0
const PRIOR_LO_BPM := 90.0     ## fold band; HI must be exactly 2x LO or folding is ambiguous
const PRIOR_HI_BPM := 180.0

# --- confidence ----------------------------------------------------------
## sharpness of 1.0 = flat (no peak); SHARP_FULL = the ratio that scores 1.0.
const SHARP_FULL := 4.0
const AGREE_TOL := 0.03        ## two estimates "agree" within 3%
const AGREE_HIST := 6          ## seconds of candidate history for the agreement test

# --- lock ----------------------------------------------------------------
const LOCK_SHARP := 0.5        ## sharp_score needed to lock (and to challenge a lock)
const LOCK_AGREE := 0.66       ## ~4 of the last 6 must agree
const LOCK_MIN_HIST := 4       ## don't lock off fewer than this many candidates
const RELOCK_SEC := 8          ## consecutive QUALITY disagreements needed to move a lock
const DROP_SEC := 10           ## consecutive IDLE seconds before a lock is released

enum State { IDLE, SEARCH, LOCKED }
const STATE_NAMES := ["IDLE  ", "SEARCH", "LOCKED"]

var _onsets: Array[float] = []
var _accum: float = 0.0
var _cand_hist: Array[float] = []   ## recent candidate BPMs (agreement test)
var _state: int = State.SEARCH
var _lock_bpm: float = 0.0
var _lock_held: int = 0             ## seconds the current lock has stood
var _challenge: Array[float] = []   ## consecutive QUALITY candidates disagreeing with the lock
var _idle_run: int = 0              ## consecutive seconds under the ioi gate


func _ready() -> void:
	if not ENABLED:
		set_process(false)
		return
	GlobalBus.beat.connect(_on_onset)
	print("[BPMSpike] armed v2 — window=%.0fs min_ioi=%d sharp_full=%.1f lock(sharp>=%.2f agree>=%.2f) relock=%ds prior=%.0f-%.0f"
		% [WINDOW_SEC, MIN_IOI, SHARP_FULL, LOCK_SHARP, LOCK_AGREE, RELOCK_SEC, PRIOR_LO_BPM, PRIOR_HI_BPM])


func _on_onset() -> void:
	_onsets.append(_now())


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REPORT_SEC:
		return
	_accum = 0.0
	_prune()
	_report()


func _prune() -> void:
	var cutoff := _now() - WINDOW_SEC
	while not _onsets.is_empty() and _onsets[0] < cutoff:
		_onsets.pop_front()


func _report() -> void:
	var n := _onsets.size()
	var raw := _intervals() if n >= MIN_ONSETS else ([] as Array[float])

	# ── IDLE: not enough evidence to say anything at all ─────────────────────
	# ⚠️ The gate is on INTERVAL count, not onset count. v1 gated on onsets only
	# and still emitted conf=1.00 off two intervals.
	if raw.size() < MIN_IOI:
		_idle_run += 1
		_cand_hist.clear()   # a gap must not let stale candidates prop up `agree`
		var tail := ""
		if _state == State.LOCKED:
			# Hold the lock through a short gap; release only after DROP_SEC.
			if _idle_run >= DROP_SEC:
				tail = " (lock %.1f RELEASED after %ds idle)" % [_lock_bpm, _idle_run]
				_state = State.SEARCH
				_lock_bpm = 0.0
				_challenge.clear()
			else:
				tail = " (holding lock %.1f, release in %ds)" % [_lock_bpm, DROP_SEC - _idle_run]
		print("[BPMSpike] IDLE   ioi=%-3d n=%-3d lvl=%.3f mic=%s%s"
			% [raw.size(), n, GlobalBus.level, str(GlobalBus.mic_active), tail])
		return
	_idle_run = 0

	# ── candidate + its evidence quality ─────────────────────────────────────
	var folded: Array[float] = []
	for t: float in raw:
		folded.append(_fold(t))
	var m := _peak(folded)
	var period: float = m["period"]
	if period <= 0.0:
		print("[BPMSpike] IDLE   ioi=%-3d n=%-3d (no candidate)" % [raw.size(), n])
		return
	var cand := 60.0 / period
	var sharp: float = m["sharpness"]
	var sharp_score := clampf((sharp - 1.0) / (SHARP_FULL - 1.0), 0.0, 1.0)

	_cand_hist.append(cand)
	while _cand_hist.size() > AGREE_HIST:
		_cand_hist.pop_front()
	var agree := _agreement(cand)

	# Product, not sum: BOTH a real peak AND persistence are required. Guessing
	# that happens to repeat still scores low, because its sharpness is low.
	var conf := sharp_score * agree

	_advance_state(cand, sharp_score, agree)

	# ── report ───────────────────────────────────────────────────────────────
	if _state == State.LOCKED:
		_lock_held += 1
		print("[BPMSpike] %s bpm=%-5.1f conf=%.2f held=%-3ds | cand=%-5.1f sharp=%.2f agree=%.2f ioi=%-3d n=%d"
			% [STATE_NAMES[_state], _lock_bpm, conf, _lock_held, cand, sharp, agree, raw.size(), n])
	else:
		print("[BPMSpike] %s cand=%-5.1f conf=%.2f sharp=%.2f agree=%.2f ioi=%-3d n=%-3d chal=%d"
			% [STATE_NAMES[_state], cand, conf, sharp, agree, raw.size(), n, _challenge.size()])


## SEARCH -> LOCKED, and the hysteresis that protects a lock.
##
## ⚠️ THE RELOCK BAR IS DELIBERATELY HIGHER THAN THE LOCK BAR. v1's worst failure
## was seven consecutive seconds at 167 BPM on a 130 track — long enough that any
## plain "N seconds disagree" counter would have followed it. Those readings had
## LOW sharpness, so requiring a challenger to clear LOCK_SHARP *and* be mutually
## consistent *and* persist for RELOCK_SEC is what rejects them. A single
## low-quality disagreement clears the challenge outright.
func _advance_state(cand: float, sharp_score: float, agree: float) -> void:
	match _state:
		State.SEARCH:
			if sharp_score >= LOCK_SHARP and agree >= LOCK_AGREE and _cand_hist.size() >= LOCK_MIN_HIST:
				# Lock to the MEDIAN of the agreeing history, not to this one sample.
				var agreeing: Array[float] = []
				for h: float in _cand_hist:
					if absf(h - cand) / cand <= AGREE_TOL:
						agreeing.append(h)
				_lock_bpm = _median(agreeing)
				_lock_held = 0
				_challenge.clear()
				_state = State.LOCKED
		State.LOCKED:
			if absf(cand - _lock_bpm) / _lock_bpm <= AGREE_TOL:
				_challenge.clear()   # the lock is being confirmed
				return
			if sharp_score < LOCK_SHARP:
				_challenge.clear()   # a weak disagreement is not evidence of anything
				return
			_challenge.append(cand)
			if _challenge.size() < RELOCK_SEC:
				return
			# Sustained AND mutually consistent? Otherwise it is just noise that
			# happens to disagree, and the lock stands.
			var med := _median(_challenge)
			var consistent := 0
			for v: float in _challenge:
				if absf(v - med) / med <= AGREE_TOL:
					consistent += 1
			if float(consistent) / float(_challenge.size()) >= 0.75:
				_lock_bpm = med
				_lock_held = 0
			_challenge.clear()


## Share of recent candidates within AGREE_TOL of this one.
func _agreement(cand: float) -> float:
	if _cand_hist.is_empty():
		return 0.0
	var k := 0
	for h: float in _cand_hist:
		if absf(h - cand) / cand <= AGREE_TOL:
			k += 1
	return float(k) / float(_cand_hist.size())


## Intervals at lag 1..MAX_LAG. The detector's 0.12 s cooldown guarantees missed
## onsets in dense material, and a missed onset hides the true period from
## consecutive IOIs entirely — it survives only as a doubled interval.
func _intervals() -> Array[float]:
	var out: Array[float] = []
	for lag: int in range(1, MAX_LAG + 1):
		for i: int in range(_onsets.size() - lag):
			var d := _onsets[i + lag] - _onsets[i]
			if d >= IOI_MIN and d <= IOI_MAX:
				out.append(d)
	return out


func _fold(t: float) -> float:
	var lo := 60.0 / PRIOR_HI_BPM
	var hi := 60.0 / PRIOR_LO_BPM
	var v := t
	var guard := 0
	while v < lo and guard < 8:
		v *= 2.0
		guard += 1
	while v > hi and guard < 8:
		v *= 0.5
		guard += 1
	return v


## Dominant period PLUS how far it stands above the distribution's own noise floor.
##
## ⚠️ THIS IS THE v1 FIX. v1 returned supporters/total, which scores a flat
## histogram and a sharp peak almost identically — 30% either way once the
## intervals are spread over a wide band. Measuring the peak against the MEDIAN
## support instead makes "flat" score ~1.0 and a real peak score 3-10, which is
## the difference between guessing and locked.
##
## Returns {period, support, background, sharpness}.
func _peak(vals: Array[float]) -> Dictionary:
	var n := vals.size()
	if n == 0:
		return {"period": 0.0, "support": 0, "background": 0.0, "sharpness": 0.0}
	var sup: Array[int] = []
	sup.resize(n)
	var best_i := -1
	var best := 0
	for i: int in n:
		var c := 0
		for j: int in n:
			if absf(vals[j] - vals[i]) <= vals[i] * TOL:
				c += 1
		sup[i] = c
		if c > best:
			best = c
			best_i = i
	if best_i < 0:
		return {"period": 0.0, "support": 0, "background": 0.0, "sharpness": 0.0}
	var supf: Array[float] = []
	for s: int in sup:
		supf.append(float(s))
	var bg := maxf(_median(supf), 1.0)
	# Refine to the mean of the winner's supporters — the peak centre, not
	# whichever sample happened to win.
	var sum := 0.0
	var cnt := 0
	for j: int in n:
		if absf(vals[j] - vals[best_i]) <= vals[best_i] * TOL:
			sum += vals[j]
			cnt += 1
	return {
		"period": sum / float(cnt),
		"support": best,
		"background": bg,
		"sharpness": float(best) / bg,
	}


func _median(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	var m := s.size() / 2
	return s[m] if s.size() % 2 == 1 else (s[m - 1] + s[m]) * 0.5
