# PocketVJ — the tracking module (CameraX → MediaPipe → parameters)

**Status: M0–M3 + M6 BUILT and device-verified; M4 (field mode), M5 and
M8 (crowd mode, §13) are design.** This document is the spec for a
general-purpose on-device tracking module: the phone's camera becomes a
sensor, MediaPipe turns frames into a **small set of filtered, normalised
parameters**, and three first-class consumers read them:

1. **PocketVJ itself** — shader uniforms and pipeline modulation, local,
   lowest latency, and **never dependent on any network path being alive**;
2. **TouchDesigner** — over the existing PVJ link's LAN, as OSC
   (the `/pvj/out/...` outbound tree `OSC_NAMESPACE_SPEC.md` §4 reserved);
3. **Bitwig** — OSC as modulation, occasionally as triggers.

It is deliberately **not built for one installation**. Landmark mode serves
the single-performer case (head position drives the visual); field mode
serves the crowd case (aggregate statistics over a person mask), with channel
names and ranges **pinned to an existing TD patch that consumes a Kinect
depth field** — the TD side must not be able to tell which source is live.

Anything below that describes MediaPipe's Android API surface from belief
rather than verified fact is marked **(unverified — confirm at M0)**. The
open questions are marked **OPEN:** inline and collected in §10.

---

## 1. Purpose and scope

**In scope (v1):**

- CameraX capture (rear lens default, lens selectable) feeding MediaPipe
  Tasks vision, on-device, no cloud, no recording.
- **Landmark mode** — face landmarks for ONE tracked subject; primary output
  head position `(x, y, z)`, z **relative to a baseline captured at
  acquisition** (see §4.1 — absolute MediaPipe z varies ±10–15% per person).
- **Field mode** — person segmentation, no per-person identity; five
  aggregate channels (`occupied_volume`, `motion_energy`, `centroid_x`,
  `centroid_y`, `spatial_variance`), all 0–1, names and ranges **frozen** to
  match the Kinect-field TD patch.
- One Euro filtering **on device, before any transport**, both parameters
  live-tunable.
- Presence/acquisition/loss with a grace period; multi-subject arbitration
  that does not oscillate.
- Trigger machinery (hysteresis + dwell + optional BeatClock quantise) for
  discrete outputs — Bitwig is the unforgiving consumer here.
- OSC out at a fixed rate: **derived values only, never raw landmark
  arrays**.

**Out of scope (v1):** hand landmarks (the data model reserves room — §4.1;
**shipped at M2b**), pose/skeleton, multi-subject *output* (arbitration picks
one — **§13 crowd mode adds it at M8**), gesture
recognition, face identity/recognition of any kind, camera auto-calibration
(the north-star pillar — separate spec), recording tracking data, and
running landmark + field mode **simultaneously** (one graph at a time; see
§8 for why). **True depth sources** (ARCore Depth, monocular depth models)
are designed in §12 as post-v1 tiers on the same output contract — read §12
before assuming the Kinect story needs them.

**The local-first law:** the GDScript side reads values by polling the
plugin every frame. OSC is a *second* reader of the same filtered snapshot.
If Wi-Fi dies, the shaders keep moving. No consumer is upstream of another.

---

## 2. Architecture

