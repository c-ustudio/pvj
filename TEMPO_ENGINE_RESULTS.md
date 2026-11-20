# PocketVJ — tempo engine results, and the mask/FX routing fix

**Date:** 2026-08-04 evening. **Device:** Pixel 9a (`tegu`) for tempo, Pixel 8 (`shiba`) for masks.
Companion to `AUTO_BPM_SPEC.md`, `AUTO_BPM_ALGORITHMS.md`, `TEMPO_PERCIVAL_SPEC.md` and
`SESSION_24_NOTES.md`.

---

## 1. Measured results — five tracks, four engines

Ground truth from Engine OS unless noted. Every DETECT press logs all engines, so each row is a
comparison on identical audio.

| track BPM | PERC | COMB | IOI | ACF |
|---|---|---|---|---|
| **130** (run 1) | **128.7** | 132, 129, 129 | 124.2, 135.7, 133.1 | 84.8, 68.8, 69.6 |
| **130** (run 2) | **128.0** | 132, 120, 120, 130 | 134.0–134.3 | 75.0, 85.6, 85.6, 149.9 |
| **135** | **134.2** | 139, 136, 135, 120 | `--` (no estimate) | 68.6, 68.8, 68.4, 103.5 |
| **122** | **124.3** | 127, 125, 123, 120 | 125.7, 126.0, 125.5, 124.4 | 132.7–133.0 |
| **81.3** ⚠️ | 103.9 | 125, 104, 146, 120 | `--` | 142.9, 142.6, **81.1, 81.2** |

### ⚠️ UPDATE — after the octave decision (`b9d0a14`), measured on BOTH phones

| track | Pixel 8 PERC | Pixel 9a PERC | error | `oct` |
|---|---|---|---|---|
| **140** | 141.2 | 139.3 | **0.9% / 0.5%** | x1.0 / x1.0 |
| **160** (footwork) | **160.2** | **159.0** | **0.1% / 0.6%** | **x2.0** / x1.0 |

**The octave stage works on real music.** On the 160 track the Pixel 8's underlying periodicity was
half-time — its IOI read 105 and COMB 119–139 — and the stage fired `x2.0` to recover **160.2**. The
9a found 160 directly and the stage correctly did **not** fire. Selective, not blanket-doubling,
which was the specific risk with dense off-beat material like footwork.

Same track BEFORE the fix: **106.9 / 154.3**. After: **160.2 / 159.0**.

### ⚠️ TWO PHONES ARE A DIAGNOSTIC, NOT JUST A REPEAT

Running both simultaneously separates *algorithm* error from *capture* error — a confound that made
every single-device result ambiguous:

| track | P8 | P9a | reading |
|---|---|---|---|
| 140 | 141.2 | 139.3 | agree → the number is about the music |
| 160 (pre-fix) | 106.9 | 154.3 | **diverge → the P8 was not hearing it well** |
| 160 (post-fix) | 160.2 | 159.0 | agree |

The pre-fix footwork failure was therefore substantially a **microphone/room** problem, not only an
algorithm one. Any future measurement should use both devices for this reason.

### ⚠️ AND A REAL LIMIT ON THE AGREEMENT IDEA

On the 160 track **COMB and IOI both failed** (COMB 119–139, IOI 105) while PERC was right to 0.1%.
Agreement-based confidence would have marked that track **low-confidence despite a correct answer**.

Agreement is conservative: it catches "nobody knows" well, but it also doubts a good engine when the
weaker ones are lost. It is still worth building — but as a *confidence* signal, never as a voting
scheme that could outvote the accurate engine.

### PERC is the most accurate

| truth | PERC | error | conf |
|---|---|---|---|
| 130 | 128.7 / 128.0 | 1.0% / 1.5% | 0.26 / 0.37 |
| 135 | 134.2 | 0.6% | 0.60 |
| 122 | 124.3 | 1.9% | 0.68 |
| 140 | 141.2 / 139.3 | 0.9% / 0.5% | 0.50 / 0.47 |
| **160** | **160.2 / 159.0** | **0.1% / 0.6%** | 0.28 / 0.33 |
| 81.3 ⚠️ | 103.9 | 28% | 0.40 |

