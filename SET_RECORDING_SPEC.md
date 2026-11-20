# PocketVJ — Set Recording (spec / backlog)

**Status:** **SPIKE DONE AND PASSED (Session 22) — approach A is confirmed viable; the feature is
cleared to build.** Own document because the encoding-method decision is load-bearing and easy to
get wrong. **Read §0.1 before writing any of the rest.**

**Goal:** record the final projected output — the `OutputWorld` texture, post warp/mask/FX — to an MP4 on device, so a set can be replayed, shared, or handed to a promoter.

---

## 0. The one decision that matters: how to encode

The frame already exists — `OutputWorld.get_texture()` is the finished 1920×1080 image. Recording is getting that texture into an MP4. **The trap is doing it in real time on the phone while decode + shading + the EGL bridge are all already running.** Dropping frames mid-set is the one failure a live tool can't have. Three approaches, and the choice is a real tradeoff:

**A — MediaCodec surface encoding (hardware, recommended).**
Feed the output into an Android `MediaCodec` encoder configured for an input Surface, using the hardware H.264/HEVC block. Cheap on CPU/GPU because the encode block is separate silicon — the same reason DUAL·TEX's ExoPlayer path was free.
- Pro: minimal frame-rate impact; native container/muxing.
- Con: **Kotlin/JNI** (breaks GDScript-only, like the bridge) and needs the output as an EGL surface the encoder can read. Since the EGL bridge already blits `OutputWorld` to a surface, this is architecturally close — the encoder is *another* consumer of the same texture. Reuse that machinery.

**B — Godot viewport → image per frame → encode offline.**
`get_image()` each frame to disk (or a ring buffer), encode later. No live encoder.
- Pro: no live CPU encode; pure GDScript.
- Con: `get_image()` is a GPU→CPU readback every frame (~10–30 ms) — **that alone can blow the frame budget**, plus enormous storage (raw frames). Likely worse for live use than A despite sounding simpler. Probably rejected.

**C — external/HDMI capture.**
Punt: the projector output is already on HDMI; a cheap HDMI recorder box captures it with zero phone cost.
- Pro: no app work, no frame-rate risk, records exactly what the audience saw.
- Con: extra hardware, not in-app. **Worth stating in the docs as the zero-risk option** — for many gigs this is genuinely the right answer and makes in-app recording a "nice to have" rather than essential.

**Recommendation:** A if building in-app (reuses the bridge's surface path). Weigh C (HDMI box) as the zero-risk fallback if A can't hold frame rate.

**DECIDED — spike before building.** Do NOT build the full recording feature first. Build the smallest thing that answers the only question that matters: **does the phone hold 60 fps while hardware-encoding?** A minimal MediaCodec encoder consuming the same `OutputWorld` surface the EGL bridge already blits to, recording ~30 s, logging frame time on both the 9a (G4) and 8 (G3). If it holds → build the rest (UI, audio mux, storage). If it tanks → the HDMI capture box is the supported method, documented, move on. Measure the risk before committing the architecture — same discipline as the preload and DUAL·TEX work.

---

## 0.1 SPIKE RESULT — **PASS.** Approach A holds 60 fps. (Session 22, spike commit `21eacd5`)

**Verified on the Pixel 9a with a real display attached and DUAL·TEX live** — i.e. deck decoding +
shading + the EGL bridge blitting to the BenQ + hardware encode, all at once. This is the
configuration that matters, not a phone-only number.

### The headline

**The encoder never back-pressures the render thread. `eglSwapBuffers` on the MediaCodec input
surface averaged 0.51 ms (max 2.72 ms) against a 16.6 ms frame budget** — a factor of ~30 of margin.
That single number is the answer: when a surface-input encoder cannot keep up, its input BufferQueue
fills and the swap *blocks the producer*. It never came close.

- **Zero frames lost between GL and file:** 2632 frames fed → `ffprobe` counts **2632** in the MP4.
- **Cadence is true 60 fps:** p50 inter-frame gap **16.72 ms** (p90 19.58, max 52.9).
- **1920×1080 H.264, 45.3 s, 11.95 Mbps, 67.6 MB** — the encoder hit its requested 12 Mbps almost
  exactly, so §1's storage math is confirmed sound (it is linear in bitrate: 10 Mbps = 75 MB/min,
  the 12 Mbps used here = ~89 MB/min ≈ 5.4 GB/hour).
