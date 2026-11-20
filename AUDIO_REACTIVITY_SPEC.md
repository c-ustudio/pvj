# PocketVJ — Audio Reactivity (spec / backlog)

**Status:** §6 (Mod v2) BUILT 2026-09-30 — the analyser (bands, hit, brightness, band onsets), targets, curves, master amount, recipes, meters, KICK/HATS triggers; headless-verified (`tools/verify_mod_matrix.gd`), not yet heard in a room. §0's listening test is still the prerequisite for tuning. Originally: not started, queued **after** Phase 1 sequencer steps 4–7.
**Why after:** several trigger modes below only make sense against a `Sequence` (beat-quantized launch, audio-advance-through-arrangement). Building the analyser first means building against a target that's about to change shape.

**What exists today:** `audio_bus.gd` (`GlobalBus`) does mic onset detection → `GlobalBus.beat`, which drives the TAP dot pulse and, when audio-switch is enabled, fires `swap()` to the mode's pre-cued target with `AUDIO_REFRACTORY_SEC = 0.2`. Broadband only. **Never verified against real music** — only ambient noise (Session 10, step 7). That listening test is the prerequisite for everything below.

---

## 0. Prerequisite — listen before building

Ten minutes, real music through speakers, existing build, swap log open:

- Does it fire on the **kick**, or on everything? (Broadband onset fires on any energy jump.)
- Does **200 ms refractory** feel right? At 123 BPM a beat is 488 ms → ~2 triggers/beat allowed.
- Does it **hold gracefully** through builds and snare rolls, or feel like it's dropping cuts?

Test material: a clear four-on-the-floor track first, then something dense.

**If broadband already feels musical on a kick-led track, band-gating is a refinement, not a fix — and the priority shifts to modulation (§3).** Decide from the listen, not from this document.

---

## 1. The core split

Audio reactivity is two channels that behave completely differently. Conflating them is why the current implementation causes trouble.

| | **Triggers** (discrete) | **Modulation** (continuous) |
|---|---|---|
| What | onset/transient → fire an event | envelope → drive a value each frame |
| Targets | `swap()`, effect toggle, shuffle | shader uniforms, warp, mask params |
| Cost | ~0 (post-v0.3, cue/swap) | **free** — a uniform write per frame |
| Risk | mistimed cut | none |
| Built? | yes, broadband only | **no — this is the gap** |

**Modulation is the underexploited half.** It never touches the decoder, costs a uniform update, and gives continuous audio-reactive motion *between* cuts. Most of the "feels alive" quality in a VJ set comes from this, not from switching. It is also **independent of the sequencer work** — different files, no conflict — so it can be slotted into a lighter session at any point.

---

## 2. Triggers

### 2.1 Already true (post-v0.3)
Audio-advance is **cueable in every mode**: the transient decides *when*, the mode's `next_index_provider` decides *what*. RANDOM uses pick-and-remember, so even random targets are pre-warmed. No stalls from audio switching.

### 2.2 Modes to add, in likely priority order

1. **Band-gated onset** — split into low / mid / high, trigger from one band. **Biggest practical upgrade over broadband:** trigger on kick only, or hats only. Route different bands to different targets (kick advances the clip, hats poke an effect). Cheap.
2. **Beat-quantized trigger** — a transient *arms* the switch; it fires on the next `BeatClock` beat/bar. Combines audio responsiveness with musical timing, and conveniently guarantees cue lead time. Good default for a sequenced set. **Depends on the strip existing.**
3. **Sustained-level gate** — fire when energy stays above threshold for N ms (a build or a drop, not a single hit). Section changes rather than per-beat cutting.
4. **Silence / drop detection** — energy below threshold for N ms → blackout, freeze, or cut to a designated clip. Very effective on breakdowns; trivially cheap.

### 2.3 Kick / snare / hat classification
Worth naming honestly: proper drum classification is a real DSP problem. **Band-gated onset with a tuned threshold gets ~80% of the musical benefit for ~10% of the work** — a low-band onset above threshold *is* a kick in most dance material. Start there. Only pursue true classification (spectral flux per band, template matching) if band-gating demonstrably isn't enough after the listening test.

### 2.4 Constraints that already apply
- **Refractory window** stays. A dense passage must not fire swaps faster than cues complete (~195 ms typical / 251 ms worst demux for the current library).
- Per-band thresholds need a UI. Sensitivity is track-dependent and will need adjusting mid-set — this is a performance control, not a settings-screen value.

