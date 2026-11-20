class_name HelpText
extends RefCounted
## Every help card in the app, keyed by WHERE the control is (HELP_CARDS_SPEC.md
## §3): "<SECTION>/<ROW CAPTION>", a section's own card at "<SECTION>", a nav
## cell at "NAV/<LABEL>", an effect's tunable at "FX <EFFECT>/<CAPTION>". A
## caption that changes with its value is found by the LONGEST key it starts
## with ("MOD MATRIX/SLOT" for "SLOT 1   LOW").
##
## The rule for a card (§4): three sentences at most — what it does, what to
## set it to, what it affects. The app's own words. No history: that is the
## specs' job.
##
## ⚠️ These are a first pass by the person who built the features.
## tools/verify_help.gd prints every control that has no card.

const FeaturesS := preload("res://core/features.gd")   ## static: loads under --script too

const CARDS := {
	# --- the nav bar ---
	"NAV/PREV": ["PREV", "The clip before this one, cut immediately. The deck keeps its mode."],
	"NAV/NEXT": ["NEXT", "The clip after this one, cut immediately. In SEQUENTIAL the sequence carries on from there."],
	"NAV/MODE": ["MODE", "How clips change: by hand, in order, at random or on a sweep — and every setting about time and sound: audio input, the mod matrix, beat flip, tracking, the second lane. The cell shows the mode that is on."],
	"NAV/FX": ["FX", "The effect on the picture and its settings. One effect at a time; OFF is the plain clip. The cell shows which is on."],
	"NAV/SRC": ["SRC", "What the deck plays: your clips (VIDEO) or the phone's camera live (CAMERA). Tap to switch. Clips fetched from Google Drive are in the library and play as VIDEO."],
	"NAV/TAP": ["TAP", "Tap the beat four or more times to set the tempo. Everything tempo-locked (BEAT FLIP on GRID, the sequencer's slot clock, BEAT in the mod matrix) follows it. The dot pulses on every sound the mic hears."],
	"NAV/WRP": ["WRP — WARP", "Fit the picture to the surface: drag the four corners, or a mesh for a bent one. CAM in there sets the corners from the phone's camera. Save a slot to keep it; slot 1 loads at start."],
	"NAV/MSK": ["MSK — MASKS", "Cut the picture into regions with their own clips, effects and warps, or lay an image mask over it. This is the mapping tool for a wall with things on it."],
	"NAV/LIB": ["LIB — LIBRARY", "Your clips and where they come from, the output (projector, LED panel, recording), the video link to another phone, and image masks."],
	"NAV/PERF": ["PERF — PERFORM", "The gig screen: the clip queue and the crossfader, nothing else. A three-finger tap anywhere gets you in and out."],
	"NAV/REC": ["REC — RECORD", "Record the output to a file on the phone, with the mic if REC AUDIO is on (LIB ▸ OUTPUT). Tap to start, tap to stop; long sets are cut into segments."],

	# --- MODE panel ---
	"SWITCH MODE": ["SWITCH MODE", "How the deck moves between clips. MANUAL: only when you press. SEQUENTIAL: in order, on the clock or on the sound. RANDOM: any clip, at the RANDOM RATE. LFO: a sweep back and forth through the list."],
	"SWITCH MODE/MANUAL": ["MANUAL", "Clips change only when you press PREV or NEXT. Audio-switch does nothing here."],
	"SWITCH MODE/SEQUENTIAL": ["SEQUENTIAL", "Clips play in order. With AUDIO-SWITCH on, the sound decides when to advance; with the sequencer armed, its slots do."],
	"SWITCH MODE/RANDOM": ["RANDOM", "Any clip next, never the same one twice in a row, every RANDOM RATE seconds (0 = on every trigger)."],
	"SWITCH MODE/LFO": ["LFO", "Sweeps up and down the clip list, LFO SEC/CLIP per step. A slow, even churn."],
	"MODE SETTINGS": ["MODE SETTINGS", "The clocks behind RANDOM and LFO, and whether the sound can advance the clip."],
	"MODE SETTINGS/LFO SEC/CLIP": ["LFO SEC/CLIP", "Seconds each clip stays in LFO mode before the sweep moves on. Not tempo-locked."],
	"MODE SETTINGS/RANDOM RATE": ["RANDOM RATE", "Seconds between random cuts. 0 cuts as fast as clips can load."],
	"MODE SETTINGS/AUDIO-SWITCH ON": ["AUDIO-SWITCH", "The sound advances the clip: every onset the mic hears (see ADVANCE ON) fires the mode's next clip, no faster than five a second. Needs a mode other than MANUAL."],
	"MODE SETTINGS/ADVANCE ON": ["ADVANCE ON", "Which sound advances the clip. ONSET: any hit. KICK: the low band — the kick and the bass. HATS: the high band. Same choice BEAT FLIP offers."],
	"LANE B": ["LANE B", "A second deck under the first, mixed with the crossfader. Arm it to pay for it; unarmed it costs nothing. It plays clips, a peer phone, or TouchDesigner."],
	"LANE B/ARM LANE B": ["ARM LANE B", "Switch the second deck on. It starts decoding, the crossfader comes alive, and the sequencer's B lane can drive it."],
	"LANE B/B SOURCE:": ["B SOURCE", "What lane B plays: CLIPS from the library, a PEER phone over the video link, or TD (TouchDesigner) over the link."],
	"LANE B/CROSSFADE": ["CROSSFADE", "0 = all lane A, 1 = all lane B. Any touch here puts XFADE MODE back to MANUAL."],
	"LANE B/XFADE MODE:": ["XFADE MODE", "Who moves the crossfader. MANUAL: you. BEAT: it flips every BEAT EVERY beats. AUDIO: it flips on the sound. LFO: a slow sweep over bars."],
	"LANE B/BEAT EVERY:": ["BEAT EVERY", "In BEAT xfade mode, how many beats between flips. 4 is once a bar."],
	"LANE B/LFO PERIOD:": ["LFO PERIOD", "In LFO xfade mode, how many bars one full sweep A → B → A takes."],
	"LANE B/SWITCH:": ["SWITCH", "In BEAT xfade mode, how long the fade takes, in beats. CUT is instant."],
	"LANE B/B PATTERN AUTO": ["B PATTERN AUTO", "Let the sequencer's B lane advance lane B's clips on its own clock."],
	"LANE B/B BAR OFFSET": ["B BAR OFFSET", "Start lane B's pattern this many beats after lane A's, so the two lanes do not change on the same downbeat."],
	"AUDIO INPUT": ["AUDIO INPUT", "The mic, and how a sound becomes a beat. Set GAIN so music sits around the top of the meter without pinning it, LEARN the floor with the room quiet, and leave the rest."],
	"AUDIO INPUT/MIC:": ["MIC", "Whether the app is listening. Tap to allow the microphone — nothing audio-reactive works without it. BLOCKED means Android has stopped asking: allow it in the phone's settings, under apps, permissions."],
	"AUDIO INPUT/INPUT LEVEL": ["INPUT LEVEL", "What the mic hears, after gain. The border flashes on every onset the detector fires — if it flashes on the beat, everything else will follow it."],
	"AUDIO INPUT/INPUT GAIN": ["INPUT GAIN", "How much the mic is turned up. Aim for music around three quarters of the meter. Too high pins it at the top and the detector goes deaf in loud passages."],
	"AUDIO INPUT/NOISE FLOOR": ["NOISE FLOOR", "Sounds under this level are not onsets. Raise it if the deck cuts on a quiet room's noise; LEARN FLOOR sets it for you."],
	"AUDIO INPUT/LEARN FLOOR": ["LEARN FLOOR", "Listens for twelve seconds and sets NOISE FLOOR just above what it heard. Do it with the music OFF and the room as it will be."],
	"AUDIO INPUT/ONSET SENS": ["ONSET SENS", "How much louder than the last moment a sound must be to count. Lower fires on more; higher only on real hits."],
	"MOD MATRIX": ["MOD MATRIX", "Sound (and the beat, and the tracker) moving the picture every frame. Four slots, each a source going to a target with a depth. Tap a RECIPE to start; AMOUNT pulls it all down when the room gets busy."],
	"MOD MATRIX/INTENSITY OUT": ["INTENSITY OUT", "The effect amount the matrix is sending right now. Watch it move while you set a slot."],
	"MOD MATRIX/SOURCES": ["SOURCES", "What each source hears, live: LOW (kick and bass), MID, HIGH (hats and air), HIT (jumps on every onset, then falls), BRIGHT (how much of the sound is high up). If a bar does not move with the music, the mic or GAIN is the problem, not the matrix."],
	"MOD MATRIX/MATRIX ON": ["MATRIX ON", "Off, the effect amount follows the mic level as it always did. On, the slots below drive it — and FX A/B and SPEED if any slot goes there."],
	"MOD MATRIX/AMOUNT": ["AMOUNT", "Scales every slot at once. The knob for the moment: down when the picture gets too busy, up for the drop."],
	"MOD MATRIX/BASE": ["BASE", "The effect amount with every source silent. The floor the slots add to."],
	"MOD MATRIX/RECIPES": ["RECIPES", "Fill the slots with a routing that works and switch the matrix on. PUMP: bass drives the effect, hits kick its first setting. SHIMMER: hats and brightness drive the effect's settings. BREATHE: the effect swells with each bar. HITS: hits drive the effect and the clip speed. CLEAR empties the slots."],
	"MOD MATRIX/SLOT": ["SLOT — SOURCE", "Tap to cycle what this slot listens to. LEVEL: loudness. LOW/MID/HIGH: the bands. HIT: onsets, falling. BRIGHT: timbre. BEAT: a saw over the bar; STEP: a saw per beat. TRACK/HAND and the CROWD sources need the tracker on."],
	"MOD MATRIX/→": ["SLOT — TARGET", "Where this slot goes. INTENSITY: the effect amount. FX A / FX B: the effect's first or second setting (named here for the effect that is on). SPEED: playback speed, up to AUDIO SPEED's max."],
	"MOD MATRIX/DEPTH": ["DEPTH", "How far the source moves the target. 1.0 = a full source moves an FX setting half its range; 2.0 = all of it."],
	"MOD MATRIX/INVERT (DUCK)": ["INVERT (DUCK)", "Turn the source upside down: silence gives full depth, sound takes it away. For things that should calm down on the hits."],
	"MOD MATRIX/CURVE": ["CURVE", "The shape between source and target. LIN: straight. SQR: quiet stays quiet, loud punches. SQRT: a little sound already moves it."],
	"BEAT FLIP": ["BEAT FLIP", "Mirrors half the picture onto the other on the beat. Choose what triggers it (a hit, the kick, the hats, or the tap grid), how often, and how the mirror is drawn."],
	"BEAT FLIP/FLIP ON": ["FLIP ON", "Switch the mirror on. Nothing happens until a trigger fires."],
	"BEAT FLIP/SUBDIVISION": ["SUBDIVISION", "Flip on every trigger, or every 2nd, 4th, 8th. 1 on a busy track is a strobe."],
	"BEAT FLIP/MODE": ["MODE", "MOMENTARY: the mirror holds for a beat after each trigger, then lets go. ALTERNATING: each trigger toggles it on or off."],
	"BEAT FLIP/SOURCE": ["SOURCE", "Which half of the picture is copied over the other: LEFT, RIGHT, or ALT, which swaps every time the mirror turns on — so the whole picture keeps moving."],
	"BEAT FLIP/TREATMENT": ["TREATMENT", "How the copied half is drawn: MIRROR (folded at the middle), FLIP (turned round), ALT (swapping between the two), REPEAT (tiled)."],
	"BEAT FLIP/AUTO-CHANGE": ["AUTO-CHANGE", "Let the bar clock change the treatment every 2, 4 or 8 bars, so the look does not sit still. Needs a tempo (TAP)."],
	"BEAT FLIP/…ADVANCING": ["…ADVANCING", "What AUTO-CHANGE advances: the treatment only, or the axis and the source with it. ALL changes everything."],
	"BEAT FLIP/AXIS": ["AXIS", "Mirror left-right (HORIZ) or top-bottom (VERT)."],
	"BEAT FLIP/TRIGGER": ["TRIGGER", "What fires the flip. ONSET: any sound the mic hears. KICK: the low band. HATS: the high band. GRID: the tap tempo, exactly on the beat — needs a TAP first."],
	"AUDIO SPEED": ["AUDIO SPEED", "The clip plays faster when the room is louder. Off, clips play at 1x. (A mod slot to SPEED takes this over.)"],
	"AUDIO SPEED/AUDIO SPEED ON": ["AUDIO SPEED ON", "Playback speed follows the mic level: quiet is 1x, loud is up to MAX SPEED."],
	"AUDIO SPEED/MAX SPEED": ["MAX SPEED", "The speed at full level. 3x is lively; 10x is a blur."],
	"TRACKING": ["TRACKING", "The camera watches people: one performer's head and hands, or a crowd. What it sees can drive the mod matrix, the CROWD and HUD effects, and OSC to a laptop."],
	"TRACKING/HEAD X·Y·Z": ["HEAD X·Y·Z", "Where the tracked head is: left-right, up-down, and how far away. In crowd mode, how many people and where they are."],
	"TRACKING/TRACKING:": ["TRACKING ON/OFF", "Start or stop the camera tracker. It takes the camera, so the deck cannot show the camera as a source at the same time."],
	"TRACKING/MODE:": ["MODE", "LANDMARK follows one person's head (and hands). CROWD counts and places several people. CAMERA is the picture only, no tracking."],
	"TRACKING/LENS:": ["LENS", "Which camera: REAR faces the room, FRONT faces you."],
	"TRACKING/RANGE (ZOOM)": ["RANGE (ZOOM)", "Zoom the tracker's view in for people further away. More zoom, narrower view."],
	"TRACKING/AE LOCK:": ["AE LOCK", "Freeze the camera's exposure so a flashing projector does not make it hunt."],
	"TRACKING/EXPOSURE": ["EXPOSURE", "Brighter or darker camera picture, in stops. Down for a bright projector wash, up for a dark room."],
	"TRACKING/CROWD SLOTS:": ["CROWD SLOTS", "How many people the crowd tracker follows at once. More costs more."],
	"TRACKING/PER-SLOT OSC:": ["PER-SLOT OSC", "Send each tracked person's position over OSC, not just the crowd's totals."],
	"TRACKING/FILTER CUTOFF": ["FILTER CUTOFF", "How quickly the tracked position follows a move. Lower is smoother and later."],
	"TRACKING/FILTER BETA": ["FILTER BETA", "How much a fast move is allowed to cut through the smoothing. Raise it if fast moves lag."],
	"TRACKING/REBASELINE DEPTH": ["REBASELINE DEPTH", "Take where the performer stands now as the middle distance for TRACK in the mod matrix."],
	"TRACKING/OSC OUT:": ["OSC OUT", "Send what the tracker sees to a laptop over the network (TouchDesigner, Resolume…)."],
	"TRACKING/OSC TARGETS": ["OSC TARGETS", "Where the OSC goes."],
	"TRACKING/TRIGGER LANES": ["TRIGGER LANES", "The tracker's events routed to the sequencer's lanes."],
	"TRACKING/TRACKER VIEW:": ["TRACKER VIEW", "Show the camera with the tracking drawn over it on the phone, to check it is seeing what you think."],
	"TRACKING/HANDS": ["HANDS", "Track hands as well as the head. HAND in the mod matrix needs it."],

	# --- LIB panel ---
	"SOURCES & LIBRARY": ["SOURCES & LIBRARY", "Where clips come from: videos, folders and packs you import (PVJ keeps its own copy), the demo clips, your recordings, a clip server on the network, Google Drive. STORAGE shows what it all takes."],
	"SOURCES & LIBRARY/CLIP GRID…": ["CLIP GRID", "Every clip as a tile. Tap one to play it; the deck's mode carries on from there."],
	"SOURCES & LIBRARY/IMPORT CLIPS": ["IMPORT CLIPS", "Pick videos with the phone's file picker — Downloads, Google Drive, a USB stick, anywhere it can reach. PVJ copies them into its own storage; your files stay where they are. A clip already in PVJ is skipped, so importing twice is safe."],
	"SOURCES & LIBRARY/IMPORT FOLDER": ["IMPORT FOLDER", "Pick a folder and its videos come in as one chip in the clip grid, named after it — the folders directly inside it are folded into that chip. PVJ copies the files; the folder itself is not changed."],
	"SOURCES & LIBRARY/IMPORT PACK": ["IMPORT PACK", "Pick a downloaded pack (.zip) and its clips land in their own chip, named after the pack — nothing to unzip by hand. Clips already in PVJ are skipped; CANCEL keeps what has landed."],
	"SOURCES & LIBRARY/COPY CLIPS INTO PVJ": ["COPY CLIPS INTO PVJ", "PVJ now keeps its own copy of your clips. This copies the folder you linked in an earlier version into PVJ, keeping its layout, so every sequence, mask and setting stays as it is. The deck keeps playing; PVJ switches to its own copy at the next start. Your folder is not changed."],
	"SOURCES & LIBRARY/RE-IMPORT OLD CLIPS FOLDER": ["RE-IMPORT OLD CLIPS FOLDER", "The folder you linked in an earlier version could not be reached. Pick it again (or a copy of it) and PVJ copies it in with its layout, so the sequences, masks and order you made find their clips again."],
	"SOURCES & LIBRARY/LOAD DEMO CLIPS": ["LOAD DEMO CLIPS", "Puts the eight clips that come with PVJ back in the library. Ones already there are left alone, so it is safe to press again."],
	"SOURCES & LIBRARY/GET MORE CLIPS…": ["GET MORE CLIPS", "Opens c-u.studio in the browser, where the free starter packs are. Download one, then IMPORT PACK brings its clips into PVJ."],
	"SOURCES & LIBRARY/LOCAL FILES…": ["LOCAL FILES", "Pick videos from anywhere on the phone. They are copied into the library."],
	"SOURCES & LIBRARY/STORAGE…": ["STORAGE", "How much room your clips and PVJ's cache take, and how much the phone has left. Tap a folder to remove it from PVJ (the files you imported it from stay where they are). CLEAR CACHE deletes thumbnails and temporary files; they are made again when needed. SAVE SETUP keeps your sequences, masks, warp and settings in one zip — RESTORE SETUP brings them back on another install."],
	"SOURCES & LIBRARY/RECORDINGS…": ["RECORDINGS", "What REC has recorded. Play one back, or share it."],
	"SOURCES & LIBRARY/CLIP SERVER…": ["CLIP SERVER", "Browse and fetch clips from a PocketVJ clip server on the same network."],
	"SOURCES & LIBRARY/GOOGLE DRIVE…": ["GOOGLE DRIVE", "Browse a Drive folder and download clips into the library. Needs a sign-in the first time."],
	"SOURCES & LIBRARY/RESCAN LIBRARY": ["RESCAN", "Look at PVJ's clips again. PVJ also looks by itself after every import."],
	"OUTPUT": ["OUTPUT", "Where the picture goes: the projector over HDMI (DUAL shows the deck there and the controls here; MIRROR shows this screen), an LED panel over the network, and the recorder's settings."],
	"OUTPUT/DISPLAY:": ["DISPLAY", "DUAL: the projector gets the deck's output and the phone keeps the controls — the normal way. MIRROR: the projector shows exactly this screen."],
	"OUTPUT/MIRROR FILL:": ["MIRROR FILL", "In MIRROR, FIT keeps the whole screen with black bars; COVER fills the projector and crops."],
	"OUTPUT/FLIP UI 180": ["FLIP UI 180", "Turn the controls upside down, for a phone mounted the other way up."],
	"OUTPUT/IDLE SCREEN": ["IDLE SCREEN", "While no clip is loaded, the projector shows the PVJ ident instead of black. Never on the phone's screen. Off: black."],
	"OUTPUT/LED PANEL": ["LED PANEL", "Also send the picture to an LED panel over the network (DDP). Set PANEL IP first."],
	"OUTPUT/PANEL IP:": ["PANEL IP", "The LED panel's address on the network."],
	"OUTPUT/LED FIT:": ["LED FIT", "How the picture fits the panel's shape: SQUASH (stretch), CROP (fill, cut the edges), LETTERBOX (fit, with bars)."],
	"OUTPUT/LED SOURCE:": ["LED SOURCE", "DECK sends the picture. LIFE sends a game of life running on the beat instead."],
	"OUTPUT/LIFE RATE:": ["LIFE RATE", "How often the game of life steps: free-running, or once, twice, four or eight times a beat."],
	"OUTPUT/LIFE RULE:": ["LIFE RULE", "Which rule the game of life runs."],
	"OUTPUT/LED SEND RATE": ["LED SEND RATE", "Frames a second sent to the panel. Lower if the network drops frames."],
	"OUTPUT/REC SEGMENT": ["REC SEGMENT", "Minutes per file when recording. A long set becomes several files, none of them huge."],
	"OUTPUT/REC AUDIO": ["REC AUDIO", "Record the phone's mic into the file as well as the picture."],
	"VIDEO LINK": ["VIDEO LINK", "Two phones on one network: one sends its picture to the other, which can play it as lane B or as a layer. This phone is the sender or the receiver."],
	"VIDEO LINK/VIDEO LINK": ["VIDEO LINK ON", "Join the link. What happens next depends on LINK ROLE."],
	"VIDEO LINK/LINK ROLE:": ["LINK ROLE", "What this phone is on the link: the one sending its picture, or the one receiving."],
	"VIDEO LINK/AUTO-PULL CAM": ["AUTO-PULL CAM", "Receive a camera phone's stream as soon as it appears, without pressing PULL."],
	"VIDEO LINK/LATENCY STAMP": ["LATENCY STAMP", "Burn a timestamp into the picture to measure the link's delay. Off for a show."],
	"VIDEO LINK/PHASE TRIM": ["PHASE TRIM", "Nudge the received picture earlier or later, in milliseconds, so two phones cut on the same beat."],
	"OSC": ["OSC", "Drive this phone from a laptop, a desk or another app over the network (OSC), and send its state back. Messages work the same controls your hands do."],
	"OSC/OSC IN": ["OSC IN", "The port and this phone's address on the network: what the sender needs typed in."],
	"OSC/OSC OUT": ["OSC OUT", "Send the deck's state (crossfade, BPM, mode, clip, beat) to the targets below, so a desk can mirror it. Off sends nothing."],
	"OSC/OUT TARGETS": ["OUT TARGETS", "Where OSC OUT goes: ip:port, up to 8, separated by commas. A list with a wrong entry is refused whole."],
	"OSC/OUT RATE": ["OUT RATE", "How many times a second OSC OUT may send. Changes go out as they happen, and everything once a second."],
	"OSC/OUT STATUS": ["OUT STATUS", "What OSC OUT is doing right now. NO TARGETS means it is on but sends nothing."],
	"MASK IMAGE": ["MASK IMAGE", "Lay a picture over the output as a mask: black hides, white shows. Draw it on a computer from a photo of the wall, or export a reference frame and paint on that."],
	"MASK IMAGE/MASK IMG:": ["MASK IMG", "Pick the image file. None turns the mask off."],
	"MASK IMAGE/MASK FIT:": ["MASK FIT", "How the image fits the output: stretched, fitted, or filling."],
	"MASK IMAGE/MASK INVERT": ["MASK INVERT", "Swap what hides and what shows."],
	"MASK IMAGE/MASK OPACITY": ["MASK OPACITY", "How hard the mask hides. 1 is black; less lets some picture through."],

	# --- FX panel ---
	"EFFECT": ["EFFECT", "One effect on the whole picture. Tap to choose; its settings are in EFFECT SETTINGS. The effect AMOUNT follows the sound (AUDIO INPUT) or the mod matrix."],
	"EFFECT/OFF": ["OFF", "The plain clip. Costs nothing."],
	"EFFECT/RGB SHIFT": ["RGB SHIFT", "The red, green and blue split sideways. AMOUNT is how far."],
	"EFFECT/KALEIDOSCOPE": ["KALEIDOSCOPE", "The picture folded into a wheel of SEGMENTS."],
	"EFFECT/FEEDBACK": ["FEEDBACK", "The last frame fed back into this one, zoomed and turned: tunnels and spirals. ZOOM, ROTATION and DECAY shape it."],
	"EFFECT/PIXELATE": ["PIXELATE", "Big square pixels. Louder is blockier, down to COARSE BLOCKS."],
	"EFFECT/CHROMA": ["CHROMA", "Colour fringing like a bad lens, with JITTER for a shake."],
	"EFFECT/ASCII": ["ASCII", "The picture drawn in text characters. DENSITY is how many across; the text can be yours."],
	"EFFECT/GLITCH": ["GLITCH", "Blocks of the picture torn and displaced, more of them the louder it gets."],
	"EFFECT/BLOOM": ["BLOOM", "Bright parts glow outwards. THRESHOLD says what is bright; RADIUS how far."],
	"EFFECT/DISPLACE": ["DISPLACE", "The picture pushed around by a moving pattern: ripples or a flow."],
	"EFFECT/TRAILS": ["TRAILS", "Motion leaves a fading trail. DECAY is how long it lasts."],
	"EFFECT/SLIT-SCAN": ["SLIT-SCAN", "Each strip of the picture from a different moment in time, SPAN frames back."],
	"EFFECT/SOLARIZE": ["SOLARIZE", "Tones above the THRESHOLD flip over. Photographic, harsh."],
	"EFFECT/CROWD": ["CROWD", "Draws on the people the tracker sees. Needs TRACKING in crowd mode."],
	"EFFECT/HUD": ["HUD", "A head-up display drawn around the tracked person. Needs TRACKING."],
	"EFFECT/HUD RINGS": ["HUD RINGS", "Rings centred on the tracked people. Needs TRACKING."],
	"EFFECT SETTINGS": ["EFFECT SETTINGS", "The settings of the effect that is on. The first two are FX A and FX B for the mod matrix."],
	"FX RGB SHIFT/AMOUNT": ["AMOUNT", "How far apart the colours sit."],
	"FX KALEIDOSCOPE/SEGMENTS": ["SEGMENTS", "How many slices in the wheel."],
	"FX FEEDBACK/ZOOM": ["ZOOM", "How much each frame's echo grows. 0 is none."],
	"FX FEEDBACK/ROTATION": ["ROTATION", "How much each echo turns."],
	"FX FEEDBACK/DECAY": ["DECAY", "How long the echoes last. Close to 1 they never die."],
	"FX PIXELATE/COARSE BLOCKS": ["COARSE BLOCKS", "How many blocks across at full amount. Fewer is blockier."],
	"FX CHROMA/AMOUNT": ["AMOUNT", "How far the colour fringes reach."],
	"FX CHROMA/JITTER": ["JITTER", "How much the fringes shake."],
	"FX ASCII/DENSITY": ["DENSITY", "Characters across the picture."],
	"FX ASCII/SPACING": ["SPACING", "The gap between characters."],
	"FX GLITCH/BLOCK COUNT": ["BLOCK COUNT", "How many torn blocks at full amount."],
	"FX GLITCH/BLOCK SIZE": ["BLOCK SIZE", "How big the blocks are, as a share of the picture's width."],
	"FX GLITCH/BLOCK ASPECT": ["BLOCK ASPECT", "The blocks' shape: minus for tall, plus for wide, 0 for square."],
	"FX BLOOM/THRESHOLD": ["THRESHOLD", "How bright a part must be to glow."],
	"FX BLOOM/RADIUS": ["RADIUS", "How far the glow spreads."],
	"FX DISPLACE/SCALE": ["SCALE", "The size of the pattern pushing the picture."],
	"FX DISPLACE/SPEED": ["SPEED", "How fast the pattern moves."],
	"FX TRAILS/DECAY": ["DECAY", "How long a trail lasts. Close to 1 it barely fades."],
	"FX SLIT-SCAN/SPAN": ["SPAN", "How many frames back the far strips reach."],
	"FX SOLARIZE/THRESHOLD": ["THRESHOLD", "The tone where the flip happens."],
	"FX HUD/HUD SCALE": ["HUD SCALE", "How big the display is around the person."],
	"FX HUD/WEIGHT": ["WEIGHT", "The thickness of its lines."],
	"FX HUD RINGS/RING SCALE": ["RING SCALE", "How wide the rings spread."],
	"FX HUD RINGS/STEPS": ["STEPS", "How many segments make a ring. Fewer looks drawn."],
	"FX HUD RINGS/RINGS": ["RINGS", "How many rings per person."],
	"FX HUD RINGS/THICKNESS": ["THICKNESS", "How thick the rings are drawn."],

	# --- HELP ---
	"HELP": ["HELP", "Hold any control for half a second to read what it does. HELP MODE makes the next tap do the same — that is the way in for the clip grid and the sequencer slots, whose holds are taken. The tour is the four cards from the first run."],
	"CLIP GRID": ["CLIP GRID", "Your clips. Tap one to play it on the armed deck (A or B, the lit letter in the bar). Drag up and down to scroll. Hold a clip and it lifts: drop it on the sequencer to add it to a lane, or drop it on another clip to reorder the grid. In CURATE mode a tap parks or unparks a clip and a hold removes it from the library."],
	"SEQUENCER": ["SEQUENCER", "The lane's playlist: the slots play in order, one per the bars set with BARS PER SLOT, when AUTO is on. Tap a slot to jump to it. Hold a slot and drag to reorder it, or drag it up into the grid to remove it. A and B pick which lane the strip shows; SLOT / SAVE / LOAD keep six named lane patterns."],
	"SEQUENCER/LANE A": ["LANE A", "Shows deck A's sequence in the strip. Taps on the grid go to the armed deck, which this also arms."],
	"SEQUENCER/LANE B": ["LANE B", "Shows deck B's sequence in the strip and arms deck B. The badge after B says where lane B's picture comes from when it is not your clips (NET, TD)."],
	"SEQUENCER/SLOT": ["SLOT", "Which of the six saved patterns SAVE and DEL work on. Tap to step through them; loading a slot also arms it. Each pattern is a whole lane: its clips and their order."],
	"SEQUENCER/SAVE": ["SAVE", "Writes this lane's sequence into the chosen slot, with the label typed next to it. A slot with a pattern in it lights on the perform strip."],
	"SEQUENCER/LOAD": ["LOAD", "Opens the six saved slots with their names and clip counts; tap one to replace this lane's sequence with it, on the next bar. Tap outside to close. In perform mode the slot buttons do the same with one tap."],
	"SEQUENCER/DEL": ["DEL", "Deletes the chosen slot's saved pattern, after a confirm. The lane playing now is not touched."],
	"SEQUENCER/CLEAR": ["CLEAR", "Empties this lane's sequence. The clips stay in the library; the deck keeps playing what it has until you pick something."],
	"SEQUENCER/BARS PER SLOT": ["BARS PER SLOT", "How long AUTO stays on each slot before moving on, in bars of the beat clock. Tap to step through the choices. Short for cuts, long for scenes."],
	"SEQUENCER/SHUFFLE": ["SHUFFLE", "Reorders this lane's sequence at random, once. Tap again for another order."],
	"SEQUENCER/AUTO": ["AUTO", "Runs the lane through its slots in order, advancing every BARS PER SLOT on the bar. ▶ is stopped, ■ is running — tap to switch. Beat flip's per-deck advance is a different thing: that skips to the next clip on a trigger."],
	"HELP/HELP MODE": ["HELP MODE", "Arm it, then tap a row, a chip, a clip or a sequencer slot: its card shows instead of anything changing, and the mode switches itself off again. Holding a control does the same at any time, without arming — except on the clip grid and the slots, where a hold already lifts things."],
	"HELP/SHOW THE WELCOME TOUR": ["THE TOUR", "The five cards from the first run: the deck, the projector, playing a set, the sound, and where help is."],
	"ABOUT": ["ABOUT", "Which PVJ this is, and where to write."],
	"ABOUT/VERSION:": ["VERSION", "The version of PVJ installed, with its build number in brackets. Quote it when you write in."],
	"ABOUT/BUILD:": ["BUILD", "PUBLIC is the Play Store app. PRO adds the LED panel, the video link, tracking and the clip server."],
	"ABOUT/SUPPORT:": ["SUPPORT", "Opens the support page in the browser: how to report a problem, and dev@c-u.studio."],
	"ABOUT/PRIVACY POLICY…": ["PRIVACY POLICY", "Opens the privacy policy in the browser. Short version: nothing leaves the phone."],
	"ABOUT/OPEN-SOURCE LICENCES…": ["OPEN-SOURCE LICENCES", "Opens PVJ's third-party list in the browser: every component it bundles and its licence, including FFmpeg (LGPLv2.1) and where to download its source."],
}