- **The recording is the finished projected image**: a frame pulled from the MP4 shows the two-region
  masked composite on black with **no UI chrome** — `OutputWorld` post warp/mask/FX, exactly as spec'd.
- Encoder self-report: `c2.exynos.h264.encoder`, `sizeRate=true`, performance points include
  `1920x1088@240`. (Its `achievable=[58.0, 99.0]` benchmark range is what the vendor XML advertises and
  what made this look marginal in advance — **it under-sells the real behaviour**, since we sustained
  60 with 30× swap margin.)

### ⚠️ The fps dips are NOT caused by recording — this needed a control to establish

The bridge blit dips to ~52–55 fps a couple of times per 30 s window *during* recording. **It does the
same with recording off** (control windows: dips to 52.9 / 53.5 / 54.9 / 55.3). Whatever they are —
GoZen loop boundaries are the prime suspect — they are pre-existing and out of this spike's scope.
Reading them as an encode cost would have been the easy wrong conclusion.

### What recording DOES cost: about one Mali DVFS step

Sampling `/sys/class/misc/mali0/device/cur_freq` (the honest proxy — the fps readout is vsync-capped
*and* delta-smoothed), % of samples at 723 MHz over 30 s windows:

| recording | run A | run B | warm final |
|---|---|---|---|
| **off** | 36% | 1% | 19% |
| **on** | 58% | 55% | — |

Controls vary a lot (content brightness moves the clock), but the separation is clean and the "on"
figures are tight. Median moves 580 → 723 MHz.

⚠️ **723 MHz is NOT the ceiling, and this is the load-bearing correction.** On the 9a
`/sys/class/misc/mali0/device/available_frequencies` **reads** (it is permission-denied on the Pixel 8,
which is why the earlier note said otherwise): `940 890 850 807 **723** 649 580 521 467 419 376 337 302
150` MHz. Recording sits on the **fifth step from the top with four steps above it** — real cost,
comfortable headroom.

### ⚠️ Frame-subsampling is NOT a cost lever — a useful negative result

An `everyNth` knob was built to fall back to 30 fps capture if 60 tanked. **N=2 produced a correct
30 fps file (1322 frames, p50 gap 33.42 ms) but did not reduce GPU load at all** — 58.3% at 723 MHz vs
55–58% for N=1. So the cost is not proportional to blit rate, and **there is no reason to ship a
half-rate capture mode**: if 60 works, take 60. Don't rebuild this lever on the assumption it helps.

### What the spike did NOT answer

- **Thermals over a real set.** Longest run was 45 s. §1's sustained-hour question is untouched and is
  now the biggest open risk — the encode is nearly free per-frame, but an hour of it plus HDMI is not.
  ✅ **Answered in §0.2** (40 min, no throttling).
- **The Pixel 8 (Tensor G3).** Only the 9a was measured. 🔴 **Still owed.**
- **Audio**, storage management, and what happens when the disk fills mid-set.
  ✅ **Answered in §0.3 (audio) and §0.4 (disk-full).**
- Whether FX/masks under heavier load change the picture (this ran with a 2-region composite,
  `effect=0`, deck frozen in MANUAL).

### Build notes for the real feature

- `SurfaceRecorder.kt` is deliberately standalone and **duplicates ~60 lines of shader/quad
  boilerplate from `EglBridge.kt`** so a recorder bug could not take the projector down while the
  answer was unknown. That reason has expired — **factor out a shared blitter** when building the feature.
- The spike's trigger is a sentinel file polled from `pipeline.gd`; `git grep -n "# SPIKE"` is the
  removal list. Real UI is §2.
- Minor: `stop()` reports `encFrames` one frame stale (2631) because it returns before EOS drains;
  the `REC FILE DONE` line has the true count.

---

## 0.2 THERMAL + STORAGE SOAK — **40 min, no throttling. Storage is the binding constraint.**

