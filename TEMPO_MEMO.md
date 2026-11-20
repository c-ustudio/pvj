# MEMO — where tempo detection actually stands

**2026-08-04.** One page. If you read nothing else about auto-BPM, read this.
Detail: `TEMPO_ENGINE_RESULTS.md` (numbers), `AUTO_BPM_ALGORITHMS.md` (options),
`AUTO_BPM_SPEC.md` (the two failed spikes), `TEMPO_PERCIVAL_SPEC.md` (the algorithm).

---

## What shipped

**Manual BPM entry** (`976b317`) — tap the readout, type a number. Works, verified across a cold
restart. ⚠️ Deliberately does **not** realign the beat grid: tap-tempo marks the downbeat, typing
corrects the rate only.

**DETECT** (`a4988a9`) — a button in that same dialog **proposes** a tempo; you press SET or CANCEL.
Three engines to choose from: **IOI · COMB · PERC**.

**Nothing detects automatically. Nothing changes tempo without a human pressing SET.**

---

## ⚠️ Why it is a proposal and not automatic

**Six confidence measures were built this session. None of them work.**

| measure | result |
|---|---|
| supporters / total | 64% precision — a coin flip |
| peak sharpness vs background | no separation; flat material scored *higher* than peaked |
| candidate dispersion | overlapping ranges |
| ACF peak vs search-range mean | saturated at 1.00 on every press |
| PERC accumulator concentration | 0.28–0.33 on the two **best** readings, 0.68 on a miss |
| cross-device agreement | both phones agreed on the same **26%-wrong** answer |

The last one is the sharpest lesson: agreement between two phones tells you the **capture** is
consistent, not that the **algorithm** is right.

Every one of these *looked* reasonable when built. **A confidence measure must be tested for
DISCRIMINATION against ground truth — split results into correct/wrong and compare the
distributions. Never ship one because the maths is plausible.**

Since no measure can say "I am unsure", a human stays in the loop. **That design absorbed every
failure below**: a 205 BPM reading on a 137 BPM track cost one glance and a CANCEL.

---

## How well it actually detects

**PERC (Percival / MTG-UPF) is accurate on steady material and unreliable on everything else.**

| material | tracks | error |
|---|---|---|
| **steady 4/4** | 130, 135, 122, 140, 160 | **0.1 – 1.9%** ✅ |
| **syncopated** | 137 | 20% / **50%** ❌ |
| **glitchy** | 150 | **26%** on both phones ❌ |
| unresolved | 81.3 | 28% — likely *Engine OS* half-timing, not PERC |

That split was predicted: the onset-envelope approach needs regular transient structure, and
syncopation or glitch removes it.

⚠️ **On the hard tracks the ranking reverses.** On 137 the 9a's IOI held 135.8–137.9 (within 1%)
while PERC was 50% off. That is why all three engines stay — not merely as a fallback, but because
which one wins is material-dependent.

**Practical guidance:** trust DETECT on four-to-the-floor. On breakbeat, footwork or glitch, expect
to reject it and tap instead.

---

## The one real algorithmic win

**The octave decision** (`b9d0a14`). Synthetic 174 BPM had been collapsing to 87; it now reads 173.7,
and on the 160 BPM footwork track the Pixel 8 — which had locked half-time — fired `oct=x2.0` and
recovered **160.2**.

It works by scoring half / true / double on **precision × recall over onset energy**: half-time misses
every other beat (low recall), double-time wastes pulses on silence (low precision), the true tempo is
strong on both. ⚠️ Scoring them on pulse-train strength instead — the obvious approach — makes it
*worse*, because that metric structurally favours slower candidates.

⚠️ **It is not free**: it also broke the 137 track, firing `x2.0` onto a wrong internal lock to land
at ~205. Net positive, but it can amplify an error as well as fix one.

---

## If someone picks this up again

1. **Don't build a seventh confidence measure without a discrimination test first.**
2. **Measure on both phones.** Divergence is informative; agreement is necessary but not sufficient.
3. **Read the `oct=` field.** `x2.0` on a track that was already right is the over-correction signature.
4. **Ground truth is not ground truth.** Engine OS is an estimator too; on 81.3 it is probably the one
   that is wrong. A hand-tap is the only independent reference in the room.
5. **The real ceiling is the input, not the maths.** `AUTO_BPM_ALGORITHMS.md` §2 — a threshold-crossing
   onset stream throws away magnitude, everything below threshold, and ~98% of the data rate. PERC
   already computes its own FFT to escape that; the next step up is **Ableton Link from Engine OS**,
   which gives exact tempo *and* phase with no estimation at all.