**Six of seven within 2%, across 90–160 BPM on two devices** — ⚠️ **AND THEN IT FAILED TWICE. See
§1b. The "most accurate" headline above is true only for STEADY material.**

⚠️ **Confidence is NOT tracking accuracy well.** The two best results (160.2 at 0.1%, 159.0 at 0.6%)
scored conf **0.28 / 0.33** — lower than the 122 reading that was 1.9% off at 0.68. Whatever the
accumulator-concentration measure is capturing, it is not correctness. That is now a **fifth**
confidence measure that does not discriminate, and it strengthens the case for deriving confidence
from cross-engine or cross-device agreement instead.

⚠️ An earlier draft of this document claimed PERC's confidence was "the first here that has ever
pointed the right way", based on 0.60/0.68 when right and 0.40 when wrong. **The 140 and 160 runs
falsified that** — 0.28 and 0.33 on the two most accurate readings in the set. Three points of
apparent correlation were coincidence, and reading them as a trend was exactly the mistake this
document elsewhere warns against.

## 1b. ⚠️ THE LATER TESTS — where PERC breaks

Two further tracks, both measured on both phones, both after the octave decision:

| truth | Pixel 8 PERC | Pixel 9a PERC | error | `oct` |
|---|---|---|---|---|
| **137** (syncopated) | 110.0, 108.5, 130.9 | **205.0, 205.9, 203.5, 202.7** | 20% / **50%** | x1.0 / **x2.0** |
| **150** (glitchy) | 110.4 | 111.0 | **26% / 26%** | x1.0 / x1.0 |

**The split is clean, and it is what `AUTO_BPM_ALGORITHMS.md` predicted:**

| material | PERC |
|---|---|
| steady 4/4 (130, 135, 122, 140, 160) | **0.1–1.9%** |
| syncopated (137) | 20–50% |
| glitchy (150) | 26% |

The onset-envelope approach depends on regular transient structure. Glitch removes it.

### ⚠️ Three conclusions this overturned

**1. The octave stage cuts both ways.** It rescued 160 on the Pixel 8 (`x2.0` → 160.2) and *broke*
137 on the 9a — firing `x2.0` four times to land on ~205, which is ~1.5x the truth, not 2x. It had
locked onto ~102 internally and doubled that. Net positive across the session, but not free.

**2. Confidence failed for the SIXTH time, in its worst form yet.** PERC scored its **highest
confidences of the night (0.63, 0.64) on its worst answer** (205 vs 137), and 0.56 on a 26% error.
High confidence on a badly wrong answer is worse than no confidence at all.

**3. ⚠️ CROSS-DEVICE AGREEMENT IS NOT SUFFICIENT — I OVERSTATED IT.** §1 promotes two-phone agreement
to a "trust this" signal on the strength of the 140 and 160 runs. The 150 glitchy track disproves it:
**both phones returned ~110.7 and both were 26% wrong.** Agreement tells you the CAPTURE is
consistent; it does not tell you the ALGORITHM is right. On 137 they disagreed (110 vs 205) and both
were wrong too. Necessary, not sufficient.

**And on the failing tracks, IOI and COMB sometimes beat PERC** — on 137 the 9a's IOI held 135.8–137.9
(within 1%) while PERC was 50% off. Keeping the three-engine panel was the right call for reasons
beyond fallback: on hard material the ranking genuinely reverses.

### ⚠️ Why none of this reached the deck

**DETECT proposes; the performer confirms.** A 26% miss costs one glance and a CANCEL. That design was
chosen before any of these failures were known, precisely because four confidence measures had already
failed — and it is the reason a 205 BPM reading on a 137 BPM track was a non-event rather than a
retimed set.

---

### ⚠️ The 81.3 result is UNRESOLVED, not a confirmed failure

The user's reaction was "it may be Engine OS also failing as it's pretty fast to me" — and that is a
real possibility. **Engine OS is itself an estimator**, and DJ software half-times fast tracks
routinely. On that track four estimators (ours plus Engine OS) produced four different answers and
no two agreed.

That may not be four failures. It may be **genuinely ambiguous material**, which is a property of
music rather than a bug — and precisely the case where the correct output is "ambiguous", not a
number.

**Only a human reference settles it:** tap the tempo in by hand and compare. Until then this row
should not be scored against any engine.