40 minutes of continuous 1080p60 recording on the 9a, real load: **DUAL·TEX blitting to a real
display + 2 warped mask regions each running the ASCII shader + a SEQUENTIAL deck switching clips**.
Ring-buffered in 10-min segments (files deleted as they closed — the phone has only 4.18 GB free).

### Thermal — conclusively NOT the constraint

| | |
|---|---|
| Thermal status | **LIGHT (1) for all 154 samples.** Never escalated. |
| VIRTUAL-SKIN | start 40.6 °C · **peak 42.8 °C at t≈9 min** · **end 41.1 °C** |
| MODERATE threshold | **43.0 °C — never crossed** |
| G3D (GPU) | 55–60 °C, flat |
| Mali clock | 53% of samples at 723 MHz (of a 14-step ladder topping at 940) |

⚠️ **The temperature curve is asymptotic, not linear — it peaks around 9 minutes and then FALLS.**
An early extrapolation from the first 10 minutes (+1.3 °C/10 min) predicted crossing MODERATE by
minute 25–30. That was wrong: the device heat-soaks to equilibrium and settles. **Do not project a
thermal trend from the first minutes of a soak.**

**Frame rate did not degrade — it improved.** First third → last third: blit 55.9 → 57.9 fps, Godot
57.0 → 58.1 fps. That is the opposite of throttling, and it is the strongest single statement the
soak makes.

Thresholds read off the device (`dumpsys thermalservice`, `VIRTUAL-SKIN` hot-throttling):
`[_, 39.0, 43.0, 45.0, 46.5, 52.0, 55.0]` for LIGHT/MODERATE/SEVERE/CRITICAL/EMERGENCY/SHUTDOWN.

### The one rough patch, and why it is not the encoder

**1.6% of 5 s windows (7 of 445) fell below 45 fps**, almost all in a single ~65 s episode at
t≈7–8 min (worst window 9.6 fps). It is *not* at a segment boundary — the nearest muxer stop is two
minutes away. The log for that window shows the deck thrashing: **SEQUENTIAL at 115.9 BPM switches a
clip roughly every 0.5 s**, and every switch is a full GoZen open/close with a ~25-line debug dump.
Encoder swap stayed at 0.5–1.0 ms through most of it (one window reached 4.67 ms avg / 93 ms max —
back-pressure as a *symptom* of a CPU-saturated system, not its cause).

⚠️ **Caveat, stated plainly:** this stressor is far above real use (a set does not cut twice a
second) and it also generated ~50 logcat lines/sec into a streaming adb capture. **The episode is not
cleanly attributable to recording without a matched no-recording control at the same switch rate,
which was not run.** What the soak does establish is that nothing degrades over time.

### Storage — the real ceiling

Measured across three 10-min segments: **888,776 / 910,000 / 907,396 KiB ⇒ ~92 MB/min**
(the 45 s spike file gave 89.7). At 12 Mbps, ~**5.5 GB/hour**.

| | |
|---|---|
| free on the 9a | 4.18 GB (109 GB device, **97% full**) |
| to Android's low-storage line (512 MB) | **~40 min** |
| to absolutely full | ~46 min |
| a 60-min set needs | 5.5 GB — **does not fit** |

To fit a set in the ~3.7 GB usable here: 8.4 Mbps for 60 min, 5.6 for 90, 4.2 for 120. **12 Mbps is a
"record a highlight" bitrate, not a "record the set" bitrate**, so bitrate is exposed.

**Battery: 23% → 12% over 39 min (~17%/hour)** — and the USB-C port is occupied by the HDMI adapter,
so a phone without a PD-passthrough adapter cannot charge while doing this. Worth a docs note.

---

## 0.3 AUDIO MUX — **shipped and verified (Session 23).** The recording is no longer silent.

A second AAC-LC track in the same MP4 files. **v1 records the DEFAULT INPUT DEVICE — the phone mic —
with no source selection** (a USB-C audio adapter presents as that same input, so line-in largely
works incidentally; picking it explicitly is a later refinement).

### The two decisions