## The PUBLIC build's wording for the cards above that name something only the
## pro build has (tracking, the LED panel, the video link, the clip server).
## Same keys; find() prefers these when the build is not pro.
const PUBLIC := {
	"NAV/MODE": ["MODE", "How clips change: by hand, in order, at random or on a sweep — and every setting about time and sound: audio input, the mod matrix, beat flip, the second lane. The cell shows the mode that is on."],
	"NAV/LIB": ["LIB — LIBRARY", "Your clips and where they come from, the output (projector, recording), and image masks."],
	"MOD MATRIX/SLOT": ["SLOT — SOURCE", "Tap to cycle what this slot listens to. LEVEL: loudness. LOW/MID/HIGH: the bands. HIT: onsets, falling. BRIGHT: timbre. BEAT: a saw over the bar; STEP: a saw per beat."],
	"SOURCES & LIBRARY": ["SOURCES & LIBRARY", "Where clips come from: videos, folders and starter packs you import with the phone's file picker (PVJ keeps its own copy), the demo clips, and your recordings. STORAGE shows what it all takes."],
	"OUTPUT": ["OUTPUT", "Where the picture goes: the projector over HDMI (DUAL shows the deck there and the controls here; MIRROR shows this screen), and the recorder's settings."],
}

## The first-run tour, in order: [title, body].
const TOUR := [
	["WELCOME", "This is a VJ deck. The bar at the top is everything: PREV and NEXT cut clips, MODE is how they change on their own, FX puts an effect on the picture, LIB is your clips. Your clips folder is on the phone; LIB ▸ LOCAL FILES pulls videos in."],
	["THE PROJECTOR", "Plug a projector into the phone with an HDMI cable and the deck's picture goes there while the controls stay here. WRP fits the picture to the wall — drag the corners, or press CAM and let the phone's camera work it out. MSK cuts the picture into regions."],
	["PLAYING A SET", "LIB ▸ CLIP GRID shows every clip as a tile: tap one to play it, hold one and drop it on the strip below to queue it. The strip is the sequencer — press AUTO and it steps through the queue on the bar. A and B are two decks; arm B and the crossfader mixes between them. A three-finger tap anywhere opens PERFORM: just the queue and the crossfader, for the gig."],
	["THE SOUND", "The phone's mic hears the room. TAP the beat to set the tempo, or tap the BPM number: the buttons there (IOI, COMB, PERC) each listen to the music and suggest a tempo, and you decide whether to take it. MODE ▸ AUDIO INPUT is the mic; MODE ▸ MOD MATRIX makes the sound move the picture — tap a recipe there to hear it; MODE ▸ BEAT FLIP mirrors the picture on the beat."],
	["HELP IS UNDER YOUR FINGER", "Hold any control for half a second and a card like this one says what it does. MODE ▸ HELP brings this tour back. Now go and make a picture."],
]