**Current reading (2026-08-04, agreed with the user): Engine OS is most likely the wrong one here.**
Every other track in the set has since been confirmed to ~1% by PERC across two independent devices,
including 160 BPM footwork. A single 28% outlier against an otherwise tight record points at the
reference rather than the estimator — especially given the track "sounds fast", which is the classic
signature of DJ software reporting half-time. ⚠️ Still not proven: it needs a hand-tap, and it is the
only row in this document without a trustworthy ground truth.

---

## 2. ⚠️ Agreement predicted correctness; self-assessment never did

The clearest finding of the session, and it arrived for free:

| track | engine agreement | outcome |
|---|---|---|
| 130 | PERC + COMB converged ~129 | both right |
| 122 | PERC + COMB + IOI converged 123–126 | all close |
| **81.3** | **scattered 104–146** | **nobody right** |

Disagreement predicted failure, agreement predicted success — with **no engine judging itself**.

That is exactly the Zapata / Davies / Gómez approach (MTG-UPF, Essentia's
`BeatTrackerMultiFeature`): run several *independent* trackers and derive confidence from their
mutual agreement. It is the answer to the problem four internal confidence measures failed at
(supporters/total → 64% precision; sharpness → no separation; dispersion → overlapping;
ACF peak-vs-mean → saturated at 1.00).

**Not implemented.** It is the obvious next step and needs no new DSP — the three engines already
exist and already run on every press.

### The panel is deliberately diverse

| engine | input | method |
|---|---|---|
| IOI | threshold onset **events** | interval histogram |
| COMB | SpectrumAnalyzer **envelope** | phase folding |
| PERC | raw **PCM** via its own FFT | generalized ACF + pulse trains |

Three different inputs, not three flavours of one. That independence is what makes agreement
meaningful, and is why the panel is worth keeping even though PERC wins on accuracy.

---

## 3. ACF removed (`f289bdc`)

Across both 130 runs: 68.8, 69.6, 75.0, 84.8, 85.6, 85.6, 149.9 — 15–48% off — with **`conf=1.00` on
every press**. The saturation is structural: its normalisation was
`(peak / search-range mean − 1) / 3`, and an autocorrelation decays with lag, so the peak always
towers over the mean.

⚠️ **It did hit 81.1 and 81.2 on the one track nothing else got.** But it also reported 142.9 and
142.6 on the same track with identical confidence — so it was not *finding* 81, it was landing there
at random with no way to tell which answer to believe. An engine that is wrong is tolerable when a
human confirms every value; one that is wrong **and certain** would poison any agreement measure
built on top of it. That is why it went rather than being demoted.

**IOI kept** despite being least accurate, as the no-FFT/no-thread/no-buffer fallback. ⚠️ But that
argument is weaker than claimed: **IOI returned `--` on two of five tracks**. It is a fallback for
when PERC's *buffer* is not ready, not a universal one.

---

## 4. PERC optimisation (`9f32646`)

| | before | after |
|---|---|---|
| window | 10 s | **20 s** |
| accumulator votes | 6 frames | **19 frames** |
| runtime (Pixel 8) | 3,352 ms | 3,469 ms |
| conf on room noise | 0.48 | **0.19** |

Decimating to 22.05 kHz **and halving the frame to 512** keeps the same time span and the same
43 Hz/bin frequency resolution as 1024 at 44.1 kHz — the same analysis for ~0.45× the cost per frame.
That bought the doubled window for free. FFT buffers are also allocated once and reused (~3,400
allocations per run previously).

### ⚠️ The harmonic weighting made accuracy WORSE before it made it better

Implementing Essentia's real pulse-train scoring (fundamental 1.0, double 0.5, 1.5× 0.5) collapsed
synthetic 120 and 130 to **half-time**. The cause is structural: for a click train at period T, a
half-tempo candidate at 2T lands its fundamental (2T, 4T…), its double (4T, 8T…) **and** its 1.5×
(3T, 6T…) all on real beats — 2.0H — while the true candidate's 1.5× term falls off-beat, giving
1.5H. Slower candidates win outright.

The prior could not rescue it because it was applied **only at the final accumulator**: by then every
frame had already voted half-time. Fix was applying the prior **per frame**, inside the candidate
choice — part of what the omitted SVM would otherwise do.