**Source: Godot's existing capture bus, NOT a native `AudioRecord`.** `scripts/audio_bus.gd` already
holds an `AudioStreamMicrophone` open for audio reactivity. A second capture client in the same
process risks Android's concurrent-capture policy starving one of the two, and the loser would be the
shipped reactivity feature failing **silently** mid-set. One client, fanned out in GDScript, has no
such failure mode — and the recording then carries exactly the signal the visuals reacted to.
⚠️ `get_buffer()` **removes** what it returns, so `audio_bus` had to become the single reader; two
independent callers would not read the same signal twice, they would take turns with it.

**Muxing: live, both tracks, NOT a post-hoc remux.** A second pass at `stop()` would need a whole
extra copy of a multi-GB file exactly where §0.2 says storage is the binding constraint, and would
put the recording behind a *second* fragile finalize.

⚠️ **`SegmentMuxer.kt` is new because of two MediaMuxer rules**, both of which corrupt the file rather
than throwing somewhere obvious: it is **not thread-safe** (two encoders, two threads), and **a track
cannot be added after `start()`** — so a segment can no longer open the moment the video format
arrives. ⚠️ **The segment ORIGIN is shared:** a roll is triggered by a video keyframe, so that
keyframe's PTS is the zero *both* tracks rebase against. Per-track origins would give the two tracks
a different zero in every segment — audio stepping further out at each boundary, the sync failure
that only becomes visible an hour into a set.

**Timebase:** audio PTS anchors **once** to the video clock, then advances purely by **sample count**,
so main-thread scheduling never becomes jitter in the track. Gaps are not estimated — Godot's
`AudioEffectCapture` reports exactly how many frames it discarded, and that count is padded with
exactly that much silence.

### Four defects found ON DEVICE, each real

1. ⚠️ **The capture ring holds up to 0.5 s of audio from BEFORE REC was pressed** (measured: a first
   chunk of **18432 frames = 418 ms**). Encoded, that stale block shifts every real sound *late* by
   up to half a second. It only stayed out of the file by the race of the video clock not being
   established yet. Fixed with `clear_buffer()` at capture start.
2. ⚠️ **Audio produced before the muxer could open was dropped while video for the same window was
   held**, so every recording opened with picture and no sound — measured **audio `start_time`
   0.191 s against video 0.000 s**. Held and flushed now.
3. ⚠️ **A 20 ms `dequeueInputBuffer` wait lost 6 chunks over 5.5 min** — unaccounted loss, i.e.
   ~0.8 s of drift per hour. Now a 100 ms wait, and anything still lost is **deferred as silence**
   rather than vanishing from the timebase.
4. ⚠️ **Audio asked for but absent must never block the file.** A missing AAC format would otherwise
   hold the muxer shut and cost the **video** too. Times out to video-only, and the UI says so —
   a recording that turns out silent afterwards is the failure this whole feature exists to fix.

### Verified on the 9a

- **Mix rate is 44100, read at runtime** — there is no `mix_rate` in `project.godot`, and encoding a
  guessed rate is a pitch-shifted, out-of-sync track. ⚠️ Do not hardcode 48000.
- **L and R capture RMS are identical** (`0.00571 / 0.00571`), confirming Godot duplicates the mono
  mic into both channels — so the `(L+R)/2` downmix costs nothing. Checked rather than assumed.
- **6 segments over 5.5 min: 19589 video frames fed → 19589 written.** Per-part audio start offset
  **7.5 / 55.5 / 44.4 / 6.8 / 5.1 / 14.8 ms — scattered, NOT growing.** That non-growth is the
  statement that the shared origin holds; a per-segment origin bug would climb here.
- After the fixes: **0 padded, 0 chunks dropped**, audio duration within ~30 ms of video duration per
  segment, and the blit still **60 fps at 0.53 ms swap** — audio costs the render thread nothing.

### 🔴 What A/V sync verification does NOT cover

**The absolute offset is not calibrated.** The decks run `enable_audio=false`, so there is no in-app
event common to both tracks, and the residual is the device's mic capture latency (tens of ms on
Android) — that needs a loopback rig or a human clapping, not adb.

⚠️ **A reference tone played through the phone's OWN speaker does not work as a substitute** — it
never appeared in the capture at all (media volume 22/25, playback confirmed `state:started` on the
speaker throughout, and the mic demonstrably peaking 32114 on room audio in another run, yet no 2 kHz
periodicity and 16 dB lower level). **Leading hypothesis: echo cancellation on the capture path
removing the device's own output** — which is precisely what AEC is for. Not proven, but it means
**self-played reference audio is the wrong instrument here**; use an external source.