---

## 3. Modulation (the gap)

### 3.1 Sources
1. **RMS / loudness envelope** → the workhorse. Attack/release smoothing so it breathes rather than jitters.
2. **Band envelopes** (low/mid/high, separately smoothed) → three independent modulators. Best value per line of code: bass → pixelate size, highs → RGB shift.
3. **Peak-hold / decay follower** → snaps up on a transient, decays smoothly. **Arguably the single most useful modulator for VJ work** — gives continuous parameters a "hit" feel.
4. **Spectral brightness (centroid)** → tracks timbre rather than volume, so it moves when loudness doesn't. Good for ASCII density, chroma amount.
5. **Beat phase from `BeatClock`** (0..1 in the bar) → not audio analysis, but the same kind of modulator and perfectly stable. Tempo-locked ramps and pulses.

### 3.2 Targets
Any exposed shader uniform (the six shaders' parameters), QuadWarp corners/scale, mask opacity, ShaderSlot QUALITY. Start with two or three.

### 3.3 Shape
An `AudioAnalyser` node exposing smoothed `rms`, `low`, `mid`, `high`, `centroid` (all 0..1) and `signal transient(band: int, strength: float)`.

Then a **modulation matrix**: `(source → target, amount, curve)`. That is the part that makes it feel like an instrument rather than a preset. **Ship with 2–3 sources and 1–2 targets first** — the matrix is what lets it grow cheaply afterwards.

---

## 4. Performance notes

- Modulation is a per-frame uniform write. Free.
- FFT/band-splitting on the mic input is cheap at typical sizes, but **profile it** — the deck holds 60 fps and this runs every frame. Godot's `AudioEffectSpectrumAnalyzer` is the obvious starting point; measure before assuming.
- Nothing here touches `ClipEngine`. The decode path is settled and must stay untouched.

---

## 5. Open questions

- Mic vs line-in: is the source always the room mic, or should a line input be supported for cleaner analysis at a gig?
- Should band thresholds persist per-clip, per-set, or globally?
- Does modulation need a global "amount" master (one knob to pull all reactivity down mid-set)? Probably yes — that's a performance control, and it's the kind of thing you want when the room changes.

---

## 6. Mod v2 — the system as it is, and how it grows (designed 2026-09-30, before the build)

Written after the camera work, when the user asked for §3.1–3.3 and "a proper think about the system how it is and how we could expand, with ease of use in mind". Sections 0–5 above are the original backlog; this is the plan that was built from it.

### 6.1 What is there today, honestly

- **One detector, broadband.** `GlobalBus` turns the mic into `level` (smoothed 0..1) and `beat` (a level jump over its running average, noise floor, 0.12 s cooldown). Everything audio-reactive hangs off those two: the TAP dot, audio-advance, BEAT FLIP's ONSET trigger, the crossfader's AUDIO mode, the speed ramp. The spectrum analyser runs on the same bus but only tempo detection reads it.
- **A matrix with one destination.** MOD MATRIX has four slots (source, depth, invert) and they all add up into ONE number: the deck's intensity. Sources: LEVEL, PULSE, BEAT (bar phase), TRACK, HAND, the crowd aggregates. It is a mixer of sources into intensity, not a routing matrix.
- **Triggers are three separate features** with their own copies of "when": audio-advance (mode panel, refractory 0.2 s), BEAT FLIP (ONSET or GRID, subdivision), crossfade AUDIO. They share the detector's sensitivity and floor, which is right, and nothing else.
- **Setup is by slots.** To get "bass pumps the effect" you open the matrix, cycle a slot to LEVEL, set a depth, and hope the room's bass is what LEVEL is hearing. There is no way to see what the sources are doing while you set them, except the intensity readout.

None of it is wrong; it is the first half of §1's split with the second half missing, and one destination.

### 6.2 What it becomes

**Sources (the analyser, in `GlobalBus`).** Added beside `level` and `pulse`, all 0..1, all read per frame:
- `low`, `mid`, `high` — band envelopes from the spectrum analyser already on the bus (≈20–150 Hz kick and bass, 150–2000 Hz body, 2000–10000 Hz hats and air), each **self-normalised** against its own recent peak (a slowly-decaying maximum) so that a quiet room and a loud one both give 0..1 without a slider per band — the room's own loudness is the reference. Attack fast, release slower, like `level`.
- `hit` — the peak-hold/decay follower: 1.0 on an onset, then a curve down over ~0.4 s. The "punch" source. (`pulse` stays as it was: a straight-line 0.25 s flash for the TAP dot.)
- `bright` — spectral centroid, 0..1 across the log-spaced bands: timbre rather than loudness.
- **Band onsets:** the same ratio test per band → `band_beat(band)`. A low-band onset above threshold *is* the kick in most dance material (§2.3); that is what KICK means below.
- `BeatClock.phase` (BEAT) stays, as the tempo-locked saw. BAR (0..1 across the bar) is added beside it.

**The matrix gets destinations.** Each slot: source → **target**, depth, invert, **curve**.
- Targets: **INTENSITY** (as now), **FX A** and **FX B** — the active effect's first and second tunable, whatever they are (the row says which: "FX A · BLOCK SIZE"), **SPEED** (playback speed, taking over the AUDIO SPEED ramp's "max speed" when routed). More can be added to the same list (mask opacity, warp scale) without touching the UI shape.
- Curve: **LIN / SQR / SQRT** — squared for punch (quiet stays quiet), root for lift (a little sound moves it). One cycle row.
- A slot to FX A adds `depth × curve(source) × half the tunable's range` on top of whatever the slider says; the slider stays the base, the matrix moves around it, and with the matrix off the base is exactly what is on the wall. A tunable's base is whatever the material holds — a slider moved mid-set is picked up as the new base, not fought.
- **AMOUNT** — one master slider at the top of the section, 0–100%, scaling every slot's depth. The mid-set knob: the room got dense, pull everything down; the drop, push it back up. (§5's open question, answered yes.)