⚠️ **The synthetic test's octave tolerance MASKED this regression** — it scores half/double as a pass
because the SVM is deliberately omitted, so a real regression appeared only as a `[HALF]` tag in the
output, not a failure. Read the tags, not just PASS.

---

## 5. Effects in mask mode — fixed (`2f08a0c`)

Reported as "effects aren't working when on mask". They were **bypassed by design**, not broken:
`_refresh_output_source` pointed QuadWarp straight at `MaskWorld` and set `shader_slot` to
`UPDATE_DISABLED` the moment one mask existed. The FX cell still changed `_effect_index`; nothing
rendered it. Per-region effects were unaffected throughout.

```
was:  ClipEngine -> MaskWorld ---------------> QuadWarp   (ShaderSlot orphaned)
now:  ClipEngine -> MaskWorld -> ShaderSlot -> QuadWarp
```

**Verified on device (Pixel 8, 2 masks):**

| check | result |
|---|---|
| routing log | `quad_warp <- ShaderSlot <- MaskWorld` |
| global FX over masked composite | ✅ visibly kaleidoscoped |
| masks render | ✅ |
| clip change keeps masks hooked | ✅ (advanced 83 → 85) |
| **FPS vs 61 baseline** | ✅ **60–61** |
| script errors | ✅ 0 |

### Three things this needed beyond the obvious

- ⚠️ **Two other writers had to be guarded.** `_apply_source()` and `_on_active_texture_changed()`
  both call `shader_slot.set_input()` with the deck texture. Unguarded they would have silently
  unhooked the masks the next time a clip changed or the source switched — a bug surfacing minutes
  later on an unrelated action. The clip-change check above is the regression test for exactly this.
- ⚠️ **Render order.** `_mask_world` is added to `output_world` *after* `ShaderSlot`, so without a
  `move_child` it renders second and ShaderSlot samples a frame-old composite.
- **The test grid now lives in ShaderSlot on both paths**, chosen deliberately: it is an alignment
  tool, so it stays *above* the masks rather than being cut up by them. It does sit downstream of the
  effect shader, so a heavy effect will colour it — accepted trade.

### ⚠️ Untested

**A feedback effect (Trails, Slit-Scan) with masks active.** Those add another full-frame read+write
(~8 MB each way at 1080p per `shader_slot.gd`'s own warning) on top of the new pass and up to
`MAX_DECODERS` mask decoders. KALEIDO is cheap by comparison. If FPS drops there, the honest fallback
is disabling global FX only for feedback effects while masks are live — not reverting the fix.

---

## 6. Open items

- **⚠️ Tap 81.3 in by hand.** Current reading is that Engine OS is the wrong one (see §1), but it is
  the only row without a trustworthy reference and a hand-tap is the only thing that proves it.
- **⚠️ Confidence is now a FIFTH failed measure.** PERC's accumulator-concentration score gave 0.28
  and 0.33 on its two most accurate readings ever (0.1% and 0.6%) and 0.68 on a 1.9% miss. Cross-engine
  or cross-device agreement is the remaining candidate — with the caveat below.
- **Agreement is conservative.** On the 160 track COMB and IOI both failed while PERC was right to
  0.1%; an agreement metric would have marked a correct answer low-confidence. Build it as a
  confidence SIGNAL, never as a vote that can outweigh the accurate engine.
- **Always measure on BOTH phones.** The pre-fix footwork divergence (106.9 vs 154.3) was largely a
  microphone/room problem, and no single-device run could have told us that.
- **Agreement-based confidence** (§2) — highest value, no new DSP, three engines already running.
- ~~Fast material ≥160 BPM untested.~~ **DONE** — 160 BPM footwork measured at 160.2 / 159.0 with the
  octave stage firing `x2.0` on the device that was hearing half-time.
- **Feedback effect + masks** FPS (§5).
- Was the prior the cause of the 81.3 miss? Testable cheaply: widen `PRIOR_SIGMA` or lower
  `PRIOR_CENTRE`, re-measure that track. If 103.9 moves toward 81, the prior is implicated.
- Pixel 8 still has **BPM 64** from an accidental blind tap; FX and mask count self-restored.