---

## 0.4 DISK-FULL — **force-tested, not threshold-tested (Session 23). Both files playable.**

§0.2 left "what happens when the disk fills mid-set" open, and b209dfe only ever checked the
threshold arithmetic. Both cases were actually forced, using `fallocate` (instant on this fuse
filesystem — 200 MB in 0.06 s, which is what makes the harsh case testable at all).

**(a) The reserve fires — PASS.** Filled to ~650 MB free against the 512 MB reserve. The drain
thread's own floor stopped the recording at `disk-full` after 126.8 s / 240 MB, and **free space
settled at 518 MB — the reserve preserved almost exactly.** The file: 7583 frames fed → **7583 in the
file**, both tracks, audio aligned to **5.1 ms**, full end-to-end decode clean.

⚠️ **Android reclaims cache as the disk fills, so the floor arrives LATER than arithmetic predicts** —
199 MB written consumed only 92 MB of reported free space. Do not compute remaining record time and
treat it as a deadline.

**(b) Genuinely 0 bytes free during the write — ALSO PASS, and this contradicts the documented
assumption.** With ~844 MB free mid-recording, `fallocate` took the volume to **0 available in one
step**, skipping the 2 s guard window entirely. `writeSampleData` failed, the recorder self-stopped,
and — **`mx.stop()` SUCCEEDED. The file is fully playable**: 1495 frames, both tracks, 7.0 ms
alignment, clean decode.

⚠️ **So "a full disk AT `stop()` costs the whole recording" did NOT reproduce.** The reserve is still
right — Android's own low-storage line is 512 MB and running a phone to zero is bad for the whole
system — but **its stated justification was stronger than the evidence.** What actually bounds the
risk is **segmenting**: measured across three files, **moov is a consistent 15.3–16.0 bytes per
frame**, so a 5-minute segment's moov is **~270 KB** — about **1900× smaller than the 512 MB
reserve**, and small enough that it fit even at 0 free.

⚠️ **Caveat on (b):** the file that survived was 25 s. moov scales linearly with frame count, so this
does not prove an arbitrarily long recording would survive — it proves a *segment-sized* one does,
which is the only size that ever has to be finalized.

---

## 1. Scope decisions (for whichever in-app path)

- **Resolution/bitrate:** record at output res (1920×1080) or lower to save space/CPU? 1080p @ ~8–12 Mbps is the obvious target; expose it.
- **Audio:** ✅ **DONE — see §0.3.** AAC-LC mono from the phone mic, muxed live as a second track,
  toggleable in Library ▸ OUTPUT. Input-source selection (line-in) deliberately deferred.
- **Storage:** write to `/storage/emulated/0/PocketVJ/recordings/` — public, reachable by the file manager, **not** `user://`.
- **Long-set storage math:** 1080p @ 10 Mbps ≈ 75 MB/min ≈ 4.5 GB/hour. Warn on low space; consider a max-duration or size cap.
- **Thermals:** a phone decoding + shading + bridging + *encoding* for an hour, driving HDMI, will run hot. Measure sustained; the hardware encoder (A) is far better here than any software path.

## 2. UX

- A single REC toggle on the transport bar, unambiguous recording indicator (a red dot that can't be mistaken for anything, but NOT projected — UI-layer only, like all chrome).
- Never let REC state be silently lost — if encoding fails mid-set (storage full, thermal), surface it without interrupting the projection.

## 3. Performance gate

Whatever the path: **the deck must still hold 60 fps with recording live.** Measure on both the 9a (G4) and the 8 (G3). If in-app recording can't hold frame rate, that's the answer — document C (HDMI box) as the supported method and move on.

✅ **Cleared on the 9a (Session 22) — see §0.1.** 60 fps held with a real display attached and
DUAL·TEX blitting; encoder swap 0.51 ms avg against a 16.6 ms budget; no frames lost.
🔴 **Still owed on this gate:** the **Pixel 8 (G3)**, and **sustained thermal behaviour over a real
set length** — 45 s proves the steady-state per-frame cost, not an hour of it.
