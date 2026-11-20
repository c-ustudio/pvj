# PocketVJ — Auto-BPM: algorithm options after two failed spikes

**Status:** research notes, nothing built. Companion to `AUTO_BPM_SPEC.md` (the feature spec and the
spike results). This document exists because two iterations of the same *approach* failed for the
same underlying reason, and the next attempt should change the approach rather than the constants.

**Read this first if you are picking up auto-BPM.** It records what was measured, why it failed, and
the four realistic alternatives with honest cost estimates.

---

## 1. What was actually measured

Two spikes, both log-only, both on a Pixel 9a with an external speaker and ground truth from
Engine OS. Full detail in `AUTO_BPM_SPEC.md`; the short version:

| | v1 (`3885b3a`) | v2 (`5194bad`) |
|---|---|---|
| method | IOI histogram, conf = supporters/total | + `ioi>=20` gate, sharpness confidence, lock state machine |
| Casino Niagara (**130**) | 44% of seconds within 5%, sd 17 | LOCKED **134.2** (3.2% err), held 62 s — but took **120 s** to fire |
| Arca — Membrane (**85**) | never found 85 at any octave | never locked; **held a stale 134.2 lock 20 s into the track** |
| Grouper (**79**, beatless) | 2 false emissions (conf 0.33 / 0.44) | **0 emissions, 75/75 IDLE** ✅ |
| silence | 4 false emissions at conf 0.50 | 0 ✅ |

### What worked and should be kept

- **The `ioi >= 20` hard gate.** Every false emission in v1 had `ioi` between 2 and 10. Gating on
  *interval count* (not onset count) removed all of them without starving the good case.
- **The lock mechanism.** 62 seconds at a single value while the underlying candidate stream wobbled
  with sd 13.5 including excursions to 167 BPM. The hysteresis genuinely rejected the failure that
  beat v1.
- **The central tendency was always right.** A 20 s median of the candidate stream gave **132.1
  against a true 130 — 2.6% error**, stable across 20/40/60 s windows. The estimator was accurate;
  only its per-second readings were noisy.

### What failed, and this is the important part

**Three different confidence measures were tried. None discriminated.**

| measure | result |
|---|---|
| supporters / total (v1) | correct vs wrong medians 0.34 vs 0.32 → best gate **64% precision** |
| peak sharpness vs median background (v2) | Arca (flat) **1.50** vs Casino (peaked) **1.45** → *flat scored higher*. **No separation.** |
| candidate dispersion (offline) | Casino sd 12–15 vs Arca sd 15–19 → **overlapping** |

Secondary v2 failures: **time-to-lock 120 s** (target ~15 s), and **the lock did not release on a
track change** — it carried a Casino-derived 134.2 into an 85 BPM track for 20 seconds.

---

## 2. The diagnosis — we were estimating tempo from the wrong representation

Every failure above is downstream of one choice: **we estimated tempo from a sparse, threshold-derived
event stream.** Real tempo trackers do not do this. They work on a **continuous onset-strength
envelope** sampled at roughly 100 Hz.

`GlobalBus` fires an onset when `level > running_avg * 1.45`, on an already-smoothed level, with a
0.12 s refractory. That discards, in order of severity:

| discarded | measured consequence |
|---|---|
| **Magnitude** — a huge kick and a marginal tick become identical timestamps | sharpness could not tell peaked material from flat |
| **Everything below threshold** | Grouper produced **0–3 onsets at level 0.95** (near maximum) |
| **Timing precision** — smoothing delays, refractory quantises | candidate sd 13.5 on a track it was centred on |
| **Density** — ~2 events/sec vs ~100 frames/sec | needed a 20 s window to average out the noise |

⚠️ **Loud, dense material produces FEWER onsets, not more.** A high running average means transients
stop clearing the ratio test. This is the Session-23 finding running in reverse, and it is exactly
backwards from what tempo estimation needs. No estimator can beat a thinning input.

---

## 3. Option 1 — Spectral flux envelope + autocorrelation ★ recommended detection path

The standard approach (Scheirer 1998; Ellis 2007; what `librosa.beat.tempo` implements).

**Algorithm**

1. Per audio frame, compute the magnitude spectrum; sum the **positive** differences from the previous
   frame across bands → one onset-strength value per frame (~100 Hz envelope).
