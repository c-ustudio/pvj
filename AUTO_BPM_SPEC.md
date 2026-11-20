# PocketVJ — Automatic BPM Detection (spec)

**Status:** ⚠️ **SPIKE RUN 2026-08-04 — ITERATE.** Promising on steady 4/4 electronic material, unproven-to-poor on slow or irregular material, and not yet safe to *act* on because the confidence measure carries no information. Not blocked; not ready. Step 1 (manual BPM entry, `976b317`) remains the shipped answer meanwhile. The spike is `3885b3a` (`tools/bpm_spike.gd` + one autoload line), still installed, and is the base for the iteration.

> **Verdict history:** the first write-up of these results said "FAILED / do not build". That was too strong and has been corrected — see "Spike results". Two errors in it: the beatless case was called dangerous on 2 leaks in 80 s when 97.5% correct silence is a good result, and the silence run was reported as 0 leaks when the fuller window shows 4. The accuracy findings below were re-checked against ground truth and stand.

**The goal:** estimate the room's tempo from the mic and offer it to `BeatClock`, so the deck locks to the music without anyone tapping. Everything already downstream of `BeatClock.bpm` — SEQUENTIAL's advance, the sequencer's slot clock, BEAT FLIP on GRID, the mod matrix's tempo-locked saw — then follows for free.

---

## What already exists (and what this reuses)

`GlobalBus` (`scripts/audio_bus.gd`) already runs a mic onset detector and emits `beat` on every detected transient:

```
beat_threshold = 1.45   ## ratio over the running average
beat_min_level = 0.15   ## absolute floor
beat_cooldown = 0.12    ## min seconds between onsets -> max ~8.3/s
```

**This feature consumes that stream. It must NOT open a second mic client.** The mic is deliberately single-consumer — set recording was scoped to phone-mic-only for exactly this reason, so audio reactivity can't be starved. Auto BPM subscribes to `GlobalBus.beat` like everything else.

`BeatClock` (`scripts/beat_clock.gd`) owns tempo: `set_bpm()` clamps to `BPM_MIN 40.0` … `BPM_MAX 300.0`, emits `bpm_changed`, and the pipeline's `_on_bpm_changed` updates the nav label and marks settings dirty. `deck/bpm` already persists.

---

## The design decision: this merges two deliberately-separate beats

`beat_clock.gd:9-11` states the split outright:

> NOTE — distinct from GlobalBus.beat, which is a MIC-DETECTED onset (drives the TAP-dot pulse, audio reactivity). This is the tap-tempo GRID. Two different "beats" on purpose.

Auto BPM **breaks that separation on purpose**, in one direction only: detected tempo flows into `BeatClock.set_bpm()`. The grid stays the thing that everything musical reads; the onset stream stays the thing that drives per-transient reactivity. What changes is that the grid can now be *informed* by the onsets instead of only by a finger.

The separation still holds everywhere else — nothing should start reading `GlobalBus.beat` where it currently reads `BeatClock.beat`, and vice versa. If this feature ever tempts someone to collapse the two signals into one, that is a different and much larger change.

### Tempo only, not phase

**Step 2 estimates TEMPO. It does not align the downbeat.** Beat *tracking* (where the beat falls) is a harder problem than tempo *estimation* (how fast it is), and mixing them in one step means neither can be verified independently.

So auto BPM calls `set_bpm()` and **does not call `reset_grid()`** — the same rule manual entry follows (`976b317`). Tap remains the only way to mark the downbeat. Expect, and do not treat as a bug: auto locks the rate correctly while the grid's phase is wherever the last tap or restart left it.

Phase alignment is a candidate step 3, and should be specified separately.

---

## Authority model: auto SUGGESTS, manual/tap OVERRIDE

**Auto is never the sole authority.** This is the load-bearing rule of the whole feature.

- A **toggle** arms it. Off by default; the deck must behave exactly as it does today when off.
- While armed, a **stable, confident** estimate calls `set_bpm()`.
- A **manual entry or a tap wins immediately** and must suppress auto from overwriting it — either by disarming auto, or by holding it off for a cooldown long enough that the performer sees their value stick. Decide which during the UI step; a performer whose typed tempo is silently replaced two seconds later will not trust the feature again.
- Detection must **never** apply a value it isn't confident about. Doing nothing is always an acceptable output — the tempo simply stays where it was.

