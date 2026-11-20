# PocketVJ — Camera, Procedural Masks & Content Export (spec / backlog)

**Status:** §1 calibration BUILT (2026-09-30, branch `feature/camera-calibration`): manual four-point + AUTO marker detection. AUTO works on a wall (Pixel 8 + projector), but its automatic rectangle is only square *as seen from the phone* — judged "not great" on a wall; a wall-true method was proven as a spike (§1b) and is now in the app as the **WALL** step, together with a nine-disc AUTO (§1c). First wall run of both the same day: AUTO 9/9 with the phone resting, WALL by gravity judged **"runs close, still not perfect… good enough"**. Since then the level lines are found in the picture, AUTO arrives on the wall's square by itself, and SURFACE says which kind of square is on (§1d) — run on the wall by the user with no taps at all: **"it looks good this one!"** Then §1e: a check of the result on the wall, heat protection, the lens from Camera2, a save prompt — verified headless and on the phone without a projector; the check itself has not yet seen a real wall. See §1a–1e. §2–§4 not started. These four features have a strict dependency order — building them out of order wastes work.

**Dependency chain (do NOT reorder):**
```
projector-camera calibration  →  edge-detection masks
        (prerequisite)              (only useful after calibration)

reference/mask export  →  AI content round-trip  (independent, small)
```

---

## 1. Projector-camera calibration — the prerequisite for everything camera-based

**The problem you already hit:** the camera view does not match the projector 1:1. It never will by nudging, because the phone camera and the projector are in **different physical positions** — the camera sees the surface from where you hold the phone, the projector hits it from where it's mounted. Any mask traced from the camera image lands in the wrong place on the projection.

**The fix is a homography between camera space and projector space, built from two views:**

The key insight: you don't compare a photo of the bare scene against a photo of the projection. You **project a pattern the app itself generates** (so its position in projector space is known exactly) and photograph *that landing on the surface*. The correspondence between "where the app put each marker" and "where the camera sees it" gives the transform directly.