**Ease of use: recipes, and meters.**
- A row of **recipe chips** above the slots — PUMP, SHIMMER, BREATHE, HITS, CLEAR — each of which fills the four slots with a known-good routing (PUMP: LOW → INTENSITY, SQR, depth 1.2 + HIT → FX A; SHIMMER: HIGH → FX A + BRIGHT → FX B; BREATHE: BEAT inverted → INTENSITY, slow; HITS: HIT → INTENSITY + HIT → SPEED). Tap one, hear it, tweak a slot if you like. A first-time user never has to know what a slot is.
- A **meter row** — the five audio sources as small live bars while the panel is open, at 10 Hz. Tuning is watching a number move while you drag (the AUDIO INPUT rule); now the sources can be watched too.

**Triggers share one vocabulary.** Wherever something fires on the music, the choice is the same four: **ONSET** (broadband, as now) · **KICK** (low band) · **HATS** (high band) · **GRID** (the tap grid). BEAT FLIP's TRIGGER row and audio-advance's new "Advance on" row both offer it; the crossfader's AUDIO mode follows when it is next touched. Band onsets ride the same sensitivity and floor as the broadband one.

**BEAT FLIP itself** gains KICK and HATS as triggers (the ask), and nothing else in this round: its mode/treatment/auto-change rows are already the richest trigger consumer in the deck, and the thing it lacked was a trigger that means the kick.

### 6.3 What is deliberately not in this round

- Per-band sensitivity sliders (§2.4). Self-normalised bands and the shared sensitivity are the bet; per-band sliders only if a real room proves the bet wrong.
- Beat-quantised triggers, sustained-level gates, silence detection (§2.2 items 2–4) — real features, later.
- Drum classification beyond band gating (§2.3).
- Mask opacity and warp scale as targets: the list is built to take them; nothing routes there yet.
- Any change to the decode path. Modulation is uniform writes and a playback-speed write, all change-gated.

### 6.4 Verification

`tools/verify_mod_matrix.gd`, headless: the analyser driven with synthetic band magnitudes (no mic on a desk) — envelopes, self-normalisation, `hit`'s decay, band onsets and their cooldown; the matrix's sum per target with curves, invert, master and ceiling; FX A/B applied to a real effect material with the base picked up from a moved slider and restored when the matrix goes off; recipes filling the slots; settings round-tripping every new key; BEAT FLIP and audio-advance firing on the chosen band only. What a desk cannot verify: whether KICK is the kick in a real room. That listening test (§0) is still owed, and is now cheap to run because the meters show what each band hears.