Manual BPM (`976b317`) is the fallback. If detection is unreliable in a given room, the answer is to switch auto off and type the number, and the feature must make that easy rather than fighting it.

---

## Detection: IOI histogram (primary)

Collect inter-onset intervals from `GlobalBus.beat` timestamps, histogram them, and take the dominant cluster as the beat period.

**Onsets are not beats.** This is the central difficulty and the reason the naive version fails:

- A kick, a snare and a hi-hat in one bar produce onsets at several different subdivisions. The IOI histogram therefore has peaks at the beat period *and* at halves, thirds and quarters of it, plus multiples where onsets are missed.
- The `0.12 s` cooldown caps the onset rate at ~8.3/s. Dense hi-hat patterns saturate it, so intervals get quantised toward the cooldown rather than the music.
- Missed onsets produce IOIs at 2× and 3× the true period, which look exactly like a slower tempo.

Mitigations the implementation must include:

1. **Multi-second lock window.** A single bar is not enough evidence. Accumulate several seconds of onsets (start around 4–8 s) before producing a first estimate, and require the estimate to be stable across consecutive windows before applying it.
2. **Cluster, don't bin naively.** Fixed-width histogram bins split a peak that straddles a boundary. Tolerance should be proportional to the interval (a ±10 ms error matters far more at 300 BPM than at 60).
3. **Fold harmonics before choosing.** Candidate periods related by ×2, ÷2, ×3, ÷3 should be gathered into one hypothesis and scored together, not treated as rivals.
4. **BPM-range prior for octave errors.** 70, 140 and 280 BPM are all "correct" for the same music; the detector must pick the one a performer means. Fold candidates by ×2/÷2 into a preferred band (something like 85–175 BPM) and prefer the folded result. The `BPM_MIN 40` / `BPM_MAX 300` clamp is a backstop, not a substitute — it will happily accept a half-time answer.
5. **Confidence score.** Peak sharpness and the fraction of observed IOIs the winning hypothesis explains. Below a threshold, output nothing.

## Fallback: onset-envelope autocorrelation

If the histogram proves too fragile on real material, autocorrelate a continuous onset envelope instead of discrete onsets — periodicity in the envelope survives missed and spurious onsets better than an IOI list does.

**Caveat to check during the spike:** `GlobalBus.level` is already smoothed for reactivity, which blunts exactly the transients an envelope autocorrelation needs. A useful envelope may require a rawer signal (e.g. a per-frame energy or spectral-flux value alongside `level`), which is an addition to `audio_bus.gd` and should be scoped as such rather than smuggled in.

---

## ⚠️ MANDATORY SPIKE — before any feature code

**Prove tempo detection works on real tracks in a loud room first.** The room, not the algorithm, is the risk. Do not build the module, the wiring or the UI until this passes.

The spike is throwaway instrumentation that logs to logcat and changes no behaviour:

- Feed it **real tracks of known BPM** — at least a handful across genres, including something with a soft or swung kick.
- Measure, per track: **error in BPM**, **time to lock**, and **whether it locks at the right octave**.
- Run it **in a loud room**, not at a desk. This is the whole point of the spike.
- Include the failure cases explicitly: **a silent room**, **the gap between tracks**, **beatless ambient material**, and **speech/crowd noise**. The correct output for all of these is *no estimate*, and a spike that only reports successes hasn't tested anything.

**Pass criterion, decided before running:** something like within ±2 BPM at the right octave, locking inside ~10 s, on the majority of test tracks, with no confident-but-wrong answer in the silent/beatless cases. A confident wrong answer is worse than no answer — it moves the deck under the performer.

If the spike fails, the feature stops here and manual BPM stands. That is an acceptable outcome and should be recorded as such.

---

## Spike results — 2026-08-04, Pixel 9a, `3885b3a`

Five windows, external speaker into the phone mic, PocketVJ foregrounded. Ground truth from
Engine OS where given. Raw logs: one line/sec, `[BPMSpike]` prefix.