1. **Project a known calibration pattern** through the output — four bright corner markers, or a grid.
2. **Photograph it on the surface** with the phone camera (`camera_engine.gd` + `camera_ycbcr.gdshader` exist).
3. **Establish correspondence** — auto-detect the bright markers, or (simpler, more robust for v1) have the user **tap the four projected corners in the camera preview**.
4. **Solve the 4-point homography** (reuse the mesh-warp session's homography solver).
5. Now **any point in camera space transforms into projector space exactly** — trace a mask on the camera image and it lands correctly on the projection.

A plain photo of the bare scene is a useful byproduct of step 2 — the reference frame you draw or edge-detect against, then transform through the homography.

**Two hard limits that shape usage:**
- **Planar.** The homography is exact for a flat surface, good for shallow relief, drifts on genuinely 3D objects (a single transform can't capture depth). For flat walls / building faces — most guerrilla targets — it's spot-on. For a sculpture, calibrate the dominant plane and hand-adjust the rest.
- **Valid only for the exact camera + projector positions it was solved from.** Move either and it's stale — recalibrate. **This means the phone camera must be FIXED during calibration and tracing, not hand-held** — hand tremor between "photograph the pattern" and "trace the mask" invalidates it. **A small tripod / phone clamp (ideally a flexible Gorillapod-style mount for guerrilla setups — wraps round a railing, pole, or bag) is effectively a required accessory for this workflow.** UI hint: prompt to recalibrate if the set has been running and the phone may have moved.

**Until this exists, edge-detection masks are misaligned by construction.** Build calibration first or not at all.

### 1a. As built (2026-09-30)

WRP ▸ **CAM** (global warp only) opens `CalibEditor`. Three steps on ONE frozen camera frame:

1. **LIVE** — `CalibPattern` (four numbered markers + a centre cross, on black) goes on the output as the topmost `OutputWorld` child, *after* `QuadWarp`, so it is in raw projector px and not warped. The phone shows the camera. **AUTO**, or FREEZE to do the next step by hand.
2. **MARKERS** — tap the four markers in numbered order (press-and-slide under a magnifier). `CalibHomography.solve()` gives camera px → output px. A ring shows where the calibration predicts the centre cross: if it sits on the cross, the taps were good.
3. **SURFACE** — arrives **already squared up**: four corners are placed automatically (`CalibEditor.auto_surface()` — the largest rectangle of the output's shape that the projector can reach, *as the camera sees it*) and applied to the global warp, so the projection corrects itself the moment the calibration is done. Drag a corner onto a real surface (or UNDO and tap four fresh ones); each maps through the calibration and becomes a corner of the global warp, live on the wall. DONE returns to the warp editor; **SAVE a slot there to keep it** (the calibration writes none, same as DONE in WRP).

**AUTO** does step 2 itself (`CalibDetect`). The wall shows DARK, then ONE plain disc at a time, then DARK; the camera takes a frame of each. A disc is *what was bright in its own frame and in no other*, and disc-shaped. *As first built (and as every wall run below used it)* the discs were the four markers plus the centre: the four were solved and the fifth was the check — predicted within 6 camera px, AUTO went straight to SURFACE, otherwise it stopped in MARKERS with the reason. **That is now a 3×3 grid fitted together — §1c.** Phone still throughout. SURFACE is then marked on a frame lit by a WHITE projector, so the surface's edges are visible in a dark room.

Decisions worth keeping:

- ⚠️ **SURFACE used to wait for four taps, and that was wrong.** On the first complete AUTO pass on a wall the operator pressed DONE the instant AUTO said OK, no corner had been tapped, and "the projection doesn't readjust". A calibration that changes nothing visible reads as a calibration that did not work — hence the automatic rectangle.
- **"As the camera sees it" is the limit of the automatic rectangle.** It is rectangular *from where the phone is*: ordinary keystone correction with the phone roughly facing the wall, right for one seat only from well off to the side, and **nothing at all with the phone beside the projector's lens** (from there every projection already looks rectangular). Squaring it on the wall itself needs the wall's angle to the camera, which one uncalibrated view does not give. Its orientation follows the projection's own top edge, not the camera's axes, so a phone that is not level does not tilt the picture.
- ⚠️ **The centre check does not catch a partly hidden marker.** A lampshade cut marker 2 in half on a wall run: the half disc was still bright, exclusive and "disc-shaped", its centroid slid ~7 px, and the centre check passed at 1.4 px (one bad corner moves the centre by a quarter of its error). So after the solve AUTO compares each disc's measured area with the area the calibration says it should have there (allowing for perspective); one under 72% of the others is hidden. (Then: stop in MARKERS and name it. Since §1c: leave it out of the fit and carry on — `CalibEditor.hidden_discs()`.)
- ⚠️ **The brightest disc-shaped thing in a frame is not always the marker.** With the operator in shot, a round patch on his face was bright for exactly one frame and beat a (half-hidden) marker on contrast; the four points then made no usable quad and AUTO stopped — safely, but needlessly. So when the strongest candidates do not agree with each other, AUTO asks each frame for its runners-up (`CalibDetect.candidates()`) and lets the geometry choose: only the real discs agree with one calibration. Replaying that run recovered the marker. (Then `pick_markers()` over five discs; since §1c `fit_grid()` over nine.)
- **The markers and the surface are marked on the same camera pose**, so nothing the hand does after the capture can invalidate the calibration. That also makes the feed's unpolished orientation irrelevant: a rotated or mirrored frame gives the identical corners (verified).
- **One disc at a time** is what makes detection unambiguous: the one lit in frame N is the one asked for in frame N, whatever way up the camera is.
- ⚠️ **Subtracting one dark frame is NOT enough** — the first version did that, and the first wall run locked onto the operator's head: he moved between frames, and hair uncovering a white wall is a bigger difference than any projected disc in a lit room. Hence "brighter than EVERY other frame" (movement usually persists into later frames; a disc is lit for exactly one) plus a shape test, plus walking down the candidates instead of trusting the brightest.
- **The camera is BORROWED as the deck source** (`_calib_take_camera`), through `_apply_source()` — the one place that arbitrates CameraServer vs tracking's CameraX. No new camera client, so the two-client wedge cannot be reached from here. The pattern is opaque, so the borrowed camera never reaches the wall.
- **Refused outside DUAL·TEX.** MIRROR puts the phone's screen on the projector and DUAL·PLAYER a raw clip; neither carries `OutputWorld`, so the pattern's known positions would be fiction.
- The solved matrix is saved to `user://calibration.cfg` (`CalibEditor.load_calibration()`), ready for §2's traced masks. It is only as true as the rig is still.
- **Debugging a wall run:** AUTO writes its frames to `user://calib_dump/` *only if that folder already exists* (`adb shell run-as <pkg> mkdir files/calib_dump`); `tools/replay_calibration.gd -- <dir>` runs the real detector over them on a desk.

**Verified headless** — `tools/verify_calibration.gd`, 84 checks at the time (127 with §1c): the solve against 200 random quads; a synthetic rig (keystoned projector, oblique camera) where the computed corners land on the surface to ~0.0001 output px and the picture is undistorted across it; detection to <0.03 px on synthetic discs, lit and dark, with a person moving through the sequence; the automatic rectangle (a true 16:9 rectangle on the wall from a square-on camera, inside the projector's frame, as large as it allows, identical for rotated and mirrored camera frames); the real `CalibEditor` through AUTO (clean, a person moving in shot, lagging camera, missing marker, non-flat surface, ESC mid-run); the real `Main` scene through CAM → SURFACE → ESC, RETAKE, a dead camera, and the MIRROR refusal.

**Verified on the Pixel 8 + NEC NP-P506QL (2026-09-30), lit room, white wall, CameraServer path:**
- The manual flow end to end, no script errors, ESC restores the warp, `warp.cfg` untouched.
- AUTO, first with marker 2 out of shot (it said so; markers 1, 3, 4 and the centre were found, repeatable to ~0.5 px between two runs), then re-aimed: **all five found, centre check 3.06 camera px, straight to SURFACE** (12:22). That rig's projection was already square to within 1% as the camera saw it, so the automatic rectangle there only brings the sides in by a few percent.
- AUTO → squared-up SURFACE, end to end, with nobody in shot (12:40): all five found, centre check 3.6 px, the four corners placed and the warp visibly applied on the projector output. ⚠️ The same scene had FAILED one build earlier on marker 4 — see the contrast floor below.

- Projector re-aimed at one wall (13:00): AUTO OK, centre check 1.4 px, squared up — but with marker 2 half behind a lampshade, which that build did not notice (see the decision above; the check was added afterwards and flags that frame set in replay).
- Reset warp → AUTO → saved, twice from the same rig (13:05 and 13:11): the two keystones agree to ~2 output px at every corner — (16, 60) (1825, 4) (1866, 1077) (51, 1021) vs (16, 59) (1827, 4) (1865, 1077) (51, 1022) — a real ~10% keystone correction for a projector hitting the wall from the side.
- ⚠️ **Heat is the practical limit on this phone.** About 1.5 h of projector + camera on battery took the Pixel 8 to Thermal Status 4, at which Android DISABLES the external display: projector black, `no-presentation-display` on every relaunch, until it cools and the display is re-enabled (`cmd display enable-display <id>` or a replug). One AUTO run takes it from status 2 to 3.

**Measured, and what they mean:**
- *Tap error is amplified about 2×.* Taps good to 1 camera px put the corners within ~2 output px on average (worst 7); 3 px gives ~7 (worst 23). Hence the magnifier — and hence AUTO, whose points are good to a fraction of a pixel.
- *A lit white wall leaves almost no headroom.* Auto-exposure put the wall at 235–248 of 255; a disc added only 5–50 levels before clipping — 9, 15 and 21 beside others worth 40–50 in the same frame. `CalibDetect.MIN_CONTRAST` started at 12 and refused a plainly visible marker (9); it is now **5**, made safe by taking each frame's own exposure drift (the median of its exclusive score) off first. In one earlier run marker 4 added ~6 at full resolution and is still lost at that floor. AUTO asks for −2 EV while it reads the wall (`CalibEditor.AUTO_EV`), but **only tracking's CameraX camera can do that** — Godot's `CameraFeed` has no exposure control, so on the CameraServer path (the public build) a near-white wall in a bright room can still fail and fall back to tapping. A dark venue is the easy case.

### 1b. "Squared up as seen from the phone" is not enough — the wall-true spike (2026-09-30)

The user's verdict on the automatic rectangle, on a wall with real keystone: **"isn't great."** The cause is structural, not a bug: the phone is on the HDMI cable, so it sits beside the projector, and from beside the lens every projection looks rectangular. Measured on that rig — the camera saw the raw frame's sides as 511 vs 481 px (no keystone); un-projected onto the wall they were 0.334 vs 0.422 (**27%**). `auto_surface()` corrected almost nothing because, from where it stood, there was almost nothing to correct.

`tools/walltrue_spike.gd` (+ `.cfg`, the inputs of that run) does it properly, outside the app: LEVEL lines on the wall (three shelf boards) give the wall's horizontal vanishing point, PLUMB lines (door frame + a vertical on the other side) the vertical one; that fixes the wall's orientation, the frame is un-projected onto it, and the largest level 16:9 rectangle is found there. Loaded into a warp slot, the user's verdict went "much better… almost aligns, still a bit skewed" → (after the plumb fix below) **"looks a lot better."**

What it taught, for whoever builds it in:
- **The vanishing points alone make it a true rectangle.** The focal length (an estimate) only moves its proportions: ±12% focal ≈ ±2% of the width.
- ⚠️ **Reference lines must BRACKET the picture.** Plumb from two door-frame edges 300 px apart on one side left a 0.8° lean on the far side; adding a vertical on the other side and fitting all of them fixed it.
- **Don't self-calibrate the focal from the two vanishing points** — with a level camera the plumb point is at infinity and the result is noise.
- The app needs a way to GET those lines: taps, a reference rectangle on the wall, or the gravity sensor for plumb. Also worth having: more markers nearer the corners (four inset markers mean the corners are extrapolated, ~2× the error) and a closed-loop check (project the corrected rectangle, photograph it, correct the difference).

### 1c. WALL and the nine-disc AUTO (built 2026-09-30, first wall run the same afternoon)

**AUTO now reads a 3×3 grid** (`CalibPattern.grid_points()`, 10% in from the edges; the four numbered markers stay for tapping by hand) and fits ONE calibration to it — `CalibEditor.fit_grid()`:

1. Every set of four found discs proposes a calibration; the one most of the grid agrees with (within 5 camera px) wins. A disc agrees if *any* of its candidates does, so a decoy that out-shone the real disc is outvoted and the real one picked from the runners-up.
2. Least squares through everything that agrees.
3. Discs that are too small for where they sit (partly hidden) are dropped and the fit redone.
4. At least six must remain, reaching both outer columns and both outer rows — otherwise MARKERS, with the count and the reason. A projection across two walls fails here by agreeing on one wall only.

What that buys, measured in the verifier at 1 camera px of detection noise: the picture's own corners are placed to **1.8 output px instead of 3.3** (nine points, and nearer the corners, where four inset markers extrapolate). And one bad disc — hidden, missed, off the surface, or a face — no longer stops the run: the hint reads `AUTO OK 8/9 · x.x PX`. The sequence is eleven frames instead of seven, at a shorter settle per disc (0.35 s; a frame that still shows the previous disc is noticed and retaken) — about seven seconds. ⚠️ **The phone must REST on something.** At the end AUTO shows the centre disc a second time; if it sits more than 4 camera px from where it was (`MOVE_TOL`), AUTO refuses with "THE PHONE MOVED n PX" — see the wall run below for why. After AUTO the MARKERS step shows where the fit puts the four numbered markers; touching one hands the calibration over to those four points.

**WALL** (a cell in SURFACE) squares the picture on the wall itself — `CalibWall`, §1b's maths as a class:

- Tap two points on each of **two lines that are level on the wall** (shelf, skirting, ceiling line), as far above/below each other as possible.
- Then either **SENSOR** — plumb from the phone's gravity sensor — or two points on each of **two vertical edges**, on either side of the picture. The eighth tap applies it and returns to SURFACE, where the corners can still be dragged.
- Level and plumb fix the wall's orientation to the camera; the projector's frame is un-projected onto the wall, the largest level 16:9 rectangle is found THERE, and it comes back as the four surface corners.

Decisions worth keeping:

- **With tapped plumb lines the picture's sides run through the two tapped vanishing points, whatever the focal length** — wall coordinates run along the two measured directions rather than being squared up first. So the edges are parallel to what was tapped, and the focal estimate (0.722 × the frame's long side ≈ the Pixel 8's main camera; no API here reports it) only moves the proportions: ±12% focal → ∓2% aspect, sides still level and plumb to 0.0000° in the verifier. ⚠️ This differs from the spike, which squared plumb against level: on the 13:53 inputs the two directions come out 0.83° off square and the two treatments put the right-hand side ~11 px apart. Which one is right on that wall is a question for the wall.
- **Gravity is the weaker measurement and is asked for less.** It is squared up against the tapped level direction, so it only supplies what level cannot say (how the wall tips about the level line). On the rig, a sensor 0.5° out then leans the worst side 0.3° instead of 0.5°. The price: on this route the focal length matters (+12% → 0.5° with the phone tipped 6°). Real intrinsics from Camera2 into `CalibEditor.focal_px` would remove that; nothing feeds it yet.
- **Gravity is read when the frame is frozen, not when SENSOR is pressed** — by then the phone has been turned in the hand to tap on it.
- ⚠️ **The sensor's axes are an assumption until a wall run checks them.** `pipeline._calib_gravity()` maps Godot's screen-frame gravity to the camera frame as (x, −y, −z), which is only right while the camera picture is upright on screen. That holds for the CameraServer feed; for tracking's CameraX feed it has never been established, so that path offers no SENSOR. **The check is built in:** when plumb is tapped and a gravity reading exists, the log prints `gravity plumb is N deg from the tapped plumb`.
- **Tap accuracy is the limit of the tapped route:** 1.5 camera px of noise on the eight points leans the worst side 0.3° on average (1.0° at worst) on the rig — long lines, far apart, matter more than anything else. The hints ask for that.
- In WALL a point is only picked up from 30 px (70 elsewhere): its lines meet — a shelf runs into a door frame — and the first tap of one line must not drag the end of the last.
- `input_devices/sensors/enable_gravity` is now on in `project.godot` (Godot ≥ 4.4 leaves sensors off by default).

**Verified headless** (`tools/verify_calibration.gd`, 129 checks, 0 failed): `fit_grid` against a decoy, a missed disc, a half-hidden one, five-of-nine and a two-wall surface; AUTO end to end through the real editor with each of those; `CalibWall` on a 3D pinhole rig with the projector beside the camera (the throw looks square from the phone — sides 1.00 — and is 1.39 on the wall; "squared up from the phone" leans 6.8° there, WALL 0.0000°), by taps and by gravity, with a wrong focal length, with tap noise, with the camera frame rotated 90°; the WALL step driven by touches; the deck keeping the pattern down and its own source up during WALL. `CalibWall` also reproduces the spike on the real 13:53 inputs to within the difference described above.

**Wall run (Pixel 8 + NEC NP-P506QL, lit room, 2026-09-30 ~16:00):**
- ⚠️ **Hand-held does not work, and the first build did not say so.** The user's own attempts were hand-held: the scene slid 10–17 px across the eleven frames (measured from the shelves and door frame in the dump), six or seven of nine discs "agreed", and AUTO said OK over a calibration blended from several poses. Hence the second look at the centre disc and the refusal; the LIVE hint now says "REST THE PHONE ON SOMETHING, NOT IN THE HAND".
- Phone resting: **9/9 discs, rms 0.9–1.2 camera px, moved 0.0–0.3 px**, three runs from two positions. 0.35 s per disc is enough for the NEC; a lit white wall gave every disc 50–115 levels of contrast.
- **The gravity mapping holds.** In two phone positions gravity came out 0.3° and 0.0° off square to the shelf edges (three shelves whose own vanishing points agree to a few px), and within 0.1° of the door's left jamb. Solving "gravity ⟂ level" for the focal length gives ~1400 and ~1460 px against the assumed 1386, so the estimate is sound for this phone.
- ⚠️ **Real "verticals" lie.** Plumb tapped on the two outer edges of the door frame was 3.66° from gravity and 2.8° off square to the shelves: the right jamb leans ~0.6° in the picture against every other reference. SENSOR was the better plumb in this room; the tapped-vs-squared question above is secondary to whether the tapped edge is really plumb.
- The user's verdict on WALL by SENSOR (shelf undersides as level, taps driven over adb from edges fitted to ~0.1 px): **"it runs close, still not perfect"**, then "good enough". Which way it is off was not said.
- ⚠️ **Two things the UI does not get across.** (1) A wall-true rectangle looks like a trapezoid from a seat beside the projector — the user's first reaction was "it skews the output"; "square on the wall" and "square from here" are different goals and the editor should say which one it just did. (2) The level/plumb taps were not understood unaided ("I don't get the align lines"); finger taps are also far coarser than the fitted edges used in this run. Detecting the lines automatically is the obvious next step.
- Heat: the whole run sat at Thermal Status 3, one below the external-display cut-off.

### 1d. The wall's square by itself, and saying which square is on (built 2026-09-30)

Both of §1c's UI findings, answered.

**The level lines are found, not tapped** — `scripts/calib_lines.gd` (`CalibLines`), the desk work of the first wall run done in the app:

1. **Segments.** Find the picture's long straight edges, whatever they are: a coarse Hough search for lines many edge pixels lie on (verticals left out beforehand — a room is mostly verticals and they say nothing about level), then each candidate re-measured at full resolution, where it has to *prove* it is an edge: a brightness step tracked along it, a straight line through those to under a pixel, there for 60% of its own length, 120 px long. A shelf edge passes; book spines, a keyboard and a chair's mesh do not.
2. **Directions.** With gravity known, each segment — if it is level — runs in one particular compass direction (the plane through the camera and the segment, cut by the horizontal). Segments along the horizon say nothing and are left out.
3. **The room's grid.** Rooms are square, so level edges point in two directions 90° apart; the segments' directions, folded onto a quarter turn, pile up there. It must rest on more than one board.
4. **Which wall.** The one the camera faces more squarely.
5. **The answer.** Every pair of the wall's own segments far enough apart proposes where they meet; the proposal most edge agrees with wins (and must be level by the sensor to 2°); one least-squares step then combines the agreeing edges with gravity — edges are sharp across themselves and vague along, and the horizon cuts across exactly that. Two lines come back, four points, what four taps would have been. With nothing usable on the wall itself, two lines in the direction the rest of the room implies ("LEVEL FROM THE ROOM").

⚠️ **Segments first, each proven — the two versions that went straight from edge PIXELS both failed on real frames.** A vote per pixel ("which way does your own edge point?") was 7° and 9° out: one pixel's direction is good to a few degrees and the compass bearing multiplies it. Scoring each candidate direction by how well the pixels line up along its lines got two real frames right and the third — the user's own run, which is how it was found — 55° wrong: a lived-in room is full of edge pixels that line up well enough along *any* direction, and the score barely moved with direction (750 against a median of 620). Counting how far each line runs, even in consecutive stretches, did not rescue it. ⚠️ **A measured line lying along the horizon agrees with every direction and must be dropped** — one (a keyboard propped against the wall) pulled the answer 1.5°.

**On the three frozen frames of the day** (`tools/replay_lines.gd -- <dump dir>`; AUTO now writes `meta.cfg` with gravity and the projector's frame beside its frames): the level direction comes out 0.6° and 0.85° from the hand-fitted one on the two frames that have one, gravity 0.06–0.31° off square to it, keystone 1.26–1.29× (hand taps: 1.28–1.29×), ~115 ms on a desk. Those frames are the user's room and stay out of the repo.

**AUTO arrives on the wall's square.** On reaching SURFACE the search runs unasked, and if it finds the wall the wall's square is what is on — so AUTO then DONE is the whole job. ⚠️ It used to take a press of WALL; on the second wall run "AUTO, DONE, DONE" left the phone's square up and the user's report was *"it resets back to the skewed, it doesn't apply the auto"*. When the wall cannot be found (no edges, no gravity reading) SURFACE stays on the phone's square and says why; WALL then opens the taps.

**SURFACE says which square is on, and flips.** "SQUARE ON THE WALL · 3 LEVEL EDGES · RIGHT FACING IT, SKEWED FROM THE SIDE" ↔ "SQUARE AS SEEN FROM THE PHONE — WALL SQUARES IT FOR PEOPLE FACING THE WALL". The second cell reads FROM HERE or WALL accordingly; the lines it used are drawn faintly on the picture, and the fifth cell becomes LINES, which opens them for dragging or re-tapping (§1c's manual step).

**Verified headless** (147 checks, 0 failed): a rendered room on the 3D rig — picture rail, shelves, a door and shelf on the next wall, a lamp, a picture hung 14° crooked — gives the level direction to 0.02° and the keystone within 0.14 output px of exact taps; with gravity 0.5° out; from the next wall alone; refused for the lamp and crooked picture alone, one board alone, an empty picture, no gravity, edges only inside the projection; and the editor: arriving on the wall's square, the flip both ways, LINES, plumb taps after found lines, the fall-back to taps.

**On the wall (Pixel 8 + NEC, 2026-09-30 ~17:30), the user's own run — AUTO, DONE, DONE, no taps:** two AUTO passes, each 9/9 (rms 0.95–1.0 px, moved 0.1 px), each landing on the wall's square: two shelf edges found in **297–329 ms on the phone**, gravity 0.1–0.2° off square to them, keystone on the wall 1.26–1.28×, the two passes agreeing on the level direction to 0.13°. **The user's verdict: "it looks good this one!"**

⚠️ **A thing to know when driving the phone over adb:** on that run the touchscreen was reporting a touch going down and up many times a second on the PREV cell — whatever held the phone was pressing the corner of the glass. PREV fired ~3×/s and every injected tap was ignored (the editors take one pointer at a time). `adb shell getevent -lt` shows it at once; it looks exactly like "the UI ignores my taps".

### 1e. The check on the wall, heat, the lens, and the save prompt (built 2026-09-30 evening)

**The check.** After an AUTO, before the deck comes back, four discs are projected at the corrected picture's own corners (10% in) and photographed; where they land is compared with where the picture was meant to be. Within 1.5 camera px: "CHECKED 0.6 PX". Between 1.5 and 30: the calibration is re-solved exactly at those four points, the corners re-set through it, and a second look confirms ("CHECKED 0.3 PX (WAS 5.2)") or puts it back. A fifth disc, where AUTO showed the one it shows twice, says whether the phone has moved since — then nothing is checked, and SURFACE says "UNCHECKED: PHONE MOVED".
- ⚠️ **What it closes and what it cannot.** It closes the loop on everything between "this is the rectangle" and the light on the wall: the fit, the warp, a lens or wall that is not what a homography assumes. It CANNOT tell whether the rectangle was the right one — a wrong idea of which way the wall faces moves the target and the result together. (I had told the user it would remove "the last degree of error"; it does not. That degree is the wall's direction, and the way to it is more evidence about the wall: more rooms' worth of edges, or a second phone position.)
- In practice it is mostly a VERIFICATION: a smooth lens distortion of 12 px at the frame's edge changed the corners' landing by 0.8 px, because the nine-disc fit absorbs it. The correction needs something local (the verifier uses a 6 px dent at one corner: 5.2 px off → 0.0).
- To make room for it, MARKERS → SURFACE is now one routine (`_arrive()`) that does everything needing the pattern up and the lens borrowed BEFORE the step changes: the phone's square, the wall's square, the check.
- Not done with no projector link, or after a FREEZE (the phone is in a hand).

**Heat** (`scripts/android_probe.gd` + the pipeline's heat watch). Android's thermal status is polled every 5 s. At 3 (SEVERE — one step before the cut): the frame rate is held at 30, a status flash says why, the FPS readout reads "HOT · FPS 30" for as long as it lasts, and the calibration's hints start "PHONE HOT — BE QUICK". At 4: a dialog that stays — Android has switched the projector off; cool, replug. Full rate returns at 1. On the Pixel 8, `adb shell cmd thermalservice override-status 3` (then `reset`) exercised it: status 0 → 3 → 0, FPS 43 → 30 → back.

**The lens.** `AndroidProbe.ask_camera()` reads the back camera's focal length and sensor size from Camera2: Pixel 8 camera 0 — 6.9 mm over a 9.792 mm sensor = **0.705 × the frame's long side, 1353 px** at 1080p (the estimate was 0.722 / 1386; "gravity ⟂ level" had said ~1400–1460). `CalibWall` and `CalibLines` now use it; the estimate remains the fallback.

⚠️ **No Kotlin for either.** Godot 4.4+ reaches Java by reflection (`Engine.get_singleton("AndroidRuntime")`, `JavaClassWrapper`), so neither needed an AAR rebuilt. But GDScript cannot catch: a missing method or an unexpected type ends the function it happened in. Hence the probe's shape — a "broken" latch set before each risky call, results in static vars with harmless defaults, and the pipeline calling it deferred from its own stack. ⚠️ `obj.call("get", key)`, never `obj.get(key)`: every Godot Object has a `get()` of its own.

**The save prompt.** DONE with a keystone applied now asks "SAVE IT TO WARP SLOT n? UNSAVED, IT IS GONE WHEN THE APP RESTARTS." — SAVE SLOT n / NOT NOW. (DONE still writes nothing by itself; the first user lost a keystone to that.)

**Verified headless** (158 checks, 0 failed) and, on the Pixel 8 without a projector: the two probes, the heat path by override, a dry-run calibration arriving on the wall's square (four shelf edges in 237 ms, gravity 0.4° off square), the hints fitting their one line (≈133 characters at most), and the save prompt.

**🔴 Owed:** the check on a real projector (it has only run against the synthetic camera); more rooms (every frame so far is one room with three shelves); a bare wall, where the direction has to come from the next wall; WALL by the user's own taps; the user's eye on tapped-vs-squared plumb with an edge that really is plumb. Then as before — corners dragged onto a real surface and the fit judged by eye; the −2 EV path with tracking holding the lens (built, never run); AUTO in a dark room; a nudge pad if the magnifier is not precise enough for manual taps. Not started: the closed-loop check (project the corrected rectangle, photograph it, correct the difference), real camera intrinsics, heat protection during long calibration sessions.

---

## 2. Edge-detection procedural masks — after calibration

Generate a mask polygon from the camera view of a surface, as an *assist* (rough polygon → user refines), not automation.

Pipeline: freeze camera frame → Sobel/threshold shader (one pass on a frozen frame, cheap; expose threshold/contrast/invert sliders — real rooms have bad light) → **one-shot** `get_image()` readback (10–30 ms, never per-frame, downsample to 720p) → tap-to-seed flood-fill → marching-squares contour → Douglas–Peucker simplify (DETAIL slider, target 8–40 points) → transform through the §1 homography → hand to `RegionEditor`'s polygon format as an editable mask.

**Steps 4–6 (trace + simplify) are the real work.** The shader is the easy part.

**DECIDED — this is a pro feature for guerrilla mapping.** The earlier challenge ("image-mask import from the desktop covers this") assumed you *have* a desktop. Guerrilla / outdoor mapping is exactly the case where you don't: out with just the phone and a projector, mapping onto a wall or found object with no laptop, no Photoshop. On-the-fly camera masking is the only way to mask in that scenario — it's not redundant with image masks, it's the tool for the situation image masks can't serve. Worth building.

**But the calibration dependency is HARDER here, not softer.** In a guerrilla rig the phone (handheld) and projector (on a bag, a ledge, wherever) are in wildly different positions, so the camera↔projector misalignment is severe, not subtle. A traced mask that lands 30 cm off the surface is useless. §1 calibration isn't optional polish for this use case — it's the thing that makes the whole guerrilla workflow function. Order is absolute: calibration first, edge detection on top.

---

## 3. Reference / mask export to disk — small, independent, unblocks AI

Export aligned PNGs on demand:
- `frame_reference.png` — camera snapshot of the target surface
- `region_mask.png` — the mask (rasterize polygon masks; raster masks export directly)

**Write to `/storage/emulated/0/PocketVJ/exports/`, NOT `user://`** — app-private storage is invisible to the file manager and other apps, so an export nobody can reach isn't an export. A few lines of code. This is the whole "feature" — the rest is workflow.

## 4. AI content round-trip — mostly workflow, not code

- Take the exported reference + mask to Gemini / Veo / etc. (happens off-device).
- Generated clips come back into the library as ordinary files via the existing scan of `/storage/emulated/0/PocketVJ/clips/`.
- The ping-pong encode (mapping spec §1) makes any generated clip loop seamlessly.
- Prompt guidance (docs, not app): specify continuous motion + seamless-loop intent, mask the region to be filled.

The only *code* here is §3's export. Everything else is a documented workflow.

---

## 5. Recommended order (all after per-region warp)

1. **Reference/mask export (§3)** — smallest, independent, immediately useful, unblocks the AI workflow.
2. **Projector-camera calibration (§1)** — the gate for anything camera-derived; reuses the mesh-warp homography.
3. **Edge-detection masks (§2)** — only after §1, and only if it beats better image-mask import.

Set recording is a separate document (`SET_RECORDING_SPEC.md`).