## The public build's first tour card: a phone without broad storage access
## has no LOCAL FILES row — clips come in through the import rows.
const TOUR_PUBLIC_WELCOME := ["WELCOME", "This is a VJ deck. The bar at the top is everything: PREV and NEXT cut clips, MODE is how they change on their own, FX puts an effect on the picture, LIB is your clips: LIB ▸ IMPORT CLIPS, IMPORT FOLDER or IMPORT PACK brings your own videos in."]


## The tour for this build.
static func tour() -> Array:
	if FeaturesS.is_pro():
		return TOUR
	var t := TOUR.duplicate()
	t[0] = TOUR_PUBLIC_WELCOME
	return t


static func _card(k: String) -> Dictionary:
	var c: Array = PUBLIC[k] if PUBLIC.has(k) and not FeaturesS.is_pro() else CARDS[k]
	return {"title": c[0], "body": c[1]}


## The card for `key`, or the longest card key `key` starts with, or {}.
## -> { title, body }
static func find(key: String) -> Dictionary:
	if CARDS.has(key):
		return _card(key)
	var best := ""
	for k: String in CARDS.keys():
		if key.begins_with(k) and k.length() > best.length():
			# A row key must not be answered by its section's card, or a row
			# with no card would look covered. "MOD MATRIX/SLOT 1" may match
			# "MOD MATRIX/SLOT"; it must not match "MOD MATRIX".
			if k.contains("/") == key.contains("/"):
				best = k
	if best == "":
		return {}
	return _card(best)