Same shape as the proven DUAL·TEX split (`EglBridge.kt` /
`PresentationPlugin.kt`): **Kotlin owns the hardware and the hot loop,
GDScript owns policy and routing.** The plugin never touches the network —
"OSC is another widget" (Session 32's law): pipeline reads the snapshot and
fans it out exactly like it fans out link verbs.

```
Android / Kotlin (android/build/src/main/java/com/pocketvj/)
┌─────────────────────────────────────────────────────────────────┐
│  TrackingPlugin.kt  (GodotPlugin "PocketVJTracking")            │
│  ├─ lifecycle, permissions, @UsedByGodot API, signals           │
│  │                                                              │
│  ├─ CameraX: ImageAnalysis, KEEP_ONLY_LATEST, own executor      │
│  │      │  (rear default; lens = setting)                       │
│  │      ▼                                                       │
│  ├─ MediaPipe Tasks (LIVE_STREAM, async result listener)        │
│  │      FaceLandmarker            ImageSegmenter                │
│  │      (landmark mode)           (field mode)                  │
│  │      │                              │                        │
│  │      ▼                              ▼                        │
│  ├─ Arbiter (sticky subject lock)  FieldStats (mask reduce)     │
│  │      │                              │                        │
│  │      └──────────┬───────────────────┘                        │
│  │                 ▼                                            │
│  ├─ OneEuroBank (per-channel One Euro, frame-PTS timestamps)    │
│  │                 ▼                                            │
│  └─ Snapshot (seq-numbered FloatArray behind a lock; latest     │
│               wins, written by listener thread, read by JNI)    │
└───────────────────────┬─────────────────────────────────────────┘
                        │ getFrame() poll, 1×/render frame
                        │ + signals for discrete events
Godot / GDScript        ▼
┌─────────────────────────────────────────────────────────────────┐
│  scripts/tracking_engine.gd  (TrackingEngine, Node)             │
│  ├─ owns plugin singleton, mode/lens state, settings I/O        │
│  ├─ TriggerLane(s): hysteresis + dwell + BeatClock quantise     │
│  └─ exposes: values Dictionary, presence, signals               │
│         │                    │                                  │
│         ▼                    ▼                                  │
│  pipeline.gd routing   scripts/osc_output.gd (new, §6)          │
│  (shader uniforms,     UDP → TD @4855-style, Bitwig             │
│   mod-matrix later)    30 Hz bundles, /pvj/out/track|field/...  │
└─────────────────────────────────────────────────────────────────┘
```

**Why filtering lives in Kotlin, not GDScript:** every consumer must get the
same clean signal (the brief's rule: filter before transport), and the One
Euro filter needs the **camera frame's timestamp**, not the render frame's —
inference completes on the listener thread at camera cadence, which the
GDScript poll only samples. Filtering at the source is the only place all
three consumers sit downstream of.

**Why triggers live in GDScript:** quantise-to-BPM needs `BeatClock`
(autoload, GDScript). Splitting trigger *evaluation* (Kotlin) from trigger
*quantise* (GDScript) would put one state machine on two clocks. The cost is
one render frame (≤17 ms) of trigger latency on top of the pipeline latency
— acceptable because a quantised trigger waits for the beat anyway, and an
unquantised one is driving visuals or a Bitwig gate where ±17 ms is inside
the noise the dwell timer already imposes.

**Threading contract** (mirrors `EglBridge`'s publish/reconcile discipline):

- Camera + inference callbacks run on the plugin's own executor(s) — **never
  on Godot's render thread**. This module, unlike `EglBridge`, needs no
  `onGLDrawFrame` hook at all; it touches no GL.
- Listener thread writes the snapshot under a plain lock (one small array
  copy; no allocation in steady state).
- `getFrame()` (called from GDScript, i.e. Godot's thread) copies out under
  the same lock. A `seq` field lets GDScript detect "no new inference since
  last poll" and skip downstream work.
- Signals (`subject_acquired` etc.) are emitted via `emitSignal` from the
  listener thread — Godot delivers plugin signals safely across threads
  (same pattern as `texture_output_ready`, which is emitted from a
  SurfaceHolder callback thread today).

### 2.1 The CameraEngine conflict — designed, not discovered later

`scripts/camera_engine.gd` already opens the **rear camera** through Godot's
CameraServer when the deck source is CAMERA. Android will not give two
clients the same camera: the second open either fails or **evicts the
first** (higher-priority client wins, the other gets `onDisconnected`)
— eviction order here **(unverified — confirm at M0)**, but the conflict
itself is certain.

**v1 rule: mutual exclusion, enforced in GDScript, loudly.**
`TrackingEngine.start()` refuses with `"camera-busy"` while
`camera_engine.is_running()` and the same lens is requested, and vice versa
(pipeline gates the CAMERA source cell while tracking runs). The status line
says which one holds the camera. Never silently evict — a VJ mid-set must
not lose the camera *visual* because tracking started, nor lose tracking
because they tapped SRC.

- Different lenses (rear visual + front tracking) **may** work — Pixels
  support limited concurrent multi-camera — but this is explicitly **not
  promised in v1**; the exclusion rule applies per-lens only after M0
  measures it. **OPEN:** does rear-CameraEngine + front-CameraX actually run
  concurrently on the Pixel 8 / 9a, and at what fps cost?
- **✅ BUILT AT M6 (Session 35) — the exclusion is now ROUTING.** Tracking
  owns the camera and *publishes* it: a CameraX `Preview` use case bound
  beside the analyzer renders into a `Surface` over a `SurfaceTexture`
  latched onto an `ExternalTexture` GDScript allocated — VideoLinkPlugin's
  receive path, camera-side, zero copies. `TrackCameraSource` (a SubViewport
  sampling that OES texture through a `samplerExternalOES` material) hands
  the deck an ordinary ViewportTexture, so ShaderSlot / masks / regions /
  MixWorld / DUAL·TEX never learn anything changed. **The rule is now
  "whoever holds the lens publishes it":** SRC▸CAMERA with tracking running
  routes to the tracking feed; turning TRACKING on while CAMERA is live
  hands the lens over (CameraServer stopped, then tracking started, then
  the wall re-pointed) instead of refusing. Two CameraServer/CameraX
  clients still NEVER overlap — that pair is the Session-33 wedge and the
  routing exists precisely to keep it impossible. CameraEngine's
  CameraServer path stays as the tracking-off backing.

### 2.2 Files

| File | Role |
|---|---|
| `android/build/src/main/java/com/pocketvj/TrackingPlugin.kt` | GodotPlugin: lifecycle, API, signals |
| `android/build/src/main/java/com/pocketvj/TrackingSession.kt` | CameraX + MediaPipe graph ownership (one per start(); torn down whole on stop/mode change) |
| `android/build/src/main/java/com/pocketvj/OneEuro.kt` | filter + per-mode filter bank |
| `android/build/src/main/java/com/pocketvj/FieldStats.kt` | mask → five channels reduction |
| `android/build/src/main/assets/mediapipe/*.task` | model bundles, packed into the APK |
| `scripts/tracking_engine.gd` | `TrackingEngine` node under `Main` (NOT inside OutputWorld — it renders nothing) |
| `scripts/osc_output.gd` | OSC 1.0 **encoder** + send scheduler (the sibling of `osc_input.gd`) |
| `scripts/trigger_lane.gd` | hysteresis/dwell/quantise state machine, reusable per trigger |

All Kotlin stays **tracked in git** in `android/build/src/main/java/com/pocketvj/`
— Godot regenerates `android/build/`, this subtree is ours (same as the nine
files already there). Manifest gains one meta-data entry
`org.godotengine.plugin.v2.PocketVJTracking` beside the existing two.
Gradle gains (versions indicative — pin at M0):

```gradle
// PocketVJ tracking: CameraX + MediaPipe Tasks vision
implementation "androidx.camera:camera-core:1.4.x"
implementation "androidx.camera:camera-camera2:1.4.x"
implementation "androidx.camera:camera-lifecycle:1.4.x"
implementation "com.google.mediapipe:tasks-vision:0.10.x"
```

⚠️ **CameraX wants a `LifecycleOwner` to bind to.** Godot's activity is a
plain Activity whose lifecycle CameraX can't observe directly
**(unverified — confirm at M0 which base class godot-lib 4.6 ships)**; the
fallback is binding to `ProcessLifecycleOwner` or driving a manual
`LifecycleRegistry` from the plugin's `onMainResume`/`onMainPause` hooks —
the plugin gets those callbacks today (`PresentationPlugin.onMainResume`
precedent). Decide at M0; the manual registry is the assumption in this
spec because it also gives us the "keep tracking while backgrounded? no —
stop it" policy explicitly (§9).

---

## 3. Kotlin ↔ GDScript interface — exact signatures

Follows the repo's JNI conventions: **String result tokens** (`"ok:..."` /
error words) for calls that can fail, **polled getters** for hot data,
signals for events. ⚠️ Per the JNI-returns memory: GDScript probes plugin
methods with `typeof() == TYPE_NIL` for missing-method (an older APK), and
coerces booleans explicitly.

```kotlin
class TrackingPlugin(godot: Godot) : GodotPlugin(godot) {

    override fun getPluginName(): String = "PocketVJTracking"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        // mode actually running ("landmark"|"field"), after camera+graph up
        SignalInfo("tracking_started", String::class.java),
        // terminal failure; token per §9 table
        SignalInfo("tracking_failed", String::class.java),
        SignalInfo("tracking_stopped"),
        // landmark mode only — fired AFTER the grace/stability logic, not raw
        SignalInfo("subject_acquired"),   // baseline captured; z is now valid
        SignalInfo("subject_lost")        // grace period expired
    )

    /**
     * Start tracking. mode: "landmark" | "field". lens: "rear" | "front".
     * Returns "ok" or an error token ("camera-busy" is decided in GDScript
     * BEFORE this call; tokens here: "no-permission", "no-camera",
     * "model-missing", "already-running", "bad-mode").
     * Async: camera+graph spin-up completes off-thread; success/failure
     * arrives as tracking_started / tracking_failed.
     */
    @UsedByGodot fun start(mode: String, lens: String): String

    @UsedByGodot fun stop()          // idempotent, synchronous teardown

    @UsedByGodot fun isRunning(): Boolean

    /**
     * The hot read. Fixed-layout FloatArray (→ PackedFloat32Array), §4.
     * Always returns the full layout; seq unchanged ⇒ no new inference.
     * Empty array ⇒ not running.
     */
    @UsedByGodot fun getFrame(): FloatArray

    /** One Euro params, applied live to every channel. */
    @UsedByGodot fun setFilter(minCutoff: Float, beta: Float)

    /** Landmark mode: recapture the z baseline from the current subject. */
    @UsedByGodot fun rebaseline()

    /** Inference throttle, Hz (camera keeps its own rate; frames between
     *  inferences are dropped by KEEP_ONLY_LATEST). Clamped 5..30. */
    @UsedByGodot fun setInferenceRate(hz: Int)

    /** "cpu" | "gpu" — takes effect on next start() (delegate is baked into
     *  the task options at graph build). */
    @UsedByGodot fun setDelegate(d: String)

    /** "mode|infer_fps|infer_ms_avg|camera_fps|dropped|delegate|lens"
     *  — polled at ~1 Hz for the status line, same idiom as
     *  getRecorderStats(). */
    @UsedByGodot fun getStats(): String
}
```

⚠️ **(unverified — confirm at M0)** that godot-lib 4.6's `@UsedByGodot`
marshals `FloatArray` → `PackedFloat32Array`. Believed yes (godot-lib
supports primitive-array signatures). Fallback if not: a pipe-delimited
String at 30 Hz (~200 bytes/frame — ugly but measured-cheap; the
`getRecorderStats` idiom at higher rate), swapped for the array when
confirmed.

GDScript side (the only consumer of the raw layout — everything else reads
`TrackingEngine`'s typed surface):

```gdscript
class_name TrackingEngine extends Node

signal started(mode: String)
signal failed(reason: String)
signal subject_acquired
signal subject_lost
signal values_updated              # once per NEW inference (seq advanced)

func start(mode: String) -> void      # lens/delegate/rate read from settings
func stop() -> void
func is_running() -> bool
func mode() -> String                 # "off" | "landmark" | "field"
func presence() -> float              # 0..1 (§5.3)
func value(chan: String) -> float     # by name: "head_x", "occupied_volume", …
func set_filter(min_cutoff: float, beta: float) -> void
func rebaseline() -> void
func add_trigger(lane: TriggerLane) -> void   # §5.4
```

`_process()` polls `getFrame()`, checks `seq`, updates the name→value map,
runs trigger lanes, emits `values_updated`. pipeline.gd and osc_output.gd
both connect to that — neither ever touches the plugin directly.

---

## 4. Data model

`getFrame()` layout — index-stable forever; new fields append. All values
already One-Euro-filtered and normalised **except** `seq`, `presence_raw`,
and `age_ms`.

| idx | name | range | notes |
|---|---|---|---|
| 0 | `seq` | int-as-float, monotonic | inference counter; unchanged ⇒ stale poll |
| 1 | `mode` | 0 off · 1 landmark · 2 field | |
| 2 | `presence` | 0–1 | debounced (§5.3); the value consumers use |
| 3 | `presence_raw` | 0/1 | this inference's raw detection, pre-grace |
| 4 | `age_ms` | ms | now − source frame timestamp (staleness guard) |

**Landmark mode (idx 5–15):**

| idx | name | range | definition |
|---|---|---|---|
| 5 | `head_x` | 0–1 | subject head centre, **output-image** horizontal; 0 = left edge of the frame *as the audience-facing composition sees it* (§4.2 orientation) |
| 6 | `head_y` | 0–1 | vertical, 0 = top |
| 7 | `head_z` | 0–1 | **relative depth**, 0.5 = baseline distance (§4.1) |
| 8 | `head_size` | 0–1 | inter-ocular distance / frame width — the 2D proxy that cross-checks z |
| 9 | `yaw` | 0–1 | head rotation, 0.5 = facing camera (from the transformation matrix rotation) |
| 10 | `pitch` | 0–1 | 0.5 = level |
| 11 | `roll` | 0–1 | 0.5 = upright |
| 12 | `crowded` | 0/1 | more faces than `max_subjects` visible (§5.2) |
| 13 | `n_faces` | count | raw detection count this inference |
| 14–15 | reserved | | hand-landmark room (v2: `hand_x`, `hand_y`) |

**Field mode (idx 5–9)** — names and ranges FROZEN to the Kinect-field TD
patch; the TD OSC In must see identical channels either way:

| idx | name | range | definition |
|---|---|---|---|
| 5 | `occupied_volume` | 0–1 | mean of the person mask = masked fraction of frame |
| 6 | `motion_energy` | 0–1 | mean abs luma difference between consecutive frames **inside the mask**, ÷255, × gain `motion_gain` (default 8.0), clamped. **OPEN:** the gain must be calibrated side-by-side against the Kinect patch's live range — the Kinect's depth-difference energy and a luma-difference energy have different natural scales, and 8.0 is a placeholder. |
| 7 | `centroid_x` | 0–1 | mask centroid, output-image horizontal |
| 8 | `centroid_y` | 0–1 | vertical, 0 = top |
| 9 | `spatial_variance` | 0–1 | `(var_x + var_y) × 6`, clamped — normalised so a mask spread uniformly across the whole frame reads ≈1.0 (uniform [0,1]² has var_x = var_y = 1/12). **OPEN:** confirm the Kinect patch's variance normalisation matches; this constant is the module's guess. |

**Empty-mask rule:** when `occupied_volume < 0.005`, `centroid_*` and
`spatial_variance` **hold their last value** (a centroid of nothing is
noise, and a jump to 0.5 would read as a person teleporting to centre);
`motion_energy` decays to 0; `presence` follows the grace logic with
`occupied_volume` as its detection signal (threshold `field_presence_floor`,
default 0.01).

### 4.1 The z story — relative, never absolute

MediaPipe's FaceLandmarker can output a **facial transformation matrix**
(option `setOutputFacialTransformationMatrixes(true)`
**(unverified — confirm exact option name at M0)**): a 4×4 pose of the face
in camera space whose translation is metric-*ish* — it fits a canonical face
model, so a large-headed person reads 10–15% nearer than they are. Absolute
distance is therefore **not an output of this module, ever**.

Instead:

- On acquisition (§5.3), collect the matrix translation `t_z` over the
  first `baseline_frames` (default 15) stable inferences; `z_ref` = median.
  Until the baseline exists, `head_z` outputs 0.5 and `subject_acquired`
  has not fired — the signal *is* "baseline ready".
- Per frame: `rel = (t_z − z_ref) / z_ref` (positive = farther), and
  `head_z = clamp(0.5 + rel / (2 × z_span), 0, 1)` with `z_span`
  default 0.35 — i.e. ±35% distance change spans the full output range.
- Per-person face size cancels exactly: it is a constant factor in both
  `t_z` and `z_ref`.
- `rebaseline()` recaptures at the performer's command (settings row +
  future OSC verb) — the "walked on stage at the wrong depth" fix.
- `head_size` (inter-ocular / frame width) ships alongside as the
  model-free cross-check; if `head_z` and `head_size` disagree in direction
  over a sustained window the status line flags `TRACK Z?` rather than any
  automatic correction (v1 keeps it honest and simple).

**OPEN:** the translation's units and sign convention (cm vs canonical
units, +z toward/away from camera) — read off the device at M0, not from
docs. Only the *sign* actually matters to the design; the ratio normalises
units away.

### 4.2 Orientation and mirroring — one convention, stated once

The app is landscape; the rear camera's sensor is landscape-native. All
`*_x`/`*_y` are in **audience view**: the frame as the composition shows it,
x rightward, y downward, 0–1. Concretely: a performer moving to *their*
right (camera's left) moves `head_x` **down** — the rear camera sees the
world like the audience does, unmirrored. Front lens output is mirrored in
software so the convention holds regardless of lens (a selfie camera is a
mirror; consumers must not care). CameraX rotation/orientation compensation
is applied before landmarks are read
**(mechanism unverified — ImageAnalysis `targetRotation` vs manual
transform; confirm at M0 on both Pixels — this is the classic silent bug)**.

---

## 5. Signal conditioning — all before transport

### 5.1 One Euro (Casiez et al. 2012)

Per-channel One Euro in Kotlin, timestamped with the **camera frame PTS**
(inference completion time would add encoder-style jitter to `dx`).

- Channels filtered: every continuous output (landmark 5–11, field 5–9).
  Flags/counts (`presence_raw`, `crowded`, `n_faces`) are not.
- Defaults: `min_cutoff = 1.0` Hz, `beta = 0.02`, `d_cutoff = 1.0` Hz.
  Casiez's canonical `beta = 0.007` is tuned for ~60 Hz pointing; at our
  ~24–30 Hz inference a slightly higher beta keeps fast head moves from
  smearing. These are **starting points — the whole reason both knobs are
  live** (settings rows + `/pvj/track/filter`, §6): tune per install, on
  the wall, not in this doc.
- One filter bank per mode; **reset on mode change, on acquisition, and on
  camera restart** — a filter warm-started across a subject swap drags the
  old person's position into the new one's first second.
- Field-mode channels get the same treatment; segmentation masks flicker at
  the edges and the Euro filter's speed-adaptive cutoff is exactly right
  for "still crowd = rock solid, moving crowd = responsive".

### 5.2 Multi-subject arbitration (landmark mode)

Naive nearest-face re-picks every frame and **oscillates** between two
people at similar distance. Instead, a **sticky lock**:

- Detector runs with `max_subjects` faces (default 3 — enough to know
  "too many", cheap enough not to matter).
- **No lock held:** a candidate must be the *largest* face (by inter-ocular
  size — the "closest" proxy that doesn't need z) for `acquire_frames`
  (default 8) consecutive inferences before it becomes the subject. That
  debounce is what kills the oscillation at the door.
- **Lock held:** the subject is whichever current detection is nearest to
  the *last known* head position, accepted only within a max-jump gate
  (default 0.25 of frame width per inference — beyond that it's a different
  person standing where ours was lost). FaceLandmarker's own detection
  indices are not stable across frames and are never trusted as identity
  **(unverified — believed true of the tasks API; confirm at M0)**.
- The lock **never transfers while held**: someone nearer walking in front
  does not steal it (they occlude → loss → grace → re-acquire picks the
  new largest — which is them, correctly, after the grace period). This is
  the deliberate behaviour: predictable beats optimal.
- **Nobody detected:** raw presence drops; the grace machinery (§5.3)
  decides what the world sees. Values freeze at last filtered output while
  `presence` is still 1 during grace (a momentary occlusion must not send
  the visual home), then hold frozen after loss. **They do not decay** —
  consumers key off `presence`, and a slow slide to centre looks like the
  performer drifting, which is worse than a hold.
- **Too many detected** (`n_faces > max_subjects`): lock behaviour is
  unchanged; `crowded = 1` so the operator (or an automation) can see the
  situation and choose to flip to field mode. The module itself never
  auto-switches modes.

### 5.3 Presence, acquisition, loss

A small state machine, all thresholds in inferences at the *configured*
inference rate (stated in ms below at 30 Hz):

```
ABSENT ──(raw detect, arbitration candidate stable ×8 ≈ 265 ms)──▶ ACQUIRING
ACQUIRING ──(baseline_frames=15 collected ≈ 500 ms)──▶ PRESENT  [subject_acquired]
PRESENT ──(raw miss)──▶ GRACE   (values freeze, presence stays 1)
GRACE ──(raw detect within grace_ms=700)──▶ PRESENT   (same baseline kept)
GRACE ──(grace_ms expires)──▶ ABSENT   [subject_lost, presence → 0]
```

- `presence` is emitted as a float but is binary in v1 (0 or 1). It rides
  the same snapshot as everything else, so the OSC and local consumers see
  the identical debounced flag.
- Re-acquisition within GRACE keeps the z baseline — a head turn or a
  hand across the face must not re-zero the depth axis. A full loss
  discards it: the next person is a new baseline.
- Field mode uses the same machine with `occupied_volume >
  field_presence_floor` as its raw detect, no ACQUIRING stage
  (no baseline to collect).

### 5.4 Triggers — hysteresis, dwell, quantise

`TriggerLane` (GDScript, one instance per configured trigger; evaluated in
`TrackingEngine._process` on each `values_updated`):

```gdscript
class_name TriggerLane extends RefCounted
var channel: String        # e.g. "head_z", "occupied_volume", "presence"
var enter_at: float        # fire threshold
var exit_at: float         # re-arm threshold  (enter 0.6 / exit 0.4 defaults)
var dwell_ms: int = 250    # must hold past enter_at this long before firing
var quantise: int = 0      # 0 = free · 1 = next beat · 2 = next bar
var invert: bool = false   # fire on falling through instead
signal fired
signal released            # crossed back below exit_at (post-dwell symmetric)
```

Rationale for the defaults, and why they are conservative:

- **Hysteresis (0.6 in / 0.4 out):** a subject hovering at a single
  threshold retriggers at the noise rate — tens of times a second. The 0.2
  gap is ~10× the observed post-filter noise floor of a still subject
  (**to be measured at M2**; the gap ships wide and tightens with data,
  never the reverse). Audio consumers cannot tolerate a double-fire; a
  too-wide gap merely makes the performer lean further, which is
  choreography, not breakage.
- **Dwell 250 ms:** below ~200 ms a segmentation flicker or a one-frame
  landmark jump can clear even a hysteresis gap. 250 ms is also under the
  shortest musically-intentional gesture we care about (a beat at 240 BPM).
  Visual-only lanes may set 100 ms; the *default* protects Bitwig.
- **Quantise:** `fired` is deferred to the next `BeatClock.beat`/`bar`
  (the same `_seq_pending`-style deferral the link verbs use). A trigger
  that fires into a quantise slot already pending is coalesced (one fire
  per slot) — a doorway crowd must not machine-gun the downbeat.
- `released` gets the same dwell on the way out, so gate-style consumers
  (Bitwig note-off) see symmetric debounce.

Trigger states ride OSC as their own addresses (§6) — a consumer must never
have to re-derive a trigger from the continuous channel (it would re-invent
these defaults, differently, per rig — the exact failure this section
exists to prevent).

---

## 6. OSC output

**Transport:** plain OSC 1.0 over UDP from `osc_output.gd`, the encoder
sibling of the shipped `osc_input.gd` parser (same padding/tag rules —
`f`/`i` only on the wire from us). Destinations are a list of `ip:port`
targets in settings (default: none — OSC out is opt-in; the local path
needs no config, the network path is deliberate). TD listens with a plain
OSC In CHOP/DAT; Bitwig via its OSC receiver (§6.3).

**Rate:** one `#bundle` per **new inference**, capped at `osc_rate_hz`
(default 30; the segmentation graph may only produce ~24 — the cap is a
ceiling, not a metronome). Bundle timetag immediate, matching the inbound
spec's "applied on arrival" stance. Continuous channels get a per-channel
deadband (default 0.001) so a static scene sends almost nothing;
`presence` and trigger addresses **always** send on change, and everything
is re-sent as a keyframe once per second so a late-joining consumer
converges within 1 s.

**Addresses — the outbound `/pvj/out/...` tree** (`OSC_NAMESPACE_SPEC.md`
§4 reserved it; this module is its first resident). One float per address —
the shape both an OSC In CHOP (address → channel name) and Bitwig's
address→parameter mapping want; no multi-arg messages except noted:

```
/pvj/out/track/presence      f 0|1
/pvj/out/track/head/x        f 0–1
/pvj/out/track/head/y        f 0–1
/pvj/out/track/head/z        f 0–1
/pvj/out/track/head/yaw      f 0–1     (pitch, roll likewise)
/pvj/out/track/crowded       f 0|1
/pvj/out/track/acquired      i 1       (event, on subject_acquired)
/pvj/out/track/lost          i 1       (event)

/pvj/out/field/occupied_volume    f 0–1
/pvj/out/field/motion_energy      f 0–1
/pvj/out/field/centroid_x         f 0–1
/pvj/out/field/centroid_y         f 0–1
/pvj/out/field/spatial_variance   f 0–1
/pvj/out/field/presence           f 0|1

/pvj/out/trigger/<name>      i 1|0    (1 on fired, 0 on released; <name>
                                       is the lane's settings key)
```

⚠️ **The field leaf names ARE the contract** — the Kinect patch's channels.
The TD side renames `/pvj/out/field/occupied_volume` → its `occupied_volume`
channel by its usual OSC-In name-trim; **OPEN:** confirm against the actual
patch whether it expects bare channel names (`occupied_volume`) or
Kinect-prefixed ones, and set the TD-side rename (not our addresses) to
match — the wire schema above does not bend per consumer.

**Inbound (this module's controls, joining the v1 namespace):**

```
/pvj/track/mode        s|i   off|landmark|field
/pvj/track/rebaseline  (no args)
/pvj/track/filter      f f   min_cutoff, beta
```

Same laws as every other inbound verb: mapped onto the SAME functions the
settings rows call, unknown-address drop, discrete ops flash the status
line (`TRACK: FIELD`, `TRACK: REBASE`).

### 6.1 Where this differs from the TouchDesigner MediaPipe plugin

The community TD MediaPipe plugin (Blankensmith et al.) runs MediaPipe *in
TD* off a webcam and emits **raw landmark arrays** — hundreds of channels,
one per landmark coordinate, unfiltered, at the host's rate. If the
installation's TD patch already consumes that, note the differences before
assuming a drop-in:

- We send **derived scalars only** (≤ 12 channels), already filtered and
  normalised — there is no `face_landmark_147_x` to map. A patch wired to
  raw landmarks needs a small adapter layer, or better: rewired to the
  derived channels, which is the point of doing the conditioning on device.
- Our z is the baselined relative depth (§4.1); the TD plugin's z is
  MediaPipe's raw canonical-units value.
- Presence/triggers arrive as explicit debounced addresses, not as
  "landmarks stopped updating".
- **What we lose:** anything needing individual landmarks (mouth open,
  eye blink, finger skeleton) is not on the wire — deliberately. If an
  installation needs one such scalar, it gets **derived on device and added
  as a named address**, not by opening the raw firehose.

### 6.2 TD integration note

For the Kinect-field patch the receiving end is one OSC In CHOP on the
listed port; because names and ranges match, the patch's downstream sees a
Kinect. The `pvj_link` COMP does **not** carry this data — OSC is its own
lane on purpose (the link is SRT/TCP video + verbs; tracking is
low-rate UDP state, and Resolume/TouchOSC must be able to listen without
speaking the link at all).

### 6.3 Bitwig integration note

Bitwig has no native OSC input; the standard route is **DrivenByMoss's OSC
module** (or a custom controller script) mapping addresses to remote
controls / actions. Continuous channels → modulators via its
value-addresses; `/pvj/out/trigger/<name>` → mapped action or note.
**OPEN:** which receiver the studio actually runs, its port, and whether
triggers should additionally ship as MIDI notes over RTP-MIDI for tighter
DAW semantics — v1 ships OSC only and keeps the trigger addresses
gate-shaped (1/0) so a note mapping is mechanical later.

---

## 7. Settings and live-tunable parameters

`settings.cfg` section, read/written like `[osc]`/`[link]`; UI as a
Library ▸ TRACKING accordion (M8 rules: uppercase, one green accent, ≤ 4
rows per group or it scrolls):

```
[tracking]
enabled = false          ; master switch (start() on boot if true + mode set)
mode = "landmark"        ; landmark | field
lens = "rear"            ; rear | front
delegate = "cpu"         ; cpu | gpu   (§8 for the default's reasoning)
inference_hz = 30        ; 5..30, live
filter_min_cutoff = 1.0  ; live
filter_beta = 0.02       ; live
z_span = 0.35            ; live
grace_ms = 700           ; live
max_subjects = 3
motion_gain = 8.0        ; field mode, live — the Kinect-match knob
osc_enabled = false
osc_rate_hz = 30
osc_targets = ""         ; "ip:port,ip:port"
```

Trigger lanes persist as their own sections (`[trigger_<name>]` with the
`TriggerLane` fields) — same pattern as warp slots: numbered, additive,
absent = none. **Live-tunable** (no restart): everything marked `live`
above, wired straight to `setFilter`/`setInferenceRate`/GDScript state.
Requires restart of the session (`stop()`+`start()`): mode, lens, delegate,
max_subjects.

Status line: tracking contributes `TRK L 30/29` (mode letter,
inference target/actual) to the bottom bar at the same 1 Hz cadence as the
FPS readout, red (`M8_RED` — error semantics, the documented exception)
when `tracking_failed` or `age_ms` > 500.

---

## 8. Performance budget

**The context:** the render pipeline holds 57–61 fps phone-only and
**52 fps with a real display attached** (S20's split — the DUAL·TEX blit is
not free), against a 55+ target. Tracking must fit in what's left, and the
GPU is the contended resource.

**Stance: tracking defaults to CPU, on its own threads, and the render
thread never waits on it.**

- The Tensor G3/G4 big cores sit largely idle during playback (the decode
  is hardware, the app is GPU-bound); XNNPACK inference there costs render
  nothing. The GPU delegate is faster *for inference* but spends exactly
  the budget the 52-fps case has already nearly exhausted. `delegate=gpu`
  stays available for phone-only rigs with headroom.
- No `onGLDrawFrame` participation at all — this module's Kotlin never
  holds the GL thread (contrast: the recorder's 0.51 ms swap was the
  *acceptable* cost of a GL-coupled module; ours is zero by construction).

**Budgets (targets to verify at M0/M1 — the starred numbers are guesses to
be replaced by measurements, in the SET_RECORDING §0 tradition of gating on
the number first):**

| Item | Budget | Basis |
|---|---|---|
| Camera capture (1280×720 analysis stream) | ~0 GPU, ISP path | CameraX ImageAnalysis, `KEEP_ONLY_LATEST`, no preview surface |
| YUV→MPImage conversion | < 2 ms CPU* | on the analysis executor **(unverified — whether tasks-vision accepts the YUV `ImageProxy` media image directly or needs an RGB convert; the RGB convert is the expensive fallback, ~5 ms*, and would push analysis resolution down to 640×480)** |
| FaceLandmarker inference (CPU) | 8–15 ms* per frame | small model; at 30 Hz ≤ half of one big core |
| ImageSegmenter inference (CPU) | 15–25 ms* per frame | heavier; if measured worse, field default drops to `inference_hz=20` — the field channels are crowd statistics, 20 Hz loses nothing |
| FieldStats reduction (256² mask) | < 1 ms CPU | 65k pixels, one pass, on the listener thread |
| Filters + snapshot + JNI poll | < 0.2 ms | tens of floats |
| GDScript per-frame (poll, triggers, OSC encode) | < 0.5 ms | budgeted like any other pipeline `_process` member |
| App render fps with tracking on | **≥ 55 phone-only, ≥ 50 with display** | the acceptance number |
| Added heat | must not tip the S22 thermal picture | the 40-min soak peaked 42.8 °C against a 43.0 threshold — tracking's CPU load eats into a **thin** margin; M1 re-runs a 20-min soak with tracking on |

**What gets sacrificed under load, in order** (a watchdog in
`TrackingEngine` steps down when app fps < 55 for 3 s, logs each step,
steps back up after 30 s clean):

1. `inference_hz` 30 → 20 → 12 (consumers already tolerate this — the One
   Euro filter is rate-aware via timestamps; OSC rate follows down).
2. Analysis resolution 720p → 480p (landmark quality degrades gracefully;
   field mode's mask is model-resolution anyway).
3. Tracking **stops** (`tracking_failed("load-shed")`, status line red).
   The show is the render pipeline; the sensor is the first thing over the
   side, and it says so out loud.

Never sacrificed: render fps (the ladder exists so the watchdog never has
to touch the deck), and filter quality (a laggier-but-clean 12 Hz signal
beats a noisy 30 Hz one for every consumer we have).

**Modes are exclusive** — landmark + field simultaneously would double
inference cost for a use case (one performer *and* crowd stats) no
installation has asked for; the budget above assumes one graph. Revisit
only with a concrete rig.

---

## 9. Failure modes and fallbacks

| Failure | Detection | Behaviour |
|---|---|---|
| Camera permission denied | `start()` → `"no-permission"` after the async request round-trip (CameraEngine's retry-poll pattern) | status line + settings row shows DENIED; no retry loop beyond the grant poll |
| Camera held by CameraEngine | GDScript gate, before Kotlin | `"camera-busy"`, status line names the holder; user chooses |
| Camera held by another app / evicted mid-run | CameraX error callback | `tracking_failed("camera-lost")`; one auto-retry after 2 s, then stay down until user action (no retry storm against a foreground camera app) |
| Model asset missing/corrupt (bad APK) | task-builder throws at `start()` | `"model-missing"`; unrecoverable without reinstall, say so |
| Inference stalls (thermal, scheduler) | `age_ms` grows in the snapshot | consumers keep last values; `presence` follows grace rules — a stalled tracker reads as a *departed subject*, never as a frozen-but-trusted one; status `TRK` red past 500 ms |
| App backgrounded | `onMainPause` | session torn down (camera released — Android would kill it anyway); `onMainResume` restarts if `enabled` — same self-heal shape as `texModeWanted` |
| Godot GL context recreated | n/a | **no-op by design** — the module holds no GL objects; explicitly not registered in the `onGLSurfaceCreated` teardown chain |
| OSC target unreachable | UDP — silent by nature | fire-and-forget, no backpressure ever reaches the local path; the 1 Hz keyframe re-send is the recovery |
| Low light / no detections | ordinary ABSENT state | not an error; `presence 0` is data. Field mode's mask degrades noisily in the dark — the Euro filter absorbs some; beyond that it's the operator's lighting problem, honestly reported |
| Load-shed floor reached | watchdog | tracking stops loudly (§8) |

**The invariant behind all rows:** every failure leaves the render pipeline
untouched and the last-known values frozen with `presence`/`age_ms` telling
the truth. No failure mode emits garbage values; consumers need exactly two
health signals and both are on the wire.

---

## 10. Open questions (collected — #11–15 for the depth tiers live in §12.6)

⚠️ **M0 ran 2026-08-20 on the P8 (`SESSION_33_NOTES.md`) — #1, #2, #4, #5
are ANSWERED below; the budget corrections live in that note's §2/§8.**
Headline: phone-only PASSES the gate (61 fps, tracking free); with
DUAL·TEX attached the spike defaults FAIL (blit 57 → ~25 fps, the
`toBitmap` convert is the confirmed cost). Landmark detection range at
640×480 indoor ≈ 1.1 m — the §5.3 grace machinery is validated as
essential, and range needs the direct-YUV path before any resolution bump.

1. **ANSWERED (M0):** rear CameraServer + rear CameraX DO stream
   concurrently on the P8/Android 17 — briefly — then a deck source
   switch **wedges Godot's main loop deterministically** (frozen
   framebuffer, Kotlin threads alive, no crash on record). §2.1's mutual
   exclusion is MANDATORY; the M1 GDScript gate is the first thing built.
   (Front+rear concurrency: still untested.)
2. **ANSWERED (M0):** ProcessLifecycleOwner binding works
   (`lifecycle-process` dep); no custom LifecycleRegistry needed for the
   spike. onMainPause teardown behaves per §9.
3. **ANSWERED (M1):** `FloatArray` marshals as `PackedFloat32Array`
   through `@UsedByGodot` — the typed path ran a full live session, the
   string fallback never fired.
4. **ANSWERED (M0+M1):** `toBitmap` was the cost; M1 removed the
   rotate-copy (rotation rides `ImageProcessingOptions`) and throttled to
   15 Hz → convert 1–3 ms even display-attached, blit 39–44 fps (from
   18–31). `MediaImageBuilder` **rejects camera YUV** ("media image must
   use RGBA_8888") — the true direct path is CameraX
   `setOutputImageFormat(OUTPUT_IMAGE_FORMAT_RGBA_8888)`, queued for M2
   with the ≥50 fps re-measure.
5. **ANSWERED (M0):** facial transformation matrix translation is
   **centimeters, z negative away from camera, linear with distance**
   (0.5 m ≈ −45, 1.0 m ≈ −95 on a live subject). §4.1 stands unchanged.
   Option name `setOutputFacialTransformationMatrixes` correct.
   (Index stability across frames: still unmeasured — assume unstable.)
6. **OPEN:** `motion_energy` gain and `spatial_variance` normalisation
   constants vs the actual Kinect patch's live ranges (§4) — needs a
   side-by-side calibration session with both sources feeding the patch.
7. **OPEN:** does the Kinect patch's OSC-In expect bare channel names or a
   prefix — settles the TD-side rename, not the wire schema (§6).
8. **OPEN:** Bitwig receiver of record (DrivenByMoss OSC? custom
   controller script? port), and whether triggers eventually want
   MIDI (§6.3).
9. **OPEN:** which segmentation model ships for field mode — selfie
   segmentation (person-class, fast) vs a multiclass model; wants the M0
   measurement plus a look at mask quality on a *crowd at distance*, which
   selfie-seg was not trained for.
10. **OPEN:** post-filter noise floor of a still subject (decides the final
    hysteresis defaults, §5.4) — measure at M2.

---

## 11. Phased build order

Each milestone is independently shippable and hardware-verified before the
next (the repo's session discipline). The gating number comes first, like
SET_RECORDING §0.

- **M0 — the spike (gate).** `TrackingPlugin` skeleton + CameraX +
  FaceLandmarker on the rear lens, CPU delegate, results to logcat only.
  **Answers, on both Pixels, with a clip playing and DUAL·TEX blitting:**
  app fps with tracking on/off, inference ms, YUV path question (#4),
  matrix units/sign (#5), lifecycle binding (#2), marshalling (#3),
  CameraEngine conflict behaviour (#1). *Go/no-go: ≥ 55 fps phone-only,
  ≥ 50 with display, at 30 Hz inference — else the ladder's floor becomes
  the default and the budget section is rewritten from data.*
- **M1 — the smallest useful thing: landmark mode drives a shader.**
  Snapshot + `getFrame()` + `TrackingEngine` + One Euro (fixed defaults) +
  single-subject only (no arbitration yet) + `head_x/y/z` with the baseline
  logic → one shader uniform in the deck (e.g. effect intensity from
  `head_z`). Library ▸ TRACKING with enable/mode/lens. **A performer walks
  toward the wall and the visual responds, no network involved.** 20-min
  thermal check rides this milestone.
- **M2 — conditioning complete.** Arbitration (§5.2), presence state
  machine + signals, filter knobs live in settings, `rebaseline()`, noise
  floor measured (#10), hysteresis defaults finalised. Status-line health.
- **M3 — OSC out.** `osc_output.gd` encoder + scheduler + targets +
  deadband/keyframe; `/pvj/out/track/*` live into a TD OSC In CHOP;
  inbound `/pvj/track/*` verbs. Latency spot-check phone→TD with the
  loopback-mirror method's little sibling (stamp a value change, screencap
  both ends).
- **M4 — field mode.** ImageSegmenter graph + `FieldStats` + the five
  frozen channels + empty-mask rules; then the **calibration session
  against the Kinect patch** (#6, #7) — the milestone is done when the
  patch cannot tell the sources apart on a live crowd (or the deltas are
  written down and accepted).
- **M5 — triggers + Bitwig.** `TriggerLane` + BeatClock quantise + persisted
  lanes + `/pvj/out/trigger/*`; Bitwig receiver decided (#8) and one gate +
  one modulation mapped end-to-end. **A person crossing a threshold on the
  floor fires a quantised event in Bitwig, once.**
- **M6 — ✅ BUILT (Session 35, not yet device-run).**
  Camera-frames-to-Godot-texture (retiring the CameraEngine exclusion,
  §2.1 — the exclusion is now *routing*), hand landmarks into the reserved
  slots (shipped earlier, at M2b), `/pvj/out` keyframing for the wider
  state-feedback tree, GPU delegate re-evaluated on whatever the fps
  picture is by then.
- **M8 — crowd mode (§13).** N people, stable slots, per-person handles
  for shaders and OSC, aggregates into the mod matrix, and the five frozen
  field channels synthesised so the Kinect patch cannot tell the source
  changed. Detector selectable (person boxes default, multi-pose
  conditional). **Gated by the M8a spike's recall number** (§13.7).
  *Scheduled 2026-09-10 AHEAD of M7 — see §13.9 for why.*
- **M7 — depth tiers (post-v1, §12).** D1 (DepthAnything on the existing
  SRT lane in TD — zero phone code, do first), then D2 (ARCore venue
  snapshot), then D3 (ARCore live depth mode) only if an installation
  actually demands it. §12.5 has the detailed ordering and gates.

---

## 12. Depth sources beyond MediaPipe — ARCore · portrait depth · TD-side

**Status: DESIGN, post-v1 (research pass 2026-08-20).** MediaPipe
segmentation gives a person *mask*; a depth source gives the third axis for
real — which is what the Kinect the TD patch was built around actually
provided. Three candidate sources were researched: **ARCore's Depth API**
(on-phone, metric), **TF.js ARPortraitDepth** (browser JS, portrait-only),
and — found during the research, and it reorders everything —
**TD-side monocular depth (DepthAnything) on the video the phone already
streams**. The design principle carried over from §1: tiers, not a rewrite.
Every tier below feeds the **same frozen field channels and the same
`/pvj/out/...` schema**; depth changes what's *behind* the numbers, never
the contract, so the TD patch and Bitwig mappings survive every tier
untouched.

### 12.1 What the research established

**ARCore Depth API** (facts from the developer guide + reference docs):

- Per-frame depth image via `Frame.acquireDepthImage16Bits()`: 16-bit
  millimetres, useful range ≈ 0.15–8 m, typical resolution **160×120**
  (up to 640×480 on some devices; size is device-dependent and may change).
- Two flavours: **full depth** (every pixel, smoothed/interpolated) and
  **raw depth + confidence image** (sparser, more geometrically accurate,
  ~half the compute).
- **No ToF needed** — Pixels do it with **depth-from-motion**: multiple
  views from a *moving camera* over a *static scene*. Neither Pixel 8 nor
  9a has a ToF sensor, so depth-from-motion is the only mechanism we get.
- Requires Google Play Services for AR installed, `Config.DepthMode`
  enabled, and an ARCore `Session` that **owns the camera**.
- The **SharedCamera** interop (ARCore + camera2 in one app) exists but:
  `setRepeatingRequest` is off-limits while ARCore is active, and
  depth-*sensor* use is unsupported in shared mode. That restriction is
  worded for ToF hardware; **OPEN:** whether depth-from-motion depth is
  delivered under SharedCamera at all — believed no, verify on device
  before any architecture leans on it.
- The GodotVR `godot_arcore` plugin is **still not working for Godot 4**
  (April 2026 status) — irrelevant to us anyway: we want depth *images* in
  our own Kotlin plugin, not Godot XR rendering. Our plugin pattern needs
  nothing from it.

⚠️ **The finding that reorders the plan: depth-from-motion needs MOTION.**
"Depth data will not be available if there are no tracked feature points —
this can happen when there is no motion." A PocketVJ phone in an
installation is **locked off on a mount with HDMI hanging out of it**. A
static camera looking at a moving crowd is depth-from-motion's *worst*
case, near-inverted from its design assumption (moving camera, static
scene). Featureless surfaces (the black-box venue wall) degrade it further.
So the honest conclusion: **ARCore live depth is NOT the wireless Kinect
for the locked-off rig.** What it *is* good at on our hardware:

1. **Setup-time venue capture** — walk the phone around the space once,
   depth-from-motion working exactly as designed, and keep the result
   (§12.3). This dovetails with the camera-auto-calibration north-star
   pillar, which will want ARCore pose tracking anyway.
2. **Handheld/moving-rig live depth** — a roaming camera operator feeding
   the field channels with true metric occupancy. Real, but a different
   show than the tripod install.

**TF.js ARPortraitDepth** (`@tensorflow-models/depth-estimation`):
lightweight U-Net, **single portrait** (one person, camera-facing, upper
body), **relative depth normalised 0–1** (not metric), browser runtime
(WebGL/WASM), 2022-era. It cannot run inside Godot; on-phone would mean a
TFLite conversion of a model that was never published as TFLite
**(feasibility unverified, and not worth it — see next)**. Its natural home
is a web runtime on the TD machine.

**The TD-side ecosystem** (the decisive practical find): Blankensmith's
MediaPipe plugin for TD runs JS models in an embedded Chromium and — more
importantly — his **DepthAnything .tox turns ANY TOP into a real-time
depth map**, no special hardware, Mac + PC. "Any TOP" includes **`srt_in0`
— the phone's own stream, which already arrives in TD at 60 fps over the
link we spent M-sessions hardening.** Monocular relative depth of the whole
scene, computed on the desktop GPU, zero phone cost, zero new transport.
DepthAnything (any scene, any framing) supersedes ARPortraitDepth (one
portrait subject) for every installation shape we can name; ARPortraitDepth
stays in the toolbox only for a hypothetical browser-deployed
portrait-booth piece.

### 12.2 The tier table

| Tier | Where it runs | Depth type | Phone cost | Static-rig viable | Ships channels |
|---|---|---|---|---|---|
| **T0** MediaPipe field mode (§4, v1) | phone | none (mask) | the §8 budget | ✅ | the five, mask-derived |
| **T1** DepthAnything on `srt_in` | TD | relative, dense, full scene | **zero** | ✅ | TD-side, from real depth |
| **T2** ARCore venue snapshot | phone, setup-time | metric, static geometry | setup only | ✅ (that's the point) | none live — a calibration asset |
| **T3** ARCore live depth mode | phone | metric, 160×120-ish | ARCore session (§12.4) | ❌ poor | the five, depth-weighted |
| — ARPortraitDepth | browser/TD web | relative, portrait-only | zero | ✅ but single-subject | not planned; niche |

**T1 is the TD helper the user asked for, and it costs one evening, not a
milestone.** Recipe (TD-side, no repo code): `srt_in0` → DepthAnything.tox
→ a small CHOP network reducing the depth TOP to `occupied_volume` /
`motion_energy` / `centroid_x/y` / `spatial_variance` — the same reduction
§4 specifies, but over true(ish) depth instead of a binary mask. Where the
phone's OSC field channels and TD's depth-derived ones disagree, that
disagreement IS the calibration session §10's #6 wanted. The two compose:
phone OSC = low-latency control signal that works with TD absent; TD depth
= rich field for TD-resident visuals (point clouds via PCR, occlusion,
displacement). **Nothing about T1 touches this module's code — it goes in
`td/TODO.md`, and the doc you are reading is its spec reference.**

### 12.3 T2 — the venue snapshot (ARCore as a setup tool)

A new, deliberately *offline* plugin capability — closer to the
`getDisplayInfo` diagnostics family than to the tracking hot path:

- **Capture:** a `TrackingPlugin` sibling mode (`start("venue_scan", …)`)
  runs an ARCore session with raw depth + confidence; the operator walks
  the space; the plugin fuses frames into a single depth+confidence pair
  keyed to a chosen reference pose (the mount position, captured by
  placing the phone on its mount for the final frames). Fusion v1 =
  per-pixel median over the last N mount-pose frames — no SLAM mesh, no
  TSDF; keep it dumb and shippable. **OPEN:** whether mount-pose-only
  frames suffice (static camera again — the scan may need to *end* moving
  toward the mount rather than resting on it).
- **Output:** a 16-bit PNG (depth mm in luma) + a JSON sidecar (intrinsics,
  pose, min/max) written to the recordings dir, shared via the existing
  `shareRecording` hand-off machinery, and fetchable by TD over the link's
  HTTP side (**OPEN:** which transport — the link has no file lane today;
  the share-sheet → SMB/Drive path works day one with zero code).
- **What TD does with it:** a static background depth field — background
  subtraction for T1 (live relative depth − venue depth = the *people*),
  projection-surface geometry for the mapping tools, and the Kinect
  patch's "empty room" reference frame.
- Explicitly **not** live: no fps budget, no filter bank, no OSC. It runs
  before doors, never during the set.

### 12.4 T3 — ARCore live depth mode (the last tier, and why)

If an installation genuinely runs a *moving* camera (operator, slider,
pan-tilt), a third `TrackingPlugin` mode `"depth_field"` becomes worth
building:

- ARCore session owns the camera (a fourth entrant in the §2.1 exclusion
  matrix — the GDScript gate grows one more holder name; SharedCamera is
  **not** assumed, per §12.1). MediaPipe can still run **on ARCore's
  frames**: `Frame.acquireCameraImage()` yields the YUV image, which feeds
  the same MPImage path §8 budgets — so "ARCore + segmentation" is one
  camera, one session, mask ∧ depth per frame
  **(acquireCameraImage under an active depth config: believed fine,
  unverified — M7 gate)**.
- The five channels get their depth upgrade, same names, same 0–1:
  `occupied_volume` weights masked pixels by nearness (a body at 1 m
  counts more than one at 6 m — what "volume" always wanted to mean);
  `centroid_*` become depth-weighted; `spatial_variance` gains the z term;
  `motion_energy` unchanged (luma diff already serves). Constants land in
  the same Kinect calibration session as #6.
- `head_z` in landmark mode could read metric depth at the head landmark
  instead of the §4.1 baseline trick — **only** where depth confidence at
  that pixel is high; the baseline path remains the fallback and the
  default (a face fills few of 160×120 depth pixels at distance).
- Budget stance: ARCore's session replaces the CameraX capture cost but
  adds its own tracking+depth compute (Play-Services-side, CPU+DSP);
  **measure before promising** — the M7 gate mirrors M0: ≥ 55/50 fps with
  a clip playing and DUAL·TEX blitting, else T3 stays shelved. The 43 °C
  thermal ceiling from S22 applies doubly; ARCore is a known heater.
- **Depth-to-TD streaming** (the true "wireless Kinect over SRT"):
  quantise depth to 8-bit luma inside a min/max window, ship it as a
  second video lane, window edges as OSC keyframes. Designed this far and
  **parked**: H.264 will smear depth edges, the link has one spare stream
  slot (`srt_in1` is unwired today), and T1 makes it mostly redundant.
  Revisit only if a rig needs *phone*-derived metric depth dense in TD.

### 12.5 Build order and gates (extends §11)

⚠️ **Re-ordered 2026-09-10: the whole D-series now follows M8 (§13).** D1
is still the cheapest item in this document, but it is TD-only and the
local-first law (§1) puts phone-resident crowd signal first. Nothing about
the gates below changed — only when they get run.

- **D1 (= T1):** DepthAnything.tox on `srt_in0` + the CHOP reduction to the
  five channels; side-by-side against the phone's OSC field channels on a
  live scene. Lands in `td/` + `td/TODO.md` item 8. *Gate: none — nothing
  can regress.*
  - ✅ **The reduction half SHIPPED 2026-09-10** — `td/depth_field.py`,
    `td/build_depth_field.py`, `td/verify_depth_field.py` (**73/73
    headless**), built live in `pvj-link.31` as `/project1/pvj_depth_field`
    and verified against the CPU reference to **float32** on all four
    moments and all five channels. Two Analyze TOPs total: the network
    computes four MEANS and recovers centroid + variance from
    `E[X²] − E[X]²` on the CPU. Depth source is a swappable input by
    design.
  - ✅ **The depth TOP SHIPPED the same day** — `td/build_depth_anything.py`
    drives the on-disk ONNX through **onnxruntime-DirectML** (no CUDA
    toolkit, no engine build, no GPU-vendor pin; any DX12 GPU). Measured
    with the show running: **TD 59.8 fps** against a 60.5 baseline, depth at
    **14–16 Hz / 55 ms**. Inference runs on a WORKER THREAD — on the main
    thread the same call costs ~267 ms because it blocks on TD's queued GPU
    work, and the show falls to 26.7 fps.
    ⚠️ **The DirectML adapter index means different GPUs in different
    processes** (standalone: dev 1 = 34 ms; inside TD: dev 1 = 502 ms,
    dev 0 = 49 ms). A device id benchmarked in a scratch script is not a
    measurement of what ships, so the comp PROBES the adapters in its own
    process and reports the probe in its status line.
  - ⚠️ **"One evening, zero repo code" was WRONG, and the wrong half was
    named.** That estimate assumed §12.1's **Blankensmith** .tox (embedded
    Chromium, vendor-neutral). What is installed here is
    **olegchomp/TDDepthAnything** — TensorRT — with no engine ever built, a
    venv pinned to cu118/TRT 9 on an **RTX 5080 (Blackwell, sm_120)** that
    cannot run it, and an extension on the TRT 9 binding API that TRT 10
    removed. The *reduction* was the easy half; the *depth TOP* is the
    blocker. See `td/TODO.md` §8b for the three routes out —
    onnxruntime-DirectML on the ONNX already on disk is the cheapest and
    the only vendor-neutral one.
- **D2 (= T2):** `venue_scan` capture → 16-bit PNG + sidecar → loaded in
  TD as the background field for D1 subtraction. *Gate: a scan of the
  studio reproduces tape-measured distances to ±10% at the mount pose.*
- **D3 (= T3):** only on a named installation with a moving camera.
  *Gate: the M0-style fps/thermal number, plus D1 demonstrably
  insufficient for that rig's need.*

### 12.6 New open questions (extend §10)

11. **OPEN:** depth-from-motion under SharedCamera — delivered or not
    (§12.1); and `acquireCameraImage()` alongside an active depth config
    (§12.4).
12. **OPEN:** actual depth image resolution + raw-depth coverage on the
    Pixel 8 / 9a specifically (docs say device-dependent).
13. **OPEN:** T2 fusion at the mount pose — does depth survive the camera
    coming to rest (§12.3), and the venue-file transport to TD.
14. **PARTLY ANSWERED 2026-09-10:** DepthAnything .tox licence/version
    pinning for `td/`. Two different .tox exist and §12.1 named the wrong
    one for this machine: Blankensmith's (Chromium/JS, Mac + PC) vs
    olegchomp's **TDDepthAnything** (TensorRT, NVIDIA-only, MIT, vendored
    from `github.com/olegchomp/TDDepthAnything`). **The pin is not just a
    version — it is a RUNTIME choice**, and a TensorRT pin ties `td/` to
    one GPU vendor and one CUDA/TRT generation, which is how the install
    on this box died. Still open: the runtime decision, and its GPU cost
    beside the existing SRT/compositing load (it shares the desktop GPU
    with the show).
15. **ANSWERED 2026-09-10:** the reduction is free at `Workres` 128 and the
    depth model costs 55 ms on a worker thread with NO measurable hit to
    TD's frame rate (59.8 vs 60.5 fps). The pair is affordable. What is now
    open is the same measurement with the phone's SRT stream live rather
    than a local movie, and on a weaker TD machine.
16. **OPEN:** §4's `motion_energy` definition assumes every cook is a new
    inference. In TD it is not (60 Hz host, ~16 Hz model), so the TD side
    ships an ENVELOPE rather than an instantaneous difference — same name,
    same range. Confirm the Kinect patch is happy with an envelope, and
    whether the PHONE should adopt one too for consistency. Measured at
    `Workres` 128 only, where it is free; the depth TOP will dominate
    anyway, but the pair has never been measured together.
15. **OPEN:** whether any planned installation actually wants
    ARPortraitDepth's portrait framing (if yes: browser piece, not phone).

---

## 13. Crowd mode — multi-person detection beyond the single lock

**Status: DESIGN, scheduled as M8 (2026-09-10).** §1 put multi-subject
*output* out of scope for v1 and §5.2 spends its whole length making sure
the module tracks exactly one person without oscillating. This section
adds the other half: **N people at once, each with a stable handle**, for
crowd-driven visuals locally and crowd data into TouchDesigner. It does
not repeal §5.2 — landmark mode's single sticky lock remains the right
answer for the single-performer rig, and the two are different modes, not
different settings of one mode.

### 13.1 Why this is a new algorithm and not a bigger `max_subjects`

Raising `max_subjects` cannot produce crowd tracking, for a measured
reason: **Session 34 re-measured stable landmark lock dying at ~0.8–1 m.**
A crowd is 3–10 m from the camera. Face landmarks are a *performer*
instrument at arm's length; at venue distance a face is a handful of
pixels and the detector returns nothing to arbitrate. Any design that
reaches the crowd must detect **bodies, not faces**, and must tolerate
back-lighting, overlap and partial occlusion — the normal state of a room
full of people in front of a projector.

Two other premises changed since §8 was written, and both open the door:

- **The render objection is dead.** Session 34's blit A/B measured
  tracking's cost on the DUAL·TEX path as *statistically zero* (56.7–60.1
  fps on vs 56.5–59.9 off) with the RGBA-direct convert at a flat 0 ms.
  §8's "modes are exclusive" ruling was priced against `toBitmap`-era
  numbers that no longer exist.
- **The thermal objection is alive and is now the only real one.** The
  same session's soak reached Thermal 3 SEVERE at ~11 min with the full
  stack. Crowd mode's budget is a *heat* budget, not an fps budget, and
  §13.7 gates on it accordingly.

### 13.2 The three algorithms, and which distance each serves

Crowd mode is one mode with a selectable detector, because the tracker,
slot model, aggregates and transport in §13.3–13.5 are **identical for all
three** — only the thing that produces boxes per inference changes.

| Algo | MediaPipe task | Per person you get | Cost shape | Venue distance | Verdict |
|---|---|---|---|---|---|
| **C0 field** (= M4, §4) | ImageSegmenter | *nothing* — aggregate mask only | one fixed inference | ✅ any | already spec'd; the fallback when the room is too dark to resolve bodies |
| **C1 boxes** (default) | ObjectDetector, `person` class (EfficientDet-Lite0) | box → x, y, size, confidence | one inference, ~flat in N | ✅ good | **the recommendation** — cheapest thing that yields per-person handles |
| **C2 pose** | PoseLandmarker, `numPoses > 1` | 33 landmarks → limbs, arms-up, height | detector + **N × per-pose model** | ⚠️ degrades with distance | expressive but scales badly; ship only if M8a finds headroom |

**(unverified — confirm at the M8a spike):** EfficientDet-Lite0's person
recall on a dim, back-lit, overlapping crowd; whether `numPoses` cost on
PoseLandmarker is genuinely linear in N on the Tensor G3; and whether
either model bundle's size is acceptable in the APK beside the two already
packed. All three are M8a measurements, not doc claims.

**Rejected:** FaceDetector (BlazeFace) multi-face — cheaper than
FaceLandmarker but hits the identical §13.1 range wall, so it buys
nothing. HolisticLandmarker — single-person by construction.

### 13.3 Slots and identity — the actual engineering

The model is the easy part; **keeping "person 3" the same human between
frames is the whole job.** Detector output order is not identity (§5.2
already assumes indices unstable, and #5 left it unmeasured). Without a
tracker, every effect bound to a person flickers and swaps.

**Slot model.** `crowd_slots` fixed slots (default 6, max 8). A slot is a
*tracked identity*, index-stable for as long as that person is held. A new
person takes the **lowest free slot**; a freed slot is held on cooldown
(`crowd_slot_cooldown_ms`, default 1500) before reuse, so an effect bound
to slot 2 does not inherit a stranger the instant its owner is occluded.

**Assignment, per inference:**

1. Detections below `crowd_min_conf` are dropped.
2. Greedy nearest-centroid matching, detections in descending confidence
   against held slots, cost = centre distance + a size-mismatch term,
   accepted only inside `crowd_max_jump` (default 0.18 of frame width per
   inference). Greedy, not Hungarian — at N ≤ 8 the optimal assignment and
   the greedy one differ vanishingly often, and greedy is auditable in a
   log line.
3. ⚠️ **All matching happens in RAW camera space.** The §4.2 audience-view
   mirror is applied at *output only*. This is not a style note: it is
   verbatim the Session 34 bug that made the single lock churn every ~2 s
   on the front lens, and a one-to-many tracker reproduces it N times over.
4. **Birth:** an unmatched detection must persist `crowd_acquire_frames`
   (default 4) consecutive inferences within the jump gate before it takes
   a slot — §5.2's door debounce, per slot. A one-frame phantom never
   creates a person.
5. **Death:** an unmatched slot freezes its values and keeps `present = 1`
   through `crowd_grace_ms` (default 900), then releases. Frozen, never
   decayed — §5.2's reasoning applies unchanged.

**Filtering:** One Euro per slot per channel (a bank of
`crowd_slots × K`), reset on slot birth so a new person does not inherit
the previous occupant's filter state.

**Per-slot channels (K = 8), all filtered and normalised:**

| k | name | range | notes |
|---|---|---|---|
| 0 | `present` | 0/1 | debounced, grace applied |
| 1 | `x` | 0–1 | box centre, output-image horizontal (§4.2) |
| 2 | `y` | 0–1 | 0 = top |
| 3 | `size` | 0–1 | box height ÷ frame height — the distance proxy, same role `head_size` plays in §4.1 |
| 4 | `vx` | −1–1 | normalised horizontal velocity, per second |
| 5 | `vy` | −1–1 | |
| 6 | `age` | 0–1 | seconds held ÷ 10, clamped — lets a visual fade newcomers in |
| 7 | `conf` | 0–1 | detector confidence, unfiltered |

There is deliberately **no z**. §4.1's relative-z story depends on a
canonical face model; a person box has no equivalent, and inventing one
would be the exact "absolute distance" claim §4.1 refuses to make. `size`
is the honest proxy, and §12's depth tiers are where real depth comes from.

### 13.4 Aggregates — and the field-mode compatibility that comes free

Per-slot data is the new capability, but **the aggregates are what a VJ
actually maps to a knob.** Computed over held slots each inference and
appended to the §4 snapshot from the first free index:

| idx | name | range | definition |
|---|---|---|---|
| 18 | `crowd_count` | count | slots currently `present` |
| 19 | `crowd_centroid_x` | 0–1 | mean slot x, size-weighted |
| 20 | `crowd_centroid_y` | 0–1 | |
| 21 | `crowd_spread` | 0–1 | `(var_x + var_y) × 6`, clamped — **the same normalisation as §4's `spatial_variance`, deliberately** |
| 22 | `crowd_energy` | 0–1 | mean slot speed × `crowd_energy_gain`, clamped |
| 23 | `crowd_nearest` | 0–1 | largest slot `size` — "someone is close" |
| 24 | `crowd_balance` | 0–1 | size-weighted mass left vs right, 0.5 = even |
| 25 | `crowd_overflow` | 0/1 | detections exceeded `crowd_slots` (§5.2's `crowded`, crowd-side) |

Snapshot grows 18 → 26; `SNAPSHOT_SIZE`'s reserved idx 17 (second
hand/gesture) is left alone. The layout stays append-only, so an older
APK's shorter array is handled by the existing length check.

**The free win:** because `crowd_spread` uses §4's variance normalisation
and `crowd_centroid_*` its centroid convention, crowd mode can **synthesise
the five frozen field channels** (`occupied_volume` = summed box area,
`motion_energy` = `crowd_energy`, plus centroid and variance) and emit them
on the `/pvj/out/field/*` addresses. With `crowd_field_compat = true`
(default), **the Kinect TD patch consumes crowd mode without knowing it
changed** — which is the same law §1 set for field mode, honoured by a
second source. The calibration question §10 #6 asks of field mode applies
identically here and is answered in the same session.

### 13.5 Consumers

**Shaders / mod matrix — split by cardinality.** Putting 8 slots × 8
channels into the mod matrix would add 64 ModSources and make the picker
unusable. Instead:

- **Aggregates go into the mod matrix as ordinary scalar ModSources**
  (`CROWD_COUNT`, `CROWD_X`, `CROWD_SPREAD`, `CROWD_ENERGY`,
  `CROWD_NEAREST`, `CROWD_BALANCE`) — existing machinery, nothing new, and
  these are the ones a performer maps to speed, brightness or retime.
- **Per-slot data reaches shaders as ONE uniform array**, not N uniforms:
  `TrackingEngine` publishes a `PackedVector4Array` of `crowd_slots`
  entries `(x, y, size, present)` that `ShaderSlot` binds as a single
  `uniform vec4 crowd[8]` alongside a `crowd_n` int. One binding, N
  people; per-instance effects (a glow per body, displacement per person)
  are then pure shader work with no additional plumbing per slot.

**OSC.** Aggregates always; per-slot opt-in, because 8 slots × 4 addresses
at 30 Hz is a different bandwidth conversation than §6 budgeted:

```
/pvj/out/crowd/count          f
/pvj/out/crowd/centroid/x     f 0–1     (y likewise)
/pvj/out/crowd/spread         f 0–1
/pvj/out/crowd/energy         f 0–1
/pvj/out/crowd/nearest        f 0–1
/pvj/out/crowd/balance        f 0–1
/pvj/out/crowd/overflow       f 0|1

/pvj/out/crowd/p<n>/x         f 0–1     (n = 1..crowd_slots, opt-in)
/pvj/out/crowd/p<n>/y         f 0–1
/pvj/out/crowd/p<n>/size      f 0–1
/pvj/out/crowd/p<n>/present   f 0|1

/pvj/out/crowd/entered        i <n>     (event: slot n took a new person)
/pvj/out/crowd/left           i <n>     (event: slot n released)
```

Per-slot addresses ride their own rate cap (`crowd_osc_slots_hz`, default
15) under the aggregate stream, and the §6 deadband + 1 Hz keyframe rules
apply unchanged. `entered`/`left` use §7's `OscOutput.event()` one-shot
path — state snapshots cannot say "it happened once", which is exactly why
that machinery was built in Session 34.

**Triggers.** `TriggerLane` (§5.4) already takes any named channel, so
`crowd_count`, `crowd_nearest` and `crowd_energy` are trigger sources on
day one with no new code — "more than four people" or "someone stepped
forward", hysteresis and beat-quantised, into Bitwig or TD. Per-slot
channels are addressable as `crowd.p2.x` for the rare targeted lane.

### 13.6 Settings

```
[tracking]
mode = "crowd"              ; landmark | field | crowd   (restart)
crowd_algo = "boxes"        ; boxes | pose              (restart)
crowd_slots = 6             ; 1..8                      (restart)
crowd_min_conf = 0.40       ; live
crowd_max_jump = 0.18       ; live
crowd_acquire_frames = 4    ; live
crowd_grace_ms = 900        ; live
crowd_slot_cooldown_ms = 1500
crowd_energy_gain = 6.0     ; live — the §10 #6 calibration knob, crowd-side
crowd_field_compat = true   ; synthesise /pvj/out/field/* (§13.4)
crowd_osc_slots = false
crowd_osc_slots_hz = 15
```

Status line: `TRK C 12/11 ×4` — mode letter, inference target/actual, and
the live slot count, at the existing 1 Hz cadence.

### 13.7 Performance — the budget is thermal, and crowd runs slow on purpose

**Design stance: crowd mode's default `inference_hz` is 12, not 30.** A
crowd is a slow signal — people cross a room in seconds, not frames — and
running the detector at 12 Hz buys back the thermal margin outright rather
than spending the §8 ladder to recover it under load. One Euro is
timestamp-driven and rate-aware (§5.1), so the filtered output stays smooth
at 12 Hz; Session 34 already ran the whole M3 verification at 12 Hz with
50–85 ms end-to-end latency.

Modes stay **exclusive** — crowd XOR landmark XOR field, one graph at a
time. §8's reasoning survives its own budget correction: two graphs is
double the heat for a rig nobody has described.

### 13.7.1 M8a RAN — 2026-09-10, P8, phone-only

**Harness:** EfficientDet-Lite0 **int8**, `setCategoryAllowlist(["person"])`,
maxResults 8, score 0.4, LIVE_STREAM, CPU, analysis throttle 15 Hz, deck
playing clips at 60 fps. Logcat only, no snapshot — the spike touches
nothing downstream so it cannot contaminate its own fps number.
Line: `crowd|analyzed_hz|results_hz|convert_ms|latency_ms|path|n|max_n|avg_score|tallest`.

| Number | Measured | Gate | Verdict |
|---|---|---|---|
| Sustainable inference rate | **~9.4 Hz** (results 8.2–12.0, two independent runs) | 12 Hz with margin | ⚠️ **below the 12 Hz default, above the 8 Hz floor** |
| Per-inference cost | **~110 ms** | ≤ 30 ms | ❌ ~3.7× over |
| End-to-end latency | **~150 ms** (110–213) | (M3 landmark: 50–85) | ⚠️ ~2× the landmark path |
| RGBA convert | **0 ms** | < 2 ms | ✅ the M2 path holds |
| Detection, 1 person close | **30/30 samples, conf 0.82–0.97** | — | ✅ the model works |
| Model size in APK (#18) | **int8 4.6 MB** (fp16 7.25, fp32 13.8) | — | ✅ payload 11.6 → 16.2 MB |

⚠️ **The GPU delegate is NOT an escape hatch on the P8.** `delegate=gpu`
builds and reports `delegate=gpu`, then produces **zero inferences** —
silently, without ever firing the error listener. The tell is one tflite
line: `Failed to load OpenCL library with dlopen: library
"libvndksupport.so" not found`. §8's "`delegate=gpu` stays available for
phone-only rigs with headroom" is **false on this device**, and that
applies to the landmark path too — nothing has ever exercised it, because
`setDelegate` existed in Kotlin from M0 and was never wired to GDScript
until this spike. Treat CPU as the only path until proven otherwise.

⚠️ **Thermal went 1 → 2 within minutes** of crowd inference, having held
at 1 all session. Early and unfavourable signal for the 20-min soak gate.

### 13.7.1a M8a VERDICT — the matrix, 2026-09-10, two people, rear lens

Ground truth **2 people**, 3–8 m, rear lens, deck under normal clip load.
`n` is the mean detected per inference; read it against 2.

| Cell | ACTUAL res | r_hz | lat ms | **n** | maxn | score |
|---|---|---|---|---|---|---|
| 480 int8 .4 | 640×480 | 9.6 | 157 | 1.7 | 3 | 0.54 |
| **720 int8 .4** | 1280×960 | 9.1 | 178 | **2.2** | 4 | **0.62** |
| 1080 int8 .4 | 1920×1440 | 8.8 | 201 | 1.9 | 3 | 0.58 |
| 720 int8 **.25** | 1280×960 | 9.3 | 167 | 3.3 | 5 | 0.51 |
| 720 **fp32** .4 | 1280×960 | **5.7** | 234 | 1.8 | 3 | 0.52 |
| 720 **ssd** .4 | 1280×960 | 8.0 | 190 | 1.2 | 2 | 0.59 |
| 720 int8 .4 **z3×** | 1280×960 | 9.3 | 177 | **0.5** | 2 | 0.56 |
| **landmark** 720 | 1280×960 | 12.4 | **62** | 0.2 | 0 | — |

**✅ GATE PASSES. The shipping config is `analysis_res=720`,
`crowd_model=edl0_int8`, `crowd_min_conf=0.4`, `zoom=1.0`.**

- **720p is the sweet spot and 1080p is a regression.** 480p under-detects
  (1.7), 720p lands on the truth (2.2, best confidence), 1080p gets *worse*
  (1.9) while costing throughput and 201 ms latency. The range curve
  FLATTENS at 720 — #27 answered, and the default should not chase pixels
  past it.
- **Lowering the threshold is a trap.** 0.25 reports 3.3 people out of 2,
  peaking at 5: ~65% false boxes, and mean confidence drops. The wall was
  never a threshold problem. 0.4 stands.
- **int8 wins decisively** — fp32 is 40% slower AND less accurate, killing
  the "quantization falls off XNNPACK" theory outright. SSD MobileNetV2 is
  conservative rather than noisy (maxn 2, no false boxes) but badly
  under-detects at 1.2 of 2.
- **Zoom collapsed recall to 0.5 — and the numbers prove WHY.** Confidence
  HELD at 0.56 while n fell. Had zoom degraded detection, confidence would
  have fallen with it; instead it detected just as confidently, far less
  often, i.e. the subjects left the frame. §13.7.3's reach-vs-coverage trade,
  measured: **zoom is a PERFORMER control, never a crowd one.**
- ⚠️ **§13.1's premise survives.** At the same distance where boxes found
  2.2 people, the FACE path found **0.2**. Faces improved with the
  resolution fix (0.8–1 m → 2 m, operator-verified) but still cannot reach
  a crowd. Crowd mode remains a separate detector for a real reason.
- The landmark path is ~3× cheaper (62 ms vs 178 ms), which is the measured
  case for "modes are exclusive" rather than the budgeted one.

**Still unrun:** the DUAL·TEX blit A/B (no display attached all day) and the
20-minute soak. Cost at Thermal 0 is ~12.5 Hz and degrades to ~9 Hz warm —
the ladder's territory, not a new problem.

### 13.7.2 ⚠️ THE ANALYSIS STREAM WAS NEVER 720p

**Found 2026-09-10, and it invalidates every range number this document
carries.** §8's budget table says "Camera capture (**1280×720** analysis
stream)". The code never called `setTargetResolution` or
`setResolutionSelector` on `ImageAnalysis` — so from M0 onward CameraX has
returned its **~640×480 default**, and every range figure in this spec and
in the session notes was measured there:

- the landmark path's **0.8–1 m** (M3; the "720p analysis resolution
  experiment" listed as the open lever ever since — it was never the
  *experiment* that was missing, it was the setting), and
- person-box range **~1.5 m**, operator-observed 2026-09-10.

At 640×480, downscaled to EfficientDet's 320×320 input, a person at 5 m is
roughly 30 px tall — at or under where these detectors fire. **Range for
any box detector is pixels-on-target**, so this is the first thing to move
and it plausibly costs nothing: `convert` measured 0 ms at 480p.

Now settings-driven for a sweep: `[tracking] analysis_res` (480 | 720 |
1080) and `[tracking] crowd_min_conf`. The plugin logs `analysis stream
ACTUAL: WxH (asked Np)` on the first frame, because CameraX silently falls
back to a nearby supported size and — per the `delegate=cpu` lesson the
same day — a configured value is not a measured one.

**If 1080p still cannot hold two people at 5 m**, that is a real answer,
not a failure: it means box detection is the wrong instrument for a crowd
and **field mode (C0/M4) is where per-pixel person classification earns its
place** — a distant crowd is still a blob of person-pixels long after no
individual resolves as a box. §13.2 predicted exactly this split.

**Not yet run** (needs hardware/people this session did not have): the blit
A/B on DUAL·TEX (no display attached), the 20-min soak, and — the actual
go/no-go — **person recall on a dim, back-lit, overlapping crowd at
3–8 m**. Close-range single-person recall says nothing about it.

**Reading:** cost is marginal rather than fatal. 9.4 Hz sits between the
§13.7 default (12) and the ladder floor (8), so C1 survives *if* the
recall gate passes and the soak does not regress — but the ~110 ms
inference means crowd mode can never share a phone with the landmark path,
and §13.7's "modes are exclusive" hardens from a budget choice into a
measured constraint.

**M8a gates (measure, then design — the M0 tradition):**

| Number | Gate |
|---|---|
| ObjectDetector inference ms, 6 people in frame, P8 CPU | must fit 12 Hz with margin (≤ 30 ms) |
| Blit fps with crowd on, DUAL·TEX attached | ≥ the M3 baseline's 56.5–59.9, statistically |
| 20-min soak, full stack | must not reach Thermal 3 SEVERE **sooner than the M3 baseline's ~11 min** |
| Person recall, dim/back-lit/overlapping, 3–8 m | the go/no-go for C1 at all — if boxes cannot see a real crowd, C0 field mode is the answer and M8b stops |

If the soak regresses, the crowd ladder's floor becomes 8 Hz before
anything else is sacrificed; the §8 watchdog steps and load-shed order are
inherited unchanged.

### 13.7.3 Range is three knobs, and only one of them is live

Operator question, 2026-09-10: *can range be adjusted in the app, or is it
automatic?* **Nothing auto-ranges, and range is not one control:**

| Knob | Buys range by | Cost | Applies |
|---|---|---|---|
| `analysis_res` 480/720/1080 | more pixels on target | inference time | **restart** (baked at graph build) |
| `zoom` 1.0–6.0 | more pixels on target | **field of view** | **LIVE** |
| `crowd_min_conf` | accepting weaker detections | false boxes | restart (could be live) |

**Zoom is the performer-facing one**, and the only one safe to touch
mid-set: `cameraControl.setZoomRatio()` needs no graph rebuild, so it never
re-enters the §2.1 teardown race that a resolution change would. It is also
nearly free on the P8 — a 50 MP sensor cropped into a ~640×480 analysis
frame is throwing away most of its pixels anyway, so 3× hands a subject at
8 m roughly the pixel count they had at 2.7 m. Shipped as Library ▸
TRACKING ▸ **Range (zoom)**, persisted as `[tracking] zoom`, and the plugin
logs the range the camera GRANTED (`zoom range: min..max`) because devices
clamp silently.

⚠️ **The two range knobs are not interchangeable.** Resolution buys reach
for free in FOV terms and costs compute; zoom buys reach for free in
compute terms and costs FOV. For a single performer zoom is a pure win. For
**crowd** work it is the coverage trade in miniature: at 3× you track the
back of the room properly and see a third of it. §13.7's sweep therefore
tests them as separate axes, not one "range" number.

**Auto-ranging is deliberately NOT built.** Driving `setZoomRatio` from
`head_size` or the tallest box is easy and tempting, and it is a control
loop whose sensor loses accuracy exactly where the loop is trying to
correct — an oscillator waiting to happen. Fixed knobs first, measured;
automation only against a rig that has asked for it.

### 13.7.4 "camera" mode — the deck's lens, with actual controls

Operator question, 2026-09-10: *can the focal length go wide→telephoto, and
can the CAMERA SOURCE have settings, not just tracking?*

**Telephoto: no, and it is hardware.** The P8 and the 9a are main + ultrawide;
optical tele is the Pro. What exists is wide↔**ultrawide** (modern Pixels
expose it below zoom ratio 1.0 on the logical rear camera — the plugin's
`zoom range: min..max` line reports the device's real floor, and if it is
~0.5 the Range slider's minimum is the only change needed) and digital zoom
on a 50 MP sensor as the tele substitute.

**Camera settings: the blocker was never our code.** Godot's `CameraFeed`
API is the entire surface the deck's CAMERA source has — pick a feed, pick a
format, on/off. No zoom, no exposure, no lens choice, no AE lock, and no way
to add them. So the fix is not "extend CameraEngine", it is **let the deck
use the CameraX path without paying for inference**:

`start(mode="camera")` binds Preview ALONE — no detector, no graph, no
analyzer, cheaper than tracking — and reuses M6's publish path to the deck.
Every CameraX control then becomes reachable:

| Control | Why it earns its place |
|---|---|
| **AE/AWB lock** | ⚠️ the one that matters on a wall: auto-exposure hunts as people cross frame, so a projected camera image PULSES and colour-shifts. Locking holds a look for a set. `startFocusAndMetering` + `disableAutoCancel`, no experimental interop |
| Exposure compensation | venues are dark; range read from the device, since EV steps vary and a guessed slider is a knob that does nothing |
| Zoom | §13.7.3 |
| Torch | a venue light already in the rig |

**Bonus, and not a small one:** `camera` mode retires the last
`CameraServer` client. The §2.1 two-client wedge stops being *reachable*
rather than merely avoided.

**Built to the plugin surface only.** UI rows and routing the deck to
`camera` mode when tracking is off are NOT done: all of it is untested on
device, and changing how the deck acquires the camera is exactly the class
of change that wedged the app on 2026-09-10.

### 13.8 Failure modes (extends §9)

| Failure | Detection | Behaviour |
|---|---|---|
| Crowd model bundle missing | `start()` → `"model-missing"` | refuse to start; never burn the camera for a session that tracks nothing (the `hands_only` precedent) |
| Zero detections, room occupied | `crowd_count` 0 with the venue known-full | status line only — **no auto-switch to field mode**; §5.2's law that the module never changes its own mode holds |
| More people than slots | `crowd_overflow = 1` | held slots keep their people; the surplus is simply untracked. Never re-shuffle held slots to "fit better" — predictable beats optimal |
| Slot thrash (occlusion-heavy crowd) | slot birth/death rate over a 10 s window | logged at 1 Hz with the stats line; the operator's lever is `crowd_grace_ms` and `crowd_slot_cooldown_ms`, both live |
| Backlit / silhouette venue | recall gate in §13.7 fails on site | documented fallback is C0 field mode, which needs no per-body resolution |

### 13.9 Build order — M8, and it lands before D1

**Decision (2026-09-10, user):** crowd mode is scheduled **ahead of the
§12.5 depth tiers.** D1 is cheap ("one evening", zero repo code, nothing
can regress) but it is **TD-only** — it produces nothing when TouchDesigner
is absent, and the module's local-first law (§1) makes phone-resident crowd
signal the more valuable of the two. D1 slips behind M8; it is not
cancelled, and its "nothing can regress" property means it can still be
dropped into any evening where a phone is unavailable.

- **M8a — the spike (gate).** ObjectDetector person-class on the P8, no
  GDScript, results to logcat: the four §13.7 numbers plus the model-size
  and recall questions from §13.2. *Go/no-go: the recall gate. Everything
  else re-prices the design rather than stopping it.*
- **M8b — boxes, tracker, slots, aggregates.** `CrowdTracker.kt` +
  snapshot growth to 26 + the six scalar ModSources + `/pvj/out/crowd/*`
  aggregates + `crowd_field_compat`. **Verified with three or more real
  people in the room**, not one person walking around — slot stability is
  the acceptance criterion and it cannot be tested solo. Headless
  `tools/verify_crowd_tracker.gd` covers assignment, birth/death, gate
  rejection, slot cooldown and overflow, in the `verify_trigger_lane.gd`
  idiom.
- **M8c — ✅ SHIPPED 2026-09-10.** `uniform vec4 crowd[8]` (fed from BOTH
  modes — person slots in crowd, head + hand in landmark, which is what made
  hand-attached effects possible at all), per-slot OSC, and the Library ▸
  TRACKING rows: Mode toggle, Crowd slots, Per-slot OSC, **OSC out + targets
  readout, Trigger lanes readout** — the M3 debt, cleared.
  Effects: `FX ▸ Crowd` (Spotlight · Markers · Warp · Blob) and `FX ▸ HUD`
  (Reticle · Full · Target) + `FX ▸ HUD Rings`, the raymarched stack.
  ⚠️ The OSC-out toggle needed a new `_apply_osc_out()`: the builder only ran
  at startup and returned early when disabled, so the setting could be changed
  and simply never take effect until a restart.
  ⚠️ `→ NO TARGETS (silent)` is surfaced deliberately — OSC out enabled with an
  empty target list sends into the void, and the only way to see that was to
  read settings.cfg over adb.
- **M8d — C2 pose, conditional.** Only if M8a found headroom; adds
  `crowd_algo = "pose"` and limb-derived channels behind the same slot
  model, changing nothing downstream.

Then §12.5's D1 → D2 → D3, unchanged.

### 13.10 New open questions (extend §10, §12.6)

16. **OPEN:** EfficientDet-Lite0 person recall on a dim, back-lit,
    overlapping crowd at 3–8 m — the M8a go/no-go, and the only question
    that can stop this milestone.
17. **OPEN:** PoseLandmarker `numPoses` cost scaling on the Tensor G3 —
    linear in N, or is the detector stage the fixed cost? Decides whether
    M8d exists.
18. **OPEN:** combined model-bundle size in the APK beside the face and
    hand graphs already packed (and whether the §cf5c227 assets-wipe trap
    applies to a third bundle).
19. **OPEN:** does `crowd_max_jump` want to scale with `size`? A distant
    person crosses fewer normalised units per second than a near one, so a
    single gate may be simultaneously too tight far and too loose near.
    Measure before adding the complexity.
20. **OPEN:** the §13.4 field-compat mapping constants — `occupied_volume`
    from summed box area is a *different* estimator than a segmentation
    mask's masked fraction, and the two will not agree out of the box.
    Same calibration session as #6; both sources feed the patch at once.
21. **OPEN:** 720p analysis resolution (the still-open M3 lever) almost
    certainly matters more to box recall at distance than it did to face
    range — run the two experiments together.
22. **OPEN:** whether per-slot OSC at 8 slots survives the venue Wi-Fi
    that §6's budget was never sized for; the `crowd_osc_slots` default
    stays `false` until measured.
23. **ANSWERED (M8a, 2026-09-10):** EfficientDet-Lite0 int8 costs ~110 ms
    per inference on the P8 CPU (~9.4 Hz sustainable), not the ≤30 ms the
    budget assumed. #17's pose question is now moot unless a cheaper
    detector is found — C2 cannot be cheaper than C1's base cost.
24. **OPEN:** a cheaper person detector. EfficientDet-Lite0 is the
    MediaPipe default, not the floor — MoveNet/BlazePose-detector-only, a
    smaller input resolution, or an NNAPI/DSP path are all unexplored, and
    a 3× win would put C1 comfortably inside the budget.
25. **OPEN:** why the GPU delegate loads but never infers (missing
    `libvndksupport.so`). Affects every graph, not just crowd; worth one
    hour because the whole §8 fallback story depends on it.
26. **ANSWERED-ish (2026-09-10):** the analysis stream was never 720p
    (§13.7.2). Every range number in this document predates the fix and
    should be re-measured before any of them is trusted — including the
    ones used to justify §13.1's "faces cannot reach a crowd" argument.
27. **OPEN:** the range/cost curve across 480/720/1080. 1080p is 6.75x the
    pixels of 480p and inference is already ~110 ms; the useful setting is
    wherever range stops improving faster than cost rises.