| # | material | truth | est / sec | median | sd | match rate | verdict |
|---|---|---|---|---|---|---|---|
| 1 | silence / room tone | — | 4 / 64 | 114 | — | — | ✅ 93.8% correctly silent |
| 2 | a "tricky" track | unknown | 79 / 80 | 115.7 | 17.1 | — | ❌ flat histogram, no peak |
| 3 | Jessy Lanza — Casino Niagara | **130** | 77 / 77 | 133.3 | 17.0 | **44%** | ⚠️ finds it, won't hold it |
| 4 | Arca — Membrane (breakbeat) | **85** | 63 / 77 | 119.6 | 22.7 | **10%** | ❌ never finds 85 |
| 5 | Grouper (beatless) | **79** | **2 / 80** | 134.3 | — | **0%** | ✅ 97.5% correctly silent |

"Match rate" is the share of emitted estimates within **5% of the true tempo OR of its double or
half** — the most generous reading, counting an octave error as a hit. Judged that way the tracks
score 44% / 10% / 0%.

**Two separate verdicts, and they differ — this is the correction to the original write-up:**

- **SAFETY (silence + beatless): largely PASSES.** 93.8% and 97.5% correctly silent, on material
  running at up to 0.999 level. The estimator holds no state, so it goes *silent*, never *stale*.
  The leaks are rare, not systematic. The first write-up called this a dangerous failure; that was
  an over-reading of the worst single line rather than the aggregate.
- **ACCURACY: does NOT pass.** One of three tracks matched, and only 44% of the time. This is the
  real blocker, and it is not an artefact of a strict threshold — Arca's 10% and Grouper's 0% are
  40%+ errors, not near-misses.

⚠️ Note for anyone re-testing BY EYE: **the spike drives nothing on screen.** It only calls
`print()`; it never touches `BeatClock.set_bpm()`, so the nav BPM readout keeps whatever manual/tap
value it already had (128 during this session) no matter what is playing. The only place the
estimate exists is logcat. An on-device impression that "it tracked the tempo" was reading the
static manual value, not the detector — which is why the by-eye impression and the logs disagreed.

### What worked — the signal IS in the onset stream

Run 3's folded-period distribution peaks at **0.46 s = 130.4 BPM** against a true 130. The first
ten seconds read `132 133 132 133 134 134 134 133 133 133` — **sd 0.8, locked in about a second**,
and two further 10 s blocks sat at 130.0 and 130.7. The octave fold did exactly its job there: the
raw dominant was the two-beat interval at ~65 BPM, `fold=x2.02` → 130.

That is the finding that keeps this idea alive. Tempo is recoverable from these onsets on easy
material. Everything below is about why the estimator around it isn't good enough yet.

### Defect 1 — `conf` is not a confidence measure ⚠️ THE IMPORTANT ONE

The whole safety model of this spec is "auto SUGGESTS only when confident". **That model does not
exist**, because the confidence number carries almost no information about correctness. On run 3:

```
correct (<=5 BPM err):  conf median 0.34
wrong   (> 5 BPM err):  conf median 0.32
best gate (conf>=0.45): 64% precision   <- barely better than a coin flip
```

Worse, it is *unbounded at low interval counts*. Observed in a transitional window (source material
not attributable with confidence, so recorded as an artefact rather than a per-track result):

```
bpm=111.9  conf=1.00  n=6  ioi=2      <- 2 intervals, both agreed, confidence 100%
```

And on run 5's beatless Grouper the two leaks came out at `conf=0.33` and **`conf=0.44`** — the
second-highest confidence of the whole session, on material with no beat, reporting 132 and 136
against a true 79.

**Fix direction:** a minimum-interval floor (`ioi` >= ~20) as a hard gate, and a confidence based
on peak sharpness *relative to the background* of the histogram, not share-of-supporters.

### Defect 2 — wrong locks are SUSTAINED, so smoothing cannot fix them

Run 3 sat at **167 BPM for seven consecutive seconds** (`158 159 129 167 167 167 167 168 167 130`),
and later spent ten seconds around 100-112. Rolling-median smoothing was tested offline against the
captured data and does not rescue it:

| rolling median | sd | within ±2 of truth |
|---|---|---|
| 5 s | 16.9 | 21% |
| 9 s | 14.6 | 26% |
| 15 s | 11.1 | 25% |

