# PocketVJ — Percival tempo engine (MTG-UPF method) implementation spec

**Status:** specified, not built. Fourth engine behind the DETECT button, alongside IOI / ACF / COMB
(`6c81983`). Companion to `AUTO_BPM_SPEC.md` (the feature and its two failed spikes) and
`AUTO_BPM_ALGORITHMS.md` (why the approach had to change).

**Why this one:** every estimator so far has been built from a guess about what tempo estimation
needs. This is a *published, benchmarked* method from the Music Technology Group at Universitat
Pompeu Fabra — the group behind Essentia — chosen deliberately because it was designed to be
**streamlined**: fewest steps and parameters that still match state-of-the-art accuracy. It is the
one classical algorithm most likely to be implementable on a phone in GDScript.

---

## 1. Where we are, measured

Four presses' worth of evidence on device (Pixel 8, `6c81983`, 20 presses on one unknown track):

| engine | median | sd | confidence behaviour |
|---|---|---|---|
| IOI (onset intervals + 20 s median) | 110.2 | **0.07** | not computed |
| ACF (spectral flux + autocorrelation) | 111.1 | 16.73 | **pinned at 1.00 every press — broken** |
| COMB (phase folding) | 138.5 | 13.90 | 0.28–0.49, varies but wrong scale |

⚠️ Ground truth for that track is still **unknown**, so this is a stability ranking, not an accuracy
one. IOI is dramatically the most *stable*; whether it is *right* is unverified.

**Two diagnoses carried into this build:**

1. **My ACF envelope was probably the problem, not the autocorrelation.** It was built from
   `AudioEffectSpectrumAnalyzer`, which is a **visualiser** — its magnitudes are smoothed, so the
   flux derived from them is blunted. That is the same criticism `AUTO_BPM_ALGORITHMS.md` §2 makes of
   `GlobalBus.level`: I may simply have swapped one smoothed signal for another.
2. **My envelope ran at 100 Hz; Percival's runs at 344 Hz.** Nearly 3.5x the temporal resolution.

---

## 2. The algorithm, as actually implemented in Essentia

Reconstructed from `essentia/src/algorithms/rhythm/percivalbpmestimator.cpp` and the reference page,
not from memory. Defaults: `sampleRate 44100`, `frameSize 1024`, `hopSize 128`, `frameSizeOSS 2048`,
`hopSizeOSS 128`, BPM range **50–210**.

### Step 1 — Onset Strength Signal (OSS)

```
FrameCutter(1024, hop 128)
  -> Windowing(Hamming)
  -> Spectrum (magnitude)
  -> x (1/frameSize)
  -> x 1000
  -> + 1.0
  -> log
  -> Flux(halfRectify = true, L1 norm)
  -> IIR lowpass
```

Three details that matter and that my ACF engine got wrong or missed:

- **The log is applied to the scaled magnitude, not to raw magnitude.** The `×1000` then `+1.0` before
  `log` is a deliberate conditioning step: it keeps the log argument ≥ 1 so the output is
  non-negative, and sets how much quiet detail is compressed.
- **Half-rectified L1 flux** — sum of positive differences only. Energy appearing is an onset; energy
  decaying is not.
- **Lowpass after the flux.** The OSS is smoothed *after* differencing, not before. Smoothing the
  input (which is what a visualiser-grade spectrum does) destroys the transient the flux is meant to
  find; smoothing the output removes jitter without touching it.

OSS rate = 44100 / 128 = **344.5 Hz**.

### Step 2 — periodicity, per OSS frame

```
FrameCutter(OSS, 2048, hop 128)
  -> AutoCorrelation(generalized = true, frequencyDomainCompression = 0.5)
  -> PercivalEnhanceHarmonics
  -> PeakDetection(maxPeaks = 10, orderBy amplitude)
  -> PercivalEvaluatePulseTrains
```

- **Generalized autocorrelation** = `IFFT( |FFT(x)|^c )` with **c = 0.5**. Plain autocorrelation is
  the c = 2 case. Compressing the magnitude spectrum before the inverse transform flattens the
  spectral tilt and **sharpens the lag peaks** — directly addressing why our plain ACF peak-picked a
  different harmonic on nearly every press.
- **Harmonic enhancement** — reinforce lags that also have support at their multiples, so a true
  tempo beats its own half and double instead of losing to them at random.
- **Pulse-train evaluation** — the step our ACF engine lacks entirely. Rather than trusting the
  tallest ACF peak, build a regularly-spaced pulse train at each candidate lag and cross-correlate it
  against the OSS. This scores a candidate on *time regularity across the whole signal*, not on a
  single peak height.

Peak search range: `minPosition = (sampleRate/hopSize) * 60 / maxBPM`, `maxPosition = (sampleRate/hopSize) * 60 / minBPM`.

### Step 3 — accumulation and octave choice

- Each OSS frame contributes a **Gaussian (σ = 10.0)** centred on its estimated lag into an
  accumulator (Essentia: Gaussian size 2000, accumulator 414 bins).
- The accumulator peak is the overall lag.
- An **SVM with hard-coded weights** then picks an octave multiplier of **0.5, 1.0 or 2.0**.

Final BPM = `60 * (sampleRate / hopSize) / lag * multiplier`.

---

## 3. What we implement, and the deliberate deviations