2. **Autocorrelate** the envelope over lags 0.3–1.5 s (40–200 BPM).
3. Weight by a tempo prior (log-normal around ~120 BPM is standard) to resolve octave ambiguity —
   this replaces our crude fold band.
4. Peak lag → tempo. **Confidence = peak height relative to the autocorrelation's own baseline.**

**Why it should beat what we have**

- Uses *all* the energy, not threshold crossings. A weak kick that never clears `1.45 × avg` still
  contributes to the envelope.
- Robust to missed onsets by construction — there are no "onsets" to miss.
- **The confidence measure is the one part most likely to finally work.** Our IOI sharpness failed
  because the histogram was built from ~100 sparse events; an autocorrelation over a dense continuous
  envelope has a well-defined baseline to measure a peak against. Grouper's sustained wash would give
  genuinely *low flux* — a real "no beat here" signal rather than our current "no data".

**⚠️ Feasibility — the finding that changes the cost estimate**

I assumed this needed risky surgery on the mic path. It does not. `audio_bus.gd` already builds a
dedicated bus and chains effects onto it:

```gdscript
const INPUT_BUS_NAME := "MicCapture"
AudioServer.add_bus(idx)
AudioServer.set_bus_mute(idx, true)
AudioServer.add_bus_effect(idx, _capture)      # existing AudioEffectCapture
```

Godot's `AudioEffectSpectrumAnalyzer` is a **bus effect**, so it *chains alongside*
`AudioEffectCapture` on that same bus. It does **not** open a second mic client, does not compete with
capture, and does not affect set recording. The single-consumer constraint that looked like the hard
blocker does not bind.

Read it per frame with
`AudioEffectSpectrumAnalyzerInstance.get_magnitude_for_frequency_range(lo, hi)` over ~24 bands.

**Cost:** one added line in `audio_bus.gd` (the effect) plus a `get_instance()` accessor; everything
else lives in the throwaway spike file. Realistically a few hours including a device session.

---

## 4. Option 2 — Band-limited onsets ★ cheapest experiment

Keep the existing detector, but run it on **40–120 Hz only** (the kick) rather than broadband.

**Rationale:** kick onsets are far more regular than broadband ones. On Arca the glitchy
high-frequency texture plausibly swamps the pulse — 63 estimates that never found 85 at any octave is
consistent with the detector triggering on texture rather than beat.

**Why do this first:** it isolates one variable. If band-limited onsets make Casino lock in ~15 s and
leave Arca flat, then onset *quality* was the problem and the IOI method is salvageable. If Casino is
unchanged, the IOI method itself is the limit and Option 1 is the only way forward. Either outcome is
worth knowing before spending hours on an envelope.

**Cost:** ~30 minutes. Needs the spectrum analyzer from Option 1 (to isolate the band) or a simple
one-pole low-pass on the captured PCM in `audio_bus.gd`.

---

## 5. Option 3 — Comb-filter resonator bank (Scheirer)

A bank of resonators tuned to candidate tempi; the one that accumulates most energy wins.

**Attraction:** the energy ratio between the best resonator and the rest is a *naturally* good
confidence measure — which is the thing we have failed to build three times.

**Cost:** similar to Option 1 once the envelope exists; more state to tune. Reasonable as a follow-up
to Option 1 if its autocorrelation confidence still does not discriminate.

---

## 6. Option 4 — Don't detect: take the clock from the source ★ possibly the real answer

The music comes from **Engine OS** — the same application used for ground truth throughout both
spikes. Two ways to take tempo directly instead of guessing at it through a microphone:

- **Ableton Link** — LAN tempo + phase sync, widely supported by DJ software.
- **MIDI clock** — over USB or network.

**Why this may simply be better:** it gives *exact* tempo **and phase**, with no DSP, no confidence
problem (there is nothing to be uncertain about), and no failure on ambient or breakbeat material.
Note that phase is something none of the mic approaches even attempt — `AUTO_BPM_SPEC.md` explicitly
scopes step 1 to tempo only, because beat tracking is a harder second problem.

**Cost / risk:** neither exists in the codebase — there is no MIDI or Link intent anywhere in the
scripts or docs today. Link is a C++ library and would need a GDExtension; MIDI clock would need a
USB-host or network listener. This is real work, and it introduces a dependency on the DJ rig being
present and configured.