A median cannot reject a seven-second excursion. **Fix direction:** an explicit lock/hysteresis
state — once locked, require strong and sustained contrary evidence to move, and prefer candidates
harmonically related to the current estimate.

### Defect 3 — onset supply COLLAPSES on loud, dense material ⚠️ UPSTREAM, not in the estimator

This one is in `audio_bus.gd`, and no estimator can beat a thinning input.

- Run 4 (Arca): `lvl` up to **0.95** while onsets fell to a median of **10**, with 14 of 77 seconds
  unable to estimate at all.
- Run 5 (Grouper): `lvl` median **0.905**, max **0.999** — near maximum — with onsets at **0-3**,
  essentially never reaching the threshold of 6.

The mechanism is the Session-23 finding running in reverse: the detector fires on
`level > avg * beat_threshold`, so loud *continuous* material raises its own running average and
transients stop clearing it. **Denser, louder music yields FEWER onsets, not more** — exactly
backwards from what tempo estimation needs. This is the deepest of the four problems.

### Defect 4 — the fold band question is still UNRESOLVED

The spike used **90-180** rather than the 70-180 sketched above, because 180/70 = 2.57 is wider than
an octave and folding into it is ambiguous. Runs 4 and 5 (85 and 79 BPM) were expected to test that
choice — a prediction was made in advance that run 4 would report ~170 (85 folded up).

**The prediction was wrong, and instructively so.** Run 4 reported a scattered 119.6 with a raw
dominant of 94.9; it never found 85 at any octave. The failure was **upstream of the fold**, so
neither run tells us anything about the band. Any recommendation to move to 80-160 (or anywhere
else) is currently **unsupported** and must wait until slow material actually locks.

### ⚠️ Two runtime constraints discovered by accident — these affect the real feature

Both were found when the spike went silent mid-session, and neither is about the algorithm:

- **Detection only runs while PocketVJ is FOREGROUNDED.** Godot pauses its main loop on Android
  `onPause`, so `_process` stops and — critically — onset consumption stops with it. A performer
  switching to their music player kills auto-BPM outright. Observed: 17 minutes of total silence
  from the spike while another app had focus.
- **Any phone call kills it.** A WhatsApp voice call put the device in `MODE_IN_COMMUNICATION`,
  which hands the mic to the call and applies aggressive AEC/NS/AGC. Detection would die silently
  mid-set, and the performer would have no indication why.

### Recommendation — ITERATE, don't ship and don't stop

The spike is **not** a dead end. It found 130.4 against a true 130, held sd 0.8 for ten seconds,
and stayed correctly quiet through silence and beatless material. What it cannot yet do is stay
locked, detect slow or irregular tempi, or tell you when it is wrong.

**Next iteration — defects 1 and 2 only. Both live entirely in `tools/bpm_spike.gd`; no real code
is touched:**

1. `ioi` floor (>= ~20 intervals) as a hard gate — kills the `conf=1.00 on 2 intervals` artefact
   and most of the silence/beatless leakage in one line.
2. Confidence from peak sharpness *relative to the histogram background*, not share-of-supporters.
3. A lock/hysteresis state — once locked, require sustained contrary evidence to move, and prefer
   harmonically-related candidates.
4. A longer window (6 s -> 12-15 s) so one transient section cannot dominate.

**Ship gate for the iteration — decide these BEFORE re-running, not after:**

- Match rate (5%, octave-generous) **>= 80%** on steady 4/4 electronic material.
- Confidence that **discriminates**: correct-vs-wrong medians clearly separated, and a gate
  reaching **>= 90% precision**. 64% is a coin flip and cannot underpin "auto suggests".
- **Zero** confident emissions on silence and beatless material.
- Re-run all five cases, measured against ground truth. ⚠️ **Not by eye** — the by-eye impression
  and the logs disagreed in this session precisely because the spike drives no UI.

If slow/irregular material still fails after that, the honest scope is "auto-BPM for steady
electronic sets only, off by default, manual always overrides" — which is still useful, provided
the feature can tell when it is out of its depth. It currently cannot; that is what defect 1 is.