⚠️ **The SVM octave classifier is NOT implemented.** Its trained weights live in Essentia's source and
we do not have them; inventing weights would be worse than not having the stage. **In its place: the
log-normal tempo prior already used by the ACF and COMB engines** (centred 120 BPM, σ 0.9 octaves).

**This is the weakest point of our port and must be reported as such.** Octave errors are the classic
failure of every tempo estimator, and this is precisely the stage the paper added to fix them. If
PERC lands consistently at half or double a known tempo, this substitution is the first suspect —
not the OSS, not the autocorrelation.

Other deviations, all for phone-in-GDScript reasons and all measurable:

| paper / Essentia | ours | why |
|---|---|---|
| hop 128 (OSS 344 Hz) | **start at 128, fall back to 256** | ~3,400 FFTs per 10 s at hop 128; if too slow, 256 halves the cost and the resolution |
| whole-file batch | **~10 s ring buffer** | DETECT is on-demand; a live deck has no file |
| IIR lowpass on OSS | simple one-pole | adequate for smoothing; not worth a biquad design pass |
| BPM 50–210 | 50–210 | unchanged |

**No AGPL exposure.** We implement a published method from the paper and the algorithm description.
Essentia itself is AGPL-3.0-or-later and is **not** linked, vendored or copied.

---

## 4. Build plan

| # | component | notes |
|---|---|---|
| 1 | **PCM ring buffer** in `audio_bus.gd` | tee from the existing `AudioEffectCapture` drain; ~10 s mono. ⚠️ Must not disturb the level/onset path that audio reactivity and BEAT FLIP depend on. |
| 2 | **`scripts/fft.gd`** | iterative radix-2 FFT + IFFT. Standalone, no engine dependencies, unit-testable off-device. |
| 3 | **`scripts/tempo_percival.gd`** | OSS -> generalized ACF -> harmonic enhancement -> peak pick -> pulse-train evaluation -> Gaussian accumulation -> prior -> BPM |
| 4 | **worker thread** | ⚠️ see §5. Analysis must not run on the main thread. |
| 5 | **`PERC` button** | fourth engine in the dialog, behind the same `estimate()` seam. Nothing else changes. |

Godot exposes no FFT to GDScript, hence (2). This also removes the dependency on
`AudioEffectSpectrumAnalyzer` entirely for this engine — which is the point, since that analyser is
the leading suspect for the ACF engine's instability.

---

## 5. ⚠️ The real risk: GDScript speed

10 s of audio at hop 128 is **~3,400 FFTs of size 1024** — roughly 35M operations, in GDScript, on a
phone already decoding 1080p video into two SubViewports. Expect **1–3 seconds** of compute.

**Therefore the analysis runs on a `Thread`, not in `_process`.** This is not a workaround; it is what
the reference implementation does. EssentiaTD — Darien Brito's TouchDesigner plugins wrapping
Essentia — exposes onset detection in real time but runs **BPM extraction in batch mode on a
background thread**. The professional implementation, with the whole C++ library available, still
treats tempo as an on-demand batch job. DETECT is already exactly that shape.

Dialog gains an `ANALYSING…` state; the result fills in when the thread finishes.

**Fallbacks if it is still too slow, in order:** hop 128 -> 256; window 10 s -> 6 s; decimate the
input to 22.05 kHz (halves every FFT). All measurable, none guesswork. **Instrument the timing on the
first build and report it before tuning anything.**

---

## 6. Validation

Same protocol as the two spikes, which has held up better than any implementation:

- **Ground truth from Engine OS, stated before the run.** ⚠️ The current outstanding gap: we have 20
  beautifully consistent IOI readings of 110.2 and no idea whether that is right.
- Known tracks: **Casino Niagara 130**, **Arca 85**, **Grouper 79 (beatless)**, **silence**.
- Tap all four engines per track; every press logs all four for a directly comparable row.
- **Judge accuracy against ground truth, never by eye** — the estimator drives nothing on screen.
- Report **time-to-result** as well as BPM; a correct answer that stalls the deck is not shippable.
- Watch for **consistent half/double errors** — that implicates the omitted SVM stage (§3), and would
  be the signal to implement a proper octave decision rather than retune anything else.

**Success would be:** PERC within ~2% on Casino, no confident answer on Grouper/silence, and either a
stable answer or a low-confidence one on Arca. Anything less and IOI — currently sd 0.07 — remains
the engine DETECT proposes from.

---

## Sources

- Percival, G. & Tzanetakis, G. (2014), *Streamlined Tempo Estimation Based on Autocorrelation and
  Cross-correlation With Pulses*, IEEE/ACM TASLP 22(12), 1765–1776.
  [PDF](https://webhome.csc.uvic.ca/~gtzan/output/taslp2014-tempo-gtzan.pdf)
- [`PercivalBpmEstimator` — Essentia reference](https://essentia.upf.edu/reference/std_PercivalBpmEstimator.html)
- [`percivalbpmestimator.cpp` — MTG/essentia source](https://github.com/MTG/essentia/blob/master/src/algorithms/rhythm/percivalbpmestimator.cpp)
- [`RhythmExtractor2013` — Essentia reference](https://essentia.upf.edu/reference/std_RhythmExtractor2013.html) (multifeature / Degara; the multi-tracker-agreement route, still unexplored here)
- [EssentiaTD — Darien Brito](https://darienbrito.com/work/essentiatd/) · [source](https://github.com/DarienBrito/EssentiaTD) — AGPL-3.0; the batch-mode threading precedent