**The honest framing:** for a visual instrument syncing to a DJ setup, taking the clock from the
source is the correct architecture, and microphone detection is the workaround for not having it.
Detection remains valuable as a fallback — for rehearsals, for other people's rigs, for when Link is
not available — but it should probably not be the primary path if the music reliably comes from
Engine OS.

---

## 7. Comparison

| option | effort | fixes confidence? | gives phase? | touches real code |
|---|---|---|---|---|
| 1. Spectral flux + autocorrelation | hours | **likely** — dense envelope has a real baseline | no | 1 line in `audio_bus.gd` |
| 2. Band-limited onsets | ~30 min | no — same IOI method | no | small, `audio_bus.gd` |
| 3. Comb-filter bank | hours | **likely** — energy ratio is a natural measure | no | same as 1 |
| 4. Ableton Link / MIDI clock | days | **N/A — no estimate to doubt** | **yes** | new subsystem |

---

## 8. Recommended order

1. **Option 2** — cheap, isolates onset quality vs method. Do this before investing in an envelope.
2. **Option 1** — the real algorithm, and much cheaper than assumed thanks to the bus-effect finding.
3. **Option 3** — only if Option 1's confidence still fails to discriminate.
4. **Option 4** — decide as a *product* question, not a technical one: *does the music always come
   from Engine OS?* If yes, Link is the feature actually wanted and detection is the fallback.

**Meanwhile:** the design that needs no confidence measure at all is a **performer-triggered
"DETECT" button** beside TAP — collect ~20 s, propose a number into the existing manual-BPM dialog
(`976b317`), performer accepts or dismisses. The 20 s median measured 2.6% error on Casino Niagara,
so this would have proposed 132 against 130. On Arca it would propose ~117, visibly wrong, dismissed
in one glance. **The human becomes the confidence measure**, which sidesteps the one problem three
algorithms have failed to solve. This is currently the highest value-per-effort path to something
shippable.

---

## 9. ⚠️ How to evaluate whatever comes next

The measurement protocol from these two spikes was more valuable than either implementation. Reuse it:

- **Ground truth from Engine OS**, stated before the run, not inferred afterwards.
- **Log the raw components, never just the verdict.** v2 logged `sharp`, `agree` and `ioi` separately,
  which is the only reason its failure could be diagnosed offline without another device session.
- **Test the confidence measure for DISCRIMINATION, not plausibility.** Split emissions into
  correct/wrong against ground truth and compare the distributions. All three measures tried so far
  *looked* reasonable and none separated. This is the single most repeated mistake.
- **Do not judge by eye.** The spike drives nothing on screen — it only calls `print()`, and the nav
  BPM readout keeps its manual value regardless. An on-device impression that "it tracked the tempo"
  during this session was reading the static manual number. Measure from the log.
- **A lock stage makes any estimator look better by eye.** Stability is not correctness. Always log
  the locked value and the live candidate side by side.
- **Test the failure cases, not just the tracks with a beat.** Silence, beatless ambient,
  between-tracks and a mid-run tempo change. A confident wrong answer is far worse than no answer, and
  a test set of only easy material cannot find it.
- **Wait for complete windows before calling a verdict.** Two premature "fail" calls in this session
  both had to be corrected, and both times the truth was more favourable than the early read.

---

## 10. Runtime constraints that apply to any approach

Both discovered by accident, both silent, neither algorithmic:

- **Detection only runs while PocketVJ is FOREGROUNDED.** Godot pauses its main loop on Android
  `onPause`, so onset consumption stops entirely. Observed: 17 minutes of dead air while another app
  had focus. A performer switching to their music player kills detection outright.
- **Any phone call takes the mic** via `MODE_IN_COMMUNICATION`, with aggressive AEC/NS/AGC applied.

Any shipped feature needs to detect and surface both, or it will appear broken for reasons the
performer cannot see. Note that **Option 4 is immune to both**, which is another point in its favour.

---

## References

- Scheirer, E. (1998), *Tempo and beat analysis of acoustic musical signals* — comb-filter resonator
  bank (Option 3).
- Ellis, D. (2007), *Beat Tracking by Dynamic Programming* — onset-strength envelope plus global
  dynamic-programming beat tracking; the source of the standard envelope + autocorrelation pipeline.
- `librosa.onset.onset_strength` / `librosa.beat.tempo` — a reference implementation of Option 1 worth
  reading before writing any of it.
- `AUTO_BPM_SPEC.md` — the feature spec, the authority model, and the full spike results.