Defect 3 (onset supply collapsing on loud dense material) is the deepest and the only one requiring
changes to real code (`audio_bus.gd`). Do not start there without deciding that auto-BPM is worth
modifying the audio path for.

## Loud-room tuning is its own step, and there is prior evidence

`pipeline.gd` already documents a measured, counter-intuitive finding from the Session-23 capture:

> ⚠️ This is NOT the control for a noisy room. Measured over the Session-23 capture, room noise is MORE peaky than music (ratio median 2.05 vs 1.71) — a quiet room has a tiny running average, so a chair creak reads as a ratio of 4. Raising sens to 1.60 keeps 82% of the silent-room fires while discarding 37% of the real music. Venue noise is a LEVEL problem; use the floor.

Read that before tuning anything. It means:

- **The sensitivity ratio is the wrong knob for a noisy venue** — the floor (`beat_min_level`) is.
- Detection quality is bounded by onset quality. Garbage onsets produce a confident, wrong tempo.
- Tuning must be validated with real captures, not by ear at a desk.

---

## Build order

1. ~~**SPIKE** (mandatory, above). Throwaway. Pass/fail on real tracks in a loud room.~~
   **DONE 2026-08-04 (`3885b3a`) — INCONCLUSIVE, iterate.** Safety passed; accuracy did not.
   Steps 2-5 wait on a second spike pass meeting the ship gate in "Spike results".
2. **Detection module** — a self-contained estimator with no engine dependencies: onsets in, `{bpm, confidence}` out. Unit-testable against recorded onset sequences without a phone.
3. **Wire to BeatClock** — call `set_bpm()` on a stable confident estimate. No `reset_grid()`. Tempo only. Verify the whole beat-synced chain follows.
4. **Toggle + UI** — off by default, live confidence/estimate readout, and the override rule (manual/tap wins). The nav-bar BPM cell is already a button (`976b317`) and is the natural place to surface auto's state.
5. **Loud-room tuning** — with real venue captures, informed by the Session-23 finding above.

Each step leaves a working build. Steps 3–5 each need on-device verification; none of this is provable at a desk.

---

## Cautions

- **Never sole authority.** Manual and tap always win. Auto that overrides a performer mid-set is worse than no auto.
- ⚠️ **Confidence must be validated before it is trusted, not assumed.** The 2026-08-04 spike's
  confidence number failed to separate correct from wrong estimates at all (64% precision at the
  best gate) and hit 1.00 on two coincidental intervals. Any future confidence measure must be
  tested for *discrimination* against ground truth, not merely computed.
- ⚠️ **Foreground-only, and call-fragile.** Godot pauses in the background, so detection stops the
  moment another app takes focus; and a phone call (`MODE_IN_COMMUNICATION`) takes the mic entirely.
  Both fail silently. Any shipped feature needs to detect and surface these, or it will appear
  broken for reasons the performer cannot see.
- **A confident wrong answer is the failure mode to design against**, not a missed detection.
- **Octave errors are the most likely wrong answer.** Half-time and double-time are both defensible readings of the same music; the range prior is what makes the choice, and it must be explicit.
- **Tempo ≠ phase.** Step 2 does not align the downbeat, and shipping it without saying so will read as a bug.
- **Don't open a second mic client.** Reuse `GlobalBus`.
- **RANDOM and LFO stay BPM-independent.** `beat_clock.gd:7` and both slider comments say so deliberately. Auto BPM does not change their rates — RANDOM's dwell and LFO's sweep remain in seconds. If tempo-relative clip rates are wanted, that is the separate per-mode clip-hold work.
- **Unrelated but adjacent:** `_lfo_period_sec`, `_random_interval_sec` and the sequencer's beats-per-slot have **no cfg keys at all** and reset every launch. Of everything that determines clip rate, only `bpm` survives a restart. Worth closing before, or alongside, further tempo work.

---

## Why it's worth it

Tap tempo works but costs attention at exactly the moment there is none — the start of a track, in the dark, with a hand already on something else. If detection is reliable enough to suggest a tempo the performer merely confirms, the whole beat-synced half of the deck arms itself. And if it isn't reliable, the toggle goes off and manual entry is already there, which is why this feature is safe to attempt at all.
