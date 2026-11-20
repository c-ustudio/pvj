extends Node2D
## PocketVJ render pipeline + deck controller (root).
##
##   ClipEngine (SubViewport)   → raw clip frame
##     → ShaderSlot (SubViewport) → effect-processed frame
##       → QuadWarp (MeshInstance2D) → warped output to the screen
##
## Stages are wired together in code (clip.get_texture → shader input,
## shader.get_texture → warp source) to avoid fragile .tscn ViewportTexture
## sub-resources.
##
## This root also drives the live "deck": audio-reactive shader intensity, the
## clip-switch modes (Manual / Sequential / Random / LFO) with a tap-tempo BPM
## clock, and the on-screen control bar (touch buttons + readouts).

# --- M8 CLASSIC palette (green hero skin, per the PocketVJ M8 design) -----
const BRAND_DARK := Color(0, 0, 0)                ## pure black
const M8_GREEN := Color(0.0, 1.0, 0.255)          ## #00FF41 the accent (dividers/handles/BPM/active)
const M8_TEXT := Color(0.929, 0.929, 0.929)       ## #EDEDED white values
const M8_LABEL := Color(0.929, 0.929, 0.929, 0.42) ## dim-white cell labels
const M8_DIMTEXT := Color(0.929, 0.929, 0.929, 0.6) ## dim readouts (clip / OUT)
# ONE accent. The old cyan/amber/orange aliases are gone — anything that needs
# the accent uses M8_GREEN, and M8_RED is reserved for errors.
const BRAND_NEON := M8_GREEN
const M8_DIM := M8_LABEL
const M8_LINE := Color(0.0, 1.0, 0.255, 0.16)     ## thin green dividers
## The ONLY non-green colour in the UI: errors. #FF4422.
const M8_RED := Color(1.0, 0.267, 0.133)


# M8 pixel font (Departure Mono) for the whole UI.
const FONT_MONO := preload("res://fonts/DepartureMono-Regular.otf")
const FONT_MONO_BOLD := preload("res://fonts/DepartureMono-Regular.otf")
const FONT_PIXEL := preload("res://fonts/DepartureMono-Regular.otf")

# M8 typography: everything is uppercase mono. Body/values run TIGHT (negative
# glyph spacing); the micro-caps labels (nav abbreviations, slider captions) run
# wide-tracked, as in the design. FontVariation is the only way to set tracking.
static func _tracked(px: int) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = FONT_MONO
	fv.spacing_glyph = px
	return fv

var _font_body: FontVariation = _tracked(-1)
var _font_label: FontVariation = _tracked(3)

# The render pipeline lives inside OutputWorld — a SubViewport fixed at
# OUTPUT_SIZE (1920x1080). Its texture is THE output: the phone shows it via
# the aspect-fit _preview TextureRect, and every projector path (mirror today,
# dual-screen plugin / EGL bridge later) consumes the same single texture.
@onready var output_world: SubViewport = $OutputWorld
@onready var clip_engine: ClipEngine = $OutputWorld/ClipEngine
@onready var camera_engine: CameraEngine = $OutputWorld/CameraEngine
@onready var shader_slot: ShaderSlot = $OutputWorld/ShaderSlot
@onready var quad_warp: QuadWarp = $OutputWorld/QuadWarp
@onready var ui_layer: CanvasLayer = $UI
@onready var status: Label = $UI/Status

const OUTPUT_SIZE := Vector2(1920, 1080)   ## the default output resolution
# The LIVE output resolution. Stays OUTPUT_SIZE unless DUAL·TEX negotiates a
# non-16:9 external display, where the output resizes to the display's aspect
# (capped at the 1080p fragment budget) so the projector never shows bars.
var _output_px: Vector2 = OUTPUT_SIZE
var _preview: TextureRect                  ## phone-side view of OutputWorld
## Every hideable UI element lives under this one container, so PERFORM can
## hide the whole interface while the preview underneath stays live.
var _chrome_layer: Control

# --- Clip source: what feeds the ShaderSlot (effects + warp run on either) -----
# VIDEO  = local clip files via ClipEngine (the GoZen video path).
# DRIVE  = Google-Drive-sourced clips — same ClipEngine playback (Drive downloads
#          are cached into the clips folder), so VIDEO and DRIVE share the same
#          texture source; the label reflects where the clips were sourced from.
# CAMERA = the live rear camera via CameraEngine (CameraServer → YCbCr→RGB).
# Switching only re-points shader_slot.set_input() + powers the camera on/off, so
# every existing effect shader works identically on whichever source is active.
enum ClipSource { VIDEO, DRIVE, CAMERA }
const SOURCE_NAMES := ["Video", "Drive", "Camera"]
var _source: int = ClipSource.VIDEO
var _btn_source: Label  # M8 value label inside the SRC cell

# --- Performance mode (clean HDMI output — hides the whole UI layer) ------
# Toggled by a THREE-FINGER tap anywhere (enter or exit).
var _perf_mode: bool = false
var _perf_strip: PerfStrip = null     ## PERF's gig strip (SEQ2 §3.6) — survives the chrome hide
var _perf_xfade_logged := -1.0         ## last crossfade value the strip logged (throttle)
# S4 (SEQUENCER_2_SPEC §5): the full-room frame-time run. Configured by hand in
# settings.cfg [perf] and NEVER written back by _save_settings, so an edited run
# survives the app's own saves. "" = off — the per-frame cost is one null check.
var _s4: FrameSampler = null
var _s4_run: String = ""
var _s4_secs: float = 600.0
var _s4_delay: float = 20.0
var _touches: Dictionary = {}       ## active touch indices (for the 3-finger gesture)
var _three_finger_fired: bool = false

## Drag-vs-tap for sidebar list rows. A row Button fires on RELEASE, and during a
## drag-to-scroll the row travels WITH the finger — so the release ALWAYS lands
## back inside the row the drag started on, and "a Button only fires if the
## release lands back inside it" (the old reasoning in _input) never protected
## anything. Scrolling the FX list therefore switched the effect to whichever row
## you happened to grab. Same slop discipline as ClipGrid.TAP_SLOP.
const PANEL_TAP_SLOP := 16.0
var _row_press_pos: Vector2 = Vector2.ZERO
var _row_moved: float = 0.0
var _row_suppressed: bool = false   ## this touch was a scroll -> swallow the row press

# --- Manual intensity fader (overrides audio reactivity while grabbed) -----
var _fader: VSlider
var _fader_label: Label
var _intensity_override: bool = false
var _manual_intensity: float = 1.0

# --- Settings persistence (user://settings.cfg) ---------------------------
const SETTINGS_PATH := "user://settings.cfg"
var _settings_dirty: bool = false
var _thumbs_prewarmed: bool = false     ## one-shot guard for the Step-2 thumb pre-warm
var _settings_accum: float = 0.0
var _saved_clip_index: int = 0
var _saved_clip_key: String = ""     ## [deck] clip_key — wins over the index when it resolves

# --- Dual-screen: HDMI Presentation plugin (plays active clip on the BenQ) ---
var _hdmi = null   ## PocketVJPresentation singleton (Android), else null

# --- Display mode: how the HDMI output is produced -----------------------
# DUAL   = the Presentation API plugin owns HDMI (ExoPlayer plays the RAW clip
#          on the projector; the phone keeps the effected UI/preview). Clean
#          split, no geometry correction on the output.
# MIRROR = the plugin is released so Android mirrors the phone screen to HDMI —
#          the warped/effected QuadWarp output reaches the projector, so the
#          corner-pin warp maps onto it. Performance Mode (three-finger tap)
#          hides the UI for a clean mirrored image. (This is the Waking Life mode.)
enum DisplayMode { DUAL, MIRROR }
const DISPLAY_MODE_NAMES := ["Dual", "Mirror"]
var _display_mode: int = DisplayMode.DUAL
var _hdmi_enabled: bool = true   ## true only in DUAL·PLAYER — gates ExoPlayer pushes
var _hdmi_presentation_active: bool = false  ## a Presentation has been created this session
var _btn_display: Button

# --- DUAL feed: what fills the HDMI Presentation surface ------------------
# TEXTURE = the EGL bridge blits OutputWorld's texture (warp/masks/shaders all
#           reach the projector — the Session-14 direct-render path, spec §3).
# PLAYER  = the Session-3b ExoPlayer path (RAW clip, no pipeline). Proven over
#           full sets; kept selectable as the fallback until TEXTURE is trusted.
enum DualFeed { TEXTURE, PLAYER }
const DUAL_FEED_NAMES := ["Tex", "Player"]
var _dual_feed: int = DualFeed.TEXTURE
var _tex_output_active: bool = false   ## texture path started (gates handle re-sends)
var _last_gl_id: int = 0               ## last handle sent to the bridge (change gate)
## The IDLE SCREEN (beta2 §2.3): with an external display and NO clip loaded,
## the projector plays the ident loop instead of black. Its own SubViewport —
## never OutputWorld, so the phone's preview (and the recorder) never see it.
## DUAL·TEX blits _idle_world's texture; DUAL·PLAYER hands ExoPlayer the file;
## MIRROR shows the phone, so nothing. Persisted as [deck] idle_screen.
var _idle_enabled: bool = true
var _idle_world: SubViewport = null
var _idle_player: VideoPlayback = null
var _idle_active: bool = false
const IDLE_SIZE := Vector2i(1280, 720)

# --- Set recording (SET_RECORDING_SPEC.md approach A) ---------------------
# Records OutputWorld — the finished projected image, post warp/mask/FX — via
# the hardware encoder. The Session-22 spike proved the encode is nearly free
# (0.51 ms of encoder swap against a 16.6 ms frame budget); STORAGE is the real
# constraint and most of what follows is about not losing a set to it.
#
# ⚠️ MP4 finalization writes the `moov` atom on stop(). If the disk is full at
# that moment the file is UNPLAYABLE and the whole recording is lost — so
# stopping early against REC_RESERVE_MB is the mechanism that makes "save what
# we have" work, not a nicety. Kotlin enforces the same floor independently, so
# a stalled UI thread cannot cost a recording.
## Desktop / no-plugin fallback only. On Android the recordings dir comes from
## Storage.recordings_dir() (Movies/PVJ Recordings) — a top-level
## /storage/emulated/0/PocketVJ is not writable without MANAGE_EXTERNAL_STORAGE.
const REC_DIR := "/storage/emulated/0/PocketVJ/recordings"
## LIB ▸ GET MORE CLIPS opens this (the starter packs). A browser intent; the
## public build has no INTERNET permission and does not need one for it.
const MORE_CLIPS_URL := "https://c-u.studio/tools/pvj#starter-pack"
## ABOUT rows (beta2 §3): the same kind of intent.
const SUPPORT_URL := "https://c-u.studio/tools/pvj/support"
const PRIVACY_URL := "https://c-u.studio/tools/pvj/privacy"
## ABOUT ▸ Open-source licences…: what PVJ bundles and under which licence,
## FFmpeg's LGPL source included (THIRD_PARTY.md, third_party/).
const LICENCES_URL := "https://github.com/c-ustudio/pvj/blob/main/THIRD_PARTY.md"
## FFmpeg's own wording for the about box (ffmpeg.org/legal.html). GoZen links
## FFmpeg into libgozen, so every build carries it.
const FFMPEG_CREDIT := "This software uses libraries from the FFmpeg project under the LGPLv2.1."
var _imp_job: int = 0                    ## the import job running (0 = none)
var _imp_copies: int = -1                ## its plan's copy count (-1 unknown: a streamed zip)
var _imp_kind: String = ""               ## its plan's kind: files / folder / pack / mirror
var _storage_panel_wanted: bool = false  ## LIB ▸ Storage… is waiting for its report
var _imp_total: int = 0                  ## clips its plan covers (copies + already present)
var _imp_strip: PanelContainer = null    ## the import progress / summary line
var _imp_label: Label = null
var _imp_btn: Button = null
var _imp_running: bool = false
var _imp_cancelling: bool = false
var _imp_details: Array = []             ## DETAILS rows: "name — reason"
var _imp_token: int = 0                  ## hides a stale summary
var _rec_dir: String = REC_DIR
const REC_BITRATE_KBPS := 12000
const REC_MIME := "video/avc"
const REC_RESERVE_MB := 512        ## matches Android's own low-storage line
const REC_SEG_MIN_DEFAULT := 5     ## ~450 MB/segment at the measured rate
const REC_SEG_MIN_LO := 1
const REC_SEG_MIN_HI := 15
const REC_WARN_MIN := 5.0          ## warn when this little record-time remains
const REC_POLL_SEC := 1.0
## Seeds remaining-time before any bytes exist. Measured on the 9a: 89.7 MB/min
## (spike) and ~92 MB/min (40-min soak). Replaced by the LIVE rate the moment
## recording starts — VBR output moves a lot with content complexity, so a
## constant is only ever an opening guess.
const REC_SEED_MB_PER_MIN := 92.0
## AAC-LC mono. Audio is ~1% of the video bitrate, so it does not move any of
## the storage math in SET_RECORDING_SPEC.md §0.2.
const REC_AUDIO_BITRATE_KBPS := 128

var _rec_active: bool = false
var _rec_set_dir: String = ""        ## this recording's set_<stamp>/ folder (for the media scan on stop)
var _rec_audio: bool = true         ## record the mic alongside (Library ▸ OUTPUT)
var _rec_audio_wanted: bool = false  ## audio asked for on THIS recording
var _rec_mute_warned: bool = false
var _rec_seg_minutes: int = REC_SEG_MIN_DEFAULT
var _rec_poll_accum: float = 0.0
var _rec_elapsed: float = 0.0
var _rec_free_mb: int = -1
var _rec_rate_mb_min: float = REC_SEED_MB_PER_MIN
var _rec_warned: bool = false
var _cell_rec: Array = []
var _lbl_rec: Label            ## status bar "REC 12:34"
var _dot_rec: Panel            ## the blinking red dot
var _rec_blink_on: bool = true
var _rec_ui_last: String = ""       ## change gate for the REC cell
var _rec_ui_was_active: bool = false

# --- MIRROR fill: how the 16:9 output maps onto a taller-than-16:9 phone -----
# The phone framebuffer is ~20:9 (2424x1080 on the 9a); OutputWorld is 16:9.
# Android mirrors the WHOLE framebuffer into the 16:9 projector, so whatever the
# phone does NOT fill becomes projected black. FIT aspect-fits the 16:9 output in
# the framebuffer (letterbox all round → ~1521x855 on the projector, nothing
# cropped). COVER crops the output to fill the framebuffer edge-to-edge (recovers
# the full width → ~1920x855, at the cost of ~21% off the top+bottom of the
# frame). MIRROR-only: DUAL always monitors the full frame (the projector there is
# fed separately by ExoPlayer). The hard ceiling is 1920x855 either way — mirror
# always fits the whole framebuffer into 16:9; the vertical bars are Android's,
# outside app reach. Direct render (spec §2/§3) is the only path past it.
enum MirrorFill { FIT, COVER }
const MIRROR_FILL_NAMES := ["Fit", "Cover"]
var _mirror_fill: int = MirrorFill.COVER
var _btn_mirror_fill: Button

# --- UI flip (180° phone rotation) ---------------------------------------
# A USB-C hub (HDMI + macropad + PD) exits the phone's RIGHT side, which turns
# the rig upside-down relative to the landscape the app is locked to. This
# rotates the ANDROID WINDOW to reverse-landscape — the whole framebuffer, so
# touch coordinates arrive already de-rotated and every existing input handler
# keeps working untouched.
#
# ⚠️ This must NEVER reach the projector, and structurally it cannot: DUAL·TEX
# blits OutputWorld's own render target (see _refresh_output_texture — it asks
# RenderingServer for the SubViewport's texture RID, not the framebuffer), and
# OutputWorld is a fixed 1920x1080 SubViewport that never tracks the window
# (_on_resize says so). Window orientation is simply not an input to that path.
# The alternative — rotating the $UI CanvasLayer — was rejected: raw _input
# positions are VIEWPORT space while Control.get_global_rect() is LAYER space,
# so a layer rotation silently desyncs them in the sidebar scroll hit-test and
# both editors' two-finger gestures, and the Android IME would come up upright
# over an upside-down UI.
#
# ⚠️ MIRROR display mode DOES rotate with this — Android mirroring copies the
# framebuffer by definition, so nothing in the app can decouple the two. DUAL is
# unaffected. Persisted; absent key = upright, so an existing settings.cfg is
# unchanged by this feature existing.
var _ui_flipped: bool = false

# --- DDP output to the 64x64 LED panel ------------------------------------
# A SINK, not a stage (DDP_OUTPUT_SPEC.md §1). DdpOutput consumes OutputWorld's
# texture the way ShaderSlot consumes ClipEngine's and produces no visual output,
# so it hangs off the pipeline without disturbing it — the EGL bridge takes the
# same texture's native GL handle, this takes it through ordinary GDScript, and
# the two never interact.
#
# ⚠️ OFF BY DEFAULT AND ALLOCATES NOTHING UNTIL ENABLED (spec §4). The tap
# viewports are built on enable, so an install with no panel pays zero — same
# lazy-build rule ShaderSlot follows for its history buffer. That is also why
# this is safe to ship unwired-in-practice: a performer who never turns it on
# cannot pay for it.
#
# ⚠️ scripts/ddp_output.gd is VENDORED from c-ustudio/led-matrix-bridge, where
# its wire format is asserted byte-for-byte against the TouchDesigner sender.
# Fix it THERE and re-sync; tools/check_ddp_drift.sh fails the commit otherwise.
var _ddp: DdpOutput = null
var _ddp_enabled: bool = false
var _ddp_target_ip: String = "192.168.1.50"
# float, not int — DdpOutput.send_fps is @export_range(1, 60, 1) var … : float,
# and the slider row hands back a float too.
var _ddp_send_fps: float = 60.0
# How the 16:9 deck is made square for the 1:1 panel. Indices match
# DdpOutput.FitMode; the labels live here because the panel is where the choice
# is actually made and the names have to read on a phone-sized button.
const DDP_FIT_NAMES := ["SQUASH", "CROP", "LETTERBOX"]
var _ddp_fit_mode: int = 0
var _btn_ddp_ip: Button
var _btn_ddp_fit: Button

# What the panel is fed. DECK is DdpOutput's MIRROR — the composited output,
# downsampled. LIFE is the cellular automaton, which is NATIVELY 64x64 and
# therefore bypasses the downsample chain entirely (ddp_output.gd
# _source_is_panel_sized). It reaches the panel through the INDEPENDENT mode the
# spec built for a second deck; the sink never learns which it is on, which is
# the point of that hook.
const DDP_SOURCE_NAMES := ["DECK", "LIFE"]
var _ddp_source: int = 0
# FREE plus the musical subdivisions. Index 0 is gen_hz free-running; 1..4 are
# generations per BEAT, phase-locked (see LifeSource.on_beat).
const LIFE_RATE_NAMES := ["FREE", "1/BEAT", "2/BEAT", "4/BEAT", "8/BEAT"]
const LIFE_RATE_PER_BEAT := [0.0, 1.0, 2.0, 4.0, 8.0]
var _life_rate: int = 0
var _btn_life_rate: Button
var _life: LifeSource = null
var _btn_ddp_source: Button
var _btn_life_rule: Button

# --- VIDEO LINK (Stage 0 MJPEG mesh — VIDEO_LINK_SPEC.md §6) ---------------
# [link] in settings.cfg is still the persisted truth, but since the mesh was
# seen working (Session 26) the VIDEO LINK panel section owns it live: enable,
# role, and per-peer pull/stop all without touching settings.cfg (spec R3 —
# pick a peer by NAME, never an address).
# role "main" receives on LINK_VIDEO_PORT and composites the stream as a
# layer over the output; role "cam" serves its camera as stream 1 on request.
# Every role answers stream requests for stream 0 (the composited output).
const LINK_VIDEO_PORT := 4851
const LINK_CTRL_PORT := 4850
# Stage 1 receive (spec §6.6): TCP, plugin-owned. A DIFFERENT port on purpose —
# 4851 stays free so a codec flip back to jpeg never fights its own ghost.
const LINK_H264_PORT := 4853
const LINK_CODECS := ["jpeg", "h264"]  # settings.cfg validation, like role
# Capture/send cadence asked of every pulled peer (one door: _link_pull_from;
# the value rides the start verb into NetSender, which drives both the capture
# accumulator and the encoder config). h264's bandwidth headroom (R2: 4 Mb/s
# CBR) pays for 60 — spec §9-M7 lever (a), milestone 2.5: same 5-7 stages at
# 16.7 ms slots ≈ 85-115 ms glass-to-glass. jpeg stays 24: MJPEG at 60 lands
# around 15-30 Mb/s per stream and busts §8's three-stream Stage 0 budget.
const LINK_H264_FPS := 60.0
const LINK_JPEG_FPS := 24.0
const LINK_FRESH_NAMES := ["LIVE", "STALE", "LOST"]   # indexed by NetSource.Freshness
# Stage 1 consumption (VideoLinkPlugin contract): an ExternalTexture must reach
# the canvas ONLY through a samplerExternalOES uniform — assigned as a
# CanvasItem texture, GLES3 binds the OES name GL_TEXTURE_2D and the layer is
# silently black (same failure family as a failed shader compile). Built in
# code, not a .gdshader: it only compiles where it can run (Android + plugin).
const LINK_OES_SHADER := """
shader_type canvas_item;
// Compatibility/Android only. filter_linear+repeat_disable: the OES target
// supports nothing else, and letting Godot try mipmap/repeat params errors.
uniform samplerExternalOES link_tex : filter_linear, repeat_disable;
void fragment() {
	// COLOR arrives as vertex colour x the 1x1 WHITE placeholder — i.e.
	// exactly modulate — so the alpha slider keeps working, multiplied in.
	COLOR *= texture(link_tex, UV);
}
"""
var _link_enabled: bool = false
var _link_role: String = "main"        # "main" | "cam"
var _link_codec: String = "jpeg"       # "jpeg" Stage 0 | "h264" Stage 1 receive
var _link_name: String = ""            # "" = derive from the device model
var _link_auto_pull_cam: bool = true   # main: auto-request a cam peer's stream
var _link_layer_alpha: float = 0.85   # Stage 3.3: the DEFAULT for a peer with no saved level
# SEQ2 Stage 3.3: one alpha per PEER, keyed by beacon NAME (never IP — DHCP
# moves it). A slot's layer shows the alpha of whichever peer is streaming into
# it, so moving the 9a's level never dims TD, and a peer keeps its level across
# pulls, slot changes and restarts. Persisted whole as [link] peer_alpha.
var _peer_alpha: Dictionary = {}
var _link_beacon: LinkBeacon = null
var _link_control: LinkControl = null
var _net_sender: NetSender = null
var _net_source: NetSource = null
var _link_uses_camera: bool = false    # stream 1 holds the deck's CameraEngine on
var _link_layer: TextureRect = null    # the received stream, over the output
var _link_pull_timer: Timer = null     # main: re-asks a cam peer while still LOST
var _link_pull_stopped: bool = false   # operator STOPped the pulled stream — the retry must not undo it
# The PEER provider currently streaming AT us ("" = nobody) — the TCP/UDP slot;
# TD's SRT pull keeps its own record (_td_rx_*, Stage 3.2). Every pull records it
# so a moved pull, a STOP, or a teardown can tell that peer to stop — a sender
# nobody stops keeps paying encode + WiFi into a port that no longer listens.
var _link_rx_ip: String = ""
var _link_rx_ctrl_port: int = 0
var _link_rx_stream: int = -1
var _link_rx_name: String = ""         # beacon name of the peer on record — its level drives _link_layer
# ── SEQ2 Stage 3.2: the TD slot — a SECOND NetSource, SRT only ─────────────
# Before Stage 3.1 the plugin held ONE receiver, so an SRT pull from TD had to
# DISPLACE the phone↔phone TCP listener and every pull was a provider SWAP.
# The slots are independent now (VideoLinkPlugin receiverTcp/receiverSrt), so
# TD gets its own NetSource, its own over-the-top layer and its own provider
# record: pulling TD no longer silences the peer phone, and vice versa.
# Built LAZILY on first use (a TD pull, or lane B set to TD): a rig without TD
# pays no decode-worker thread, no ExternalTexture and no layer (R1).
var _net_source_td: NetSource = null
var _td_layer: TextureRect = null      # TD's stream, over the output — directly above _link_layer
var _td_rx_ip: String = ""             # the TD we are dialling ("" = none); parting word is srt_disarm
var _td_rx_ctrl_port: int = 0
var _td_rx_name: String = ""           # beacon name of the TD on record — its level drives _td_layer
# Pre-milestone-2 tripwire (spec §6.4): while receiving h264 we also hold UDP
# on the SAME port number. MJPEG chunks landing there can only be a sender
# that ignored the codec field — it gets a stop (it cannot see its own burn:
# a full capture cadence of readback + encode + WiFi into a port that will
# never read it — and it honours the asked fps, now 60 for h264 pulls) and
# its ip stands the auto-pull down until its beacon next reappears.
var _link_tripwire: PacketPeerUDP = null
# ── N4: one clock, two phones (SEQ2 §3.4, slave law = spike S3's law v2) ──
# Slave-side estimator state: the last 5 raw per-bar phase errors (seconds).
# Median-5 absorbs WiFi delivery jitter (corr −0.80 with the raw error, S3);
# a 20 ms deadband keeps the grid still when it is already right; corrections
# spread over 2 bars; only a FILTERED half-beat disagreement snaps.
var _beat_errs: Array[float] = []
var _phase_trim_ms: float = 0.0     ## [link] cfg — measured one-way bias (S3: ~15 ms)
var _srt_latency_ms: int = 40       ## [link] cfg — SRT ARQ window, both directions
									## (§9-M8: the APK's baked 120 was the TD legs'
									## dominant term; a clean LAN wants 20–40)
var _osc_enabled: bool = true       ## [osc] cfg — the OSC control surface (spec)
var _osc_port: int = 4855           ## [osc] cfg — UDP port for /pvj/...
var _osc: OscInput = null
var _osc_out_enabled: bool = false  ## [osc] cfg — /pvj/out/... state feedback (§4)
var _osc_out_targets: String = ""   ## [osc] cfg — "ip:port,ip:port"; empty = silent
var _osc_out_rate: int = 30         ## [osc] cfg — send passes per second, 1..60
var _osc_out: OscOutput = null
var _osc_out_clip: String = ""      ## cached by _on_clip_changed for the echo
var _osc_lib_out_toggle: CheckButton = null   ## LIB ▸ OSC rows (Task 1, SESSION_45)
var _osc_lib_targets_btn: Button = null
var _osc_lib_in_lbl: Label = null
var _osc_lib_out_lbl: Label = null
var _osc_targets_dlg: M8Dialog = null   ## the last OUT TARGETS prompt (verify only)
var _beat_rx_count: int = 0         ## lines heard since boot (for the log/verify)
var _bc_beat_index: int = 0         ## master send: last beat index seen from BeatClock
var _bc_bar_index: int = 0          ## master send: last bar index (TD pars want bars)
# Remote sequencer asks waiting for our next downbeat ("at":"bar").
var _seq_pending: Array[Dictionary] = []
var _link_pre_m2: Dictionary = {}      # ip -> true; the auto-pull skips these
var _link_stats_timer: Timer = null    # 1 Hz bottom-bar poll — freed with the rest on teardown
var _link_debug_counter: bool = false  # burn ticks_msec into the stream (spec §9 latency shot)
var _link_encoder_feed: String = "gpu" # h264 send feed: "gpu" (2.5(b) blit) | "cpu" (v1 readback)
var _link_debug_lbl: Label = null      # the sender's LOCAL live clock — the photo's other half
var _btn_link_role: Button = null      # panel row: "Link role: MAIN|CAM"
var _link_peer_vbox: VBoxContainer = null  # panel peer list, rebuilt on peers_changed

# --- Effects -------------------------------------------------------------
# Effect bank — null shader means pass-through (no effect).
var _effects: Array[Dictionary] = []
var _effect_index: int = 0
var _status_token: int = 0

# --- Audio reactivity ----------------------------------------------------
# Shader intensity = base + level * amount, driven by GlobalBus.
@export var audio_base: float = 0.15    ## intensity floor with no audio
@export var audio_amount: float = 1.6   ## how hard the level pushes intensity
var _meter: M8Meter                     ## on-screen level meter, M8 mixer style (vertical segments)

# --- Modulation matrix (v1: continuous sources -> the deck's intensity) ---
# The line above (`audio_base + level * audio_amount`) is ALREADY a one-route
# matrix, so the matrix ABSORBS it rather than running beside it:
#     audio_base + level*audio_amount  ==  base + slot(LEVEL, depth=audio_amount, NORM)
# Enabling the matrix therefore starts from a seed that reproduces the old drive
# exactly, and _deck_intensity() is the ONE owner of the value — there is no
# second path left to fight with. With `_mod_enabled` false the deck evaluates
# the original expression literally, so OFF is bit-identical to fabcbaf.
enum ModSource { NONE, LEVEL, PULSE, BEAT, TRACK, HAND,
	## M8b crowd aggregates (§13.4). APPENDED, never reordered — the slot
	## sources persist as ints and a reorder would silently re-point every
	## saved mod slot at a different signal.
	CROWD_COUNT, CROWD_X, CROWD_SPREAD, CROWD_ENERGY, CROWD_NEAREST, CROWD_BALANCE,
	## Mod v2 (AUDIO_REACTIVITY_SPEC.md §6): the analyser's bands, the hit
	## follower, brightness, and a saw per BEAT (BEAT above is the saw per BAR,
	## and keeps its name because saved slots hold it). Appended, as above.
	LOW, MID, HIGH, HIT, BRIGHT, STEP }
enum ModPolarity { NORM, INV }
## Where a slot goes (§6.2). INTENSITY is the deck's effect amount, as the
## matrix always drove; FX_A/FX_B are the active effect's first and second
## tunable (MOD_FX); SPEED is playback speed. APPENDED, never reordered —
## saved slots hold these as ints.
enum ModTarget { INTENSITY, FX_A, FX_B, SPEED }
const MOD_TARGET_NAMES := ["INTENSITY", "FX A", "FX B", "SPEED"]
## SQR for punch (a quiet source stays quiet), SQRT for lift (a little sound
## moves it a lot). Appended, as above.
enum ModCurve { LIN, SQR, SQRT }
const MOD_CURVE_NAMES := ["LIN", "SQR", "SQRT"]
## The active effect's modulatable tunables, in FX A / FX B order:
## [uniform, min, max]. A slot's depth at 1.0 with its source at 1.0 moves the
## tunable by HALF its range from wherever its slider left it (depth goes to
## 2.0, so the full range is reachable). Effects absent here have no FX targets
## and their rows say so.
const MOD_FX := {
	"RGB Shift": [["amount", 0.0, 0.05]],
	"Kaleidoscope": [["segments", 2.0, 16.0]],
	"Feedback": [["zoom", 0.0, 0.2], ["rotation", 0.0, 0.4]],
	"Pixelate": [["coarse_blocks", 4.0, 64.0]],
	"Chroma": [["amount", 0.0, 0.08], ["jitter", 0.0, 0.02]],
	"ASCII": [["columns", 40.0, 240.0], ["spacing", 0.0, 2.0]],
	"Glitch": [["block_size", 1.0, 35.0], ["block_count", 0.0, 250.0]],
	"Bloom": [["threshold", 0.0, 1.0], ["radius", 0.5, 10.0]],
	"Displace": [["scale", 0.5, 12.0], ["speed", 0.0, 3.0]],
	"Trails": [["decay", 0.5, 0.97]],
	"Solarize": [["threshold", 0.0, 1.0]],
	"HUD": [["hud_scale", 0.2, 8.0], ["weight", 0.0005, 0.02]],
	"HUD Rings": [["ring_scale", 0.3, 10.0], ["thickness", 0.002, 0.05]],
	"Crowd": [["reach", 0.05, 1.5], ["push", 0.0, 0.3]],
}
## Recipes (§6.2): a tap fills the four slots with a known-good routing, so
## nobody has to know what a slot is to get bass pumping the effect. Each
## entry: [name, [[source, target, depth, polarity, curve], …]].
const MOD_RECIPES := [
	["PUMP", [[ModSource.LOW, ModTarget.INTENSITY, 1.2, ModPolarity.NORM, ModCurve.SQR],
		[ModSource.HIT, ModTarget.FX_A, 0.8, ModPolarity.NORM, ModCurve.LIN]]],
	["SHIMMER", [[ModSource.HIGH, ModTarget.FX_A, 1.0, ModPolarity.NORM, ModCurve.LIN],
		[ModSource.BRIGHT, ModTarget.FX_B, 0.8, ModPolarity.NORM, ModCurve.LIN],
		[ModSource.LEVEL, ModTarget.INTENSITY, 0.8, ModPolarity.NORM, ModCurve.LIN]]],
	["BREATHE", [[ModSource.BEAT, ModTarget.INTENSITY, 1.0, ModPolarity.INV, ModCurve.SQRT]]],
	["HITS", [[ModSource.HIT, ModTarget.INTENSITY, 1.4, ModPolarity.NORM, ModCurve.LIN],
		[ModSource.HIT, ModTarget.SPEED, 1.0, ModPolarity.NORM, ModCurve.SQR]]],
	["CLEAR", []],
]
## The one mid-set knob: scales every slot's depth. 0..1.
var _mod_master: float = 1.0
## FX targets: a tunable's base is whatever its slider left in the material,
## and the matrix moves around it. `_mod_fx_base` is that base per uniform;
## `_mod_fx_written` is what the matrix wrote last, so a slider that moved the
## uniform since is recognised (the value differs from what was written) and
## its new position adopted as the base rather than fought.
var _mod_fx_base: Dictionary = {}
var _mod_fx_written: Dictionary = {}

# --- Help cards (HELP_CARDS_SPEC.md) --------------------------------------
# One card per control, under the finger: HOLD any registered control for
# HELP_HOLD_SEC, or turn HELP MODE on and tap. Every row a panel builder makes
# registers itself under "<section>/<caption>" (HelpText has the texts), so
# nothing at a call site changes and a new row is covered by writing its card.
const HELP_HOLD_SEC := 0.55
var _help_mode: bool = false
var _help_targets: Array = []           ## [[Control, key, kind], …]; kind: "row" | "nav" | "header"
var _help_section: String = ""          ## the collapsible being built
var _help_hold_timer: Timer
var _help_hold_pos: Vector2 = Vector2.ZERO
var _help_swallow: bool = false         ## the touch that opened a card must not act
var _help_mode_toggle: CheckButton = null
var _tour_seen: bool = false
const MOD_SLOTS := 4                    ## fixed and bounded — not a growable list
const MOD_DEPTH_MAX := 2.0              ## 0..2, NOT 0..1: the seed needs audio_amount (1.6)
## Ceiling on the summed value. The seeded slot alone peaks at 0.15 + 1.6 = 1.75
## (GlobalBus.level is clamped to 1), so this never bites in the equivalent case
## and the OFF==ON proof holds; it only stops four slots stacking to nonsense.
const MOD_CEIL := 2.0
var _mod_enabled: bool = false          ## off by default — additive, Sunday-safe
var _mod_base: float = 0.15             ## seeded from audio_base
var _mod_slots: Array[Dictionary] = []  ## MOD_SLOTS x {src, depth, pol}
const MOD_SOURCE_NAMES := ["—", "LEVEL", "PULSE", "BEAT", "TRACK", "HAND",
	"CROWD N", "CROWD X", "SPREAD", "CROWD E", "NEAREST", "BALANCE",
	"LOW", "MID", "HIGH", "HIT", "BRIGHT", "STEP"]   ## indexed by ModSource
var _mod_slot_buttons: Array[Button] = []  ## the source-cycling row per slot
var _mod_dst_buttons: Array[Button] = []   ## the target-cycling row per slot
var _mod_curve_buttons: Array[Button] = [] ## the curve-cycling row per slot
var _mod_depth_sliders: Array[HSlider] = []
var _mod_inv_toggles: Array[CheckButton] = []
var _mod_recipe_buttons: Array[Button] = []
var _mod_on_toggle: CheckButton = null
var _mod_master_slider: HSlider = null
var _mod_readout: Label = null          ## live intensity number (the tuning instrument)
var _mod_meter: Label = null            ## the five audio sources, live, while the panel is open


# --- BEAT FLIP (v1: the TRIGGER half of audio reactivity) -----------------
# Spec §1's other channel. The matrix drives a value EVERY FRAME; this fires a
# DISCRETE event and is the deck's first consumer of one — everything audio-
# reactive before it polled a float.
#
# ⚠️ THE TWO "BEATS" ARE NOT INTERCHANGEABLE, which is why both are offered:
#   ONSET  GlobalBus.beat   — a real mic transient. Works with no setup, but the
#                             count is the DETECTOR's, not the music's: the 0.12 s
#                             cooldown allows ~8/s, so a snare roll inflates it and
#                             a /4 subdivision walks off the bar.
#   GRID   BeatClock.beat   — the tap-tempo grid. /8 really is every 8 and stays on
#                             the bar, but it FREE-RUNS: untapped it is 120 BPM and
#                             unrelated to the track, which looks like a broken
#                             feature rather than an untapped one.
# Default ONSET, because the feature has to do something musical before anyone taps.
enum FlipMode { MOMENTARY, ALTERNATING }
enum FlipAxis { HORIZONTAL, VERTICAL }
## KICK and HATS: the analyser's low- and high-band onsets (§6.2) — the same
## four words audio-advance offers. Appended: saved as ints.
enum FlipTrig { ONSET, GRID, KICK, HATS }
## WHICH half drives the other. LEFT is the original behaviour and stays the
## default. ALTERNATE ping-pongs it on each trigger, which is the point: with a
## fixed source the driving half NEVER CHANGES, so half the screen sits static
## through the whole effect. LEFT/RIGHT deliberately equal the shader's src_half
## values (0/1) so the fixed cases need no mapping.
enum FlipSource { LEFT, RIGHT, ALTERNATE }
## HOW the driven half is drawn. MIRROR is the original and stays the default.
## FLIP turns the copy 180 degrees, so the frame is symmetric about the CENTRE
## rather than about the seam — the fold stops being the obvious feature.
## ALTERNATE swaps between the two on each trigger, the same ON-edge ping-pong
## FlipSource.ALTERNATE uses. MIRROR/FLIP are deliberately the shader's
## `treatment` values (0/1) so the fixed cases need no mapping.
## ⚠️ REPEAT IS APPENDED AT 3, NOT INSERTED AT 2, and that is the whole design
## of this line. settings.cfg stores this as a bare integer, so inserting REPEAT
## before ALTERNATE would silently reinterpret every saved 2 from "alternating"
## to "repeat" — a config migration with no version marker to hang it on, and no
## way to tell an old 2 from a new one after the first save. Appending costs
## nothing: ALTERNATE never reaches the shader (it is resolved to MIRROR or FLIP
## by _reset_flip_treatment), so 3 is free on the uniform side and every enum
## value still equals its shader value.
enum FlipTreatment { MIRROR, FLIP, ALTERNATE, REPEAT }
const FLIP_DIVS := [1, 2, 4, 8]         ## fire on every Nth trigger
const FLIP_DIV_NAMES := ["1", "2", "4", "8"]
const FLIP_MODE_NAMES := ["Momentary", "Alternating"]
const FLIP_AXIS_NAMES := ["Horiz", "Vert"]
const FLIP_TRIG_NAMES := ["Onset", "Grid", "Kick", "Hats"]
## What audio-advance fires on: ONSET (broadband, as always), KICK, HATS.
enum TrigBand { ONSET, KICK, HATS }
const TRIG_BAND_NAMES := ["ONSET", "KICK", "HATS"]
var _audio_band: int = TrigBand.ONSET
var _audio_band_btn: Button = null
const FLIP_SOURCE_NAMES := ["Left", "Right", "Alt"]
const FLIP_TREATMENT_NAMES := ["Mirror", "Flip", "Alt", "Repeat"]
## MOMENTARY's hold, in beats at the CURRENT tempo — a 16th, which reads as a
## stutter-hit at any BPM. Tempo-derived on purpose: a fixed millisecond hold
## would be a hit at 120 and a held flip at 60, and that would need a fifth
## control to fix something the clock already knows.
const FLIP_HOLD_BEATS := 0.25
var _flip_enabled: bool = false         ## off by default — additive, Sunday-safe
var _flip_div_index: int = 1            ## index into FLIP_DIVS; 1 = every 2 triggers
var _flip_mode: int = FlipMode.ALTERNATING
var _flip_axis: int = FlipAxis.HORIZONTAL
var _flip_trig: int = FlipTrig.ONSET
var _flip_source: int = FlipSource.LEFT ## the SETTING
var _flip_src_half: int = 0             ## the half driving RIGHT NOW (what the shader gets)
var _flip_treatment: int = FlipTreatment.MIRROR   ## the SETTING

# AUTO-CHANGE: rotate the treatment on a BAR cycle, so the effect punches in with
# a different character every few bars instead of doing one thing all set.
#
# ⚠️ ROTATES THE *SELECTION*, NOT THE LIVE VALUE. It calls _set_flip_treatment(),
# the same entry point the chips use, so _flip_treat_now keeps exactly ONE owner
# (_reset/_advance_flip_treatment). A second writer poking _flip_treat_now
# directly is the S24 AUTO bug rebuilt: two things driving one value, and which
# one wins depends on ordering nobody wrote down.
#
# ⚠️ ALTERNATE IS IN THE CYCLE, AND IT IS THE ODD ONE OUT. The other three are
# LOOKS; ALTERNATE is a ROTATOR — it ping-pongs MIRROR/FLIP on every ON edge. So
# that stage nests a per-trigger rotation inside the per-bar one, and its
# character depends on the RATIO of the two periods rather than on either alone:
# how many triggers fit inside the window, which is `div`, the BPM and the bar
# length together. Change any one and that section behaves differently.
#
# That is a real cost and it was left out at first for exactly that reason. It
# is in now because the cost was overstated: at div=2 and 90 BPM a trigger lands
# every 2.67 s, so a 2-bar window holds about two of them — ONE swap, a flutter,
# not chaos. And on the longer intervals the window is long enough for the
# ping-pong to establish itself as its own section rather than read as a glitch,
# which is the point of having it. ⚠️ PREFER 4 OR 8 BARS WITH THIS IN THE CYCLE;
# at 2 BARS the busy stage barely gets going before it hands over.
const FLIP_ROTATE_NAMES := ["OFF", "2 BARS", "4 BARS", "8 BARS"]
const FLIP_ROTATE_BARS := [0, 2, 4, 8]
const FLIP_ROTATE_CYCLE := [FlipTreatment.MIRROR, FlipTreatment.FLIP,
	FlipTreatment.REPEAT, FlipTreatment.ALTERNATE]
## WHICH parameters the bar cycle advances. Cumulative rather than three
## independent toggles: on a phone, mid-set, one row you can read at a glance
## beats three you have to reason about.
##
## ⚠️ THE LIST LENGTHS ARE WHY "ALL" IS WORTH HAVING. Treatment has 4 entries,
## source 3, axis 2 — so advancing them together does NOT cycle in 4 and repeat.
## It runs lcm(4, 3, 2) = 12 DISTINCT COMBINATIONS before coming back round. At
## 4 bars a stage that is 48 bars of evolving material out of one chip, which is
## the difference between a loop and a sequence.
const FLIP_ROT_WHAT_NAMES := ["TREAT", "T+AXIS", "T+SRC", "ALL"]
var _flip_rot_what: int = 0
var _flip_rot_what_buttons: Array[Button] = []

var _flip_rotate: int = 0          ## index into FLIP_ROTATE_NAMES; 0 = off
var _flip_rotate_bars: int = 0     ## bars counted since the last change
var _flip_rotate_pos: int = 0      ## where we are in FLIP_ROTATE_CYCLE
var _flip_rotate_buttons: Array[Button] = []
var _flip_treat_now: int = FlipTreatment.MIRROR   ## drawn RIGHT NOW (MIRROR/FLIP/REPEAT, never ALTERNATE)
## Counts ON edges. Only used to halve SOURCE's rate when BOTH ping-pongs are
## running, which is what walks the pair through all four combinations.
var _flip_alt_tick: int = 0
var _flip_count: int = 0                ## triggers seen since enable (the subdivision counter)
var _flip_state: bool = false           ## is the mirror currently applied
var _flip_hold_left: float = 0.0        ## MOMENTARY release countdown, seconds
var _flip_mat: ShaderMaterial = null    ## QuadWarp's material — see beat_flip.gdshader
var _flip_div_buttons: Array[Button] = []
var _flip_mode_buttons: Array[Button] = []
## AXIS and TRIGGER are CYCLE ROWS, not chips — see _build_flip_section. One
## button each whose label carries the current value, the _cycle_mod_source
## pattern.
var _flip_axis_btn: Button = null
var _flip_trig_btn: Button = null
var _flip_source_buttons: Array[Button] = []
var _flip_treatment_buttons: Array[Button] = []


# --- Per-frame change gating (see _process) ------------------------------
# _process runs at 60 Hz behind live video decode, so every write it makes is
# gated on the value having actually changed. These hold the last pushed values.
const INTENSITY_EPS := 0.004            ## below this, an intensity change is invisible
var _last_intensity: float = -1.0
var _last_region_intensity: float = -1.0
var _effect_has_intensity: bool = false ## false for Off/passthrough (no such uniform)
var _cached_size: Vector2 = Vector2.ZERO ## viewport size; refreshed only on resize
var _theme: Theme                       ## the one global theme (see _apply_global_theme/_ui_add)

# --- Clip-switch deck ----------------------------------------------------
enum SwitchMode { MANUAL, SEQUENTIAL, RANDOM, LFO }
const MODE_NAMES := ["Manual", "Sequential", "Random", "LFO"]

var _mode: int = SwitchMode.MANUAL
# Tempo (BPM + beat grid + tap) now lives in the BeatClock autoload; SEQUENTIAL
# advances on BeatClock.beat (see _on_beat_clock_beat). RANDOM/LFO keep their own
# BPM-independent rates below.
var _lfo_phase: float = 0.0             ## 0..1 sweep position (LFO mode)
var _lfo_accum: float = 0.0             ## seconds toward the next LFO cut
## ⚠️ Floor on the LFO cut rate. The sweep's step rate scales with the LIVE SET SIZE
## (235 live clips over an 8 s period is ~58 index changes per second), and without a
## floor it asks for cuts far faster than a ~195 ms demux can serve. 0.25 s caps it at
## 4 cuts/second, which a warm back decoder can sustain.
const LFO_MIN_DWELL := 0.25
## ⚠️ SECONDS PER CLIP, not per sweep. It used to be the full ping-pong duration, which
## made the control's meaning depend on how many clips were LIVE: time-per-clip is
## period / (2*(n-1)), so 47 live clips at the 30 s slider maximum still gave 0.33 s per
## clip, and 235 gave 0.06 s. No setting on the slider produced a musical dwell on an
## uncurated library. As seconds-per-clip the control means the same thing at any pool
## size and the sweep duration is derived instead.
var _lfo_sec_per_clip: float = 0.5      ## dwell on each clip in the LFO sweep (BPM-independent)
var _random_accum: float = 0.0          ## seconds toward the next Random switch
var _random_interval_sec: float = 1.0   ## dwell between Random switches (0 = fastest hard cut)
const RANDOM_MIN_INTERVAL := 0.06       ## floor so 0 doesn't reload every frame

# --- Audio-reactive clip switching (separate from shader intensity) -------
var _audio_switch_enabled: bool = false
## Onset sensitivity: how far above its own running average the level must jump to
## count as a transient. Drives GlobalBus.beat_threshold. Lower = more cuts.
## Replaced the old absolute-level threshold — see _on_audio_onset for why.
##
## ⚠️ This is NOT the control for a noisy room. Measured over the Session-23 capture,
## room noise is MORE peaky than music (ratio median 2.05 vs 1.71) — a quiet room has
## a tiny running average, so a chair creak reads as a ratio of 4. Raising sens to
## 1.60 keeps 82% of the silent-room fires while discarding 37% of the real music.
## Venue noise is a LEVEL problem; use the floor below.
var _audio_sensitivity: float = 1.45
## Input gain and noise floor, mirrored from GlobalBus so the sliders and settings
## have something to read back. See audio_bus.gd for how the floor was measured.
var _audio_gain: float = 8.0
var _audio_floor: float = 0.15
const AUDIO_SENS_MIN := 1.05
const AUDIO_SENS_MAX := 3.0
const AUDIO_GAIN_MIN := 1.0
const AUDIO_GAIN_MAX := 24.0
const AUDIO_FLOOR_MIN := 0.02
## Capped well below full scale on purpose: past this you are not tuning a floor,
## you are switching audio-advance off. A venue loud enough to need more wants LESS
## GAIN instead — that keeps the music/noise separation the floor depends on.
const AUDIO_FLOOR_MAX := 0.60
## LEARN FLOOR — one press instead of hunting the slider in a dark room: listen to
## the venue, then set the floor from what was actually measured. The three numbers
## are derived in _finish_learn_floor; they are not taste.
const LEARN_SEC := 12.0
const LEARN_PERCENTILE := 0.90
const LEARN_MARGIN := 2.2
## Refuse the result if the "room" was this loud — i.e. someone ran the learn with
## the music still playing. MEASURED separation over the Session-23 capture, what a
## 12 s learn would measure as p90:
##   SILENT room:    median 0.090   p99 0.258   MAX 0.258
##   MUSIC playing:  median 0.810   p90 0.930   MAX 0.984
## At 0.30 that rejects 0% of quiet-room learns and 100% of music-playing ones.
## Without this the learn is a foot-gun: measured live with music on, it produced
## p90=0.705 -> floor 1.55, clamped to 0.60, which is a dead deck one tap away.
const LEARN_MAX_ROOM := 0.30
var _learn_left: float = -1.0               ## seconds remaining, <0 = not listening
var _learn_samples: PackedFloat32Array = PackedFloat32Array()
var _learn_shown: int = -1                  ## whole seconds last written to the button
var _learn_btn: Button
var _btn_mic: Button = null   ## AUDIO INPUT ▸ Mic — the explicit in-context ask
var _floor_slider: HSlider                  ## LEARN writes the floor THROUGH this
var _audio_last_fire_ms: int = -1           ## refractory clock (ms), -1 = never fired
## Minimum seconds between audio-fired swaps (REV2 §5.2 refractory window). Long
## enough that a dense passage can't ask for swaps faster than a cue completes
## (~195 ms typical demux) — if it does, swap() just holds, but rate-limiting the
## trigger keeps a snare roll from machine-gunning the deck in the first place.
const AUDIO_REFRACTORY_SEC := 0.2

# --- Audio-reactive video speed (GoZen playback_speed) -------------------
# Louder audio speeds the clip up: playback_speed = 1 + level * (_speed_max - 1),
# clamped to 1x..10x. _speed_max (the slider) is the top speed at full audio.
const SPEED_MAX_CEIL := 10.0
var _speed_ramp_enabled: bool = false
var _speed_max: float = 3.0                  ## top multiplier at full audio (1x..10x)

# --- Params panel widgets ------------------------------------------------
var _params_panel: PanelContainer
var _params_vbox: VBoxContainer            ## current row target (a section's content)
var _panel_root_vbox: VBoxContainer        ## the panel's top-level vbox (section headers go here)
var _panel_scrolls: Array[ScrollContainer] = []  ## every sidebar scroller (drag-to-scroll, see _input)

# --- Mode panel (switch mode selector + auto-switch settings) ------------
# Opened by the Mode bar button. Groups the mode choice with its tweaks, so the
# Library panel is shorter and switch settings aren't buried in a long scroll.
var _mode_panel: PanelContainer
var _mode_buttons: Array[Button] = []

# --- FX panel (effect selector + per-effect settings) --------------------
# Opened by the FX bar button. Mirrors the Mode panel: pick an effect + tune its
# shader uniforms. The EFFECT SETTINGS section rebuilds for the selected effect.
var _fx_panel: PanelContainer
var _fx_buttons: Array[Button] = []
var _fx_settings_box: VBoxContainer   ## per-effect settings (rebuilt on effect change)
# ASCII shader tunables (persisted-in-material at apply time).
var _ascii_columns: float = 120.0
var _ascii_mode: int = 0          ## 0 Brightness · 1 Binary 0/1 · 2 Random · 3 Custom text
var _ascii_text: String = "LOVE"  ## used in Custom-text mode
var _ascii_spacing: float = 1.0   ## glyph size within its cell (1.0 = tight grid)
var _ascii_mode_buttons: Array[Button] = []
var _ascii_text_edit: LineEdit = null   ## FX ▸ ASCII's TEXT field while it is built (OSC keeps it in step)
# Glitch CHARACTER tunables — the flavour `intensity` acts on, not the modulated
# value. Held as members (the ASCII pattern) rather than written straight to the
# material, so switching effects and coming back doesn't silently reset a look
# that was dialled in mid-set. Defaults match the shader's own.
var _glitch_block_count: float = 110.0   ## expected blocks on a full-intensity burst frame
var _glitch_block_size: float = 4.5      ## base block size, % of frame width
var _glitch_block_aspect: float = 0.0    ## block shape in stops: 0 square, + wide, - tall
# Ranges live here, not inline in the slider calls, so the sliders and the
# settings-load clamps cannot drift apart (the audio-input pattern above).
const GLITCH_COUNT_MIN := 0.0
const GLITCH_COUNT_MAX := 250.0
const GLITCH_SIZE_MIN := 1.0
const GLITCH_SIZE_MAX := 35.0
## ±4 stops = up to 16:1 either way, which covers wide datamosh banding at one
## end and tall slivers at the other without the extremes being unusable.
const GLITCH_ASPECT_MIN := -4.0
const GLITCH_ASPECT_MAX := 4.0

# Bloom CHARACTER tunables — same session→disk pattern as the glitch ones above.
var _bloom_threshold: float = 0.6   ## luma a pixel must exceed before it blooms
var _bloom_radius: float = 2.5      ## how far the glow bleeds, % of frame width
const BLOOM_THRESHOLD_MIN := 0.0
const BLOOM_THRESHOLD_MAX := 1.0
## Capped at 10%: the halo is TAPS samples wide, so past this the gaps between
## taps start to show as separate ghosts rather than a glow. More reach wants
## more taps, which is a fill-rate decision, not a slider one.
const BLOOM_RADIUS_MIN := 0.5
const BLOOM_RADIUS_MAX := 10.0

# Displace CHARACTER tunables — same session→disk pattern as the two above.
var _displace_scale: float = 3.0   ## field cycles across the frame (broad → fine)
var _displace_speed: float = 1.0   ## flow rate; 0 freezes the field
## 0 NOISE (organic melt) · 1 RADIAL (rings from centre). Scale and speed mean the
## analogous thing in both, which is why this is a mode rather than a new effect.
var _displace_pattern: int = 0
const DISPLACE_PATTERN_NAMES := ["Noise", "Radial"]
var _displace_pattern_buttons: Array[Button] = []
const DISPLACE_SCALE_MIN := 0.5
const DISPLACE_SCALE_MAX := 12.0
## Speed floor is 0 ON PURPOSE — a frozen field still displaces, so 0 is a
## static-distortion look, not an off switch. Turning the effect off is what the
## selector is for.
const DISPLACE_SPEED_MIN := 0.0
const DISPLACE_SPEED_MAX := 3.0

# Trails CHARACTER tunables — persistence and blend of the feedback buffer.
var _trails_decay: float = 0.90
## 0 MIX · 1 MAX. MIX is the default deliberately: MAX only shows where the live
## pixel is DARKER than the decayed history, so on bright footage it is invisible
## and reads as a broken effect (it was mistaken for a wiring bug during
## development). MIX always visibly does something.
var _trails_blend: int = 0
const TRAILS_BLEND_NAMES := ["Mix", "Max"]
var _trails_blend_buttons: Array[Button] = []
const TRAILS_DECAY_MIN := 0.5
## ⚠️ Below 1.0 and load-bearing, matching the shader's own clamp: the loop feeds
## its output back in, so decay * intensity must stay < 1 or the frame never
## fades and the smear can only be cleared by leaving the effect.
const TRAILS_DECAY_MAX := 0.97

# Slit-Scan CHARACTER tunables — which way the time gradient runs, and how deep.
## 0 HORIZONTAL (bands across, time deepens DOWN) · 1 VERTICAL (bands down, time
## deepens ACROSS). Both are the same mechanism on a different axis, which is why
## this is a mode rather than two effects.
var _slitscan_direction: int = 0
const SLITSCAN_DIR_NAMES := ["Horizontal", "Vertical"]
var _slitscan_dir_buttons: Array[Button] = []
## Depth of the oldest strip IN FRAMES — and simultaneously the STRIP COUNT,
## because the ring's write head advances exactly one strip per frame. Frames,
## not seconds: the head is clocked by frames, so a seconds unit would drift with
## the framerate and shift the look between FULL and FAST quality.
##
## ⚠️ CHANGING THIS REPARTITIONS THE ATLAS, so ShaderSlot re-primes and the shear
## collapses to live for one frame. That is why it is pushed on release-ish
## granularity rather than being smoothed — it is a visible reset, not a glide.
var _slitscan_span: float = 32.0
## Floor of 8: below this the strips are thicker than a fifth of the frame and it
## reads as a few big blocks rather than a scan. Also 8 frames is barely past the
## clip's own cadence, so there is little time to see.
const SLITSCAN_SPAN_MIN := 8.0
## 90 frames = 1.5s at 60fps, and 12 px strips at 1080. Deeper than this the
## oldest strip stops relating to the live one at all — the picture stops being
## one image — and the strips get thin enough to alias on the output scale.
const SLITSCAN_SPAN_MAX := 90.0

# Solarize CHARACTER tunables — same session→disk pattern as the others above.
## 0 INVERT (whole frame) · 1 SOLARIZE (only tones above the threshold). A mode
## rather than two effects: both are the same inversion, one of them gated.
var _solarize_mode: int = 0
const SOLARIZE_MODE_NAMES := ["Invert", "Solarize"]
## M8c crowd effect. MARKERS is the debug view — rings in per-SLOT colour,
## so a colour change across a crossing means the §13.3 matcher swapped
## two people and slot identity is broken.
const CROWD_MODE_NAMES := ["Spotlight", "Markers", "Warp", "Blob"]
const HUD_MODE_NAMES := ["Reticle", "Full", "Target"]
var _hud_mode: int = 1
var _hud_scale: float = 1.0
var _hud_weight: float = 0.0035
var _hud_readout: int = 0
## HUD Rings — the quality knobs, in the order worth spending them.
var _rings_steps: int = 32
var _rings_count: int = 5
var _rings_scale: float = 1.6
var _crowd_fx_mode: int = 3   ## default BLOB — the classic tracker look
var _crowd_fx_reach: float = 0.45
var _crowd_fx_sink: float = 0.75
var _crowd_fx_push: float = 0.06
## [tracking] crowd_fx_flip — mirror the box x into deck space. FALSE by
## measurement: with it true the boxes sat on each other's people.
var _crowd_fx_flip: bool = false
var _solarize_mode_buttons: Array[Button] = []
## Luma at which the tone flip happens. SOLARIZE only — the settings rows are
## rebuilt on a mode switch so INVERT does not show a slider that does nothing.
var _solarize_threshold: float = 0.5
## Full 0..1 on purpose. The ends are not dead: at 0 everything is above the
## threshold so it collapses to a straight invert, at 1 nothing is and it becomes
## passthrough — both are reachable, legible states rather than a broken slider.
const SOLARIZE_THRESHOLD_MIN := 0.0
const SOLARIZE_THRESHOLD_MAX := 1.0
var _quality_buttons: Array[Button] = []

# --- Shader-stage render quality -----------------------------------------
# The ShaderSlot SubViewport is where EVERY effect actually runs, so its size is
# the effect fill-rate cost — not anything inside a given shader. FULL is native
# 1080p; HALF/FAST render the effect stage smaller and let the output quad
# upscale. On a projector, block-style effects (ASCII, Pixelate) are nearly
# indistinguishable at HALF. Persisted in settings.cfg.
enum Quality { FULL, HALF, FAST }
const QUALITY_NAMES := ["Full", "Half", "Fast"]
const QUALITY_SIZES := [Vector2i(1920, 1080), Vector2i(1280, 720), Vector2i(960, 540)]
var _quality: int = Quality.FULL
const ASCII_MODE_NAMES := ["Brightness", "Binary 0/1", "Random", "Custom"]
## /pvj/fx/ascii/mode names, same order as ASCII_MODE_NAMES (index 3 = Custom text).
const ASCII_MODE_KEYS := ["brightness", "binary", "random", "custom"]
const ASCII_MODE_CUSTOM := 3
const ASCII_TEXT_MAX := 64   ## ascii.gdshader's text_chars[64]

# --- Control bar widgets -------------------------------------------------
# HFlowContainer so the (now longer) button row WRAPS to a second line if it
# would overflow the screen edge, instead of pushing buttons off-screen.
var _main_bar: BoxContainer
var _bar_bg: Panel          ## nav-bar backdrop (a separate node from _main_bar)
var _status_bar: PanelContainer  ## bottom CLIP/FPS/OUT strip
var _chrome_tween: Tween
var _btn_mode: Label    # M8 value label inside the MODE cell
var _btn_effect: Label  # M8 value label inside the FX cell
var _lbl_bpm: Label
var _perc_dialog: M8Dialog   ## open BPM dialog awaiting a Percival result, if any
var _lbl_clip: Label    ## bottom bar, left: "CLIP 13/28 · name.mp4"
var _lbl_out: Label     ## bottom bar, right: "OUT"
var _lbl_fps: Label     ## bottom bar, right: "FPS 60" (red when dropping frames)
# FPS is sampled on a timer, NOT every frame — see _update_fps.
const FPS_SAMPLE_SEC := 0.5
const FPS_WARN := 50     ## below this the readout goes red (dropped frames)
var _fps_accum: float = 0.0
var _last_fps: int = -1
var _fps_ok_state: int = -1   ## -1 not yet applied · 0 red (dropping) · 1 dim (ok)
# LINK stats live left of FPS but exist on screen only while frames actually
# move — the bar is show UI, and an idle "LINK" reading is clutter, not status.
var _lbl_link: Label          ## bottom bar, right: "LINK TX … RX …" (see _update_link_stats)
var _lbl_link_sep: Label      ## its " · " divider — shown and hidden WITH the label
var _link_lbl_state: int = -1 ## -1 not yet applied · 0 red (RX degraded) · 1 dim (healthy)
# --- Nav cell value abbreviations ----------------------------------------
# A nav cell is ~130 px wide (ten SIZE_EXPAND_FILL cells sharing the bar minus
# the fixed BPM cell), which is ~122 px usable — about 10.4 chars of Departure
# Mono at size 20. Long names clipped (KALEIDOSCOPE, and SEQUENTIAL sat flush
# against the edges), so the NAV BAR shows M8-style short forms. These are for
# the nav cells ONLY — the sidebar lists, status flashes and settings all keep
# the full names (there is room there, and the reference shows them in full).
const NAV_MAX_CHARS := 8
const NAV_ABBREV := {
	"SEQUENTIAL": "SEQ",
	"MANUAL": "MAN",
	"KALEIDOSCOPE": "KALEIDO",
	"RGB SHIFT": "RGB",
	"FEEDBACK": "FEEDBK",
	# 9 chars, so without this the hard cap below would silently show "SLIT-SCA".
	"SLIT-SCAN": "SLITSCAN",
}

# Nav-cell value text: uppercase, abbreviated if we have a short form, and hard
# capped at NAV_MAX_CHARS so a future name can never silently clip again.
func _nav_value(s: String) -> String:
	var up := s.to_upper()
	if NAV_ABBREV.has(up):
		return str(NAV_ABBREV[up])
	return up.left(NAV_MAX_CHARS)


# Nav cells whose panels can be open — [button, value_label, label_label] each,
# so _refresh_cell_highlights can light the whole cell green.
var _cell_mode: Array = []
var _cell_fx: Array = []
var _cell_lib: Array = []
var _cell_tap: Array = []
var _cell_wrp: Array = []
var _cell_msk: Array = []
var _tap_dot_tween: Tween

# --- QuadWarp corner-pin editor ------------------------------------------
var _warp: WarpEditor
# Toggleable test grid rendered INSIDE the active pre-warp viewport (ShaderSlot,
# or MaskWorld while masks own the output — _refresh_output_source reparents it),
# so it warps with the footage and reaches the projector — straightness on the
# wall is the whole point.
var _grid_overlay: GridOverlay

# --- Multi-region mask compositor (Phase 1: shared source, per-region FX) -
# The compositor renders into MaskWorld, a pre-warp SubViewport locked to the
# output basis (_output_px). Routing is a SOURCE swap (S17 / Option A): when any
# masks exist QuadWarp samples MaskWorld instead of ShaderSlot, so warp applies
# to the masked composite. QuadWarp itself stays visible on both paths.
var _mask_world: SubViewport
var _region_comp: RegionCompositor
## True while the warp editor is editing a REGION, so closing it returns to the
## mask editor rather than the deck.
var _warp_return_to_masks: bool = false
var _region_editor: RegionEditor
var _mask_edit_active := false   ## mask editor open — MaskWorld owns the output while true

# --- Raster (image) mask — the topmost OutputWorld layer -------------------
# Multiplies the composited output by a greyscale image (soft edges / edge
# blending). Independent of the polygon-mask routing: composes with BOTH the
# QuadWarp path and the RegionCompositor path.
var _mask_overlay: MaskOverlay
## Camera keystone (CalibEditor): the pattern that goes on the wall, the editor
## on the phone, and the deck source the calibration borrowed the lens from
## (-1 = nothing borrowed).
var _calib: CalibEditor
var _calib_pattern: CalibPattern
var _calib_prev_source: int = -1
## Heat (AndroidProbe): the last thermal status seen (-1 = not known), and
## whether the frame rate is being held down because of it (the rate it had).
var _heat: int = -1
var _heat_capped: bool = false
var _heat_prev_fps: int = 0
var _mask_browser: Control                 ## LocalBrowser in select-image mode
var _btn_mask_img: Button                  ## Library row: current mask file
var _btn_mask_fit: Button                  ## Library row: STRETCH / FIT / FILL

# --- Clip browser (laptop clip server / Google Drive / local files) ------
var _clip_browser: Control
var _drive_browser: Control
var _local_browser: Control
var _rec_browser: Control                  ## LocalBrowser rooted at _rec_dir (read-only)
var _clip_grid: ClipGrid                 ## the visual clip browser (Step 3)
var _folder_tabs: FolderTabBar           ## ALL / LIVE / PARKED tabs (Step 4)
var _seq_strip: SequenceStrip            ## the bottom slot row (Step 5)
var _drag_proxy: TextureRect             ## floating grid->strip drag proxy (Step 6)
var _drag_clip_id: String = ""           ## clip being dragged from the grid


## One lane of the two-lane sequencer (SEQUENCER_2_SPEC §3.2). Plain object,
## not a node. Lane A wraps the existing deck and the WHOLE Sequencer 1.0 mode
## system — its fields are the old _seq_* state, renamed in place. Lane B is
## sequence-only by design: no modes, no audio-switch, no LFO.
## Beat counting is per-lane (not bar-subscribed) so 1/2/4/8-beat slots all
## work; the playhead reads BeatClock.phase for the intra-slot fraction.
class SeqLane:
	var sequence: Sequence = Sequence.new()  ## ordered clip-id list (its own .tres)
	var engine: ClipEngine = null            ## which deck this lane steps
	var beats_per_slot: int = 4              ## per-lane slot clock ([seq] cfg key in 1.3)
	var auto: bool = false                   ## run/stop
	var index: int = -1                      ## active slot (playhead)
	var beat_count: int = 0                  ## beats into the current slot (may start negative: stagger)
	var bar_offset: int = 0                  ## stagger in beats — spike S2: advisory, defaults on for B

var _lane_a := SeqLane.new()
var _lane_b := SeqLane.new()
var _strip_lane: int = 0             ## which lane the strip (and grid arming) edits
var _lane_b_model_loaded := false    ## sequence_b.tres loaded once, lazily
var _saved_lane_b_armed := false     ## [seq] restore — applied at the end of _ready
var _saved_lane_b_auto := false      ## restored with armed, so the pattern resumes
var _lane_b_arm_toggle: CheckButton = null    ## panel rows mirror state set elsewhere
var _lane_b_auto_toggle: CheckButton = null
# Dual-phone B deck (DUAL_PHONE_B_DECK_SPEC): what feeds lane B's face.
# CLIP = engine B (Stage 1 as shipped). NET = the incoming link stream —
# remote camera or a remote phone's composited deck, whichever was pulled.
# Cam-vs-deck is NOT a mode here: lane B consumes "the stream".
## NET = the PEER slot's stream (a phone's cam or deck); TD = the TD slot's SRT
## stream. Two NET flavours since Stage 3.2: with two receivers live, "the
## incoming stream" is no longer one thing, and 2C (TD's deck riding lane B,
## verified 2026-08-19) must survive the split. Persisted values: NET stays 1.
enum LaneBSource { CLIP, NET, TD }
const LANE_B_SOURCE_NAMES := ["CLIPS", "PEER", "TD"]
var _lane_b_source: int = LaneBSource.CLIP
var _lane_b_src_btn: Button = null     ## cycle row; label mirrors state set elsewhere
# The OES material for the NET face, built ONCE (hazard 4: LINK_OES_SHADER is
# code-built, and a mid-set source flip must not pay the compile twice).
var _lane_b_net_mat: ShaderMaterial = null


func _lane_for_strip() -> SeqLane:
	return _lane_b if _strip_lane == 1 else _lane_a

# --- Sequencer 2.0 Stage 1: MixWorld + the lane B deck (SEQUENCER_2_SPEC §3.1) ---
# All of it is built lazily on FIRST arm — an unarmed lane B is absent, not idle,
# so the chain stays byte-for-byte the single-deck app (R1).
var _mix_world: SubViewport = null       ## the blend bus: deck A under deck B
var _deck_a_rect: TextureRect = null     ## lane A's face inside MixWorld
var _deck_b_rect: TextureRect = null     ## lane B's face; modulate.a IS the crossfade
var _clip_engine_b: ClipEngine = null    ## the second deck (sequence-only by spec)
var _lane_b_armed: bool = false
## MixWorld has rendered ≥1 frame since its last wake. Routing the output onto
## a just-woken render target in the same frame presents one black/stale frame
## (the arm flash) — _refresh_output_source clears this on every wake and a
## frame_post_draw one-shot raises it, so the mix is only shown once it holds
## a real frame.
var _mix_warmed: bool = false
var _xfade: float = 0.5
# ── Crossfade automation (XF1+): modes mirroring lane A's clip modes, all
# feeding the ONE crossfade value. Reuses the proven front ends — BEAT is the
# flip trigger/divisor shape on BeatClock.beat; AUDIO (XF4) the onset bus +
# refractory; LFO (XF3) the phase-accumulator idiom clocked in bars. The
# performer always wins: any operator gesture on the crossfade demotes to
# MANUAL instantly (_set_xfade_manual).
enum XfadeMode { MANUAL, BEAT, AUDIO, LFO }
const XFADE_MODE_NAMES := ["MANUAL", "BEAT", "AUDIO", "LFO"]
## The modes THIS build implements, in cycle order (AUDIO lands in XF4). The
## cfg clamp checks membership, so a newer build's saved mode degrades to
## MANUAL instead of selecting an engine that does not exist here.
const XFADE_MODES_AVAILABLE: Array[int] = [XfadeMode.MANUAL, XfadeMode.BEAT,
	XfadeMode.AUDIO, XfadeMode.LFO]
const XFADE_EVERY := [1, 2, 4, 8]       ## BEAT: flip every N beats (flip-div idiom)
const XFADE_SWITCH := [0, 1, 2, 4]      ## XF2: fade length in beats; 0 = hard CUT
const XFADE_LFO_BARS := [1, 2, 4, 8]    ## XF3: full A→B→A sweep period in bars
var _xfade_mode: int = XfadeMode.MANUAL
var _xfade_every_idx: int = 2           ## default 4 beats = one bar
var _xfade_switch_idx: int = 0          ## default CUT (punchy)
var _xfade_lfo_bars_idx: int = 1        ## default 2 bars per sweep
var _xfade_target: float = 0.0          ## where automation is heading (0=A, 1=B)
var _xfade_beat_count: int = 0
# XF2 fade animation: -1 = idle, else 0..1 progress. Tempo-locked — progress
# advances by beats elapsed, so a mid-fade tempo change stays musical.
var _xfade_anim_from: float = 0.0
var _xfade_anim_t: float = -1.0
var _xfade_audio_last_ms: int = -1      ## XF4: onset refractory (audio-switch idiom)
var _xfade_mode_btn: Button = null
var _xfade_every_btn: Button = null
var _xfade_switch_btn: Button = null
var _xfade_lfo_btn: Button = null

# Ordered playlist persistence (the live play order). ⚠️ "PLAYLIST" IS NOW ONLY THIS
# FILE AND ClipEngine's clips/live_set — the PlaylistManagerUI panel that used to own
# them was retired once the grid could curate, order and remove. The data model is
# load-bearing (RANDOM/LFO read live_indices()); only its panel went.
const PLAYLIST_PATH := "user://playlist.cfg"

# The sequence is a Resource, so it persists as a .tres — the exact call a later
# SessionStore autoload will take over (it just owns save/load instead of pipeline;
# nothing to migrate). Without this a set built during a show evaporates on restart.
const SEQUENCE_PATH := "user://sequence.tres"
const SEQUENCE_B_PATH := "user://sequence_b.tres"   ## lane B's pattern (SEQ2 §3.7)

# Named save slots (warp-slot pattern): each is user://sequences/slot_N.tres, an
# independent Sequence snapshot with an optional .label. The autosave above stays
# the live working arrangement; slots are explicit saves.
const SEQUENCES_DIR := "user://sequences"
const SEQ_SLOT_COUNT := 6


func _ready() -> void:
	add_child(BootTiming.new())   # [boot] / [perf] lines in logcat (scripts/boot_timing.gd)
	# Force the root-window clear color to pure black. Godot's default is grey
	# (0.3,0.3,0.3), which shows through wherever the warped QuadWarp polygon
	# doesn't cover the screen — visible on the projector during corner-pin warp.
	# Set in code (not just the project setting) so it applies regardless of the
	# import/export state.
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 1))

	# One global theme so EVERY menu (panels, browsers, mask picker/numbers, warp
	# bar) shares the opaque dark look + consistent buttons. Inline overrides on
	# existing controls still win, so layouts are untouched.
	_apply_global_theme()
	status.theme = _theme

	_effects = [
		{"name": "Off", "shader": null},
		{"name": "RGB Shift", "shader": preload("res://shaders/rgb_shift.gdshader")},
		{"name": "Kaleidoscope", "shader": preload("res://shaders/kaleidoscope.gdshader")},
		{"name": "Feedback", "shader": preload("res://shaders/feedback.gdshader")},
		{"name": "Pixelate", "shader": preload("res://shaders/pixelate.gdshader")},
		{"name": "Chroma", "shader": preload("res://shaders/chromatic_aberration.gdshader")},
		{"name": "ASCII", "shader": preload("res://shaders/ascii.gdshader")},
		# APPENDED, never inserted: this index is what settings.cfg persists
		# (deck/effect) and what RegionCompositor stores per region, so inserting
		# above would silently repoint every saved effect on the next launch.
		{"name": "Glitch", "shader": preload("res://shaders/glitch.gdshader")},
		{"name": "Bloom", "shader": preload("res://shaders/bloom.gdshader")},
		{"name": "Displace", "shader": preload("res://shaders/displace.gdshader")},
		# "history": the effect needs LAST frame's pixels, so ShaderSlot switches
		# on its feedback buffer (a full-frame extra pass — see shader_slot.gd).
		# Absent on every other entry, which is how they keep paying nothing.
		{"name": "Trails", "shader": preload("res://shaders/trails.gdshader"), "history": true},
		# "slices": needs genuinely OLD frames, not just the last one, so
		# ShaderSlot builds its ring atlas (1/bands of a frame per frame). A
		# DIFFERENT mechanism from "history" above, and the two are independent.
		{"name": "Slit-Scan", "shader": preload("res://shaders/slit_scan.gdshader"),
			"slices": true},
		# No flags: a pure fragment shader, so it allocates nothing and costs what
		# RGB Shift costs. Back to the cheap end of the bank after two
		# buffer-backed effects.
		{"name": "Solarize", "shader": preload("res://shaders/solarize.gdshader")},
	]
	# The tracking FX draw tracked points, so they exist only where tracking
	# does (Features.MEDIAPIPE — the pro build). load(), not preload(): the
	# public build never compiles them. APPENDED LAST, so the saved effect
	# index of every effect above means the same thing in both builds; a pro
	# index past the public end is clamped by _load_settings.
	if Features.MEDIAPIPE:
		_effects.append_array([
			# M8c: the tracker made visible. Also a pure fragment shader — the per
			# person data arrives as ONE array uniform, so it allocates nothing and
			# costs what Solarize costs plus the loop.
			{"name": "Crowd", "shader": load("res://shaders/crowd.gdshader")},
		])
		# M8c: HUD and HUD Rings, locked to tracked points. Their shaders are not
		# in the open-source tree (they port Shadertoy code under a non-commercial
		# licence, see THIRD_PARTY.md), so each is added only if its file exists.
		# Drop in your own hud.gdshader / hud_rings.gdshader with the same uniforms
		# and they appear in the FX list again.
		for hud: Array in [["HUD", "res://shaders/hud.gdshader"],
				["HUD Rings", "res://shaders/hud_rings.gdshader"]]:
			if ResourceLoader.exists(str(hud[1])):
				_effects.append({"name": str(hud[0]), "shader": load(str(hud[1]))})

	# Push the audio-input tuning to GlobalBus BEFORE restoring settings: on first run
	# _load_settings() returns early, so without this the two files' defaults would
	# only ever agree by coincidence. Now pipeline.gd is the single source of truth
	# whether or not a settings.cfg exists.
	_set_audio_gain(_audio_gain)
	_set_audio_floor(_audio_floor)
	_set_audio_sensitivity(_audio_sensitivity)

	# Seed the matrix BEFORE _load_settings() for the same reason as the three
	# lines above: a saved [mod] section must overwrite the seed, and a file that
	# predates the matrix must leave it standing.
	_mod_init_defaults()

	# Restore saved deck state BEFORE building the UI so widgets pick up the values.
	_load_settings()
	_help_hold_timer = Timer.new()
	_help_hold_timer.one_shot = true
	_help_hold_timer.wait_time = HELP_HOLD_SEC
	add_child(_help_hold_timer)
	_help_hold_timer.timeout.connect(_help_hold_fire)
	if not _tour_seen:
		# The tour waits for the deck to be up; it must never delay the picture.
		get_tree().create_timer(2.0).timeout.connect(func() -> void: _show_tour(0))
	_load_sequence()   # the saved set (Step 5); survives app restarts across a show

	# BeatClock owns the tap-tempo grid now (Step 0). SEQUENTIAL advances on its
	# `beat`; the nav BPM label + settings-save react to tempo changes. Connect
	# AFTER _load_settings so restoring the saved BPM doesn't spuriously mark dirty.
	BeatClock.beat.connect(_on_beat_clock_beat)
	BeatClock.beat.connect(_on_seq_beat)          # sequencer auto-advance (Step 7)
	BeatClock.bpm_changed.connect(_on_bpm_changed)
	# N4: the master shares its grid once per bar; the same downbeat drains any
	# bar-quantized remote sequencer asks. Both no-ops unless the link is up
	# (internal guards) — connected unconditionally like every clock consumer.
	BeatClock.beat.connect(func(index: int) -> void: _bc_beat_index = index)
	# XF1: BEAT-mode crossfade automation (early-outs unless the mode is BEAT
	# and lane B is armed — the R1 cost of this connection is one comparison).
	BeatClock.beat.connect(_on_xfade_beat)
	# XF4: AUDIO mode rides the same mic-onset bus as audio-switch and the
	# flip's ONSET trigger — the whole detection stack (sensitivity, floor)
	# is reused; this is just one more consumer with its own refractory.
	GlobalBus.beat.connect(_on_xfade_onset)
	BeatClock.bar.connect(_on_beatclock_bar_link)
	# A tempo change must not wait for the next bar (spec §3.4). (A TAP that
	# lands the SAME bpm realigns the grid without this signal — the tap cell
	# handler sends its own line for that case.)
	BeatClock.bpm_changed.connect(func(_v: float) -> void: _send_link_beat())

	# BEAT FLIP subscribes to BOTH beats permanently and lets the handler decide
	# which one counts. Connecting/disconnecting on the TRIG chip instead would
	# make the wiring a second piece of state that can disagree with the setting —
	# and the ignored branch costs one int compare per beat, not per frame.
	GlobalBus.beat.connect(func() -> void: _flip_trigger(FlipTrig.ONSET))
	BeatClock.beat.connect(func(_index: int) -> void: _flip_trigger(FlipTrig.GRID))
	# KICK and HATS: the analyser's low and high bands (the mid band drives
	# nothing here — it is the body of the mix, not a drum).
	GlobalBus.band_beat.connect(func(band: int) -> void:
		if band == GlobalBus.BAND_LOW:
			_flip_trigger(FlipTrig.KICK)
		elif band == GlobalBus.BAND_HIGH:
			_flip_trigger(FlipTrig.HATS))
	GlobalBus.band_beat.connect(_on_band_onset)
	# BAR, not beat: the auto-change cycle is measured in bars (see _on_flip_bar).
	BeatClock.bar.connect(_on_flip_bar)

	clip_engine.start_index = _saved_clip_index   # consumed by ClipEngine's deferred _start
	_lane_a.engine = clip_engine
	# (_lane_b.bar_offset default 2 — spike S2's stagger — now comes from
	# _load_settings' [seq] merge, which ran just above.)
	clip_engine.swap_held.connect(_flash_held.bind("A"))
	clip_engine.clip_failed.connect(_on_clip_failed)

	clip_engine.clips_ready.connect(_on_clips_ready)
	clip_engine.clip_changed.connect(_on_clip_changed)
	clip_engine.clip_missing.connect(_on_clip_missing)
	# The deck runs two decoders; when the live one flips, its ViewportTexture is a
	# different object, so everything sampling it has to be re-pointed. Re-pointing
	# a texture reference is free — no GPU copy. (v0.3 REV2 §2.1)
	clip_engine.active_texture_changed.connect(_on_active_texture_changed)

	# ClipLibrary reflects the deck's clip list into the ClipData/Folder model the
	# visual browser reads (Step 1). It's an additive layer — ClipEngine still owns
	# scan/order/live_set. bind() connects clips_ready and builds when the deck scans.
	ClipLibrary.bind(clip_engine)
	# Pre-warm the thumbnail disk cache once, a couple of seconds after boot (Step 2),
	# so the ClipGrid is populated when first opened. request()/request_all() dedupe.
	ClipLibrary.library_ready.connect(_on_library_ready)

	_apply_cue_target()   # before the deck's deferred _start loads the first clip

	if Features.DRIVE_OAUTH:
		_wire_drive_client.call_deferred()   # Features adds DriveClient deferred too

	# Storage (core/storage.gd): the library is user://clips; imports are jobs.
	Storage.import_planned.connect(_on_import_planned)
	Storage.import_progress.connect(_on_import_progress)
	Storage.import_finished.connect(_on_import_finished)
	Storage.image_picked.connect(_on_mask_image_picked)
	Storage.demo_clips_done.connect(_on_demo_clips_done)
	Storage.storage_report_ready.connect(_on_storage_report)
	Storage.setup_done.connect(_on_setup_done)
	_rec_dir = Storage.recordings_dir(REC_DIR)

	# Live camera source — revert to video if the feed can't be acquired.
	camera_engine.camera_failed.connect(_on_camera_failed)
	# The mic is asked for in context (GlobalBus.request_mic); its answer
	# arrives here, whichever feature asked.
	GlobalBus.mic_state_changed.connect(_on_mic_state_changed)

	# Wire the chain. The quad fills the fixed OutputWorld, not the phone window.
	output_world.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	shader_slot.set_input(clip_engine.active_texture())
	quad_warp.fill_rect(_output_size())
	quad_warp.set_source(shader_slot.get_texture())
	_build_flip_material()  # BEAT FLIP's output-stage mirror (inert until enabled)
	_apply_quality()       # restored shader-stage resolution (FULL/HALF/FAST)
	_build_preview()       # the phone's view of OutputWorld, under all chrome

	_build_warp_editor()   # behind the control bar; transparent to input when idle
	_build_region_compositor()   # multi-region mask layer + its editor overlay
	_build_mask_overlay()  # raster image mask — LAST OutputWorld child = topmost
	_build_calibration()   # camera keystone — its pattern draws above even that
	_build_heat_watch()    # warn, and ease off, before Android cuts the projector
	_build_controls()
	_build_mode_panel()
	_build_fx_panel()
	_build_params_panel()
	_build_intensity_fader()
	_build_meter()
	_apply_effect()        # apply the restored effect shader
	_apply_source()        # route the restored clip source (and start the camera if saved)
	get_viewport().size_changed.connect(_on_resize)

	# Restore a saved warp (slot 1) once the viewport size is valid.
	_warp.call_deferred("load_slot", 1)

	# Restore saved mask regions (deferred so normalized points map to real px),
	# then route the output through the compositor if any exist.
	_region_editor.call_deferred("load_saved")
	call_deferred("_refresh_region_routing")
	call_deferred("_refresh_nav_values")

	# Dual-screen: HDMI Presentation plays the active clip via the native plugin.
	if Engine.has_singleton("PocketVJPresentation"):
		_hdmi = Engine.get_singleton("PocketVJPresentation")
		print("[hdmi] plugin ready: ", _hdmi.getDisplayInfo())
		_hdmi.connect("texture_output_ready", _on_texture_output_ready)
		_hdmi.connect("texture_output_lost", _on_texture_output_lost)
		# Re-send the GL handle whenever OutputWorld's texture is recreated.
		output_world.size_changed.connect(func():
			if _tex_output_active:
				_send_output_texture())
	else:
		print("[hdmi] plugin not present (desktop/editor build)")

	# Apply the restored display mode: DUAL leaves the normal ExoPlayer push flow
	# active; MIRROR releases the Presentation so Android mirrors the phone.
	_apply_display_mode()

	# …and the restored UI rotation. AFTER the UI is built (the toggle row reads
	# _ui_flipped when it is created) and after the display mode, so a flipped
	# start never races the Presentation setup.
	_apply_ui_flip()

	# DDP sink. Built unconditionally (a bare Node costs nothing) but only
	# ALLOCATES once enabled — see the _ddp block. set_source() takes the same
	# OutputWorld the EGL bridge reads, so the panel shows the composited
	# pipeline: warp, masks and shaders included (spec §2 MIRROR).
	_build_ddp()

	# Video link (Stage 0). Off by default; [link] enabled=true in settings.cfg
	# turns a phone into a mesh peer. Costs nothing when disabled — not built.
	_build_link()

	# OSC inbound (OSC_NAMESPACE_SPEC.md) — the standard-protocol control
	# surface: TD, Resolume, TouchOSC, any desk. Independent of the link
	# (a rig with no PocketVJ mesh still gets OSC). Default on, like the
	# beacon — this is a LAN instrument.
	_build_osc()
	_build_osc_out()
	_build_tracking()

	if INPUT_PROBE:
		_probe_announce()   # TEMPORARY macropad diagnostic — see the INPUT_PROBE block

	# Branded splash overlay (fades out shortly after launch).
	_build_splash()

	# First run on Android: offer to bring your own clips. Asked once, after the
	# splash. An upgraded beta tester is asked about their linked folder instead.
	if Storage.needs_setup():
		get_tree().create_timer(2.5).timeout.connect(_prompt_first_import)
	elif Storage.copy_offer_due():
		get_tree().create_timer(2.5).timeout.connect(_offer_copy_into_pvj)
	elif Storage.old_folder_notice() != "":
		get_tree().create_timer(2.5).timeout.connect(_notice_old_folder)

	# Sequencer 2.0: re-arm lane B if the last session left it armed ([seq]
	# restore). LAST — it builds MixWorld + the second deck, so the whole chain
	# and every panel must already exist. A never-armed session skips this and
	# stays byte-for-byte the single-deck app (R1).
	_build_perf_strip()   # PERF's gig strip (SEQ2 §3.6) — hidden until PERF
	if _s4_run != "":
		print("[s4] run '%s' armed — starts in %.0f s, lasts %.0f s" % [_s4_run, _s4_delay, _s4_secs])
		get_tree().create_timer(_s4_delay).timeout.connect(_start_s4)
	if _saved_lane_b_armed:
		_set_lane_b_armed(true)
		# Auto restores WITH armed — otherwise the session comes back blending
		# a frozen deck B over the set until the performer notices.
		if _saved_lane_b_auto:
			_set_lane_b_auto(true)
	BootTiming.mark("pipeline ready")


func _snap_bps(beats: int) -> int:
	var options := [1, 2, 4, 8]   # must match SequenceStrip._bps_options
	var best: int = options[0]
	for o: int in options:
		if absi(o - beats) < absi(best - beats):
			best = o
	return best


func _process(delta: float) -> void:
	# DUAL·TEX: the render target's GL name can churn behind our back — poll at
	# ~4 Hz, change-gated inside (_refresh_output_texture sends only on change).
	# The recorder reads the SAME texture, so it needs the same poll — without
	# HDMI attached nothing else would ever re-send a churned handle.
	if (_tex_output_active or _rec_active) and Engine.get_process_frames() % 15 == 0:
		_refresh_output_texture()

	_rec_poll(delta)

	# PERFORMANCE: this runs at 60 Hz behind live video decode, so everything here
	# is change-gated — a write only happens when the value actually moved. The
	# intensity term is also computed ONCE and shared (it was computed twice).
	var intensity := _deck_intensity()

	# Live readout. Gated on the panel actually being open, so it costs nothing
	# during a set, and refreshed at ~10 Hz — a figure respinning at 60 Hz is
	# unreadable, which defeats the point of having it.
	if _mod_readout != null and _mode_panel != null and _mode_panel.visible \
			and Engine.get_process_frames() % 6 == 0:
		_mod_readout.text = "%.2f" % intensity

	# TRACKING readout — same gating + cadence rules as the mod readout.
	if _track_readout != null and _mode_panel != null and _mode_panel.visible \
			and Engine.get_process_frames() % 6 == 0:
		if _tracking != null and _tracking.is_running():
			# ⚠️ head()/presence() are the LANDMARK path's values and are dead in
			# crowd and camera modes — reading them there printed "(NO SUBJECT)"
			# over a tracker that was happily holding two people, which reads as
			# broken. Third time this class of lie has cost us today (the mode
			# signal, the viewer, this): report what the LIVE MODE knows.
			match _tracking.mode():
				"crowd":
					var ca: Dictionary = _tracking.crowd.aggregates()
					_track_readout.text = "CROWD %d · x %.2f · spread %.2f%s" % [
						int(ca["count"]), float(ca["centroid_x"]), float(ca["spread"]),
						" · OVF" if float(ca["overflow"]) > 0.5 else ""]
				"camera":
					_track_readout.text = "CAMERA ONLY"
				_:
					var h := _tracking.head()
					_track_readout.text = "%.2f · %.2f · %.2f %s" % [h.x, h.y, h.z,
						"" if _tracking.presence() >= 0.5 else "(NO SUBJECT)"]
		else:
			_track_readout.text = "OFF"

	# The sources, live, while the panel is open: what each band hears is how
	# the matrix gets set (AUDIO_REACTIVITY_SPEC.md §6.2). Plain ASCII bars.
	if _mod_meter != null and _mode_panel != null and _mode_panel.visible \
			and Engine.get_process_frames() % 6 == 0:
		_mod_meter.text = "LOW %s MID %s HIGH %s HIT %s BRIGHT %s" % [_bar8(GlobalBus.low),
			_bar8(GlobalBus.mid), _bar8(GlobalBus.high), _bar8(GlobalBus.hit), _bar8(GlobalBus.bright)]

	# FX A / FX B, every frame (change-gated inside).
	_apply_mod_targets()

	# Shader intensity — skipped entirely when the effect is Off (passthrough has
	# no `intensity` uniform, so the call was pure waste), and only pushed when it
	# has moved perceptibly.
	if _effect_has_intensity and absf(intensity - _last_intensity) > INTENSITY_EPS:
		var mat := shader_slot.get_shader_material()
		if mat != null and mat.shader != null:
			mat.set_shader_parameter("intensity", intensity)
			_last_intensity = intensity

	# M8c: the crowd's positions, EVERY frame while the effect is live. Gated on
	# the effect actually being selected so a tracked room costs nothing while
	# the deck is on any other look.
	var _fxname := str(_effects[_effect_index].name)
	if _fxname == "Crowd" or _fxname == "HUD" or _fxname == "HUD Rings":
		_push_crowd_uniforms()

	# Mask regions pulse with the same value. set_intensity() loops EVERY region
	# and sets a shader param on each, so gate it on a real change too.
	#
	# MEASURED on the Pixel 8 (G3), because a BEAT-routed slot ramps continuously
	# and defeats this gate — every frame clears EPS, where a level-driven deck
	# does not. The gate turns out to be doing far less than it looks: with LEVEL
	# it still fired on ~90% of frames (~270/300), because room tone jitters the
	# level constantly. BEAT alone takes that to 300/300 — a real change of
	# regime, and a trivial one in cost:
	#     6 regions:  ~73 us/call   12 regions: ~112 us/call
	# against a 16667 us frame, i.e. 0.4-0.7%, at a steady 60 fps either way.
	# So routing BEAT with masks up is FINE and needs no guard. Revisit only if
	# region count grows by an order of magnitude — the cost is ~35 us fixed plus
	# ~6.4 us per region, so it stays cheap for any plausible mapping.
	if _region_comp != null and _region_comp.has_regions() \
			and absf(intensity - _last_region_intensity) > INTENSITY_EPS:
		_region_comp.set_intensity(intensity)
		_last_region_intensity = intensity

	SwitchProfiler.frame(delta)   # PROFILE (v0.3 Task 0) — no-op unless capturing
	if _s4 != null:
		_s4.frame()   # S4: one ticks_usec span per frame
	# The meter self-updates in its own _process now (M8Meter) — no per-frame call here.
	_update_fps(delta)

	# Latency burn-in, local half. Per-frame writes are ALLOWED here, against
	# the rule the rest of this function lives by, because the label only
	# exists during a measurement session ([link] debug_counter=true) — the
	# normal path pays one null check. Shown only while actually sending: a
	# clock on a phone that isn't streaming is a number nobody should diff.
	if _link_debug_lbl != null:
		var link_sending := _net_sender != null and _net_sender.is_active()
		if _link_debug_lbl.visible != link_sending:
			_link_debug_lbl.visible = link_sending
		if link_sending:
			_link_debug_lbl.text = str(Time.get_ticks_msec())
	_advance_clock(delta)
	# Audio-advance is signal-driven now (GlobalBus.beat -> _on_audio_onset), not polled.
	_tick_learn_floor(delta)   # returns on the first line unless a learn is running
	_tick_flip(delta)          # MOMENTARY's release; returns on the first line otherwise
	_tick_xfade(delta)         # XF2 fade animation; returns on the first line while idle
	_drive_playback_speed()
	_update_seq_playhead()
	_flush_settings(delta)


# Drive the sequence strip's playhead (Step 7) — only while auto-advance is on and
# the strip is visible. Fraction = whole beats done this slot + BeatClock's
# fractional position within the current beat, over beats-per-slot.
func _update_seq_playhead() -> void:
	# Per-lane run tests (not .auto): an armed AUTO outside SEQUENTIAL drives
	# nothing, so animating a playhead there would advertise a dead slot clock.
	if _seq_strip == null or not _seq_strip.visible:
		return
	var within_beat := fmod(BeatClock.phase * float(BeatClock.beats_per_bar), 1.0)
	var sel := _lane_for_strip()
	var sel_runs := _seq_drives() if _strip_lane == 0 else _lane_b_drives()
	if sel_runs:
		# maxf: lane B's beat_count starts NEGATIVE while the stagger elapses.
		_seq_strip.set_playhead(
			(maxf(0.0, float(sel.beat_count)) + within_beat) / float(sel.beats_per_slot))
	# The hidden lane keeps a slim ghost row (SEQ2 §3.6) so it stays honest.
	var other := _lane_b if _strip_lane == 0 else _lane_a
	var other_runs := _lane_b_drives() if _strip_lane == 0 else _seq_drives()
	_seq_strip.set_ghost_playhead(
		((maxf(0.0, float(other.beat_count)) + within_beat) / float(other.beats_per_slot))
		if other_runs else -1.0)


## The detector's tuning lives on GlobalBus (it owns the signal chain); these
## mirror it locally so the sliders and settings have something to read back.
func _set_audio_sensitivity(v: float) -> void:
	_audio_sensitivity = clampf(v, AUDIO_SENS_MIN, AUDIO_SENS_MAX)
	GlobalBus.beat_threshold = _audio_sensitivity


## Input gain. ⚠️ UNVALIDATED AGAINST A REAL LINE-IN. Every measurement behind the
## defaults was taken on the phone's built-in mic, where 8.0 is right: peak median
## 0.735 with 2 clipped seconds in 463 s of music. A USB-C line-in adapter runs far
## hotter and will pin the level at the 1.0 clamp, which flattens the running average
## and starves the ratio test — the symptom is the deck going quiet in loud passages.
## The slider exists so that is fixable in the room; the RANGE and the default are
## reasoned, not measured, and should be re-derived from a real line-in capture.
## Seed the matrix so that turning it on changes NOTHING: slot 0 reproduces the
## legacy `audio_base + level * audio_amount` drive exactly, the rest are empty.
## Called before _load_settings() so a saved [mod] section overrides these, and a
## settings.cfg predating the matrix (no [mod] at all) keeps them — which is the
## whole merge path.
func _mod_init_defaults() -> void:
	_mod_base = audio_base
	_mod_slots.clear()
	for i in MOD_SLOTS:
		_mod_slots.append({
			"src": ModSource.LEVEL if i == 0 else ModSource.NONE,
			"depth": audio_amount if i == 0 else 0.0,
			"pol": ModPolarity.NORM,
			"dst": ModTarget.INTENSITY,
			"curve": ModCurve.LIN,
		})
	_mod_master = 1.0


## The mod sources, all already normalized 0..1 by their owners.
func _source_value(src: int) -> float:
	match src:
		ModSource.LEVEL:
			return GlobalBus.level      ## smoothed continuous energy
		ModSource.PULSE:
			return GlobalBus.pulse      ## decaying onset
		ModSource.BEAT:
			return BeatClock.phase      ## 0..1 saw within the bar (tempo-locked)
		ModSource.STEP:
			# 0..1 within each BEAT: the fast tempo-locked saw.
			return fmod(clampf(BeatClock.phase, 0.0, 1.0) * float(BeatClock.beats_per_bar), 1.0)
		ModSource.LOW:
			return GlobalBus.low
		ModSource.MID:
			return GlobalBus.mid
		ModSource.HIGH:
			return GlobalBus.high
		ModSource.HIT:
			return GlobalBus.hit
		ModSource.BRIGHT:
			return GlobalBus.bright
		ModSource.TRACK:
			# head_z, presence-gated: nobody tracked = 0 contribution, never a
			# stale mid-value. (0.5 = the acquisition-baseline distance; INV on
			# the slot makes "closer = more" — the natural stage read.)
			if _tracking != null and _tracking.is_running() and _tracking.presence() >= 0.5:
				return _tracking.value_at(TrackingEngine.IDX_HEAD_Z)
			return 0.0
		ModSource.HAND:
			# Hand HEIGHT: raise the hand, raise the value (y is 0 at the top
			# of frame, so 1-y reads naturally). Gated on a hand being seen.
			if _tracking != null and _tracking.is_running() and _tracking.hand_present():
				return clampf(1.0 - _tracking.hand().y, 0.0, 1.0)
			return 0.0
		ModSource.CROWD_COUNT, ModSource.CROWD_X, ModSource.CROWD_SPREAD, \
		ModSource.CROWD_ENERGY, ModSource.CROWD_NEAREST, ModSource.CROWD_BALANCE:
			# §13.5: aggregates ride the EXISTING mod matrix as ordinary scalars.
			# Per-slot data deliberately does NOT — 8 slots x 8 channels would add
			# 64 sources and make the picker unusable; that surface is M8c's
			# single `uniform vec4 crowd[8]` instead.
			return _crowd_source(src)
	return 0.0


## Crowd aggregates, gated on crowd mode actually running so a stale value can
## never leak into the deck after the mode changes.
func _crowd_source(src: int) -> float:
	if _tracking == null or not _tracking.is_running() or _tracking.mode() != "crowd":
		return 0.0
	var a: Dictionary = _tracking.crowd.aggregates()
	match src:
		ModSource.CROWD_COUNT:
			# normalised by the SLOT BANK, so the knob's full travel is "as many
			# people as this rig can track", not an arbitrary ceiling
			return clampf(float(a["count"]) / maxf(float(_tracking.crowd.slots), 1.0), 0.0, 1.0)
		ModSource.CROWD_X: return float(a["centroid_x"])
		ModSource.CROWD_SPREAD: return float(a["spread"])
		ModSource.CROWD_ENERGY: return float(a["energy"])
		ModSource.CROWD_NEAREST: return float(a["nearest"])
		ModSource.CROWD_BALANCE: return float(a["balance"])
	return 0.0


## One slot's contribution: source, then INV ((1 - x): the source DUCKS the
## destination, silence means full depth), then the curve, then depth and the
## master amount.
func _slot_value(s: Dictionary) -> float:
	var src := int(s["src"])
	if src == ModSource.NONE:
		return 0.0
	var x := clampf(_source_value(src), 0.0, 1.0)
	if int(s["pol"]) == ModPolarity.INV:
		x = 1.0 - x
	match int(s.get("curve", ModCurve.LIN)):
		ModCurve.SQR:
			x = x * x
		ModCurve.SQRT:
			x = sqrt(x)
	return x * float(s["depth"]) * _mod_master


## Every slot routed to `dst`, summed. No base: that is intensity's own.
func _mod_target_sum(dst: int) -> float:
	var v := 0.0
	for s in _mod_slots:
		if int(s.get("dst", ModTarget.INTENSITY)) == dst:
			v += _slot_value(s)
	return v


func _mod_routes(dst: int) -> bool:
	for s in _mod_slots:
		if int(s["src"]) != ModSource.NONE and int(s.get("dst", ModTarget.INTENSITY)) == dst:
			return true
	return false


## Sum every slot routed to INTENSITY into the deck's intensity.
func _mod_sum() -> float:
	return clampf(_mod_base + _mod_target_sum(ModTarget.INTENSITY), 0.0, MOD_CEIL)


## The active effect's FX A / FX B tunables, as the matrix moves them. Runs
## every frame; every write is change-gated. With the matrix off the sum is 0,
## so the tunables settle back on their bases and the dictionaries empty.
func _apply_mod_targets() -> void:
	var table: Array = MOD_FX.get(str(_effects[_effect_index].name), [])
	var mat := shader_slot.get_shader_material()
	if table.is_empty() or mat == null or mat.shader == null:
		return
	if not _mod_enabled and _mod_fx_written.is_empty():
		return
	for t in mini(table.size(), 2):
		var spec: Array = table[t]
		var u: String = spec[0]
		var cur: Variant = mat.get_shader_parameter(u)
		if cur == null:
			continue
		var curf := float(cur)
		if _mod_fx_written.has(u) and absf(curf - float(_mod_fx_written[u])) > 1e-6:
			_mod_fx_base[u] = curf      # a slider moved it: that is the new base
		elif not _mod_fx_base.has(u):
			_mod_fx_base[u] = curf
		var span: float = (float(spec[2]) - float(spec[1])) * 0.5
		var sum := _mod_target_sum(ModTarget.FX_A + t) if _mod_enabled else 0.0
		var v := clampf(float(_mod_fx_base[u]) + sum * span, float(spec[1]), float(spec[2]))
		if absf(v - curf) > 1e-4:
			mat.set_shader_parameter(u, v)
			_mod_fx_written[u] = v
	if not _mod_enabled:
		_mod_fx_written.clear()   # settled on the bases; nothing more to undo
		_mod_fx_base.clear()


## For the target rows: what FX A / FX B are on the effect that is up.
func _mod_target_label(dst: int) -> String:
	if dst == ModTarget.FX_A or dst == ModTarget.FX_B:
		var table: Array = MOD_FX.get(str(_effects[_effect_index].name), [])
		var t := dst - ModTarget.FX_A
		if t < table.size():
			return "%s · %s" % [MOD_TARGET_NAMES[dst], str(table[t][0]).replace("_", " ").to_upper()]
		return "%s · (NONE ON THIS EFFECT)" % MOD_TARGET_NAMES[dst]
	return MOD_TARGET_NAMES[dst]


## THE single owner of the deck's intensity. Precedence: the performer's hand
## beats the matrix, the matrix beats the legacy drive. Nothing else may compute
## this value — _process pushes what this returns to both the active effect's
## material and every mask region.
func _deck_intensity() -> float:
	if _intensity_override:
		return _manual_intensity        # fader grabbed — momentary, wins outright
	if not _mod_enabled:
		# The original expression, literally. This is what makes "matrix off is
		# bit-identical to fabcbaf" a fact rather than an intention.
		return audio_base + GlobalBus.level * audio_amount
	return _mod_sum()


## An eight-step bar for the meter row.
func _bar8(v: float) -> String:
	var n := clampi(roundi(clampf(v, 0.0, 1.0) * 8.0), 0, 8)
	return "#".repeat(n) + ".".repeat(8 - n)


## The MOD MATRIX rows. Order is deliberate and matches AUDIO INPUT's: the live
## readout goes FIRST, because every control under it is set by watching that
## number move while you drag — the same reason the meter tops AUDIO INPUT.
func _build_mod_matrix_section(sections: Array) -> void:
	_add_collapsible("MOD MATRIX", false, sections)
	_mod_readout = _add_readout_row("Intensity out")
	_mod_meter = _add_readout_row("Sources")
	_mod_on_toggle = _add_toggle_row("Matrix on", _mod_enabled, func(on: bool):
		_mod_enabled = on
		_settings_dirty = true
		_mod_ask_mic())
	# The mid-set knob: every slot's depth at once.
	_mod_master_slider = _add_slider_row("Amount", 0.0, 1.0, 0.01, _mod_master, "", func(v: float):
		_mod_master = v
		_settings_dirty = true)
	# The floor with every source at zero — this is audio_base generalized.
	_add_slider_row("Base", 0.0, 1.0, 0.01, _mod_base, "", func(v: float):
		_mod_base = v
		_settings_dirty = true)
	# Recipes: a tap fills the slots and turns the matrix on. Tweak after.
	var names: Array = []
	for r: Array in MOD_RECIPES:
		names.append(r[0])
	_chip_row("Recipes  (fill the slots)", names, _mod_recipe_buttons,
		func(i: int): _apply_mod_recipe(i))

	_mod_slot_buttons.clear()
	_mod_dst_buttons.clear()
	_mod_curve_buttons.clear()
	_mod_depth_sliders.clear()
	_mod_inv_toggles.clear()
	for i in MOD_SLOTS:
		var idx := i
		# Source, target and curve each CYCLE on tap. A cycle rather than radio
		# rows keeps a slot to five rows; at 4 slots that is the difference
		# between a section you can thumb through and one you cannot.
		_mod_slot_buttons.append(_add_button_row(_mod_slot_label(idx),
			func(): _cycle_mod_source(idx)))
		_mod_dst_buttons.append(_add_button_row(_mod_dst_label(idx),
			func(): _cycle_mod_target(idx)))
		_mod_depth_sliders.append(_add_slider_row("  Depth", 0.0, MOD_DEPTH_MAX, 0.05,
			float(_mod_slots[idx]["depth"]), "", func(v: float):
				_mod_slots[idx]["depth"] = v
				_settings_dirty = true))
		# INV is (1 - x): the source DUCKS the destination, so silence means full
		# depth. Labelled "duck" because "invert" reads as negative depth.
		_mod_inv_toggles.append(_add_toggle_row("  Invert (duck)",
			int(_mod_slots[idx]["pol"]) == ModPolarity.INV,
			func(on: bool):
				_mod_slots[idx]["pol"] = ModPolarity.INV if on else ModPolarity.NORM
				_settings_dirty = true))
		_mod_curve_buttons.append(_add_button_row(_mod_curve_label(idx),
			func(): _cycle_mod_curve(idx)))


## A captioned row of mutually-exclusive chips — the TRAILS MIX/MAX pattern,
## pulled out as a helper because BEAT FLIP needs four of them.
##
## ⚠️ The chips carry the SAME drag guard as _add_button_row and _stepper. The
## FX-panel chip rows predate it and build their Buttons inline; these do not,
## because this section lives in the MODE panel, which is the tall scrolling one
## where a scroll-tap silently retunes a live control (see PANEL_TAP_SLOP).
func _chip_row(caption: String, names: Array, buttons: Array[Button],
		on_pick: Callable) -> void:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = caption.to_upper()
	lbl.add_theme_font_override("font", _font_label)
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", M8_LABEL)
	block.add_child(lbl)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	buttons.clear()
	for i in names.size():
		var idx := i
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 22)
		b.text = str(names[idx]).to_upper()
		b.pressed.connect(func() -> void:
			if _row_suppressed:
				return
			on_pick.call(idx))
		buttons.append(b)
		row.add_child(b)
	block.add_child(row)
	var wrap := _row_wrap(block)
	_params_vbox.add_child(wrap)
	_help_register(wrap, "%s/%s" % [_help_section, caption])


## Light the active chip green-on-green (the ASCII/Trails/Solarize treatment).
func _highlight_chips(buttons: Array[Button], active: int) -> void:
	for i in buttons.size():
		var b := buttons[i]
		if not is_instance_valid(b):
			continue
		var on := i == active
		b.add_theme_color_override("font_color", M8_GREEN if on else M8_TEXT)
		if on:
			b.add_theme_stylebox_override("normal",
				_btn_stylebox(Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.10), M8_GREEN, 1.0))
		else:
			b.remove_theme_stylebox_override("normal")


func _flip_axis_label() -> String:
	return "AXIS       %s" % FLIP_AXIS_NAMES[_flip_axis]


func _flip_trig_label() -> String:
	return "TRIGGER    %s" % FLIP_TRIG_NAMES[_flip_trig]


func _cycle_flip_axis() -> void:
	_set_flip_axis((_flip_axis + 1) % FLIP_AXIS_NAMES.size())


func _cycle_flip_trig() -> void:
	_set_flip_trig((_flip_trig + 1) % FLIP_TRIG_NAMES.size())


func _update_flip_buttons() -> void:
	_highlight_chips(_flip_div_buttons, _flip_div_index)
	_highlight_chips(_flip_mode_buttons, _flip_mode)
	_highlight_chips(_flip_source_buttons, _flip_source)
	_highlight_chips(_flip_treatment_buttons, _flip_treatment)
	_highlight_chips(_flip_rotate_buttons, _flip_rotate)
	_highlight_chips(_flip_rot_what_buttons, _flip_rot_what)
	# The two cycle rows carry their value in the label instead of a highlight.
	if is_instance_valid(_flip_axis_btn):
		_flip_axis_btn.text = _flip_axis_label().to_upper()
	if is_instance_valid(_flip_trig_btn):
		_flip_trig_btn.text = _flip_trig_label().to_upper()


## BEAT FLIP's rows. Collapsed by default, and placed AFTER the matrix because
## that is spec §1's split: modulation is the continuous channel, this is the
## discrete one, and reading them in that order is how the two stay distinct.
func _build_flip_section(sections: Array) -> void:
	_add_collapsible("BEAT FLIP", false, sections)
	_add_toggle_row("Flip on", _flip_enabled, func(on: bool): _set_flip_enabled(on))
	# EVERY-1 is deliberately in range: it is a strobe and it is meant to be.
	_chip_row("Subdivision  (every N triggers)", FLIP_DIV_NAMES, _flip_div_buttons,
		func(i: int): _set_flip_div(i))
	_chip_row("Mode", FLIP_MODE_NAMES, _flip_mode_buttons, func(i: int): _set_flip_mode(i))
	# ALT is the reason this row exists — a fixed source leaves half the frame
	# static for the whole effect.
	_chip_row("Source  (which half drives)", FLIP_SOURCE_NAMES, _flip_source_buttons,
		func(i: int): _set_flip_source(i))
	# HOW the driven half is drawn — independent of WHICH half drives, so the two
	# rows multiply rather than overlap.
	_chip_row("Treatment", FLIP_TREATMENT_NAMES, _flip_treatment_buttons,
		func(i: int): _set_flip_treatment(i))
	# Punch-in: hand the treatment over to the bar clock and let it change itself.
	# BARS, not beats — a look needs a few bars to register as a look, and
	# changing on the beat is just noise.
	_chip_row("Auto-change  (every N bars)", FLIP_ROTATE_NAMES, _flip_rotate_buttons,
		func(i: int): _set_flip_rotate(i))
	_chip_row("…advancing", FLIP_ROT_WHAT_NAMES, _flip_rot_what_buttons,
		func(i: int): _set_flip_rot_what(i))
	# AXIS and TRIGGER are CYCLE ROWS and they come LAST, because they are
	# set-and-leave: you pick an axis and a clock for the room and then stop
	# touching them, where the four rows above are the mid-set controls. A cycle
	# row is ~1/3 the height of a captioned chip row, and moving the rarely-used
	# pair here is what brings the whole section back inside one screen.
	# ONSET = mic transients (no setup). GRID = the tap grid (exact bars, needs a TAP).
	_flip_axis_btn = _add_button_row(_flip_axis_label(), func(): _cycle_flip_axis())
	_flip_trig_btn = _add_button_row(_flip_trig_label(), func(): _cycle_flip_trig())
	_update_flip_buttons()


func _mod_slot_label(i: int) -> String:
	return "SLOT %d   %s" % [i + 1, MOD_SOURCE_NAMES[int(_mod_slots[i]["src"])]]


func _mod_dst_label(i: int) -> String:
	return "  → %s" % _mod_target_label(int(_mod_slots[i].get("dst", ModTarget.INTENSITY)))


func _mod_curve_label(i: int) -> String:
	return "  CURVE   %s" % MOD_CURVE_NAMES[int(_mod_slots[i].get("curve", ModCurve.LIN))]


func _cycle_mod_source(i: int) -> void:
	var s: Dictionary = _mod_slots[i]
	s["src"] = (int(s["src"]) + 1) % MOD_SOURCE_NAMES.size()
	# TRACK..CROWD_BALANCE read the tracker. Without one (public build) the
	# cycle steps over them to the Mod v2 sources rather than offering dead ones.
	if not Features.MEDIAPIPE and int(s["src"]) > ModSource.BEAT \
			and int(s["src"]) < ModSource.LOW:
		s["src"] = ModSource.LOW
	_refresh_mod_rows()
	_settings_dirty = true


func _cycle_mod_target(i: int) -> void:
	var s: Dictionary = _mod_slots[i]
	s["dst"] = (int(s.get("dst", ModTarget.INTENSITY)) + 1) % MOD_TARGET_NAMES.size()
	_refresh_mod_rows()
	_settings_dirty = true


func _cycle_mod_curve(i: int) -> void:
	var s: Dictionary = _mod_slots[i]
	s["curve"] = (int(s.get("curve", ModCurve.LIN)) + 1) % MOD_CURVE_NAMES.size()
	_refresh_mod_rows()
	_settings_dirty = true


## Fill the slots from a recipe and turn the matrix on. Base and Amount are
## the performer's and stay.
func _apply_mod_recipe(i: int) -> void:
	if i < 0 or i >= MOD_RECIPES.size():
		return
	var rows: Array = MOD_RECIPES[i][1]
	for k in MOD_SLOTS:
		var s: Dictionary = _mod_slots[k]
		if k < rows.size():
			var r: Array = rows[k]
			s["src"] = int(r[0])
			s["dst"] = int(r[1])
			s["depth"] = float(r[2])
			s["pol"] = int(r[3])
			s["curve"] = int(r[4])
		else:
			s["src"] = ModSource.NONE
			s["depth"] = 0.0
			s["pol"] = ModPolarity.NORM
			s["dst"] = ModTarget.INTENSITY
			s["curve"] = ModCurve.LIN
	_mod_enabled = not rows.is_empty()
	_refresh_mod_rows()
	_settings_dirty = true
	_mod_ask_mic()
	_flash_status("MOD: %s" % str(MOD_RECIPES[i][0]))


## The matrix is on and a slot listens to the room: ask for the mic here, where
## it is used (never at launch). Silent when it is already live.
func _mod_ask_mic() -> void:
	if not _mod_enabled or GlobalBus.mic_active:
		return
	for s: Dictionary in _mod_slots:
		if int(s["src"]) in [ModSource.LEVEL, ModSource.PULSE, ModSource.LOW,
				ModSource.MID, ModSource.HIGH, ModSource.HIT, ModSource.BRIGHT]:
			_want_mic()
			return


## Every matrix row from the slots (after a recipe, a cycle, an effect change).
## The depth slider is set THROUGH its signal: its readout label only follows
## value_changed, and the slot it re-sets is already set (harmless).
func _refresh_mod_rows() -> void:
	for i in MOD_SLOTS:
		if i < _mod_slot_buttons.size() and is_instance_valid(_mod_slot_buttons[i]):
			_mod_slot_buttons[i].text = _mod_slot_label(i).to_upper()
		if i < _mod_dst_buttons.size() and is_instance_valid(_mod_dst_buttons[i]):
			_mod_dst_buttons[i].text = _mod_dst_label(i).to_upper()
		if i < _mod_curve_buttons.size() and is_instance_valid(_mod_curve_buttons[i]):
			_mod_curve_buttons[i].text = _mod_curve_label(i).to_upper()
		if i < _mod_depth_sliders.size() and is_instance_valid(_mod_depth_sliders[i]):
			_mod_depth_sliders[i].value = float(_mod_slots[i]["depth"])
		if i < _mod_inv_toggles.size() and is_instance_valid(_mod_inv_toggles[i]):
			_mod_inv_toggles[i].set_pressed_no_signal(int(_mod_slots[i]["pol"]) == ModPolarity.INV)
	if _mod_on_toggle != null and is_instance_valid(_mod_on_toggle):
		_mod_on_toggle.set_pressed_no_signal(_mod_enabled)


# --- BEAT FLIP ------------------------------------------------------------

## Attach the mirror shader to the OUTPUT stage. Done once at boot, on purpose:
## see the warning in beat_flip.gdshader about compiling mid-set.
##
## QuadWarp is the last stage on BOTH routes — _refresh_output_source() re-points
## it between ShaderSlot and MaskWorld, but it is always what draws into
## OutputWorld — so the flip reaches the preview, the recorder and the DUAL·TEX
## blit without any of them knowing it exists.
func _build_flip_material() -> void:
	_flip_mat = ShaderMaterial.new()
	_flip_mat.shader = preload("res://shaders/beat_flip.gdshader")
	_flip_mat.set_shader_parameter("axis", _flip_axis)
	_flip_mat.set_shader_parameter("flip_on", false)
	quad_warp.material = _flip_mat
	_reset_flip_source()      # seeds src_half from the restored SOURCE setting
	_reset_flip_treatment()   # …and treatment from the restored TREATMENT setting


## One handler, both signals. Returns on the first line in the normal (disabled)
## case, and on the second whenever the other clock ticks.
func _flip_trigger(src: int) -> void:
	if not _flip_enabled or src != _flip_trig:
		return
	_flip_count += 1
	if _flip_count % int(FLIP_DIVS[_flip_div_index]) != 0:
		return
	# ⚠️ THE SOURCE SWAPS ONLY WHEN THE MIRROR TURNS ON, NOT ON EVERY TRIGGER.
	# In ALTERNATING every second trigger turns it OFF, and a swap there is
	# invisible — the next ON would swap back and the SAME half would drive every
	# time, i.e. ALTERNATE would silently behave exactly like a fixed source.
	# Gating on the ON edge gives ON(left) → off → ON(right) → off, which is the
	# ping-pong that actually brings both halves alive.
	var turning_on := true
	if _flip_mode == FlipMode.ALTERNATING:
		# Hold until the NEXT trigger — this is the one that flips back and forth
		# every N beats rather than stuttering.
		turning_on = not _flip_state
		_set_flip_state(not _flip_state)
		_flip_hold_left = 0.0
	else:
		_set_flip_state(true)
		_flip_hold_left = FLIP_HOLD_BEATS * 60.0 / BeatClock.bpm
	if turning_on:
		# ⚠️ WHEN BOTH ARE ALTERNATE THE TWO PING-PONGS RUN AT DIFFERENT RATES, ON
		# PURPOSE. Advancing both on every edge keeps them in phase forever, which
		# visits only two of the four combinations — (mirror,left) and (flip,right)
		# — and looks like a single two-state toggle rather than two independent
		# controls. Halving SOURCE's rate makes the pair a 4-cycle:
		#     mirror/left → flip/left → mirror/right → flip/right → repeat
		# Only this both-ALTERNATE case is affected; with one of them fixed the
		# other still advances every edge exactly as before.
		var both_alt := _flip_source == FlipSource.ALTERNATE \
			and _flip_treatment == FlipTreatment.ALTERNATE
		_advance_flip_treatment()
		if not both_alt or _flip_alt_tick % 2 == 0:
			_advance_flip_source()
		_flip_alt_tick += 1


## Pick the half that drives for the flip about to start. Fixed sources just
## restate themselves (LEFT/RIGHT == src_half 0/1); ALTERNATE is the ping-pong.
func _advance_flip_source() -> void:
	if _flip_source == FlipSource.ALTERNATE:
		_flip_src_half = 1 - _flip_src_half
	else:
		_flip_src_half = _flip_source
	_push_flip_source()


func _push_flip_source() -> void:
	if _flip_mat != null:
		_flip_mat.set_shader_parameter("src_half", _flip_src_half)


## The TREATMENT twin of _advance_flip_source. ALTERNATE lives entirely here and
## never reaches the shader — it is resolved to a real treatment before the
## uniform is written.
##
## ⚠️ THE PING-PONG IS `1 - x` AND THAT IS WHY REPEAT IS NOT IN IT. The toggle
## only spans 0/1, so ALTERNATE swaps MIRROR and FLIP exactly as it always has;
## REPEAT (3) is reachable only as a fixed choice. That is deliberate — the two
## folded treatments are variations on one idea and alternating them reads as one
## effect breathing, whereas cutting to an unfolded repeat every N beats reads as
## the deck glitching.
func _advance_flip_treatment() -> void:
	if _flip_treatment == FlipTreatment.ALTERNATE:
		_flip_treat_now = 1 - _flip_treat_now
	else:
		_flip_treat_now = _flip_treatment
	_push_flip_treatment()


func _push_flip_treatment() -> void:
	if _flip_mat != null:
		_flip_mat.set_shader_parameter("treatment", _flip_treat_now)


## Park the treatment ping-pong so the FIRST flip after an enable (or a treatment
## change) is always MIRROR — the look people already know. Same reasoning as
## _reset_flip_source.
func _reset_flip_treatment() -> void:
	_flip_alt_tick = 0
	if _flip_treatment == FlipTreatment.ALTERNATE:
		_flip_treat_now = FlipTreatment.FLIP   # the first _advance_ flips this to MIRROR
	else:
		_flip_treat_now = _flip_treatment
	_push_flip_treatment()


## MOMENTARY's release. Called every frame from _process and returns immediately
## unless a hold is actually running, which is the normal case.
func _tick_flip(delta: float) -> void:
	if _flip_hold_left <= 0.0:
		return
	_flip_hold_left -= delta
	if _flip_hold_left <= 0.0:
		_flip_hold_left = 0.0
		_set_flip_state(false)


## The ONE writer of the flip uniform. Gated on change: a trigger at /1 on a busy
## track is still only a handful of writes a second, but the state is also forced
## on enable/disable and there is no reason to push a value the GPU already has.
func _set_flip_state(on: bool) -> void:
	if on == _flip_state:
		return
	_flip_state = on
	if _flip_mat != null:
		_flip_mat.set_shader_parameter("flip_on", on)


## Enabling/disabling always lands the output in a known state — a disable while
## the mirror happens to be held would otherwise leave it stuck on screen with no
## trigger coming to clear it.
func _set_flip_enabled(on: bool) -> void:
	_flip_enabled = on
	_flip_count = 0        # a fresh subdivision phase, so /8 starts counting from here
	_flip_hold_left = 0.0
	_reset_flip_source()
	_reset_flip_treatment()
	if not on:
		_set_flip_state(false)
	_settings_dirty = true


## Park the ping-pong so the FIRST flip after an enable (or a source change) is
## always the LEFT-driven one people already know. Without this, ALTERNATE would
## open on whichever half it happened to stop on last time.
func _reset_flip_source() -> void:
	# The 4-cycle's phase lives in the tick, so parking a half without parking the
	# tick would restart the pair mid-pattern and the first flip after a tap would
	# no longer be predictable.
	_flip_alt_tick = 0
	if _flip_source == FlipSource.ALTERNATE:
		_flip_src_half = 1     # the first _advance_ flips this to 0 = LEFT
	else:
		_flip_src_half = _flip_source
	_push_flip_source()


func _set_flip_div(i: int) -> void:
	_flip_div_index = clampi(i, 0, FLIP_DIVS.size() - 1)
	_flip_count = 0        # re-phase, or the new rate inherits the old count's offset
	_update_flip_buttons()
	_settings_dirty = true
	_flash_status("BEAT FLIP: EVERY %s %s" %
		[FLIP_DIV_NAMES[_flip_div_index], FLIP_TRIG_NAMES[_flip_trig].to_upper()])


func _set_flip_mode(m: int) -> void:
	_flip_mode = clampi(m, 0, FLIP_MODE_NAMES.size() - 1)
	# Switching out of a held state must not strand the mirror on.
	_flip_hold_left = 0.0
	_set_flip_state(false)
	_update_flip_buttons()
	_settings_dirty = true
	if _flip_mode == FlipMode.ALTERNATING:
		_flash_status("BEAT FLIP: ALTERNATING — HOLDS UNTIL THE NEXT TRIGGER")
	else:
		_flash_status("BEAT FLIP: MOMENTARY — SNAPS BACK AFTER A 16TH")


func _set_flip_axis(a: int) -> void:
	_flip_axis = clampi(a, 0, FLIP_AXIS_NAMES.size() - 1)
	if _flip_mat != null:
		_flip_mat.set_shader_parameter("axis", _flip_axis)
	_update_flip_buttons()
	_settings_dirty = true


## The fix for "one half never changes". Fixed sources apply IMMEDIATELY (so the
## chip does something visible without waiting for a beat); ALTERNATE re-parks and
## starts ping-ponging from the next trigger.
func _set_flip_source(s: int) -> void:
	_flip_source = clampi(s, 0, FLIP_SOURCE_NAMES.size() - 1)
	_reset_flip_source()
	_update_flip_buttons()
	_settings_dirty = true
	# Name the halves the way the CURRENT axis shows them — on VERT there is no
	# left or right, and a chip labelled LEFT that moves the top half is a lie.
	var lo := "LEFT" if _flip_axis == FlipAxis.HORIZONTAL else "TOP"
	var hi := "RIGHT" if _flip_axis == FlipAxis.HORIZONTAL else "BOTTOM"
	match _flip_source:
		FlipSource.ALTERNATE:
			_flash_status("BEAT FLIP: ALTERNATE — %s AND %s TAKE TURNS DRIVING" % [lo, hi])
		FlipSource.RIGHT:
			_flash_status("BEAT FLIP: %s HALF DRIVES" % hi)
		_:
			_flash_status("BEAT FLIP: %s HALF DRIVES" % lo)


## Composes with SOURCE: this changes only HOW the driven half is drawn, never
## WHICH half drives. The fixed looks apply IMMEDIATELY (so the chip does
## something visible without waiting for a beat); ALTERNATE re-parks and starts
## swapping from the next trigger.
func _set_flip_rot_what(i: int) -> void:
	_flip_rot_what = clampi(i, 0, FLIP_ROT_WHAT_NAMES.size() - 1)
	_settings_dirty = true
	_update_flip_buttons()
	_flash_status("AUTO-CHANGE ADVANCES: %s" % FLIP_ROT_WHAT_NAMES[_flip_rot_what])


func _set_flip_rotate(i: int) -> void:
	_flip_rotate = clampi(i, 0, FLIP_ROTATE_NAMES.size() - 1)
	# Restart the count on every change, so switching 8 BARS -> 4 BARS gives a
	# full 4 bars rather than firing immediately off a stale count.
	_flip_rotate_bars = 0
	# Pick up wherever the performer left the treatment, so the first rotation
	# moves ON from their choice instead of jumping back to MIRROR.
	_flip_rotate_pos = maxi(0, FLIP_ROTATE_CYCLE.find(_flip_treatment))
	_settings_dirty = true
	_update_flip_buttons()
	_flash_status("BEAT FLIP AUTO-CHANGE: %s" % FLIP_ROTATE_NAMES[_flip_rotate])


## One bar of the deck's tempo. Counts, and hands over to _set_flip_treatment
## when the cycle is up.
##
## Gated on _flip_enabled: rotating a treatment nobody can see would still flash
## the status line every few bars, which reads as the deck doing something.
func _on_flip_bar(_index: int) -> void:
	if _flip_rotate == 0 or not _flip_enabled:
		return
	_flip_rotate_bars += 1
	if _flip_rotate_bars < int(FLIP_ROTATE_BARS[_flip_rotate]):
		return
	_flip_rotate_bars = 0
	_flip_rotate_pos = (_flip_rotate_pos + 1) % FLIP_ROTATE_CYCLE.size()
	# Treatment always advances — it is the visible one, and a cycle that left it
	# alone would read as nothing happening.
	_set_flip_treatment(int(FLIP_ROTATE_CYCLE[_flip_rotate_pos]))
	# The others go through their OWN setters for the same reason the treatment
	# does: one owner per value, no second writer poking state behind them.
	if _flip_rot_what == 1 or _flip_rot_what == 3:
		_set_flip_axis((_flip_axis + 1) % FLIP_AXIS_NAMES.size())
	if _flip_rot_what == 2 or _flip_rot_what == 3:
		_set_flip_source((_flip_source + 1) % FLIP_SOURCE_NAMES.size())
	# Flashed LAST, on purpose: each setter above flashes its own line, so
	# without this the performer sees whichever happened to run last rather than
	# what actually changed.
	if _flip_rot_what != 0:
		_flash_status("BEAT FLIP: %s / %s / %s" % [
			FLIP_TREATMENT_NAMES[_flip_treatment].to_upper(),
			FLIP_AXIS_NAMES[_flip_axis].to_upper(),
			FLIP_SOURCE_NAMES[_flip_source].to_upper()])


func _set_flip_treatment(t: int) -> void:
	_flip_treatment = clampi(t, 0, FLIP_TREATMENT_NAMES.size() - 1)
	# ⚠️ A MANUAL TAP BECOMES THE CYCLE'S NEW STARTING POINT. Without this the
	# auto-change carries on from wherever IT was and the performer's tap looks
	# ignored a few bars later — the one genuinely confusing thing about having
	# manual and automatic at once. Re-deriving here is safe when the ROTATION is
	# the caller: _on_flip_bar sets the position first and passes that entry, so
	# find() returns the same index it just wrote.
	_flip_rotate_pos = maxi(0, FLIP_ROTATE_CYCLE.find(_flip_treatment))
	_reset_flip_treatment()
	_update_flip_buttons()
	_settings_dirty = true
	match _flip_treatment:
		FlipTreatment.ALTERNATE:
			_flash_status("BEAT FLIP: ALTERNATE — MIRROR AND FLIP TAKE TURNS")
		FlipTreatment.FLIP:
			_flash_status("BEAT FLIP: FLIP — THE COPY IS TURNED 180°")
		_:
			_flash_status("BEAT FLIP: MIRROR — THE COPY IS A REFLECTION")


## Naming the consequence, not the setting: GRID is silently useless until the
## tempo has been tapped, and the status line is where that gets said.
func _set_flip_trig(t: int) -> void:
	_flip_trig = clampi(t, 0, FLIP_TRIG_NAMES.size() - 1)
	_flip_count = 0        # the two clocks have unrelated counts; don't inherit one
	_update_flip_buttons()
	_settings_dirty = true
	if _flip_trig == FlipTrig.GRID:
		_flash_status("BEAT FLIP: GRID — TAP THE TEMPO OR IT RUNS AT %.0f BPM" % BeatClock.bpm)
	else:
		_flash_status("BEAT FLIP: ONSET — FIRES ON MIC TRANSIENTS")


func _set_audio_gain(v: float) -> void:
	_audio_gain = clampf(v, AUDIO_GAIN_MIN, AUDIO_GAIN_MAX)
	GlobalBus.gain = _audio_gain


## Noise floor — the per-venue control. See audio_bus.gd for the measurement.
func _set_audio_floor(v: float) -> void:
	_audio_floor = clampf(v, AUDIO_FLOOR_MIN, AUDIO_FLOOR_MAX)
	GlobalBus.beat_min_level = _audio_floor


## Ask for the mic on behalf of the feature the performer just touched. True if
## it is live now; otherwise the status line says what happens next.
func _want_mic() -> bool:
	if GlobalBus.request_mic():
		return true
	_flash_status(_mic_blocked_text() if GlobalBus.mic_denied
		else "ALLOW THE MICROPHONE TO USE AUDIO FEATURES")
	return false


func _mic_blocked_text() -> String:
	return "MIC BLOCKED — ALLOW IT IN ANDROID SETTINGS ▸ APPS ▸ PERMISSIONS"


func _mic_label() -> String:
	if GlobalBus.mic_active:
		return "Mic: ON"
	return "Mic: BLOCKED (settings)" if GlobalBus.mic_denied else "Mic: OFF — tap to allow"


func _on_mic_state_changed(active: bool) -> void:
	if _btn_mic != null:
		_btn_mic.text = _mic_label().to_upper()   # rows are built uppercase
	_flash_status("MIC ON" if active else _mic_blocked_text())


func _learn_label() -> String:
	return "LEARN FLOOR (%dS)" % int(LEARN_SEC)


## Start listening, or cancel a listen already running (same button).
func _toggle_learn_floor() -> void:
	if _learn_left >= 0.0:
		_end_learn_floor("LEARN CANCELLED")
		return
	if not GlobalBus.mic_active:
		if not _want_mic():
			return
	_learn_left = LEARN_SEC
	_learn_samples = PackedFloat32Array()
	_learn_shown = -1
	_flash_status("LISTENING TO THE ROOM — LEAVE THE MUSIC OFF")


func _end_learn_floor(msg: String) -> void:
	_learn_left = -1.0
	_learn_samples = PackedFloat32Array()
	if _learn_btn != null:
		_learn_btn.text = _learn_label()
	if msg != "":
		_flash_status(msg)


## Collect one frame of room tone. Called from _process; returns immediately when
## no learn is running, which is the normal case.
func _tick_learn_floor(delta: float) -> void:
	if _learn_left < 0.0:
		return
	_learn_samples.append(GlobalBus.level)
	_learn_left -= delta
	# Countdown on the button itself — written once per WHOLE second, not per frame.
	var left := maxi(0, int(ceil(_learn_left)))
	if left != _learn_shown and _learn_btn != null:
		_learn_shown = left
		_learn_btn.text = "LISTENING… %dS" % left
	if _learn_left <= 0.0:
		_finish_learn_floor()


## Turn the collected room tone into a floor.
##
## THE THREE CONSTANTS ARE MEASURED, NOT PICKED. Replayed over the 525 s of silent
## room in the Session-23 capture — every possible window, asking how often the
## learned floor lands in the 0.12..0.35 band that audio_bus.gd measured as safe
## (music onsets 100% kept, most silent-room fires rejected):
##
##   window  estimator  margin   in band  too low  too high
##      3 s        max     x2.6      64%      18%       18%
##      8 s        p90     x2.2      75%      13%       13%
##     12 s        p90     x2.2      81%      10%        9%
##
## Hence 12 s / p90 / x2.2, and hence the wait is 12 s rather than the 3 s this was
## first sketched as — a 3 s window is simply not a sample of a room.
##
## ⚠️ THE MAX IS DELIBERATELY NOT THE ESTIMATOR. One door slam inside the window
## drags it by a factor of nine (silent-room 3 s maxima ran 0.066 median against
## 0.574 worst), and a learn that fires on a cough is worse than no learn at all.
## A percentile over ~700 frames does not care.
##
## x2.2 is preferred to x2.6 (which scores marginally better, 83%) because x2.6 buys
## that by landing TOO HIGH more often, and too high is the dead-deck failure this
## whole line of work exists to prevent — while too low is merely noisy. The result
## is announced and written to the slider rather than applied silently, so a bad
## learn is one tap from corrected.
func _finish_learn_floor() -> void:
	var n := _learn_samples.size()
	var samples := _learn_samples
	_learn_left = -1.0
	_learn_samples = PackedFloat32Array()
	if _learn_btn != null:
		_learn_btn.text = _learn_label()
	if n < 30:
		_flash_status("LEARN FAILED — NO INPUT SAMPLED")
		return
	samples.sort()
	var measured := samples[clampi(int(round(LEARN_PERCENTILE * float(n - 1))), 0, n - 1)]
	# A learn taken over music measures the music, and the floor it computes kills the
	# deck. Refuse rather than apply it — the old floor is a far better answer than a
	# confidently wrong new one, and the performer gets told what to fix.
	if measured > LEARN_MAX_ROOM:
		print("[LearnFloor] REFUSED: room p%d=%.3f > %.2f (music still playing?)" %
			[int(LEARN_PERCENTILE * 100.0), measured, LEARN_MAX_ROOM])
		_flash_status("ROOM TOO LOUD (%.2f) — TURN THE MUSIC OFF AND RETRY" % measured)
		return
	# Written THROUGH the slider: its value_changed already updates the readout,
	# calls _set_audio_floor and marks settings dirty, so there is one path that
	# applies a floor rather than two that can disagree.
	if _floor_slider != null:
		_floor_slider.value = measured * LEARN_MARGIN   # slider clamps + steps
	else:
		_set_audio_floor(measured * LEARN_MARGIN)
	print("[LearnFloor] %d samples, p%d=%.3f x%.1f -> floor %.2f" %
		[n, int(LEARN_PERCENTILE * 100.0), measured, LEARN_MARGIN, _audio_floor])
	_flash_status("ROOM %.2f  →  FLOOR %.2f" % [measured, _audio_floor])


# Goal 4: fire a clip switch on a detected ONSET, independent of the shader
# intensity reactivity.
#
# ⚠️ THIS USED TO TRIGGER ON ABSOLUTE MIC LEVEL (rising cross of a threshold with
# 80% hysteresis) and that had a structural dead-zone, measured against two real
# tracks (AUDIO_REACTIVITY_SPEC §0):
#
#   * Loud sustained passage — the smoothed envelope never falls back under
#     0.8 x threshold, so the edge never re-arms and the deck stops cutting.
#     Measured: one 110 s and one 34 s freeze through the loudest sections;
#     43% and 64% of each track with no audio-fired cut at all.
#   * Quiet passage — the envelope never reaches the threshold, so nothing fires.
#
# Both failures are properties of comparing a SLOW ENVELOPE to an ABSOLUTE level,
# so neither band-splitting nor threshold tuning removes them. GlobalBus.beat is a
# RELATIVE detector (level against its own running average), which makes it
# level-independent: over the identical audio it was dead 12% of the time where
# this gate was dead 43-64%. So the transient decides WHEN, as before — it is just
# detected by ratio rather than by absolute loudness.
#
# GATED ON SWITCH MODE (v0.3 §4): in MANUAL the performer has explicitly said
# "do not advance", so a mic transient must not move the deck. This was a real
# bug, not just a measurement artifact — it advanced the deck three clips during
# the Task-0 setup while nominally in MANUAL, and once the sequencer exists a
# stray transient would jump the arrangement.
## A band onset (KICK = low, HATS = high) reaches audio-advance only when that
## is the band it is set to; the broadband one only when it is set to ONSET.
func _on_band_onset(band: int) -> void:
	if (band == GlobalBus.BAND_LOW and _audio_band == TrigBand.KICK) \
			or (band == GlobalBus.BAND_HIGH and _audio_band == TrigBand.HATS):
		_audio_fire()


func _on_audio_onset() -> void:
	if _audio_band == TrigBand.ONSET:
		_audio_fire()


func _audio_band_label() -> String:
	return "ADVANCE ON   %s" % TRIG_BAND_NAMES[_audio_band]


func _cycle_audio_band() -> void:
	_audio_band = (_audio_band + 1) % TRIG_BAND_NAMES.size()
	if _audio_band_btn != null and is_instance_valid(_audio_band_btn):
		_audio_band_btn.text = _audio_band_label()
	_settings_dirty = true


func _audio_fire() -> void:
	if _mode == SwitchMode.MANUAL:
		return
	# SEQ2 §3.2 (the resolved open decision): the mic transient may only steal a
	# deck that no armed lane owns. While the sequence drives deck A, onsets
	# stand down — and they never touch deck B at all.
	if _seq_drives():
		return
	if not _audio_switch_enabled or _source == ClipSource.CAMERA:
		return
	# Refractory stays (REV2 §5.2 / spec §2.4) — it protects the demux from a
	# snare roll, and it is now the ONLY rate limit on this path. Timestamped
	# rather than a per-frame countdown because this is signal-driven, not polled.
	var now := Time.get_ticks_msec()
	if _audio_last_fire_ms >= 0 and now - _audio_last_fire_ms < int(AUDIO_REFRACTORY_SEC * 1000.0):
		return
	var gap := -1.0 if _audio_last_fire_ms < 0 else float(now - _audio_last_fire_ms) * 0.001
	_audio_last_fire_ms = now
	# Fire a SWAP to the mode's pre-cued target (pick-and-remember, §5.2): the
	# transient decides WHEN to advance, the mode's provider already decided
	# WHAT to. So audio-advance is cueable in every mode — SEQUENTIAL/LFO down
	# the arrangement, RANDOM to the remembered random pick. If the cue isn't
	# warm swap() holds, so a burst can't outrun the demux.
	clip_engine.swap()
	# One line per audio-fired cut. The absence of this is what made §0 unmeasurable
	# the first time round — swap() itself only logs when it HOLDS.
	print("[AudioSwitch] cut gap=%s lvl=%.3f" %
		[("--" if gap < 0.0 else "%.3fs" % gap), GlobalBus.level])


# Goal 5: spike GoZen playback speed on each beat pulse, ramping back to 1.0 as
# the pulse decays. `intensity` scales how aggressive the spike is.
func _drive_playback_speed() -> void:
	var p := clip_engine.player
	if p == null:
		return
	if _mod_enabled and _mod_routes(ModTarget.SPEED):
		# The matrix owns it: 1x plus the routed sum, up to AUDIO SPEED's max.
		var s := clampf(1.0 + _mod_target_sum(ModTarget.SPEED) * (_speed_max - 1.0), 1.0, SPEED_MAX_CEIL)
		if absf(s - p.playback_speed) > 0.005:
			p.playback_speed = s
	elif _speed_ramp_enabled:
		# Continuous: quiet = 1x, loud = up to _speed_max. GlobalBus.level is already
		# smoothed, so the speed ramps gradually rather than jumping.
		# PERFORMANCE: only write when it actually moved — this crosses into GoZen
		# on every assignment and was being set unconditionally every frame.
		var s := clampf(1.0 + GlobalBus.level * (_speed_max - 1.0), 1.0, SPEED_MAX_CEIL)
		if absf(s - p.playback_speed) > 0.005:
			p.playback_speed = s
	elif p.playback_speed != 1.0:
		p.playback_speed = 1.0   # restore normal speed when disabled


# --- Clip-switch clock ---------------------------------------------------

func _advance_clock(delta: float) -> void:
	if _source == ClipSource.CAMERA:
		return   # nothing to auto-switch while the live camera is the source
	if clip_engine.clips.size() <= 1:
		return
	# ⚠️ NO SEQUENCER GUARD HERE, DELIBERATELY. An earlier cut returned early while the
	# sequence was driving, to stop RANDOM/LFO double-cutting against it. With a
	# mode-blind _seq_drives() that froze both modes outright — LFO worst of all, since
	# the return landed BEFORE _lfo_phase is integrated below, so the sweep itself
	# stopped rather than just the cut. Now that the sequence only ever drives inside
	# SEQUENTIAL, whose branch is `pass` anyway, such a guard could not protect
	# anything: RANDOM and LFO are unreachable while the sequence drives. Leaving it
	# out makes that true BY CONSTRUCTION instead of by predicate, so a future change
	# to _seq_drives() cannot resurrect the freeze.
	match _mode:
		SwitchMode.SEQUENTIAL:
			# Beat-synced advance is driven by BeatClock.beat now (see
			# _on_beat_clock_beat), not a local accumulator — one clock for the
			# whole app (Step 0). Nothing to do here per frame.
			pass
		SwitchMode.RANDOM:
			# Own dwell interval (0 = fastest hard cut), independent of BPM. The
			# boundary action is a SWAP to the pre-cued random target (pick-and-remember,
			# §3): the target was chosen when it was warmed, so we do NOT re-randomize
			# here. If it isn't warm yet swap() holds — which is what stops a fast dwell
			# (down to the 0.06 s floor) from collapsing the frame rate the way the old
			# per-cut random open did.
			var iv := maxf(_random_interval_sec, RANDOM_MIN_INTERVAL)
			_random_accum += delta
			if _random_accum >= iv:
				_random_accum -= iv
				clip_engine.swap()
		SwitchMode.LFO:
			# Ping-pong through the live set at its own rate (independent of the BPM
			# clock). The phase advances every frame; the CUT is rate-limited.
			#
			# ⚠️ THIS USED TO CALL play_index() AND IT FROZE THE DECK. The sweep was
			# re-evaluated per frame and cut whenever the rounded index moved, which
			# scales with the LIVE SET SIZE: 47 live clips over an 8 s period is ~11.5
			# index changes per second, 235 live clips is ~58. play_index() is a
			# SYNCHRONOUS ~150 ms FFmpeg open, so either rate asks for more blocking
			# work than there are seconds — measured at 4 fps on device.
			#
			# Worse, it was self-reinforcing: play_index() restarts the cue, so the cue
			# never finished warming, so `idx == cued_index()` was never true, so it
			# took the blocking path EVERY time. Once tipped it could not recover.
			#
			# Now it mirrors RANDOM: swap() only, which HOLDS when the next clip is not
			# warm instead of blocking — that is exactly why RANDOM never stalled — plus
			# a dwell floor so the sweep cannot request cuts faster than a decoder can
			# serve them. With 235 clips over 8 s each clip previously got 34 ms, which
			# is not a musical value under any reading.
			_lfo_phase = fmod(_lfo_phase + delta / _lfo_sweep_sec(), 1.0)
			_lfo_accum += delta
			# The dwell IS the control now — one cut per clip — with LFO_MIN_DWELL as a
			# floor so a very small setting cannot outrun the decoder.
			if _lfo_accum >= maxf(_lfo_sec_per_clip, LFO_MIN_DWELL):
				_lfo_accum = 0.0
				if _lfo_index() != clip_engine.current_index:
					clip_engine.swap()
		SwitchMode.MANUAL:
			pass


# SEQUENTIAL clip-advance, driven by the one BeatClock grid (Step 0). Same guards
# and same SWAP boundary as the old inline clock — the next clip is already warm in
# the back decoder; if it isn't, swap() holds and we cut on the next beat, so cuts
# stay on the grid either way. Fires every beat but only acts in SEQUENTIAL.
func _on_beat_clock_beat(_index: int) -> void:
	if _mode != SwitchMode.SEQUENTIAL:
		return
	# The sequencer's auto-advance also cuts on the beat and drives the deck itself
	# (via jump). If it's running, the explicit sequence wins — don't also swap here,
	# or the two clocks double-cut on the same beat.
	#
	# PRE-EXISTING FIX (predates Piece 1): this tested _lane_a.auto raw, so AUTO armed
	# with an EMPTY sequence yielded the beat to a sequencer that then had nothing to
	# step through — SEQUENTIAL simply stopped advancing, with no way to tell from the
	# UI. _seq_drives() carries the non-empty test, so the clip-array walk now resumes
	# instead of stalling.
	if _seq_drives():
		return
	if _source == ClipSource.CAMERA:
		return   # nothing to auto-switch while the live camera is the source
	if clip_engine.clips.size() <= 1:
		return
	clip_engine.swap()


# Tempo changed (tap or set_bpm) — keep the nav BPM label in sync and persist.
func _on_bpm_changed(_value: float) -> void:
	_update_bpm_label()
	_settings_dirty = true


# Pre-warm the thumbnail cache once, after boot settles (Step 2). The 2 s delay
# keeps the extractor's first decodes off the boot frame where the deck is opening
# its own first clip + cue; the service serializes and backs off after that.
func _on_library_ready() -> void:
	# The folder chips follow the library: a sub-folder that appeared on a
	# rescan gets its chip, one that went loses it (ALL otherwise).
	if _folder_tabs != null:
		_folder_tabs.refresh()
	if _thumbs_prewarmed:
		return
	_thumbs_prewarmed = true
	get_tree().create_timer(2.0).timeout.connect(ThumbnailService.request_all)


# Tell the deck what to warm next, so the cue target matches what the switch clock
# will actually ask for (v0.3 REV2 §3). Re-applied on every mode change.
## `recue` false sets the provider WITHOUT re-warming — for the one caller that is
## about to issue its own jump(), where recueing first would start an open that the
## jump immediately restarts (cue() only short-circuits on an ALREADY-READY index).
func _apply_cue_target(recue: bool = true) -> void:
	# THE SEQUENCE WINS while it is running (Piece 1). Before this branch existed the
	# sequencer drove the deck through jump() but the back decoder was still being
	# warmed with next_live_index() — the PLAYLIST's next clip — so unless the two
	# orders happened to coincide, jump() missed its warm path (clip_engine.jump:
	# `idx == _cued_index and _cue_ready`) and every sequencer step paid the full
	# ~195 ms cold demux the two-decoder design exists to avoid.
	#
	# ⚠️ This provider MUST resolve a slot to an engine index exactly the way
	# _advance_sequence_to eventually will, or the cue warms one clip while the jump
	# asks for another and we are back to cold opens. That is why both go through
	# _engine_index_for_clip_id() rather than each doing their own find().
	if _seq_drives():
		clip_engine.next_index_provider = func() -> int: return _seq_next_engine_index()
		if recue:
			clip_engine.recue()
		return
	match _mode:
		SwitchMode.LFO:
			clip_engine.next_index_provider = func() -> int: return _lfo_next_index()
		SwitchMode.RANDOM:
			# Pick-and-remember: roll the random target ONCE, when it is warmed. cue()
			# stores it and swap() uses that same index — no re-roll at the cut.
			clip_engine.next_index_provider = func() -> int: return clip_engine.random_live_index()
		_:
			clip_engine.next_index_provider = func() -> int: return clip_engine.next_live_index()
	# Warm the new mode's target now — the clip the old mode cued is likely wrong.
	if recue:
		clip_engine.recue()


## True while the SEQUENCE is the thing driving the deck.
##
## ⚠️ THE MODE TEST IS LOAD-BEARING. AUTO is a strip button with no relationship to
## _mode and it is not persisted, so it stays armed while the performer cycles modes.
## The first cut of this predicate omitted the mode and therefore read "AUTO is
## armed" as "the sequence owns the deck everywhere" — one armed toggle captured all
## four modes: RANDOM and LFO stopped advancing, and every mode's cue target became a
## sequence slot. Each switch mode names its OWN source, and this is the only one
## that names the sequence:
##
##   MANUAL      the tapped clip, pinned
##   SEQUENTIAL  clip-array order          <- and the grid sequence when AUTO is armed
##   RANDOM      the playlist LIVE pool
##   LFO         the playlist LIVE pool
##
## Giving the sequence a switch mode of its own (so AUTO becomes its run/stop rather
## than a button that does nothing in three of four modes) is Piece 2, still not done
## here.
func _seq_drives() -> bool:
	return _lane_a.auto and not _lane_a.sequence.is_empty() and _mode == SwitchMode.SEQUENTIAL


## The engine index the sequencer will step to next, or -1 for "don't cue".
##
## _lane_a.index of -1 (nothing active yet) yields slot 0, which is where
## _on_seq_auto_toggled starts a fresh run — so arming AUTO warms the clip it is
## about to play. A dangling entry (id no longer resolves to a present clip, e.g. a
## renamed file) returns -1: _cue_next() then skips cueing entirely, which preserves
## today's behaviour that such a slot holds the previous clip rather than cutting
## somewhere unexpected.
func _seq_next_engine_index() -> int:
	if _lane_a.sequence.is_empty():
		return -1
	var slot := (_lane_a.index + 1) % _lane_a.sequence.size()   # wraps at the end, like _on_seq_beat
	return _engine_index_for_clip_id(_lane_a.sequence.get_id(slot))


# Where the LFO will step next: it walks the live list one slot at a time, so the
# next slot is current +/- 1 depending on which way the triangle is going.
## ⚠️ Predicts the sweep position ONE DWELL AHEAD, not one step ahead. The cut is now
## rate-limited to LFO_MIN_DWELL, and in that time the sweep can cross SEVERAL indices
## when the live set is large — 47 clips over an 8 s period moves ~2.9 steps per 0.25 s
## dwell. Cueing "current ± 1" would warm a clip the sweep has already passed, so every
## cut would find a cold decoder and hold, which is the stall this rewrite exists to
## remove.
func _lfo_next_index() -> int:
	var li := clip_engine.live_indices()
	var n := li.size()
	if n == 0:
		return clip_engine.current_index
	if n == 1:
		return li[0]
	var next_phase := fmod(_lfo_phase
		+ maxf(_lfo_sec_per_clip, LFO_MIN_DWELL) / _lfo_sweep_sec(), 1.0)
	var tri := 1.0 - absf(2.0 * next_phase - 1.0)
	return li[clampi(int(round(tri * float(n - 1))), 0, n - 1)]


## Full ping-pong duration, DERIVED from the per-clip dwell and the live-set size.
## A sweep visits 2*(n-1) clips — up the list and back — so this is what keeps
## "seconds per clip" honest whether 10 clips are live or 235.
func _lfo_sweep_sec() -> float:
	var n := clip_engine.live_indices().size()
	var steps := maxi(2 * (n - 1), 1)
	return maxf(_lfo_sec_per_clip * float(steps), 0.05)


func _lfo_index() -> int:
	# Ping-pong over the LIVE subset (returns all indices when nothing is parked).
	var li := clip_engine.live_indices()
	var n := li.size()
	if n == 0:
		return clip_engine.current_index
	if n == 1:
		return li[0]
	var tri := 1.0 - absf(2.0 * _lfo_phase - 1.0)   # triangle wave 0..1..0
	return li[clampi(int(round(tri * float(n - 1))), 0, n - 1)]


func _set_mode(mode: int) -> void:
	_mode = mode
	BeatClock.reset_grid()   # realign the beat grid on a switch into SEQUENTIAL
	_lfo_phase = 0.0
	_lfo_accum = 0.0   # a fresh sweep starts its dwell clock fresh too
	# The sequencer's slot clock only means anything while the sequence drives, and
	# _seq_drives() now turns over with the mode. Entering SEQUENTIAL therefore gets a
	# whole first slot rather than inheriting a count from beats that stepped nothing;
	# leaving it clears the strip instead of stranding a playhead mid-slot. The strip
	# is built lazily on the first grid toggle, hence the null check.
	_lane_a.beat_count = 0
	if not _seq_drives() and _seq_strip != null:
		_seq_strip.set_playhead(0.0)
	if _btn_mode != null:
		_btn_mode.text = _nav_value(MODE_NAMES[_mode])
	_update_mode_buttons()
	_apply_cue_target()   # the new mode wants a different clip warmed
	_settings_dirty = true
	_flash_status("MODE: %s" % MODE_NAMES[_mode].to_upper())


func _update_mode_buttons() -> void:
	for i in _mode_buttons.size():
		_mode_buttons[i].text = MODE_NAMES[i].to_upper()
		_style_list_item(_mode_buttons[i], i == _mode)


# M8 selected-row look: BRIGHT green text on a faint green block that runs the
# full width of the sidebar (the rows are full-bleed — the panel has no padding),
# separated by a hairline green rule. Unselected rows are white-on-black.
func _style_list_item(b: Button, active: bool) -> void:
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 66)
	b.add_theme_color_override("font_color", M8_GREEN if active else M8_TEXT)
	b.add_theme_color_override("font_hover_color", M8_GREEN if active else M8_TEXT)
	var sb := _list_row_stylebox(active)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", _list_row_stylebox(true))


# Section header: flat black, no border, indented to line up with the list rows.
func _header_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.set_corner_radius_all(0)
	sb.set_border_width_all(0)
	sb.content_margin_left = 26
	sb.content_margin_right = 18
	sb.content_margin_top = 14
	sb.content_margin_bottom = 10
	return sb


func _list_row_stylebox(active: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(0)
	sb.bg_color = Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.12) if active else Color(0, 0, 0, 0)
	sb.border_color = M8_LINE          # hairline rule between rows
	sb.border_width_bottom = 1
	sb.content_margin_left = 26
	sb.content_margin_right = 18
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	return sb


func _cycle_mode() -> void:
	_set_mode((_mode + 1) % MODE_NAMES.size())


# --- Performance mode ----------------------------------------------------

func _enter_perf() -> void:
	if _perf_mode:
		return
	_close_panels()
	_perf_mode = true
	# Show the restore hint briefly, then hide all chrome for clean output. The
	# preview stays visible — the phone (and a mirrored projector) keeps showing
	# the full OutputWorld with no interface over it.
	_flash_status("PERFORMANCE MODE — THREE-FINGER TAP TO RESTORE UI")
	await get_tree().create_timer(1.3).timeout
	if _perf_mode:
		_chrome_layer.visible = false
		_refresh_perf_strip()   # the ONE strip that stays (SEQ2 §3.6)


func _exit_perf() -> void:
	if not _perf_mode:
		return
	_perf_mode = false
	_chrome_layer.visible = true
	_refresh_perf_strip()
	# Levels moved on the strip while the panel was hidden: its peer rows are
	# seeded from the store, so a rebuild makes their labels tell the truth.
	_refresh_link_peer_rows()


## Build PERF's gig strip. ON the UI layer as the chrome's SIBLING, added after
## it so it draws on top: hiding _chrome_layer is all PERF does, and this strip
## is the part that must survive that.
func _build_perf_strip() -> void:
	_perf_strip = PerfStrip.new()
	_perf_strip.theme = _theme
	ui_layer.add_child(_perf_strip)
	_perf_strip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_perf_strip.offset_top = -PerfStrip.STRIP_H
	_perf_strip.offset_bottom = 0.0
	_perf_strip.setup(_font_label)   # after add_child (hazard 2)
	_perf_strip.visible = false
	_perf_strip.slot_pressed.connect(_on_perf_slot)
	_perf_strip.xfade_moved.connect(_on_perf_xfade)
	_perf_strip.level_moved.connect(_on_perf_level)


## Shown only in PERF, and only in DUAL: in MIRROR the phone screen IS the
## projector, and the spec's rule is that this strip is never projected.
func _refresh_perf_strip() -> void:
	if _perf_strip == null:
		return
	var show_it := _perf_mode and _display_mode == DisplayMode.DUAL
	if show_it and not _perf_strip.visible:
		_push_perf_strip_all()
	_perf_strip.visible = show_it


## Everything the strip shows, pushed fresh on every show — it keeps no state
## the pipeline cannot rebuild.
func _push_perf_strip_all() -> void:
	_refresh_slot_labels()        # the shared bank, both strips
	_push_perf_lane_b()
	_perf_strip.set_xfade(_xfade)
	_apply_link_layer_alphas()    # pushes P / T with their providers


func _push_perf_lane_b() -> void:
	if _perf_strip != null:
		_perf_strip.set_lane_b(_lane_b_armed, ["", "NET", "TD"][_lane_b_source])


## One tap = one pattern, bar-quantized. Local loads ride the OSC/link verbs'
## _seq_pending queue (drained on the next downbeat by _on_beatclock_bar_link,
## connected unconditionally — link or not). Lane B on a stream routes to that
## stream's instrument instead: the same N4 law as the sequence strip's LOAD.
func _on_perf_slot(lane: int, slot: int) -> void:
	if not FileAccess.file_exists(_slot_path(slot)):
		_perf_strip.flash("SLOT %d EMPTY" % slot)
		return
	if lane == 1:
		if not _lane_b_armed:
			_perf_strip.flash("LANE B NOT ARMED")
			return
		if _lane_b_source != LaneBSource.CLIP:
			var prov := _lane_b_provider()
			if prov.is_empty() or _link_control == null:
				_perf_strip.flash("LANE B IS %s — NOTHING STREAMING" % LANE_B_SOURCE_NAMES[_lane_b_source])
				return
			_link_control.send_seq_slot(str(prov["ip"]), int(prov["ctrl"]), "a", slot, "bar")
			_perf_strip.flash("→ %s SLOT %d @ BAR" % [str(prov["who"]), slot])
			print("[perf] slot %d -> %s (remote, @ bar)" % [slot, str(prov["who"])])
			return
	var lane_key := "b" if lane == 1 else "a"
	_seq_pending.append({"lane": lane_key, "op": "slot", "slot": slot, "on": false})
	_perf_strip.set_pending_slot(lane, slot)
	_perf_strip.flash("%s%d @ BAR" % [lane_key.to_upper(), slot])
	print("[perf] slot %d -> lane %s queued for the next bar" % [slot, lane_key.to_upper()])


## A hand on the strip's crossfader: the operator's path, so automation yields.
func _on_perf_xfade(v: float) -> void:
	_set_xfade_manual(v)
	# Log in 0.1 steps (and at the ends) — a drag is dozens of writes, and the
	# log is how a device run proves the fader reached the mix.
	if absf(v - _perf_xfade_logged) >= 0.1 or ((v <= 0.0 or v >= 1.0) and v != _perf_xfade_logged):
		_perf_xfade_logged = v
		print("[perf] xfade -> %.2f" % v)


## P / T: the level of WHOEVER is on that slot right now (Stage 3.3's store).
func _on_perf_level(which: int, v: float, final: bool) -> void:
	var peer_name := _link_rx_name if which == 0 else _td_rx_name
	if peer_name == "":
		return
	_set_peer_alpha(peer_name, v, final)


## S4: start the run named in [perf] s4_run. The context lines record what the
## rig ACTUALLY was when timing began — the layers the operator believes are
## live and the layers that are live are not always the same set.
func _start_s4() -> void:
	if not Features.PRO or _s4_run == "" or _s4 != null:
		return
	var peer_state := "no-link"
	if _net_source != null:
		peer_state = "%s %s" % [_link_rx_name if _link_rx_name != "" else "-",
				LINK_FRESH_NAMES[_net_source.freshness()]]
	var td_state := "not-built"
	if _net_source_td != null:
		td_state = "%s %s" % [_td_rx_name if _td_rx_name != "" else "-",
				LINK_FRESH_NAMES[_net_source_td.freshness()]]
	var ctx := {
		"device": OS.get_model_name(),
		"deck_mode": MODE_NAMES[_mode],
		"effect": str(_effects[_effect_index].name),
		"display": _display_mode_label(),
		"lane_b_armed": _lane_b_armed,
		"lane_b_source": LANE_B_SOURCE_NAMES[_lane_b_source],
		"xfade": snappedf(_xfade, 0.01),
		"xfade_mode": XFADE_MODE_NAMES[_xfade_mode],
		"peer_slot": peer_state,
		"td_slot": td_state,
		"tracking": _track_enabled,
		"perf_mode": _perf_mode,
	}
	_s4 = FrameSampler.new()
	_s4.start(_s4_run, _s4_secs, ctx)


func _toggle_perf() -> void:
	if _perf_mode:
		_exit_perf()
	else:
		_enter_perf()


# --- Display mode (DUAL / MIRROR) ----------------------------------------

# Reconcile the HDMI plugin with the current display mode. Safe to call on boot
# and on every switch; a no-op chain when the plugin is absent (desktop/editor).
func _apply_display_mode() -> void:
	_hdmi_enabled = (_display_mode == DisplayMode.DUAL and _dual_feed == DualFeed.PLAYER)
	if _btn_display != null:
		_btn_display.text = "DISPLAY: %s" % _display_mode_label()
	# COVER only bites in MIRROR, so the preview crop follows the display mode.
	_apply_preview_fill()
	# Bottom-right OUT indicator: green while an external display is being driven.
	if _lbl_out != null:
		_lbl_out.add_theme_color_override("font_color",
			M8_GREEN if _hdmi != null else M8_DIMTEXT)
	if _hdmi == null:
		return
	_update_idle_output()
	if _display_mode == DisplayMode.DUAL and _dual_feed == DualFeed.TEXTURE:
		# DUAL·TEX: the EGL bridge blits OutputWorld onto the Presentation —
		# the full pipeline (warp/masks/shaders) reaches the projector.
		_start_texture_output()
	elif _hdmi_enabled:
		# DUAL·PLAYER: ExoPlayer takes over the HDMI surface again with the
		# active clip (playOnHdmi rebuilds it after a prior stop).
		_stop_texture_output()
		_push_clip_to_hdmi(clip_engine.current_index)
	else:
		# MIRROR: stop both paths + release the external display so Android
		# mirrors the phone screen (warp/effects + UI) onto HDMI.
		_stop_texture_output()
		_hdmi.stopHdmi()


func _display_mode_label() -> String:
	if _display_mode == DisplayMode.DUAL:
		return "DUAL·%s" % DUAL_FEED_NAMES[_dual_feed].to_upper()
	return "MIRROR"


# --- DUAL·TEX: the EGL bridge feed (spec §3, Session 14) ------------------

func _start_texture_output() -> void:
	var res: String = _hdmi.startTextureOutput()
	# The one prominent line per session: what the link actually negotiated.
	print("[hdmi] TEXTURE OUTPUT LINK: %s" % res)
	if not res.begins_with("ok:"):
		_flash_status("HDMI: %s" % res.to_upper())
		return
	_tex_output_active = true
	_hdmi_presentation_active = true
	# The GL handle is sent from _on_texture_output_ready, once the projector
	# surface actually exists (it arrives async from the UI thread).


func _stop_texture_output() -> void:
	if _tex_output_active:
		_hdmi.stopTextureOutput()
	_tex_output_active = false


# The projector surface is live at surface_w x surface_h. Size OutputWorld to
# the display's aspect (capped at the 1080p fragment budget) and hand the GL
# texture over. Re-entered on every surface rebuild (replug, resume).
func _on_texture_output_ready(surface_w: int, surface_h: int) -> void:
	if not _tex_output_active:
		return
	var aspect := float(surface_w) / float(surface_h)
	var th := mini(1080, surface_h)
	var tw := roundi(th * aspect)
	if tw > 1920:
		tw = 1920
		th = roundi(tw / aspect)
	var target := Vector2i(tw, th)
	if output_world.size != target:
		# Non-16:9 display: the preset-normalization basis changes with the
		# output size — same wrinkle as the pre-S13 configs. Warn, don't solve
		# (spec S14 decision); on the 16:9 BenQ this branch never runs.
		output_world.size = target
		_output_px = Vector2(target)
		if _mask_world != null:
			_mask_world.size = target   # mask space is LOCKED to the output basis
		if _mix_world != null:
			_mix_world.size = target    # the mix bus follows the same basis
		# reset_all, not fill_rect: this branch already discards the warp and
		# tells the user to re-save, and a mesh's offsets are in OUTPUT px —
		# carrying them across a basis change would deform against a new scale.
		quad_warp.reset_all(_output_size())
		_refresh_output_source()   # re-point the warp at the resized source
		push_warning("[hdmi] output basis changed to %dx%d — re-save warp/mask slots" % [tw, th])
		_flash_status("OUTPUT %dx%d — RE-SAVE WARP/MASK SLOTS" % [tw, th])
	print("[hdmi] LINK NEGOTIATED: surface %dx%d, OutputWorld %dx%d" %
		[surface_w, surface_h, output_world.size.x, output_world.size.y])
	_update_idle_output()
	_send_output_texture()


func _on_texture_output_lost() -> void:
	# Kotlin already stopped blitting; nothing to tear down here. The hotplug
	# listener rebuilds on replug and ready fires again.
	print("[hdmi] texture output lost (unplug/background)")
	_flash_status("HDMI OUTPUT LOST")


# Fetch OutputWorld's native GL texture name and hand it to the bridge. Waits
# one drawn frame first: after a resize the GL texture is recreated, and the
# handle is only valid once the new target has rendered.
func _send_output_texture() -> void:
	await RenderingServer.frame_post_draw
	if not _tex_output_active:
		return
	_refresh_output_texture(true)


# The render target's GLuint is NOT stable: Godot can recreate the RT (and GL
# recycles freed names for e.g. decoder textures — observed on device as the
# projector showing a raw deck clip). Poll cheaply and re-send on change; the
# log line records every churn so the pattern is visible in logcat.
func _refresh_output_texture(force: bool = false) -> void:
	# Ask the server for the render-target texture directly — the ViewportTexture
	# resource RID is a proxy, and texture_get_native_handle returns 0 for it.
	# The idle screen is its own viewport (never OutputWorld — the phone's
	# preview must not show it); while it is up, the bridge blits that.
	var vp: SubViewport = _idle_world if _idle_active and _idle_world != null else output_world
	var rid := RenderingServer.viewport_get_texture(vp.get_viewport_rid())
	var gl_id := RenderingServer.texture_get_native_handle(rid)
	if gl_id == _last_gl_id and not force:
		return
	_last_gl_id = gl_id
	_hdmi.setSourceTexture(gl_id, vp.size.x, vp.size.y)
	print("[hdmi] source texture sent: gl_id=%d %dx%d%s" %
		[gl_id, vp.size.x, vp.size.y, " (idle screen)" if vp == _idle_world else ""])


# --- Set recording --------------------------------------------------------

func _toggle_rec() -> void:
	if _rec_active:
		_rec_stop("user")
	else:
		_rec_start()


func _rec_start() -> void:
	if _hdmi == null:
		_flash_status("RECORDING NEEDS THE ANDROID BUILD")
		return
	# Refuse rather than start a recording that cannot survive its own moov write.
	var free := _rec_query_free()
	if free >= 0 and free <= REC_RESERVE_MB:
		_flash_status("NO SPACE TO RECORD — %d MB FREE" % free)
		return
	# No mic, no audio track — asking for one the capture bus can never feed
	# would make the muxer wait on a format that never arrives. Asking for the
	# mic HERE is the in-context moment; this take is video-only either way
	# (the grant is async), the next one has sound.
	if _rec_audio and not GlobalBus.mic_active:
		GlobalBus.request_mic()
	_rec_audio_wanted = _rec_audio and GlobalBus.mic_active
	var res: String = _hdmi.startRecording(
		_rec_dir, output_world.size.x, output_world.size.y, 60,
		REC_BITRATE_KBPS, REC_MIME, _rec_seg_minutes * 60, REC_RESERVE_MB,
		_rec_audio_wanted, int(AudioServer.get_mix_rate()), REC_AUDIO_BITRATE_KBPS)
	print("[rec] START %dx%d %s %dkbps seg=%dmin audio=%s@%dHz -> %s" %
		[output_world.size.x, output_world.size.y, REC_MIME,
		REC_BITRATE_KBPS, _rec_seg_minutes, str(_rec_audio_wanted),
		int(AudioServer.get_mix_rate()), res])
	if not res.begins_with("ok:"):
		_flash_status("REC FAILED: %s" % res.to_upper())
		return
	_rec_active = true
	_rec_set_dir = res.substr(3).get_slice(":", 0)   # "ok:<set dir>:<caps>"
	_rec_elapsed = 0.0
	_rec_warned = false
	_rec_mute_warned = false
	_rec_rate_mb_min = REC_SEED_MB_PER_MIN
	if _rec_audio_wanted:
		GlobalBus.begin_pcm_capture()
	elif _rec_audio:
		_flash_status("REC — NO MIC, VIDEO ONLY")
	_flash_status("REC — %s" % _rec_remaining_text())
	# The recorder reads OutputWorld's GL name, and that handle is only valid
	# after a drawn frame. With DUAL·TEX off nothing else would ever send it.
	_rec_send_texture()
	_update_rec_ui()


func _rec_send_texture() -> void:
	await RenderingServer.frame_post_draw
	if _rec_active:
		_refresh_output_texture(true)


# Stopping NEVER touches the deck, the compositor or the bridge — a recording
# failure must not interrupt what is on the wall.
func _rec_stop(reason: String) -> void:
	if not _rec_active:
		return
	GlobalBus.end_pcm_capture()
	var summary: String = _hdmi.stopRecording(reason)
	_rec_active = false
	Storage.scan_media(_rec_set_dir)   # into Photos now, not at the next media scan
	_rec_audio_wanted = false
	print("[rec] %s" % summary)
	match reason:
		"disk-full":
			_flash_status("REC STOPPED — DISK FULL. RECORDING SAVED.")
		"user":
			_flash_status("REC SAVED — %.0f MIN" % (_rec_elapsed / 60.0))
		_:
			_flash_status("REC STOPPED — %s. RECORDING SAVED." % reason.to_upper())
	_update_rec_ui()


# Straight through to the AAC encoder's queue. Deliberately does no per-sample
# work — the bytes are the capture buffer verbatim and Kotlin downmixes them.
func _on_pcm_captured(pcm: PackedByteArray, frames: int, pad_frames: int) -> void:
	if not _rec_active or _hdmi == null:
		return
	_hdmi.pushRecorderAudio(pcm, frames, pad_frames)


func _rec_query_free() -> int:
	if _hdmi == null:
		return -1
	# StatFs needs an existing path; the recordings dir may not exist yet.
	var probe := _rec_dir if DirAccess.dir_exists_absolute(_rec_dir) else _rec_dir.get_base_dir()
	_rec_free_mb = int(_hdmi.getFreeMb(probe))
	return _rec_free_mb


## Minutes of recording the remaining space allows, over and above the reserve.
func _rec_remaining_minutes() -> float:
	if _rec_free_mb < 0:
		return -1.0
	var usable := float(_rec_free_mb - REC_RESERVE_MB)
	if usable <= 0.0:
		return 0.0
	return usable / maxf(_rec_rate_mb_min, 1.0)


func _rec_remaining_text() -> String:
	var m := _rec_remaining_minutes()
	if m < 0.0:
		return "-- MIN LEFT"
	return "%d MIN LEFT" % int(m)


# 1 Hz. Reads the recorder's own byte counter (so the rate is MEASURED, not
# assumed), refreshes free space, warns, and stops before the disk is full.
func _rec_poll(delta: float) -> void:
	if _hdmi == null:
		return
	_rec_poll_accum += delta
	if _rec_poll_accum < REC_POLL_SEC:
		return
	var dt := _rec_poll_accum
	_rec_poll_accum = 0.0
	_rec_query_free()

	if not _rec_active:
		_update_rec_ui()
		return

	_rec_elapsed += dt
	# stats: rec|elapsed_s|bytes|bytes_per_sec|segments|dir|error|has_audio_track
	var parts := str(_hdmi.getRecorderStats()).split("|")
	var err := ""
	if parts.size() >= 7:
		_rec_elapsed = float(parts[1])
		var bps := float(parts[3])
		if bps > 0.0:
			_rec_rate_mb_min = bps * 60.0 / 1048576.0
		err = parts[6]
	# Audio was asked for, the file has no audio track, and a segment is already
	# open — the encoder gave up on it. Say so ONCE. A recording that turns out
	# to be silent afterwards is the failure this whole feature exists to fix.
	if parts.size() >= 8 and _rec_audio_wanted and not _rec_mute_warned:
		if int(parts[4]) > 0 and parts[7] == "0":
			_rec_mute_warned = true
			_flash_status("REC IS SILENT — AUDIO ENCODER FAILED")

	# Kotlin stops itself on its own storage floor and on write errors; mirror
	# that into the UI rather than waiting for the user to notice.
	if err != "":
		_rec_stop(err)
		return

	var left := _rec_remaining_minutes()
	if left >= 0.0 and left <= 0.05:
		_rec_stop("disk-full")
		return
	if left >= 0.0 and left <= REC_WARN_MIN and not _rec_warned:
		_rec_warned = true
		_flash_status("RECORDING: %s" % _rec_remaining_text())
	_update_rec_ui()


# Change-gated like everything else that runs on a timer here: the colour
# override in particular is a theme write and must not fire every poll.
func _update_rec_ui() -> void:
	var clock := "%d:%02d" % [int(_rec_elapsed) / 60, int(_rec_elapsed) % 60]
	var want: String
	if _rec_active:
		want = clock
	else:
		var m := _rec_remaining_minutes()
		want = "OFF" if m < 0.0 else "%dM" % int(m)
	if want == _rec_ui_last and _rec_active == _rec_ui_was_active:
		return
	if _cell_rec.size() >= 2 and _cell_rec[1] != null:
		var v := _cell_rec[1] as Label
		v.text = _nav_value(want)
		if _rec_active != _rec_ui_was_active:
			v.add_theme_color_override("font_color", M8_RED if _rec_active else M8_TEXT)
	if _lbl_rec != null:
		_lbl_rec.visible = _rec_active
		_lbl_rec.text = "REC %s" % clock
	if _dot_rec != null:
		_dot_rec.visible = _rec_active and _rec_blink_on
	_rec_ui_last = want
	_rec_ui_was_active = _rec_active


# The dot blinks on a 1 Hz timer, NOT a per-frame write — everything in
# _process here is change-gated and a recording indicator is no reason to
# break that.
func _rec_blink() -> void:
	_rec_blink_on = not _rec_blink_on
	if _dot_rec != null:
		_dot_rec.visible = _rec_active and _rec_blink_on


func _set_display_mode(mode: int) -> void:
	_display_mode = clampi(mode, 0, DISPLAY_MODE_NAMES.size() - 1)
	_apply_display_mode()
	_refresh_perf_strip()   # MIRROR projects the phone screen — the strip must go
	_settings_dirty = true
	# Switching to MIRROR after a Presentation was created this session: the HDMI
	# display is stuck in "extend" mode, so mirroring stays blank until a replug.
	if _display_mode == DisplayMode.MIRROR and _hdmi_presentation_active:
		_flash_status("MIRROR — REPLUG HDMI OR RESTART APP TO MIRROR")
	else:
		_flash_status("DISPLAY: %s" % _display_mode_label())


# Three states on one button: DUAL·TEX -> DUAL·PLAYER -> MIRROR -> DUAL·TEX.
func _cycle_display_mode() -> void:
	if _display_mode == DisplayMode.DUAL and _dual_feed == DualFeed.TEXTURE:
		_dual_feed = DualFeed.PLAYER
		_set_display_mode(DisplayMode.DUAL)
	elif _display_mode == DisplayMode.DUAL:
		_set_display_mode(DisplayMode.MIRROR)
	else:
		_dual_feed = DualFeed.TEXTURE
		_set_display_mode(DisplayMode.DUAL)


## True when the preview should COVER-crop the 16:9 output to fill the phone
## framebuffer — MIRROR + COVER only. This is the single source of truth both the
## preview TextureRect and the editor output→screen transform read, so the warp/
## mask overlays stay aligned with the cropped image the projector actually shows.
func _preview_covers() -> bool:
	return _display_mode == DisplayMode.MIRROR and _mirror_fill == MirrorFill.COVER


## Point the preview at the current fill mode. COVER fills the framebuffer (crops
## top/bottom); FIT/DUAL show the whole 16:9 frame (letterbox).
func _apply_preview_fill() -> void:
	if _preview != null:
		_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED \
			if _preview_covers() else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if _btn_mirror_fill != null:
		_btn_mirror_fill.text = "Mirror fill: %s" % MIRROR_FILL_NAMES[_mirror_fill]


func _set_mirror_fill(mode: int) -> void:
	_mirror_fill = clampi(mode, 0, MIRROR_FILL_NAMES.size() - 1)
	_apply_preview_fill()
	_settings_dirty = true
	if _display_mode == DisplayMode.MIRROR:
		_flash_status("MIRROR FILL: %s" % MIRROR_FILL_NAMES[_mirror_fill].to_upper())
	else:
		# No visible effect until MIRROR — say so rather than flash a no-op.
		_flash_status("MIRROR FILL: %s (APPLIES IN MIRROR)" % MIRROR_FILL_NAMES[_mirror_fill].to_upper())


func _cycle_mirror_fill() -> void:
	_set_mirror_fill((_mirror_fill + 1) % MIRROR_FILL_NAMES.size())


# --- UI flip -------------------------------------------------------------

## Rotate the PHONE window 180° (landscape <-> reverse-landscape). No-op off
## Android: screen_set_orientation is only implemented on the handheld backends,
## so the editor/desktop build ignores it rather than erroring.
func _apply_ui_flip() -> void:
	DisplayServer.screen_set_orientation(DisplayServer.SCREEN_REVERSE_LANDSCAPE \
		if _ui_flipped else DisplayServer.SCREEN_LANDSCAPE)


func _set_ui_flip(on: bool) -> void:
	_ui_flipped = on
	_apply_ui_flip()
	_settings_dirty = true
	# The window size is IDENTICAL either way (2400x1080 both orientations), so
	# no size_changed fires and nothing needs repositioning. But the GL surface
	# can be rebuilt under us by the orientation change, and a stale GLuint shows
	# on the projector as a raw decoder texture — the exact failure
	# _refresh_output_texture documents. Re-send on the same terms as the resume
	# path. The ~4 Hz poll in _process would catch it within 15 frames anyway;
	# this just closes the window where the projector shows garbage.
	if _tex_output_active:
		_send_output_texture()
	_flash_status("UI FLIP: %s" % ("180 (HUB RIGHT)" if on else "OFF"))


# --- DDP output ----------------------------------------------------------

## Create the sink and point it at OutputWorld. Called from _ready AFTER the
## output viewport exists (DDP_OUTPUT_SPEC.md §4 step 3).
##
## The node is created unconditionally because a bare Node costs nothing and it
## keeps the enable path a single boolean rather than a build-on-first-use
## branch that has to be got right twice. The EXPENSIVE part — the two tap
## SubViewports — is what stays unbuilt until `enabled` goes true.
func _build_ddp() -> void:
	# Pro only. LifeSource is built here too because the LED panel is its only
	# consumer today — without the panel there is nothing to show it on.
	if not Features.LED_DDP:
		return
	_ddp = DdpOutput.new()
	_ddp.name = "DdpOutput"
	add_child(_ddp)
	# MIRROR: the same SubViewport the EGL bridge blits, so the panel and the
	# projector show the same composited frame. Reading a viewport's texture does
	# not disturb it, which is what lets this hang off the live output path.
	_ddp.set_source(output_world)
	_ddp.target_ip = _ddp_target_ip
	_ddp.send_fps = _ddp_send_fps
	_ddp.fit_mode = _ddp_fit_mode

	# The automaton. Built alongside the sink rather than lazily on selection: it
	# owns a 64x64 viewport (16 KB of render target) and stops stepping when it
	# is not the selected source, so idle cost is a stopped _process and nothing
	# else. Building it up front keeps the source switch instant, which matters
	# when the switch happens mid-set.
	_life = LifeSource.new()
	_life.name = "LifeSource"
	add_child(_life)
	_ddp.set_independent_source(_life.get_viewport_source())
	_apply_life_rate()
	_life.set_bpm(BeatClock.bpm)
	# Wired once and left alone: on_beat() is a no-op in FREE mode and while the
	# sim is stopped, so there is no subscribe/unsubscribe dance to get wrong.
	BeatClock.beat.connect(func(_i: int): _life.on_beat())
	BeatClock.bpm_changed.connect(func(v: float): _life.set_bpm(v))
	_life.rule_changed.connect(func(_id: String, label: String, spec: String) -> void:
		if _btn_life_rule != null:
			_btn_life_rule.text = "Life rule: %s" % label
		# Only announce mid-set when the panel is actually showing it — otherwise
		# a cycling automaton nobody is watching would flash the status line.
		if _ddp_source == 1 and _ddp_enabled:
			_flash_status("LIFE: %s (%s)" % [label.to_upper(), spec]))
	_apply_ddp_source()
	_ddp.output_failed.connect(func(reason: String) -> void:
		# Surfaced, never fatal: a missing panel must not take the deck with it.
		push_warning("[ddp] output failed: %s" % reason)
		_flash_status("LED PANEL: %s" % reason.to_upper()))
	# Restored state is applied LAST so a failed open can clear the flag without
	# racing the assignments above.
	_ddp.set_enabled(_ddp_enabled)


# --- VIDEO LINK (Stage 0) --------------------------------------------------

func _build_link() -> void:
	if not Features.TD_PVJ_LINK or not _link_enabled:
		return
	# Re-entrant since the panel toggle: built at boot OR after a mid-run
	# teardown, never twice — the beacon is created unconditionally below, so
	# its ref is the "already built" marker.
	if _link_beacon != null:
		return
	var display_name := _link_name
	if display_name == "":
		# "Pixel 8" / "Pixel 9a" — unique across this rig, stable across boots.
		display_name = OS.get_model_name()

	# A rebuilt link is a new session: no provider on record, no operator
	# STOP left armed to silently suppress the auto-pull, and no tripwire
	# marks — the peer that earned one may have upgraded across the rebuild.
	_link_pull_stopped = false
	_link_rx_ip = ""
	_link_rx_stream = -1
	_td_rx_ip = ""
	_link_rx_name = ""
	_td_rx_name = ""
	_link_pre_m2.clear()

	_link_beacon = LinkBeacon.new()
	_link_beacon.name = "LinkBeacon"
	add_child(_link_beacon)

	_link_control = LinkControl.new()
	_link_control.name = "LinkControl"
	add_child(_link_control)
	if _link_control.listen(LINK_CTRL_PORT) != OK:
		push_warning("[link] control port %d refused — remote start/stop dead" % LINK_CTRL_PORT)

	# The sender exists on every role; what it captures is decided per request
	# (stream 0 = composited output, stream 1 = camera). Built up front so a
	# "start" landing seconds after boot has something to talk to.
	_net_sender = NetSender.new()
	_net_sender.name = "NetSender"
	add_child(_net_sender)
	_net_sender.set_encoder_feed(_link_encoder_feed)
	# §9-M8: tell the plugin the configured SRT ARQ window (both directions)
	# before anything dials. Probe by CALLING — a pre-M8 APK answers null and
	# keeps its baked 120 ms (the has_method/JNI lesson, again).
	if Engine.has_singleton("PocketVJVideoLink"):
		var lat_ans: Variant = Engine.get_singleton("PocketVJVideoLink").call(
			"set_srt_latency", _srt_latency_ms)
		if lat_ans == null:
			push_warning("[link] APK predates set_srt_latency — SRT window stays 120 ms")
	if _link_debug_counter:
		_net_sender.set_debug_counter(true)
		_build_link_debug_label()

	var recv_port := 0
	if _link_role == "main":
		_net_source = NetSource.new()
		_net_source.name = "NetSource"
		add_child(_net_source)
		# Codec BEFORE listen (it selects the whole body). set_codec falls back
		# to jpeg with one warning when the plugin is absent — desktop, or an
		# APK from before Stage 1 — so everything after this line asks the
		# EFFECTIVE codec, never the setting: port, layer shader, beacon line.
		_net_source.set_codec(_link_codec)
		var video_port := LINK_H264_PORT if _net_source.get_codec() == "h264" \
				else LINK_VIDEO_PORT
		if _net_source.listen(video_port) == OK:
			recv_port = video_port
			if _net_source.get_codec() == "h264":
				# The §6.4 tripwire: a pre-milestone-2 sender ignores the codec
				# field and aims MJPEG/UDP at this SAME port number, where the
				# plugin's TCP listener can never see it — but a UDP socket
				# can, and one datagram IS the diagnosis. Drained on the pull
				# tick (3 s is plenty; this is a detector, not a feed), and a
				# bind failure is survivable for the same reason: one warning,
				# no retry loop.
				_link_tripwire = PacketPeerUDP.new()
				if _link_tripwire.bind(video_port, "*") != OK:
					push_warning("[link] tripwire UDP %d refused — pre-M2 senders go undetected" % video_port)
					_link_tripwire = null
		else:
			push_warning("[link] video port %d refused — receiving dead" % video_port)
		_build_link_layer()
		_net_source.state_changed.connect(_on_link_freshness)
		# Boot-order race (session 26 bug 3): peer_appeared fires ONCE per
		# appearance, but the cam phone is deaf for ~35 s of shader-cache cold
		# boot — a request landing in that window is lost until relaunch. So
		# the auto-pull is a standing reflex, not an event: every 3 s, if a cam
		# peer is visible and our stream is still LOST, ask again. The tick
		# no-ops the moment frames arrive and wakes on its own when freshness
		# decays back to LOST — which also self-heals a cam-app restart
		# mid-show. A Timer, not _process: 3 s cadence, not frame spam.
		_link_pull_timer = Timer.new()
		_link_pull_timer.name = "LinkPullTimer"
		_link_pull_timer.wait_time = 3.0
		_link_pull_timer.autostart = true
		_link_pull_timer.timeout.connect(_on_link_pull_tick)
		add_child(_link_pull_timer)

	# The advertised codec is the receive side's EFFECTIVE one (post-fallback);
	# a role with no receiver advertises the Stage 0 default — with port 0 the
	# field is moot, but a parseable line must still say something true-shaped.
	var adv_codec: String = _net_source.get_codec() if _net_source != null \
			else LinkBeacon.BEACON_CODEC
	_link_beacon.configure(display_name, _link_role, recv_port, LINK_CTRL_PORT, adv_codec)
	_link_beacon.peer_appeared.connect(_on_link_peer_appeared)
	_link_beacon.peer_lost.connect(func(peer_name: String) -> void:
		_flash_status("LINK LOST: %s" % peer_name.to_upper()))
	# One coarse signal redraws the whole panel list — appear, lose, or a peer's
	# ip/role/ports moving under the same name all land as a rebuild.
	_link_beacon.peers_changed.connect(_refresh_link_peer_rows)
	_link_control.stream_requested.connect(_on_link_stream_requested)
	_link_control.stream_stopped.connect(func(_stream_id: int, remote_ip: String) -> void:
		# Scoped to the asker: a stop removes THAT peer's destination, and the
		# stream (and camera) only wind down when the last consumer is gone —
		# TD saying stop must not black out the main phone's cam layer.
		if _net_sender != null:
			_net_sender.stop_target(remote_ip)
			if _net_sender.is_active():
				return
		# Power the camera down ONLY if the link was the reason it ran — the
		# deck's own CAMERA source keeps it regardless.
		if _link_uses_camera:
			_link_uses_camera = false
			if _source != ClipSource.CAMERA:
				camera_engine.stop()
		_flash_status("LINK SEND: STOPPED"))
	# N4 (SEQ2 Stage 2): the shared grid + remote sequencer triggers ride the
	# same ctrl wire. Handlers carry their own role checks — a master ignores
	# incoming beat lines (R4: the authority chain has one head).
	_link_control.beat_received.connect(_on_link_beat)
	_link_control.seq_received.connect(_on_link_seq)

	# Bottom-bar stats cadence. NetSender.get_stats() measures fps/kbps over
	# the window since the PREVIOUS call, so a steady ~1 Hz poll IS the
	# measurement — sampling faster would only add noise. A Timer, like the
	# FPS readout's sampling: the bottom bar never earns per-frame writes.
	_link_stats_timer = Timer.new()
	_link_stats_timer.name = "LinkStatsTimer"
	_link_stats_timer.wait_time = 1.0
	_link_stats_timer.autostart = true
	_link_stats_timer.timeout.connect(_update_link_stats)
	add_child(_link_stats_timer)

	# The panel's peer list exists whether or not the link does — repaint it now
	# that there is a beacon behind it (boot builds the panel first).
	_refresh_link_peer_rows()


## The received stream, composited over everything output_world holds. LAST
## child = drawn on top; the warp/mask stack stays untouched underneath, so a
## dead link degrades to exactly the show that ran before the link existed.
func _build_link_layer() -> void:
	_link_layer = _make_link_layer(_net_source, "NetLayer")
	output_world.add_child(_link_layer)


## One over-the-top layer for one NetSource (Stage 3.2: the peer slot and the
## TD slot each get one).
func _make_link_layer(ns: NetSource, layer_name: String) -> TextureRect:
	var layer := TextureRect.new()
	layer.name = layer_name
	if ns.get_codec() == "h264":
		# Stage 1: the texture is an ExternalTexture and must NOT be assigned
		# here (see LINK_OES_SHADER). The TextureRect instead draws a 1x1 WHITE
		# placeholder — geometry for the material to run over, and white so the
		# vertex COLOR the shader inherits is exactly modulate (alpha slider) —
		# while the video arrives through the samplerExternalOES uniform.
		var img := Image.create(1, 1, false, Image.FORMAT_RGB8)
		img.fill(Color.WHITE)
		layer.texture = ImageTexture.create_from_image(img)
		var sh := Shader.new()
		sh.code = LINK_OES_SHADER
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mat.set_shader_parameter("link_tex", ns.get_texture())
		layer.material = mat
	else:
		layer.texture = ns.get_texture()
	layer.stretch_mode = TextureRect.STRETCH_SCALE
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.modulate.a = _link_layer_alpha
	layer.visible = false   # nothing to show until the first frame lands
	return layer


## The alpha a peer's layer shows: its own saved level, or the default for a
## peer nobody has adjusted — which is where the pre-3.3 single slider's value
## lives on, so an upgrade changes nothing on screen.
func _alpha_for_peer(peer_name: String) -> float:
	return clampf(float(_peer_alpha.get(peer_name, _link_layer_alpha)), 0.0, 1.0)


## Push each slot's provider level onto its layer. Idempotent; called when a
## provider or a level changes, never per frame. The lane B face is NOT touched:
## its modulate.a is the crossfade and belongs to the operator (hazard 5).
func _apply_link_layer_alphas() -> void:
	if _link_layer != null:
		_link_layer.modulate.a = _alpha_for_peer(_link_rx_name)
	if _td_layer != null:
		_td_layer.modulate.a = _alpha_for_peer(_td_rx_name)
	if _perf_strip != null:
		_perf_strip.set_levels(_link_rx_name, _alpha_for_peer(_link_rx_name),
				_td_rx_name, _alpha_for_peer(_td_rx_name))


func _set_peer_alpha(peer_name: String, v: float, announce: bool = true) -> void:
	_peer_alpha[peer_name] = clampf(v, 0.0, 1.0)
	_settings_dirty = true
	_apply_link_layer_alphas()
	var slot := "none"
	if peer_name != "" and peer_name == _td_rx_name:
		slot = "td"
	elif peer_name != "" and peer_name == _link_rx_name:
		slot = "peer"
	# One line per stepper tap (the slider is drag-immune): the log is how a
	# device run proves the level landed on the RIGHT slot — a capture of a
	# playing deck cannot.
	if announce:   # false mid-drag (PERF strip): the release logs the landing value once
		print("[link] alpha %s = %.2f (slot: %s)" % [peer_name, _alpha_for_peer(peer_name), slot])


## The TD slot, built on first use (see _net_source_td). false = no receive side
## to hang it on (link off, or this phone is a cam) — callers refuse out loud.
func _ensure_td_source() -> bool:
	if _net_source_td != null:
		return true
	if _net_source == null or _link_control == null:
		return false
	_net_source_td = NetSource.new()
	_net_source_td.name = "NetSourceTD"
	add_child(_net_source_td)
	# Always h264: SRT is h264-only by construction, whatever the PEER link's
	# codec setting says — a jpeg phone↔phone rig can still pull TD. With no
	# plugin this stays jpeg and pull_srt refuses out loud, same as before.
	_net_source_td.set_codec("h264")
	_net_source_td.state_changed.connect(_on_td_freshness)
	_td_layer = _make_link_layer(_net_source_td, "TdLayer")
	output_world.add_child(_td_layer)
	# Directly above the peer layer, wherever that sits: inherit its place in
	# the chain (post-warp, and wherever it stands against the mask overlay)
	# instead of landing LAST by accident of build order and quietly changing
	# what draws over what.
	if _link_layer != null:
		output_world.move_child(_td_layer, _link_layer.get_index() + 1)
	return true


## TD-slot twin of _on_link_freshness: the same R5 law (LOST hides, the deck
## never degrades), scoped to the TD layer and — while lane B rides TD — the B face.
func _on_td_freshness(state: int) -> void:
	if _s4 != null:
		_s4.note("td slot %s" % LINK_FRESH_NAMES[state])
	_refresh_link_layer_visibility()
	if _lane_b_armed and _lane_b_source == LaneBSource.TD and _deck_b_rect != null:
		_deck_b_rect.visible = state != NetSource.Freshness.LOST
	match state:
		NetSource.Freshness.LIVE:
			_flash_status("TD: LIVE")
		NetSource.Freshness.LOST:
			_flash_status("TD: LOST")


## The LOCAL half of the latency measurement (spec §9): the sender's own live
## clock on the sender's own screen. Photograph both phones in ONE shot — the
## receiver shows the timestamp NetSender burned in at capture, this label
## shows the same clock at shutter time, and the difference IS glass-to-glass
## latency in ms, no frame-rate math.
## ⚠️ CLOCK CAVEAT: ticks_msec is per-device — the two phones' counters share
## no epoch. The diff only works because BOTH numbers in the photo come from
## the SENDER's clock: the burned one travelled the link, this one didn't. Do
## not "fix" this into a label on the receiver, or into comparing the two
## devices' clocks — that difference is boot-time skew, not latency.
func _build_link_debug_label() -> void:
	if _link_debug_lbl != null:
		return   # rebuild after teardown only — never a second clock on screen
	_link_debug_lbl = Label.new()
	_link_debug_lbl.name = "LinkDebugClock"
	# Same face as the burned-in stamp (NetSender.set_debug_counter): the two
	# numbers in the photo should be read the same way, off the same glyphs.
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["monospace"])
	_link_debug_lbl.add_theme_font_override("font", f)
	_link_debug_lbl.add_theme_font_size_override("font_size", 48)
	_link_debug_lbl.add_theme_color_override("font_color", Color.WHITE)
	_link_debug_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	_link_debug_lbl.add_theme_constant_override("outline_size", 10)
	_link_debug_lbl.position = Vector2(12, 12)
	_link_debug_lbl.visible = false   # only while this device is actually sending
	# CHROME, not a root CanvasLayer: in MIRROR mode the phone screen IS the
	# projector, and Performance Mode's only lever is hiding _chrome_layer — a
	# clock parented anywhere else survives the three-finger tap and ticks in
	# 48px monospace over the wall with no touch way to remove it. Added last,
	# so it draws over the bars it measures past.
	_chrome_layer.add_child(_link_debug_lbl)


func _on_link_freshness(state: int) -> void:
	if _s4 != null:
		_s4.note("peer slot %s" % LINK_FRESH_NAMES[state])   # a LOST mid-run spoils its windows
	if _link_layer == null:
		return
	# LIVE shows, STALE holds the last frame (a WiFi hiccup must not strobe the
	# layer), LOST hides — spec R5: the remote layer degrades, the deck never.
	# Lane B ownership folds into the same rule (_refresh_link_layer_visibility);
	# while lane B owns the stream, freshness drives the B FACE instead — its
	# visibility only, never the crossfade (the mix degrades to pure deck A).
	_refresh_link_layer_visibility()
	if _lane_b_armed and _lane_b_source == LaneBSource.NET and _deck_b_rect != null:
		_deck_b_rect.visible = state != NetSource.Freshness.LOST
	match state:
		NetSource.Freshness.LIVE:
			_flash_status("LINK: LIVE")
		NetSource.Freshness.LOST:
			_flash_status("LINK: LOST")


func _on_link_peer_appeared(peer_name: String) -> void:
	# Teardown nulls these refs, but the queue-freed beacon keeps draining its
	# socket (and can emit) until end of frame — the same window every other
	# link handler already guards against.
	if _link_beacon == null or _link_control == null:
		return
	var peer: Dictionary = _link_beacon.get_peer(peer_name)
	_flash_status("LINK PEER: %s (%s)" % [peer_name.to_upper(), str(peer.get("role", "?")).to_upper()])
	# A fresh appearance clears the tripwire mark (§6.4): the upgrade path is
	# an app reinstall/restart, which is a >TTL beacon gap — the new build
	# gets one chance, and a still-pre-M2 peer just trips the wire again.
	_link_pre_m2.erase(str(peer.get("ip", "")))
	# S2 with zero UI: the moment a camera phone shows up, the main phone pulls
	# its feed. One knob ([link] auto_pull_cam) turns the reflex off — and so
	# does an operator STOP (_link_pull_stopped), even across a cam-app restart.
	# (Milestone 1's h264 stand-down is gone: the request now carries our
	# codec, and _link_pull_from aims the sender at the matching port.)
	if _link_role == "main" and _link_auto_pull_cam and not _link_pull_stopped \
			and str(peer.get("role", "")) == "cam" and _net_source != null:
		# N2: the reflex must not outvote the operator's DECK pull. A beacon
		# gap (WiFi hiccup, peer app restart) re-fires this appearance — while
		# a stream-0 pull is the LIVE provider, re-asking for the cam here
		# would silently swap lane B from the peer's deck to its camera.
		if _link_rx_stream == 0 and _net_source.freshness() != NetSource.Freshness.LOST:
			return
		# ...and when the drop DID happen (LOST — e.g. the peer app restarted),
		# heal back to the stream the operator chose, same rule as the retry
		# tick: a 9a crash mid-set must not come back as the camera when lane B
		# was riding its deck.
		var sid := 0 if (str(peer.get("ip", "")) == _link_rx_ip
				and _link_rx_stream == 0) else 1
		_link_pull_from(str(peer_name), peer, sid)


## The retry half of the auto-pull (the fast path is _on_link_peer_appeared).
## Only re-asks while there is nothing to lose: any freshness above LOST means
## a pull already landed, and a duplicate start would restart a healthy stream.
func _on_link_pull_tick() -> void:
	# The tripwire outranks every auto-pull guard below: a pre-M2 sender
	# burns whether or not the reflex is armed (a manual PULL starts one
	# just as well), and this tick is the only cadence it drains on.
	_drain_link_tripwire()
	if _link_role != "main" or not _link_auto_pull_cam:
		return
	# The operator's STOP outranks the reflex: without this latch the retry
	# re-pulls the exact stream a STOP tap just killed, ~5 s later, forever.
	if _link_pull_stopped:
		return
	if _link_beacon == null or _link_control == null or _net_source == null:
		return
	# (Milestone 1's codec stand-down lived here; milestone 2 removed it —
	# the request carries our codec now, and an M2 cam serves h264 back.)
	# Port never bound (taken by another instance): retrying would make the cam
	# burn encode + WiFi into a dead socket every 3 s. _build_link warned once;
	# re-flashing here at tick rate would be spam, so just stand down.
	if not _net_source.is_listening():
		return
	if _net_source.freshness() != NetSource.Freshness.LOST:
		return
	var peers := _link_beacon.get_peers()
	for peer_name in peers:
		var peer: Dictionary = peers[peer_name]
		if str(peer.get("role", "")) != "cam":
			continue
		if _link_pre_m2.has(str(peer.get("ip", ""))):
			# Tripwire-marked (§6.4): it answered our codec with MJPEG at the
			# TCP port. Re-asking would only restart that burn — stand down
			# until its beacon reappears (the appearance clears the mark).
			continue
		# Same request as the fast path; the cam side treats a repeat start as
		# a restart, so hitting one that is already warming up costs nothing.
		# N2: if the LOST provider was this peer's DECK (stream 0), re-ask for
		# THAT — the operator chose it, and healing a drop must not change the
		# source. Any other case keeps the reflex's cam ask.
		var sid := 0 if (str(peer.get("ip", "")) == _link_rx_ip
				and _link_rx_stream == 0) else 1
		_link_pull_from(str(peer_name), peer, sid)
		return


## The §6.4 pre-milestone-2 tripwire. Any datagram on the h264 port number is
## a sender aiming MJPEG at a TCP listener that will never see it — a peer
## that ignored the codec field in our start, now paying readback + encode +
## WiFi into nothing, forever, because the pull path never stops a stream
## that never fed it (the sender-side twin of the dead-port burn the
## is_listening() refusal exists for). Tell it to stop, mark its ip so the
## retry stops re-arming the burn, and say so on screen — the operator is
## the one who can actually fix it (upgrade the peer's APK).
func _drain_link_tripwire() -> void:
	if _link_tripwire == null:
		return
	var hit_ip := ""
	while _link_tripwire.get_available_packet_count() > 0:
		_link_tripwire.get_packet()   # content is MJPEG chunks — arrival IS the fact
		hit_ip = _link_tripwire.get_packet_ip()
	if hit_ip == "" or _link_pre_m2.has(hit_ip):
		return
	_link_pre_m2[hit_ip] = true
	# The ctrl port comes from the live beacon table, not the provider-on-
	# record (that may have moved on already). No beacon entry means no
	# address to aim a stop at — the mark alone still ends the re-asking,
	# which is what keeps the burn alive.
	if _link_control != null and _link_beacon != null:
		var peers := _link_beacon.get_peers()
		for peer_name in peers:
			var peer: Dictionary = peers[peer_name]
			if str(peer.get("ip", "")) == hit_ip:
				_link_control.send_stop(hit_ip, int(peer["ctrl_port"]),
						_link_rx_stream if hit_ip == _link_rx_ip else 1)
				break
	if hit_ip == _link_rx_ip:
		_link_rx_ip = ""      # nothing owed a stop at teardown — it just got one
		_link_rx_stream = -1
	_flash_status("LINK: PEER %s IS PRE-M2 — MJPEG AT TCP PORT, STOPPED" % hit_ip)


## One door for every pull, manual or reflex. Owns the bookkeeping a request
## must never skip: the provider on record (STOP and teardown owe that peer a
## stop), NetSource's stream filter (4851 is ONE reassembler — a second sender
## interleaving it makes both streams abandon nearly every frame, so the moment
## we ask for a stream, everything else is refused at ingest), and a stop to
## the previous provider when the pull moves. Refuses outright when the receive
## port never bound — a request then would aim a sender at a port nobody
## opened: the silent black nothing.
func _link_pull_from(peer_name: String, peer: Dictionary, stream_id: int) -> void:
	if _link_control == null or _net_source == null:
		return
	var peer_ip := str(peer.get("ip", ""))
	var peer_ctrl_port := int(peer.get("ctrl_port", 0))
	if str(peer.get("codec", "")) == "srt":
		# The TD leg (M3 S1): the peer's beacon advertises an SRT video
		# LISTENER, so WE dial it — no 'start' request at all; the plugin's
		# srt_arm doorbell on the peer's control port IS the start, and its
		# dial loop re-rings it on every drop. h264-only by construction
		# (pull_srt refuses jpeg-fallback builds out loud).
		# Stage 3.2: into the TD SLOT. The phone↔phone listener is no longer
		# displaced (the plugin holds both receivers), so the peer's layer,
		# stream filter and provider record are not touched here at all.
		if not _ensure_td_source():
			_flash_status("LINK: SRT PULL FAILED (NO RECEIVE SIDE)")
			return
		# Validate-then-retire (the refusals-before-teardown rule): pull_srt
		# runs every gate and swaps the TD receiver FIRST; only a successful
		# swap disarms a DIFFERENT TD we were dialling before.
		var err: Error = _net_source_td.pull_srt(peer_ip,
				int(peer.get("video_port", 0)), peer_ctrl_port)
		if err != OK:
			_flash_status("LINK: SRT PULL FAILED (SEE LOG)")
			return
		if _td_rx_ip != "" and _td_rx_ip != peer_ip:
			_link_control.send_srt_disarm(_td_rx_ip, _td_rx_ctrl_port)
		_td_rx_ip = peer_ip
		_td_rx_ctrl_port = peer_ctrl_port
		_td_rx_name = peer_name
		_apply_link_layer_alphas()   # THIS TD's level, not the last provider's
		return
	# (Stage 3.2: an SRT pull used to be retired here before any tcp/jpeg ask,
	# because its dialer had replaced the TCP listener. It no longer does.)
	# The request carries OUR effective codec and its port (§6.4, milestone
	# 2): the sender picks the body that matches where it is being aimed.
	# The one honest gap is a pre-milestone-2 peer, which ignores the field
	# and aims MJPEG/UDP at the TCP port, where it silently vanishes — the
	# layer just stays LOST and the retry keeps asking, the same visible
	# failure as any dead sender (the spec says so out loud).
	var codec := _net_source.get_codec()
	var video_port := LINK_H264_PORT if codec == "h264" else LINK_VIDEO_PORT
	if not _net_source.is_listening():
		_flash_status("LINK: PORT %d NOT BOUND — CANNOT RECEIVE" % video_port)
		return
	if _link_rx_ip != "" and (_link_rx_ip != peer_ip or _link_rx_stream != stream_id):
		# One port, one stream: the old provider must stop, or it keeps paying
		# encode + WiFi to feed a filter that now drops its every packet.
		_link_control.send_stop(_link_rx_ip, _link_rx_ctrl_port, _link_rx_stream)
	_net_source.stream_filter = stream_id
	_link_rx_ip = peer_ip
	_link_rx_ctrl_port = peer_ctrl_port
	_link_rx_stream = stream_id
	_link_rx_name = peer_name
	_apply_link_layer_alphas()   # THIS peer's level, not the last provider's
	var fps := LINK_H264_FPS if codec == "h264" else LINK_JPEG_FPS
	_link_control.request_stream(peer_ip, peer_ctrl_port, stream_id, "",
			video_port, fps, 0.75, codec)


func _on_link_stream_requested(stream_id: int, dest_ip: String, dest_port: int,
		fps: float, quality: float, codec: String, transport: String) -> void:
	if _net_sender == null:
		return
	# The codec is the REQUESTER's (§6.4 — it says what dest_port speaks);
	# NetSender refuses an ask it cannot honour — no send plugin, or the
	# other codec's consumers still hold the stream (§6.6) — which beats
	# aiming the wrong bytes at it. start() answers for THIS CALL, and only
	# it: is_active() was the old check here and it lies whenever some other
	# stream (say, jpeg to a different peer) is still running — a refusal
	# would flash success naming a peer whose layer stays LOST. The refusal
	# must also reach the OPERATOR's eyes — NetSender's warning only reaches
	# logcat, and a flash claiming a send that never started is how a dead
	# link looks healthy on stage.
	# start() BEFORE any source retarget, deliberately: the sender's one
	# shared SubViewport is what a SURVIVING stream keeps capturing, so a
	# refused ask that had already swapped the source (camera↔output-world)
	# would permanently change what the surviving consumer sees — and with a
	# retrying srt asker (pre-M3 or cpu-feed build) that's a steady state,
	# not a one-off. start() never reads the source synchronously (the next
	# capture tick does), so arming it after success loses nothing.
	if not _net_sender.start(dest_ip, dest_port, stream_id, fps, quality, codec, transport):
		# Nothing to undo: the source was not retargeted and the camera was
		# not armed for an ask that never started.
		_flash_status("LINK SEND: %s REFUSED (NO PLUGIN OR CODEC CLASH)" % codec.to_upper())
		return
	match stream_id:
		1:
			# The deck's own camera engine — already on-device-proven, already
			# handling the Android format/datatype traps, and already running
			# whenever the deck source is CAMERA. start() is idempotent; the
			# permission dialog (first run only) is handled inside it, and its
			# retry loop makes a request-before-grant recover on its own.
			# ⚠️ M6 routes here too: before this, a cam-role PULL opened
			# CameraServer with NO tracking gate at all — the one remaining
			# door to the Session-33 wedge, and the reason the gate had to
			# become routing rather than a second refusal.
			_cam_via_tracking = _track_camera != null and _tracking != null \
					and _tracking.is_running()
			if _cam_via_tracking:
				camera_engine.stop()
				_track_camera.start()
			else:
				camera_engine.start()
			_link_uses_camera = true
			_net_sender.set_source(_cam_texture())
		_:
			_net_sender.set_source(output_world.get_texture())
	_flash_status("LINK SEND: STREAM %d -> %s (%s)" % [stream_id, dest_ip, codec.to_upper()])


# --- N4: one clock, two phones + remote triggers (SEQ2 §3.4 / Stage 2) ----

## Master send, once per bar (and immediately on tempo change / tap). The
## MAIN phone is always tempo master (it is the mixing seat). Slaves: role
## "cam" phones (law v2) and role "td" peers (TD applies the stamp to its
## PVJ Grid pars — the Stage 2 TD half). TD never masters back, so widening
## the fan-out cannot create a second authority.
func _send_link_beat() -> void:
	if _link_role != "main" or _link_control == null or _link_beacon == null:
		return
	var peers := _link_beacon.get_peers()
	for peer_name in peers:
		var peer: Dictionary = peers[peer_name]
		var role := str(peer.get("role", ""))
		if role != "cam" and role != "td":
			continue
		_link_control.send_beat(str(peer.get("ip", "")), int(peer.get("ctrl_port", 0)),
			BeatClock.bpm, _bc_beat_index, _bc_bar_index, BeatClock.phase)


## The shared downbeat: master shares the grid; everyone drains bar-quantized
## remote asks. (One handler for both so the ordering is fixed: the asks land
## ON the downbeat the message promised.)
func _on_beatclock_bar_link(index: int) -> void:
	_bc_bar_index = index
	_send_link_beat()
	if _seq_pending.is_empty():
		return
	var pending := _seq_pending
	_seq_pending = []
	for act in pending:
		_apply_remote_seq(act)


## Slave law — spike S3's law v2 EXACTLY (the naive per-message law is dead:
## it chased the network, p95 120 ms, 8 snap/counter-snap pairs). Median-5
## filter before acting; 20 ms deadband; corrections spread over 2 bars via
## BeatClock.slew; snap ONLY on a filtered half-beat. phase_trim_ms owns the
## fixed one-way delivery bias (measured ~15 ms on this WiFi in S3).
func _on_link_beat(bpm: float, _beat_i: int, _bar_i: int, mphase: float) -> void:
	if _link_role == "main":
		return   # R4: the authority chain has one head — masters take no grid
	_beat_rx_count += 1
	# Distribution, not estimation: the value WAS human-set, on the master.
	if bpm >= BeatClock.BPM_MIN and absf(bpm - BeatClock.bpm) > 0.01:
		BeatClock.set_bpm(bpm)
		print("[beat] master bpm %.1f" % bpm)
	var bar_secs := 60.0 / BeatClock.bpm * float(BeatClock.beats_per_bar)
	var target := mphase + (_phase_trim_ms / 1000.0) / bar_secs
	var err := (BeatClock.phase - target) * bar_secs
	err = fposmod(err + bar_secs * 0.5, bar_secs) - bar_secs * 0.5
	_beat_errs.append(err)
	if _beat_errs.size() > 5:
		_beat_errs.pop_front()
	if _beat_errs.size() < 3:
		return   # law v2's first rule: FILTER BEFORE ACTING
	var s := _beat_errs.duplicate()
	s.sort()
	var med: float = s[s.size() / 2]
	if absf(med) > (60.0 / BeatClock.bpm) * 0.5:
		# The grids genuinely disagree (re-tapped master, resume from Android
		# pause). One clean jump beats a long audible... visible chase.
		BeatClock.snap_to_phase(target)
		_beat_errs.clear()
		print("[beat] SNAP (filtered err %+.0f ms)" % (med * 1000.0))
	elif absf(med) > 0.020:
		# Close the filtered error over 2 bars. Re-measured every bar, so this
		# is a proportional controller, not a stack of corrections.
		BeatClock.slew(-med, bar_secs * 2.0)
		print("[beat] nudge %+.1f ms (n=%d)" % [-med * 1000.0, _beat_rx_count])


## Remote sequencer ask arrived (SEQ2 §3.4): quantize to our next downbeat
## unless it says now. Applied via the same paths as the local widgets — a
## remote verb is just another widget.
func _on_link_seq(lane: String, op: String, slot: int, on: bool, at: String) -> void:
	var act := {"lane": lane, "op": op, "slot": slot, "on": on}
	if at == "now":
		_apply_remote_seq(act)
		return
	_seq_pending.append(act)
	_flash_status("LINK SEQ: %s %s @ BAR" % [op.to_upper(),
		str(slot) if op == "slot" else ("ON" if on else "OFF")])


func _apply_remote_seq(a: Dictionary) -> void:
	var lane_b := String(a.get("lane", "a")) == "b"
	match String(a.get("op", "")):
		"slot":
			if lane_b:
				_ensure_lane_b_model()
			_load_seq_slot_into(_lane_b if lane_b else _lane_a, int(a.get("slot", 1)))
		"auto":
			if lane_b:
				_set_lane_b_auto(bool(a.get("on", false)))
			else:
				_set_lane_a_auto(bool(a.get("on", false)))
				if _seq_strip != null and _strip_lane == 0:
					_seq_strip.set_auto(bool(a.get("on", false)))
		_:
			print("[seq] unknown remote op: %s" % str(a))


# --- OSC inbound (OSC_NAMESPACE_SPEC.md) -----------------------------------

func _build_osc() -> void:
	if not Features.OSC or not _osc_enabled:
		return
	_osc = OscInput.new()
	_osc.name = "OscInput"
	add_child(_osc)
	var err := _osc.listen(_osc_port)
	_sync_osc_rows()   # LIB ▸ OSC was built before the listener existed
	if err != OK:
		push_warning("[osc] port %d refused — OSC control dead" % _osc_port)
		return
	_osc.message.connect(_on_osc)


## The namespace map (spec §3). Every action lands on the SAME functions the
## panel rows call — OSC is another widget, like the link verbs before it.
## Laws (spec §2): /pvj/xfade IS a hand on the fader (demotes automation);
## /pvj/seq/* rides the link verbs' _seq_pending queue (bar-quantized);
## /pvj/bpm is human-set HERE — on the master, bpm_changed re-broadcasts to
## every slave and TD (conduct tempo THROUGH the authority, never around it).
func _on_osc(address: String, args: Array) -> void:
	match address:
		"/pvj/xfade":
			if args.size() >= 1:
				_set_xfade_manual(clampf(_osc_f(args[0]), 0.0, 1.0))
		"/pvj/xfade/mode":
			var m := _osc_index(args, XFADE_MODE_NAMES)
			if m >= 0:
				_set_xfade_mode(m)
				_flash_status("OSC: XFADE %s" % XFADE_MODE_NAMES[m])
		"/pvj/bpm":
			if args.size() >= 1:
				var bpm := _osc_f(args[0])
				if bpm >= BeatClock.BPM_MIN:
					BeatClock.set_bpm(bpm)
					_flash_status("OSC: BPM %.1f" % bpm)
		"/pvj/mode":
			var m2 := _osc_index(args, MODE_NAMES)
			if m2 >= 0:
				_set_mode(m2)
				_flash_status("OSC: MODE %s" % String(MODE_NAMES[m2]).to_upper())
		"/pvj/seq/slot":
			if args.size() >= 1:
				_seq_pending.append({"lane": _osc_lane(args, 1), "op": "slot",
					"slot": int(_osc_f(args[0])), "on": false})
				_flash_status("OSC: SLOT %d @ BAR" % int(_osc_f(args[0])))
		"/pvj/seq/auto":
			if args.size() >= 1:
				var on := _osc_f(args[0]) >= 0.5
				_seq_pending.append({"lane": _osc_lane(args, 1), "op": "auto",
					"slot": 0, "on": on})
				_flash_status("OSC: AUTO %s @ BAR" % ("ON" if on else "OFF"))
		"/pvj/lane_b/arm":
			if args.size() >= 1:
				_set_lane_b_armed(_osc_f(args[0]) >= 0.5)
		"/pvj/lane_b/source":
			var src := _osc_index(args, ["clip", "net", "td"])
			if src >= 0:
				_set_lane_b_source(src)   # LaneBSource.CLIP=0, NET=1 (peer), TD=2
		# Deck transport (SESSION_45): AT ONCE, like the button or the grid tap
		# it stands for — not bar-quantized. A cut on the beat is the sender's
		# job (send on the beat, or use /pvj/seq/slot, which IS quantized).
		# Same calls as the nav cells and the grid, so the warm-cue path and the
		# dead-clip skip come with them; the performer's next tap simply wins.
		"/pvj/deck/next":
			clip_engine.next_clip()
			_flash_status("OSC: NEXT")
		"/pvj/deck/prev":
			clip_engine.prev_clip()
			_flash_status("OSC: PREV")
		"/pvj/deck/clip":
			var ci := -1
			if args.size() >= 1:
				ci = OscDeck.resolve(args[0], clip_engine.clips,
					func(p: String) -> String: return Storage.rel(p),
					func(id: String) -> String: return ClipLibrary.path_for(id))
			if ci < 0:
				if _osc != null:
					_osc.warn_dropped("/pvj/deck/clip: no such clip %s"
						% (str(args[0]) if args.size() >= 1 else "(no arg)"))
			else:
				clip_engine.jump(ci)   # the grid tap's call (lane A deck)
				_flash_status("OSC: CLIP %d/%d" % [ci + 1, clip_engine.clips.size()])
		"/pvj/fx/ascii/text":
			if args.size() >= 1 and args[0] is String:
				_show_ascii_message(args[0])
			elif _osc != null:
				_osc.warn_dropped("/pvj/fx/ascii/text: wants one string")
		"/pvj/fx/ascii/mode":
			var am := _osc_index(args, ASCII_MODE_KEYS)
			if am >= 0:
				_set_ascii_mode(am)   # the mode buttons' call; the effect itself is left alone
			elif _osc != null:
				_osc.warn_dropped("/pvj/fx/ascii/mode: not one of %s" % "|".join(ASCII_MODE_KEYS))
		_:
			if _osc != null:
				_osc.warn_unknown(address)


func _osc_f(v: Variant) -> float:
	if v is float or v is int:
		return float(v)
	return 0.0


## Menu arg: a string matched case-insensitively, or an int index. Returns
## -1 (refused) rather than guessing — an unknown name must not pick mode 0.
func _osc_index(args: Array, names: Array) -> int:
	if args.is_empty():
		return -1
	var v: Variant = args[0]
	if v is String:
		for i in names.size():
			if String(names[i]).to_lower() == String(v).to_lower():
				return i
		return -1
	if v is int or v is float:
		var i2 := int(v)
		if i2 >= 0 and i2 < names.size():
			return i2
	return -1


func _osc_lane(args: Array, idx: int) -> String:
	if args.size() > idx and args[idx] is String \
			and String(args[idx]).to_lower() == "b":
		return "b"
	return "a"


# --- OSC outbound (/pvj/out/... — OSC_NAMESPACE_SPEC.md §4) -----------------

## The other half of the namespace: phone -> desk state feedback, so a TD /
## Resolume / TouchOSC surface can MIRROR the deck (fader echoes, bpm, clip,
## the sequencer's auto flag). Opt-in by targets — the inbound receiver is
## zero-config like the beacon, but WE don't spray packets at a LAN that
## never asked. OscOutput owns rate/change/keyframe policy; this side only
## says what the state IS — the same read-only sampling the status bar does,
## no setter grows a side effect.
## Enable/disable the outbound tree at RUNTIME. _build_osc_out only ever ran
## at startup and returned early when disabled, so the new UI toggle had nothing
## to call — the setting could be changed but never took effect until a restart.
func _apply_osc_out() -> void:
	if _osc_out_enabled:
		if _osc_out == null:
			_build_osc_out()
		else:
			_osc_out.rate_hz = _osc_out_rate
			_osc_out.set_targets(_osc_out_targets)
	elif _osc_out != null:
		# Free it outright rather than muting: a live UDP sender with no
		# consumers is a packet spray at a LAN that never asked (§6's stance).
		_osc_out.queue_free()
		_osc_out = null


func _build_osc_out() -> void:
	if not Features.OSC or not _osc_out_enabled:
		return
	_osc_out = OscOutput.new()
	_osc_out.name = "OscOutput"
	_osc_out.rate_hz = _osc_out_rate
	_osc_out.snapshot = _osc_out_snapshot
	add_child(_osc_out)
	_osc_out.set_targets(_osc_out_targets)


## LIB ▸ OSC (pro): the outbound tree's settings as rows — until SESSION_45
## they lived in settings.cfg only, plus an ON/OFF buried in TRACKING. Every
## row writes [osc] and applies live through _apply_osc_out; the status line
## says what is actually on the wire. The OSC IN readout shows this phone's
## address: the number a desk, a laptop or the Logos bridge needs typed in.
func _build_osc_section(sections: Array) -> void:
	_add_collapsible("OSC", false, sections)
	_osc_lib_in_lbl = _add_readout_row("OSC in")
	_osc_lib_out_toggle = _add_toggle_row("OSC out", _osc_out_enabled,
		func(on: bool): _set_osc_out_enabled(on))
	_osc_lib_targets_btn = _add_button_row("Out targets…", func(): _prompt_osc_targets())
	_add_slider_row("Out rate", 1.0, 60.0, 1.0, float(_osc_out_rate), " Hz",
		func(v: float): _set_osc_out_rate(int(v)))
	_osc_lib_out_lbl = _add_readout_row("Out status")
	for l: Label in [_osc_lib_in_lbl, _osc_lib_out_lbl]:
		# Two targets with ports don't fit one line at 22 px; wrap, never widen
		# the panel.
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", 18)
	_sync_osc_rows()


## The ONE way OSC out is switched (LIB ▸ OSC toggle, TRACKING's button).
func _set_osc_out_enabled(on: bool) -> void:
	_osc_out_enabled = on
	_settings_dirty = true
	_apply_osc_out()
	_sync_osc_rows()
	_flash_status(OscOutput.status_line(_osc_out_enabled, _osc_out_targets, _osc_out_rate))


func _set_osc_out_rate(hz: int) -> void:
	_osc_out_rate = clampi(hz, 1, 60)
	_settings_dirty = true
	if _osc_out != null:
		_osc_out.rate_hz = _osc_out_rate   # live; no keyframe storm on each step
	_sync_osc_rows()


func _prompt_osc_targets() -> void:
	var dlg := M8Dialog.prompt(_chrome_layer, "OSC OUT TARGETS",
		"IP:PORT, UP TO %d, COMMA-SEPARATED. EMPTY SENDS NOTHING. THE LOGOS BRIDGE LISTENS ON 9000."
			% OscOutput.MAX_TARGETS,
		_osc_out_targets, "SET", func(t: String) -> void: _apply_osc_out_targets(t))
	dlg.set_keyboard(LineEdit.KEYBOARD_TYPE_URL)   # the numeric pad has no ':'
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance
	_osc_targets_dlg = dlg   # for tools/verify_osc_settings.gd


## Validate before committing, like the LED panel IP: OSC is fire-and-forget
## UDP, so a bad destination fails silently. One bad entry refuses the WHOLE
## list (nothing half-applies) and the flash names it. Returns true if applied.
func _apply_osc_out_targets(text: String) -> bool:
	var parsed := OscOutput.parse_targets(text)
	if not (parsed["rejected"] as Array).is_empty():
		# Short: the flash is one big centred line (~35 chars on a phone) and the
		# long form ran off both edges on the Pixel 8. The prompt says the rules.
		_flash_status("BAD TARGET, KEPT OLD: %s" % ", ".join(parsed["rejected"]))
		return false
	_osc_out_targets = parsed["spec"]
	_settings_dirty = true
	_apply_osc_out()
	_sync_osc_rows()
	_flash_status(OscOutput.status_line(_osc_out_enabled, _osc_out_targets, _osc_out_rate))
	return true


func _sync_osc_rows() -> void:
	var line := OscOutput.status_line(_osc_out_enabled, _osc_out_targets, _osc_out_rate)
	if _osc_lib_out_toggle != null:
		_osc_lib_out_toggle.set_pressed_no_signal(_osc_out_enabled)
	if _osc_lib_targets_btn != null:
		_osc_lib_targets_btn.text = "OUT TARGETS: %s…" % (
			_osc_out_targets.replace(",", ", ") if _osc_out_targets != "" else "NONE")
	if _osc_lib_out_lbl != null:
		_osc_lib_out_lbl.text = line
	if _osc_lib_in_lbl != null:
		_osc_lib_in_lbl.text = _osc_in_line()
	if _btn_osc_out != null:
		_btn_osc_out.text = "OSC out: %s" % ("ON" if _osc_out_enabled else "OFF")
	if _lbl_osc_out != null:
		# ⚠️ The TARGETS are the thing that silently makes OSC out do nothing —
		# enabled with an empty list sends into the void.
		_lbl_osc_out.text = line


func _osc_in_line() -> String:
	if not _osc_enabled:
		return "OFF ([osc] enabled in settings.cfg)"
	if _osc == null or not _osc.is_listening():
		return "UDP %d REFUSED — OSC IN DEAD" % _osc_port
	var ip := _lan_ipv4()
	return "UDP %d · %s" % [_osc_port, ip if ip != "" else "NO NETWORK"]


## This phone's LAN IPv4 (a private range first), or "" with no network.
static func _lan_ipv4() -> String:
	var fallback := ""
	for a: String in IP.get_local_addresses():
		if not a.is_valid_ip_address() or a.contains(":") or a.begins_with("127."):
			continue
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return a
		if fallback == "" and not a.begins_with("169.254."):
			fallback = a
	return fallback


## One coherent state frame per send pass. Menu values go out as the same
## lowercase names the inbound parser accepts — a desk can echo a received
## value straight back and it round-trips.
func _osc_out_snapshot() -> Dictionary:
	var out := {
		"/pvj/out/xfade": _xfade,
		"/pvj/out/xfade/mode": String(XFADE_MODE_NAMES[_xfade_mode]).to_lower(),
		"/pvj/out/bpm": BeatClock.bpm,
		"/pvj/out/mode": String(MODE_NAMES[_mode]).to_lower(),
		"/pvj/out/clip": _osc_out_clip,
		"/pvj/out/seq/auto": 1 if (_seq_strip != null and _seq_strip.auto_enabled()) else 0,
		"/pvj/out/lane_b/arm": 1 if _lane_b_armed else 0,
		"/pvj/out/lane_b/source": ["clip", "net", "td"][_lane_b_source],
		"/pvj/out/beat": _bc_beat_index,
		"/pvj/out/bar": _bc_bar_index,
	}
	# /pvj/out/track/* (doc §6): derived, conditioned scalars while the
	# tracker runs — one float per address, the OSC-In-CHOP shape. hand/*
	# is post-doc (M2b grew the second graph); same shape, same law.
	if _tracking != null and _tracking.is_running():
		out["/pvj/out/track/presence"] = _tracking.presence()
		var th := _tracking.head()
		out["/pvj/out/track/head/x"] = th.x
		out["/pvj/out/track/head/y"] = th.y
		out["/pvj/out/track/head/z"] = th.z
		out["/pvj/out/track/crowded"] = _tracking.value_at(TrackingEngine.IDX_CROWDED)
		var thnd := _tracking.hand()
		out["/pvj/out/track/hand/x"] = thnd.x
		out["/pvj/out/track/hand/y"] = thnd.y
		out["/pvj/out/track/hand/present"] = 1.0 if _tracking.hand_present() else 0.0
	# /pvj/out/crowd/* (doc §13.5): aggregates ALWAYS, per-slot opt-in — 8 slots
	# x 4 addresses at 30 Hz is a different bandwidth conversation than §6 was
	# sized for, so crowd_osc_slots stays false until a venue proves it.
	if _tracking != null and _tracking.is_running() and _tracking.mode() == "crowd":
		var ca: Dictionary = _tracking.crowd.aggregates()
		out["/pvj/out/crowd/count"] = float(ca["count"])
		out["/pvj/out/crowd/centroid/x"] = float(ca["centroid_x"])
		out["/pvj/out/crowd/centroid/y"] = float(ca["centroid_y"])
		out["/pvj/out/crowd/spread"] = float(ca["spread"])
		out["/pvj/out/crowd/energy"] = float(ca["energy"])
		out["/pvj/out/crowd/nearest"] = float(ca["nearest"])
		out["/pvj/out/crowd/balance"] = float(ca["balance"])
		out["/pvj/out/crowd/overflow"] = float(ca["overflow"])
		if _track_crowd_osc_slots:
			for si in _tracking.crowd.slots:
				var pre := "/pvj/out/crowd/p%d" % (si + 1)
				out[pre + "/present"] = _tracking.crowd.slot_channel(si, CrowdTracker.CH_PRESENT)
				out[pre + "/x"] = _tracking.crowd.slot_channel(si, CrowdTracker.CH_X)
				out[pre + "/y"] = _tracking.crowd.slot_channel(si, CrowdTracker.CH_Y)
				out[pre + "/size"] = _tracking.crowd.slot_channel(si, CrowdTracker.CH_SIZE)
		# ⚠️ §13.4's FREE WIN: crowd mode synthesises the five FROZEN Kinect
		# channels on the FIELD addresses, so the TD patch cannot tell the
		# source changed. The channel names are the contract (§6); only the
		# estimator behind occupied_volume differs (#20 owns that calibration).
		if _track_crowd_field_compat:
			for k: String in _tracking.crowd.field_channels():
				out["/pvj/out/field/%s" % k] = float(_tracking.crowd.field_channels()[k])
			out["/pvj/out/field/presence"] = 1.0 if int(ca["count"]) > 0 else 0.0
	# Trigger lanes are STATE on the wire (1 fired .. 0 released), so they
	# ride the snapshot and the keyframe heals a lost edge within a second.
	for lane_name: String in _track_trigger_state:
		out["/pvj/out/trigger/%s" % lane_name] = int(_track_trigger_state[lane_name])
	return out


# --- TRACKING M1 (docs/MEDIAPIPE_MODULE.md §11) -----------------------------
# The M0 spike scaffolding is gone; TrackingEngine (scripts/tracking_engine.gd)
# is the real thing. Pipeline owns policy: settings, the Library section, the
# §2.1 camera gate's SRC half, and the TRACK mod-matrix source.

var _tracking: TrackingEngine = null
var _track_enabled: bool = false       ## [tracking] enabled — auto-start on boot
var _track_lens: String = "rear"       ## [tracking] lens — rear | front
## A lens switch is a stop()+start() pair. Between them the `stopped`
## signal would hand the wall back to CameraServer, which then opens the
## SAME lens CameraX is about to take — two clients, one camera, the
## deterministic Session-33 wedge (observed again 2026-09-10: three
## identical crash-restart cycles switching tracking to the rear lens).
## While this is true the wall stays put and CameraServer is never woken.
var _track_switching: bool = false
var _track_pub_rot: int = 270          ## [tracking] publish_rot — M6 orientation (measured)
## M8a spike gate (doc §13.9). Person boxes instead of face landmarks,
## logcat only — no snapshot, no ModSources, nothing on the wall. This is
## a MEASUREMENT build switch, not a feature; it goes away when M8b lands.
var _track_crowd_spike: bool = false
var _track_delegate: String = "cpu"   ## [tracking] delegate — cpu | gpu (§8)
var _track_crowd_model: String = "edl0_int8"  ## [tracking] crowd_model — M8a sweep
var _track_analysis_res: int = 720     ## [tracking] analysis_res — MEASURED best (§13.7.1a)
var _track_crowd_score: float = 0.4    ## [tracking] crowd_min_conf
var _track_zoom: float = 1.0           ## [tracking] zoom — live range control
var _track_pub_mirror: int = 0         ## [tracking] publish_mirror — 0 MEASURED|1|-1
var _track_crowd_osc_slots: bool = false  ## [tracking] crowd_osc_slots (§13.5)
var _track_crowd_field_compat: bool = true ## [tracking] crowd_field_compat (§13.4)
## Camera controls (§13.7.4). Live — they go through CameraControl, which
## needs no graph rebuild, so none of them can re-enter the §2.1 teardown
## race the way a resolution change would.
var _track_ae_lock: bool = false       ## [tracking] ae_lock
var _track_exposure: int = 0           ## [tracking] exposure — device EV steps
var _track_torch: bool = false         ## [tracking] torch
## [tracking] camera_via_camerax — route the deck's CAMERA source through
## the plugin (Preview only, no inference) so the camera controls exist
## even with tracking off. OFF by default: never device-run (§13.7.4).
var _track_camera_only: bool = false
var _track_cutoff: float = 1.0         ## [tracking] filter_min_cutoff (One Euro)
var _track_beta: float = 0.02          ## [tracking] filter_beta
var _track_hz: int = 15                ## [tracking] inference_hz (M0: 15 is honest)
var _track_hands: bool = false         ## [tracking] hands — second graph, costs fps
var _track_hands_only: bool = false    ## [tracking] hands_only — M3 economy mode
## §5.4 trigger lanes — [triggers] section, one key per lane:
##   <name> = "channel enter exit dwell_ms quantise invert"
##   e.g. close = "head_z 0.65 0.45 250 1 1"  (fires as the subject nears)
## Parsed at boot into TriggerLane objects on TrackingEngine; the wire state
## (name -> 0|1) rides /pvj/out/trigger/<name> in the snapshot.
var _track_triggers_cfg: Dictionary = {}    ## name -> raw spec string (persisted)
var _track_trigger_state: Dictionary = {}   ## name -> 0|1 (the wire truth)
var _btn_track_on: Button = null
var _btn_track_lens: Button = null
var _btn_track_ae: Button = null
var _btn_track_mode: Button = null
var _btn_crowd_slots: Button = null
var _btn_crowd_osc: Button = null
var _btn_osc_out: Button = null
var _lbl_osc_out: Label = null
var _lbl_triggers: Label = null
var _track_crowd_slots: int = 6
var _track_readout: Label = null
var _track_viewer: TrackViewer = null
var _btn_track_view: Button = null
## M6: the CAMERA source, backed by TRACKING's camera instead of CameraServer.
## Whoever holds the lens publishes it — so SRC▸CAMERA no longer refuses while
## tracking runs (§2.1's exclusion becomes routing). Which backing is live is
## decided when CAMERA is applied and HELD until the next apply, so every
## consumer in a frame agrees about the texture it is looking at.
var _track_camera: TrackCameraSource = null
var _cam_via_tracking: bool = false


func _build_tracking() -> void:
	if not Features.MEDIAPIPE:
		return
	_tracking = TrackingEngine.new()
	_tracking.name = "TrackingEngine"
	_tracking.camera_engine = camera_engine    # the §2.1 gate's other half
	add_child(_tracking)
	_tracking.started.connect(func(_m: String) -> void:
		# M6's missing half — see _claim_wall_for_tracking.
		if _claim_wall_for_tracking():
			_flash_status("TRACKING ON — CAMERA NOW VIA TRACKING")
		else:
			_flash_status("TRACKING ON"))
	_tracking.failed.connect(func(reason: String) -> void:
		_track_enabled = false
		_sync_track_rows()
		_release_wall_from_tracking()
		_flash_status("TRACKING: %s" % reason.to_upper()))
	# M6: the publisher going away must not leave the wall on a frozen last
	# frame — re-apply the source and it routes back to CameraServer.
	_tracking.stopped.connect(_release_wall_from_tracking)
	_tracking.subject_acquired.connect(func() -> void:
		_flash_status("TRACK: SUBJECT LOCKED")
		if _osc_out != null:
			_osc_out.event("/pvj/out/track/acquired", 1))
	_tracking.subject_lost.connect(func() -> void:
		_flash_status("TRACK: SUBJECT LOST")
		if _osc_out != null:
			_osc_out.event("/pvj/out/track/lost", 1))
	_build_trigger_lanes()
	# M6: the publish path's viewport. Built here (not in Main.tscn) so the
	# scene stays as it was and a desktop run simply never starts it.
	_track_camera = TrackCameraSource.new()
	_track_camera.name = "TrackCameraSource"
	_track_camera.size = output_world.size
	_track_camera.engine = _tracking
	_track_camera.rot_offset = _track_pub_rot
	_track_camera.mirror_override = _track_pub_mirror
	output_world.add_child(_track_camera)
	# Same fallback as a dead CameraServer feed: the deck drops to VIDEO
	# rather than showing a black wall nobody can explain.
	_track_camera.camera_failed.connect(_on_camera_failed)
	# The tracker viewer PiP (M2) — phone-side chrome, never on the wall.
	_track_viewer = TrackViewer.new()
	_track_viewer.name = "TrackViewer"
	_track_viewer.engine = _tracking
	_chrome_layer.add_child(_track_viewer)
	if _track_enabled:
		_track_start()


## [triggers] cfg strings -> TriggerLane objects on the engine. Lenient like
## set_targets: a malformed lane is skipped with one log line, the rest live.
func _build_trigger_lanes() -> void:
	for lane_name: String in _track_triggers_cfg:
		var spec := str(_track_triggers_cfg[lane_name])
		var p := spec.split(" ", false)
		if p.size() < 3:
			print("[track] trigger '%s' skipped (want: channel enter exit [dwell_ms quantise invert]): %s"
					% [lane_name, spec])
			continue
		var lane := TriggerLane.new()
		lane.channel = p[0]
		lane.enter_at = float(p[1])
		lane.exit_at = float(p[2])
		if p.size() > 3:
			lane.dwell_ms = maxi(int(p[3]), 0)
		if p.size() > 4:
			lane.quantise = clampi(int(p[4]), 0, 2)
		if p.size() > 5:
			lane.invert = int(p[5]) != 0
		var ln := lane_name   # capture by value for the lambdas
		lane.fired.connect(func() -> void:
			_track_trigger_state[ln] = 1
			_flash_status("TRIG: %s" % ln.to_upper()))
		lane.released.connect(func() -> void:
			_track_trigger_state[ln] = 0)
		_track_trigger_state[lane_name] = 0
		_tracking.add_lane(lane_name, lane)
	if not _track_triggers_cfg.is_empty():
		print("[track] %d trigger lane(s) armed" % _tracking.lanes().size())


## Tracking ARRIVED (M6). The mirror image of _release_wall_from_tracking, and
## the piece whose absence made M6 a no-op on device: the publisher comes up
## ASYNCHRONOUSLY, so every _apply_source() that ran before the tracking_started
## signal necessarily saw is_running() == false and routed the wall to
## CameraServer. Nothing re-routed it afterwards — the release path existed, the
## claim path did not — so SRC▸CAMERA with tracking on showed the REAR lens
## through CameraServer while CameraX held the front, both clients open at once.
## This is the one moment is_running() is true and the wall can be re-pointed.
## Returns true when it actually took the wall (the caller's status line).
func _claim_wall_for_tracking() -> bool:
	if _source != ClipSource.CAMERA or _cam_via_tracking:
		return false
	_apply_source()
	return _cam_via_tracking


## Tracking stopped or died while the wall was showing ITS camera (M6): route
## the CAMERA source back to CameraServer. Cheap and idempotent when the deck
## is on VIDEO/DRIVE, which is the common case.
func _release_wall_from_tracking() -> void:
	# ⚠️ Mid-switch the publisher is coming straight back. Releasing here opens
	# CameraServer on the lens CameraX is about to bind — the wedge. The wall
	# holds its last frame for the ~0.4 s instead, which nobody can see.
	if _track_switching:
		return
	if _source == ClipSource.CAMERA and _cam_via_tracking:
		_apply_source()
		_flash_status("CAMERA: TRACKING RELEASED THE LENS")


## User intent "tracking on" — applies knobs then starts.
## §2.1's other half, M6 edition: the deck's CAMERA source no longer BLOCKS
## tracking, it HANDS THE LENS OVER. CameraServer is stopped first, tracking
## takes the camera, and the wall is re-pointed at tracking's own publish —
## the same picture, a different owner, no operator detour through VIDEO.
## The refusal path stays for everything else (permission, model, a lens the
## OS will not give) and is still LOUD.
func _track_start() -> void:
	if not _tracking.available():
		_flash_status("TRACKING: NO PLUGIN (DESKTOP?)")
		_track_enabled = false
		return
	_tracking.set_delegate(_track_delegate)
	_tracking.set_crowd_model(_track_crowd_model)
	_tracking.set_analysis_res(_track_analysis_res)
	_tracking.set_crowd_score(_track_crowd_score)
	_tracking.set_zoom(_track_zoom)
	# ⚠️ AE lock is applied LAST and only when asked: a lock taken before the
	# camera has metered the real scene freezes the wrong exposure, and a
	# black wall that stays black looks like a crash.
	_tracking.set_exposure(_track_exposure)
	_tracking.set_torch(_track_torch)
	if _track_ae_lock:
		_tracking.set_ae_lock(true)
	_tracking.set_filter(_track_cutoff, _track_beta)
	_tracking.set_inference_rate(_track_hz)
	_tracking.set_hands(_track_hands)
	_tracking.set_hands_only(_track_hands_only)
	# The handover. Stopping CameraServer BEFORE start() is what clears the
	# engine's own "camera-busy" refusal — the two clients still never
	# overlap, which is the whole point of §2.1 and stays true here.
	var handover := _source == ClipSource.CAMERA and camera_engine.is_running()
	if handover:
		camera_engine.stop()
	var refuse := _tracking.start(_track_lens, "crowd" if _track_crowd_spike else "landmark")
	if refuse == "" and handover:
		# ⚠️ DO NOT _apply_source() here. TrackingPlugin.start() is ASYNC (§3):
		# TrackingEngine._running only flips on the tracking_started signal, so
		# a re-apply on this line still sees is_running() == false, takes the
		# CameraServer branch, and RE-OPENS the very client the handover just
		# closed — two camera clients, which is the Session-33 wedge the whole
		# routing exists to prevent. The wall is dark for the ~1-2 s the graph
		# takes to come up; _claim_wall_for_tracking() lights it from the
		# started handler, which is the only moment the answer is true.
		_flash_status("TRACKING ON — HANDING THE LENS OVER")
	elif refuse != "" and handover:
		# Handover failed: give the lens straight back, no dark wall.
		camera_engine.start()
	if refuse != "":
		# A refused start means no publisher is coming: drop the hold so the
		# wall can fall back instead of freezing on the last tracked frame.
		_track_switching = false
		_release_wall_from_tracking()
	if refuse == "camera-busy":
		_track_enabled = false
		_flash_status("TRACKING BLOCKED: CAMERA SOURCE HOLDS THE LENS")
	elif refuse == "no-permission":
		_flash_status("TRACKING: GRANT CAMERA, THEN RE-TAP")
		_track_enabled = false
	elif refuse != "":
		_track_enabled = false
		_flash_status("TRACKING: %s" % refuse.to_upper())
	_sync_track_rows()


func _set_tracking_enabled(on: bool) -> void:
	_track_enabled = on
	_settings_dirty = true
	if on:
		_track_start()
	else:
		_tracking.stop()
		_sync_track_rows()


func _sync_track_rows() -> void:
	if _btn_track_on != null:
		_btn_track_on.text = "Tracking: %s" % ("ON" if _track_enabled else "OFF")
	if _btn_track_lens != null:
		_btn_track_lens.text = "Lens: %s" % _track_lens.to_upper()
	if _btn_track_ae != null:
		_btn_track_ae.text = "AE lock: %s" % ("ON" if _track_ae_lock else "OFF")
	if _btn_track_mode != null:
		_btn_track_mode.text = "Mode: %s" % ("CROWD" if _track_crowd_spike else "LANDMARK")
	if _btn_crowd_slots != null:
		_btn_crowd_slots.text = "Crowd slots: %d" % _track_crowd_slots
	if _btn_crowd_osc != null:
		_btn_crowd_osc.text = "Per-slot OSC: %s" % ("ON" if _track_crowd_osc_slots else "OFF")
	_sync_osc_rows()   # the OSC out button + targets readout here mirror LIB ▸ OSC
	if _lbl_triggers != null:
		if _track_trigger_state.is_empty():
			_lbl_triggers.text = "no lanes ([triggers] in settings.cfg)"
		else:
			var parts: Array[String] = []
			for ln: String in _track_trigger_state:
				parts.append("%s%s" % [ln, "*" if int(_track_trigger_state[ln]) == 1 else ""])
			_lbl_triggers.text = " · ".join(parts)


## Library ▸ TRACKING (doc §7's M1 subset). The readout row is first, same
## law as AUDIO INPUT/MOD MATRIX: you tune while watching the number move.
func _build_tracking_section(sections: Array) -> void:
	if not Features.MEDIAPIPE:
		return
	_add_collapsible("TRACKING", false, sections)
	_track_readout = _add_readout_row("Head x·y·z")
	_btn_track_on = _add_button_row("Tracking: OFF",
		func(): _set_tracking_enabled(not _track_enabled))
	# ⚠️ MODE, and it needs a restart because the GRAPH is built at start():
	# landmark builds the face (+hand) landmarkers, crowd builds the object
	# detector and NEITHER of the others. That is why the viewer shows no dots
	# in crowd mode — there is no face graph to produce them — and why the two
	# cannot simply coexist: M8a measured landmark at 62 ms and crowd at 178 ms,
	# so both would be ~4 Hz. §8's "modes are exclusive" as a measured fact.
	# Until now switching meant hand-editing settings.cfg, which is why the
	# operator spent a day asking whether tracking was broken when it was only
	# in the other mode.
	_btn_track_mode = _add_button_row("Mode: LANDMARK", func():
		_track_crowd_spike = not _track_crowd_spike
		_settings_dirty = true
		_sync_track_rows()
		if _track_enabled:
			_track_switching = true          # hold the wall across the rebuild
			_tracking.stop()
			get_tree().create_timer(0.4).timeout.connect(func():
				_track_switching = false
				if _track_enabled:
					_track_start()
				else:
					_release_wall_from_tracking())
		_flash_status("TRACKING MODE: %s" % ("CROWD" if _track_crowd_spike else "LANDMARK")))
	_btn_track_lens = _add_button_row("Lens: REAR", func():
		_track_lens = "front" if _track_lens == "rear" else "rear"
		_settings_dirty = true
		_sync_track_rows()
		if _track_enabled:                # a lens change needs a clean session
			_track_switching = true       # hold the wall across the gap
			_tracking.stop()
			# Give the camera unbind a beat before rebinding the other lens —
			# belt to the Kotlin teardown's braces (the lens-switch freeze).
			get_tree().create_timer(0.4).timeout.connect(func():
				_track_switching = false
				if _track_enabled:
					_track_start()
				else:
					# Switched off mid-gap: the release never ran, so run it
					# now or the wall keeps a frozen frame forever.
					_release_wall_from_tracking()))
	# RANGE. The only tracking control that applies LIVE — CameraX zoom needs
	# no graph rebuild, so dragging this mid-set cannot re-enter the §2.1
	# teardown race. Cropping a 50 MP sensor into a ~640x480 analysis frame is
	# near-free, so this buys reach at almost no quality cost; what it spends
	# is FIELD OF VIEW, which for crowd work is the actual coverage trade.
	_add_slider_row("Range (zoom)", 1.0, 6.0, 0.1, _track_zoom, "x", func(v: float):
		_track_zoom = v
		_settings_dirty = true
		if _tracking != null and _tracking.is_running():
			_tracking.set_zoom(v))
	# ⚠️ AE/AWB LOCK — the one that matters on a wall. Auto-exposure re-meters
	# as people cross frame, so a projected camera image PULSES and colour-
	# shifts with movement instead of with the music. Locking holds the look.
	# It is a deliberate act, never a default: lock while pointing at a bright
	# wall and a dark room stays dark, which reads as a crash.
	_btn_track_ae = _add_button_row("AE lock: OFF", func():
		_track_ae_lock = not _track_ae_lock
		_settings_dirty = true
		if _tracking != null and _tracking.is_running():
			if not _tracking.set_ae_lock(_track_ae_lock):
				_track_ae_lock = false
				_flash_status("AE LOCK REFUSED BY CAMERA")
			else:
				_flash_status("AE/AWB %s" % ("LOCKED" if _track_ae_lock else "AUTO"))
		_sync_track_rows())
	_add_slider_row("Exposure", -12.0, 12.0, 1.0, float(_track_exposure), "ev", func(v: float):
		# device EV STEPS, not stops — getExposureRange() reports the real
		# bounds and the plugin clamps; a slider built on guesses is a knob
		# that does nothing on half the phones.
		_track_exposure = int(v)
		_settings_dirty = true
		if _tracking != null and _tracking.is_running():
			_tracking.set_exposure(_track_exposure))
	# M8c: the crowd knobs. `slots` reallocates the bank and therefore LOSES all
	# identities, which is why §13.6 marks it restart-only and why it is a
	# stepped button rather than a slider anyone can drag mid-set.
	_btn_crowd_slots = _add_button_row("Crowd slots: 6", func():
		var n := _track_crowd_slots + 2
		if n > 8:
			n = 2
		_track_crowd_slots = n
		_settings_dirty = true
		if _tracking != null:
			_tracking.crowd.set_slots(n)
		_sync_track_rows()
		_flash_status("CROWD SLOTS: %d (identities reset)" % n))
	# ⚠️ OFF by default and it says why: 8 slots x 4 addresses at 30 Hz is a
	# different bandwidth conversation than §6 was ever sized for.
	_btn_crowd_osc = _add_button_row("Per-slot OSC: OFF", func():
		_track_crowd_osc_slots = not _track_crowd_osc_slots
		_settings_dirty = true
		_sync_track_rows()
		_flash_status("PER-SLOT OSC: %s (%d addresses)" % [
			"ON" if _track_crowd_osc_slots else "OFF",
			_track_crowd_slots * 4 if _track_crowd_osc_slots else 0]))
	_add_slider_row("Filter cutoff", 0.1, 3.0, 0.05, _track_cutoff, "", func(v: float):
		_track_cutoff = v
		_tracking.set_filter(_track_cutoff, _track_beta)
		_settings_dirty = true)
	_add_slider_row("Filter beta", 0.0, 0.2, 0.005, _track_beta, "", func(v: float):
		_track_beta = v
		_tracking.set_filter(_track_cutoff, _track_beta)
		_settings_dirty = true)
	_add_button_row("Rebaseline depth", func():
		_tracking.rebaseline()
		_flash_status("TRACK: REBASELINE"))
	# --- M3 DEBT, absorbed by M8c (§13.9) ---------------------------------
	# Both of these have been settings-only since M3 shipped, which meant the
	# only way to know whether the outbound tree was live — or which lanes were
	# armed — was to read settings.cfg over adb. That is exactly the class of
	# invisibility that cost this session five rounds of "is tracking broken?".
	_btn_osc_out = _add_button_row("OSC out: OFF", func():
		_set_osc_out_enabled(not _osc_out_enabled))
	_lbl_osc_out = _add_readout_row("OSC targets")
	_lbl_triggers = _add_readout_row("Trigger lanes")
	_btn_track_view = _add_button_row("Tracker view: OFF", func():
		var on := not _track_viewer.visible
		_track_viewer.set_open(on)
		_btn_track_view.text = "Tracker view: %s" % ("ON" if on else "OFF"))
	_add_toggle_row("Hands", _track_hands, func(on: bool):
		_track_hands = on
		_settings_dirty = true
		if _track_enabled:                # second graph joins on a clean session
			_tracking.stop()
			get_tree().create_timer(0.4).timeout.connect(func():
				if _track_enabled:
					_track_start()))
	_sync_track_rows()


## Undo everything _build_link made, in dependency order, leaving the deck
## exactly as it runs with the link disabled at boot. stop() is called BEFORE
## queue_free where a socket is held: queue_free releases in _exit_tree at end
## of frame, which is one frame too late for the rebuild that role-flipping
## does in the same call. (The beacon has no stop() — its 4849 bind frees at
## end of frame and the NEW beacon's once-a-second bind retry picks it up; one
## "port busy" warning is the designed-in cost.)
## A throwaway LinkControl for ONE parting word (see _teardown_link): the live
## control is freed with its outgoing queue, so the word rides this node, which
## outlives the teardown by the send timeout and then frees itself.
func _link_parting() -> LinkControl:
	var parting := LinkControl.new()
	parting.name = "LinkPartingStop"
	add_child(parting)
	get_tree().create_timer(LinkControl.SEND_TIMEOUT_SECS + 0.5).timeout.connect(
		func() -> void:
			if is_instance_valid(parting):
				parting.queue_free())
	return parting


func _teardown_link() -> void:
	# Hazard 1 (DUAL_PHONE_B_DECK_SPEC §6): the receiver — and with it the
	# ExternalTexture behind lane B's NET face — is about to die. Degrade the
	# lane to CLIPS FIRST, while the engine rebind can still run cleanly; the
	# toggle mirrors it and the flash says why. Persisted, so a relaunch with
	# the link re-enabled starts from the honest state.
	if _lane_b_source != LaneBSource.CLIP:
		_lane_b_source = LaneBSource.CLIP
		_push_lane_b_src_btn()
		_apply_lane_b_source()
		_settings_dirty = true
		_flash_status("LANE B: LINK OFF — USING CLIPS")
	# Tell whoever is streaming AT us to stop BEFORE the receive port closes:
	# without this, the "off" toggle looked clean locally while the cam phone
	# kept paying GPU readback + encode at the asked cadence into a dead socket —
	# on the one phone that cannot charge. The stop rides a THROWAWAY control
	# node because the live one is freed with its outgoing queue a few lines
	# down, which would strand the send mid-handshake; the throwaway outlives
	# this call by the send timeout and then frees itself.
	# Each parting word rides its OWN throwaway node: with two slots there can
	# be two providers owed a word, and neither may strand the other mid-send.
	if _td_rx_ip != "":
		# The TD SRT contract: WE were the dialer, so the parting word is
		# srt_disarm (park the single-shot listener clean) — a plain stop
		# only clears TD's Stage-0 jpeg sender and leaves srt_out wedged.
		_link_parting().send_srt_disarm(_td_rx_ip, _td_rx_ctrl_port)
		_td_rx_ip = ""
	if _link_rx_ip != "":
		_link_parting().send_stop(_link_rx_ip, _link_rx_ctrl_port, _link_rx_stream)
		_link_rx_ip = ""
		_link_rx_stream = -1
	if _net_sender != null:
		_net_sender.stop()
		_net_sender.queue_free()
		_net_sender = null
	# Same camera-release rule as the stream_stopped handler: power down ONLY
	# if the link was the reason it ran — the deck's own CAMERA source keeps it.
	if _link_uses_camera:
		_link_uses_camera = false
		if _source != ClipSource.CAMERA:
			camera_engine.stop()
	if _net_source != null:
		_net_source.stop()              # frees the receive socket now — UDP 4851, or the plugin's TCP 4853 (decode thread joins in _exit_tree)
		_net_source.queue_free()
		_net_source = null
	if _net_source_td != null:
		_net_source_td.stop()           # the SRT dial loop dies now, not at end of frame
		_net_source_td.queue_free()
		_net_source_td = null
	if _link_tripwire != null:
		_link_tripwire.close()          # frees UDP 4853 now, same reasoning as the sockets above
		_link_tripwire = null
	_link_pre_m2.clear()
	if _link_control != null:
		_link_control.stop()            # frees TCP 4850 now
		_link_control.queue_free()
		_link_control = null
	if _link_beacon != null:
		_link_beacon.queue_free()
		_link_beacon = null
	if _link_layer != null:
		_link_layer.queue_free()
		_link_layer = null
	if _td_layer != null:
		_td_layer.queue_free()
		_td_layer = null
	if _link_pull_timer != null:
		_link_pull_timer.queue_free()
		_link_pull_timer = null
	if _link_stats_timer != null:
		_link_stats_timer.queue_free()
		_link_stats_timer = null
	if _link_debug_lbl != null:
		_link_debug_lbl.queue_free()    # a plain chrome child now — never its parent
		_link_debug_lbl = null
	# The 1 Hz stats poll died with its timer — clear the bar by hand or the
	# last reading sits there looking alive.
	if _lbl_link != null and _lbl_link.visible:
		_lbl_link.visible = false
		_lbl_link_sep.visible = false
	_refresh_link_peer_rows()           # the list now reads LINK OFF


## Live on/off for the latency burn-in (spec §9). Persisted like the rest of
## [link], and applied to a RUNNING link in place — a measurement toggle that
## needed a relaunch to clear would get left on, which is exactly how the
## stamp used to survive into shows.
func _set_link_debug_counter(on: bool) -> void:
	if on == _link_debug_counter:
		return
	_link_debug_counter = on
	_settings_dirty = true
	if _net_sender != null:
		_net_sender.set_debug_counter(on)
	if on:
		if _link_beacon != null:      # link running — otherwise _build_link applies it
			_build_link_debug_label()
	elif _link_debug_lbl != null:
		_link_debug_lbl.queue_free()
		_link_debug_lbl = null


func _set_link_enabled(on: bool) -> void:
	if on == _link_enabled:
		return
	_link_enabled = on
	_settings_dirty = true
	if on:
		_build_link()
	else:
		_teardown_link()
	_flash_status("VIDEO LINK: %s" % ("ON" if on else "OFF"))


## MAIN <-> CAM. The receive side (NetSource, layer, pull timer) exists
## per-role, so a mid-run flip is a full teardown + rebuild, not a flag write.
func _cycle_link_role() -> void:
	_link_role = "cam" if _link_role == "main" else "main"
	_settings_dirty = true
	if _btn_link_role != null:
		_btn_link_role.text = "Link role: %s" % _link_role.to_upper()
	if _link_enabled:
		_teardown_link()
		_build_link()
	_flash_status("LINK ROLE: %s" % _link_role.to_upper())


## Repaint the panel's peer list. Called at panel build, from every
## peers_changed, and after teardown — peers appear and vanish while the panel
## is open. Old rows are DETACHED before queue_free so a burst of beacon churn
## inside one frame can never show a row twice; a collapsed section just holds
## the same children invisible, so rebuilding under it is free.
func _refresh_link_peer_rows() -> void:
	if _link_peer_vbox == null:
		return                          # panel not built yet
	for child in _link_peer_vbox.get_children():
		_link_peer_vbox.remove_child(child)
		child.queue_free()
	if _link_beacon == null:
		_link_peer_vbox.add_child(_link_peer_note("LINK OFF"))
		return
	var peers := _link_beacon.get_peers()
	if peers.is_empty():
		_link_peer_vbox.add_child(_link_peer_note("NO PEERS"))
		return
	var names := peers.keys()
	names.sort()                        # stable order — churn must not shuffle rows under a finger
	for peer_name in names:
		_link_peer_vbox.add_child(_link_peer_row(str(peer_name), peers[peer_name]))


## One dim informational row ("LINK OFF" / "NO PEERS") — a state, not a control.
func _link_peer_note(text: String) -> Control:
	var l := _make_label(text)
	l.add_theme_color_override("font_color", M8_DIMTEXT)
	return _row_wrap(l)


## "NAME (ROLE)" + PULL/STOP for the peers that can stream to us. The row
## captures this rebuild's snapshot of ip/ctrl_port — safe because the beacon
## fires peers_changed (-> a fresh row) whenever either moves under the name.
func _link_peer_row(peer_name: String, peer: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var role := str(peer.get("role", "?"))
	var lbl := _make_label("%s (%s)" % [peer_name.to_upper(), role.to_upper()])
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.clip_text = true
	row.add_child(lbl)
	if role == "cam" or role == "td":
		# Stream numbering is the wire contract: 1 = the cam phone's camera,
		# 0 = a peer's composited output — what TD serves, and what ANY
		# PocketVJ sender serves when asked (the dual-phone B deck, N2):
		# _on_link_stream_requested's `_` arm captures output_world.
		# PULL only exists while this role can receive at all (main built a
		# NetSource). A NetSource whose bind FAILED still shows the buttons —
		# _link_pull_from refuses that case out loud, which beats hiding the
		# control and leaving the operator to guess why it is gone.
		if _net_source != null:
			if role == "cam":
				# A phone peer serves BOTH: its camera and its whole deck.
				row.add_child(_link_pull_button(peer_name, peer, 1, "CAM"))
				row.add_child(_link_pull_button(peer_name, peer, 0, "DECK"))
			else:
				row.add_child(_link_pull_button(peer_name, peer, 0, "PULL"))
		row.add_child(_link_peer_button("STOP", func() -> void:
			if _link_control == null:
				return
			# Two pullable streams per phone peer now — stop the one we are
			# actually receiving from this peer; the row default only covers
			# the nothing-recorded case (harmless: a stop for a stream the
			# peer isn't sending is a no-op at its end).
			var sid := _link_rx_stream if (str(peer.get("ip", "")) == _link_rx_ip
					and _link_rx_stream >= 0) else (1 if role == "cam" else 0)
			if str(peer.get("codec", "")) == "srt":
				# SRT pull mode: WE are the dialer, so stopping means killing
				# our own pull loop and parking TD's single-shot listener clean
				# (srt_disarm — else it sits wedged with an error badge). Stage
				# 3.2: the TD slot only. There is no displaced phone↔phone
				# listener to restore, and the peer's record is not ours to clear.
				if _net_source_td != null:
					_net_source_td.stop()
				_link_control.send_srt_disarm(str(peer["ip"]), int(peer["ctrl_port"]))
				if str(peer["ip"]) == _td_rx_ip:
					_td_rx_ip = ""             # nothing owed at teardown any more
				_flash_status("LINK STOP: %s" % peer_name.to_upper())
				return
			_link_control.send_stop(str(peer["ip"]), int(peer["ctrl_port"]), sid)
			if role == "cam":
				# The retry must not undo the operator: without this latch the
				# 3 s auto-pull re-starts a stream from the peer this tap just
				# silenced — for a stopped DECK pull it would even come back
				# as the CAM, switching sources under the performer.
				_link_pull_stopped = true
			if str(peer["ip"]) == _link_rx_ip and sid == _link_rx_stream:
				_link_rx_ip = ""             # nothing owed at teardown any more
				_link_rx_stream = -1
			_flash_status("LINK STOP: %s" % peer_name.to_upper())))
	var wrapped := _row_wrap(row)
	# Stage 3.3: this peer's own layer level, under its buttons — only for peers
	# that can stream to us, and only while this phone has a receive side (the
	# PULL gate). Seeded from the store: the row is rebuilt on every beacon
	# churn, so the store, not the widget, is the truth.
	if (role == "cam" or role == "td") and _net_source != null:
		var block := VBoxContainer.new()
		block.add_child(wrapped)
		_add_slider_row("Layer alpha", 0.0, 1.0, 0.01, _alpha_for_peer(peer_name), "",
			func(v: float): _set_peer_alpha(peer_name, v), block)
		return block
	return wrapped


## One pull button (N2: a phone peer row carries two — CAM and DECK). The
## flash first, the request after: _link_pull_from carries the empty-ip rule
## (spec §6.4 — the far end substitutes this TCP connection's address) and,
## on a dead receive port, overwrites this flash with the reason nothing
## will arrive.
func _link_pull_button(peer_name: String, peer: Dictionary, sid: int, label: String) -> Button:
	return _link_peer_button(label, func() -> void:
		if _link_control == null:
			return
		# An explicit PULL un-does an explicit STOP — for EITHER stream: the
		# operator is choosing a source, and the reflex must not outvote them.
		_link_pull_stopped = false
		_flash_status("LINK PULL: %s %s" % [peer_name.to_upper(), label])
		_link_pull_from(str(peer_name), peer, sid))


## Small green-outlined action button, stepper-styled. Carries the same
## scroll-vs-tap guard as _add_button_row/_stepper: the peer list scrolls with
## the rest of the panel, and a PULL fired by a passing scroll starts a stream.
func _link_peer_button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(110, 62)
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_color_override("font_color", M8_GREEN)
	b.add_theme_color_override("font_hover_color", M8_GREEN)
	b.add_theme_color_override("font_pressed_color", BRAND_DARK)
	b.add_theme_stylebox_override("normal", _btn_stylebox(Color(0, 0, 0, 0), M8_GREEN, 0.8))
	b.add_theme_stylebox_override("hover", _btn_stylebox(Color(0, 0, 0, 0), M8_GREEN, 1.0))
	b.add_theme_stylebox_override("pressed", _btn_stylebox(M8_GREEN, M8_GREEN, 1.0))
	b.pressed.connect(func() -> void:
		if _row_suppressed:
			return
		on_press.call())
	return b


func _set_ddp_enabled(on: bool) -> void:
	_ddp_enabled = on
	_settings_dirty = true
	if _ddp != null:
		_ddp.set_enabled(on)
	_apply_ddp_source()   # the sim must stop when the panel goes off
	_flash_status("LED PANEL: %s" % ("ON (%s)" % _ddp_target_ip if on else "OFF"))


## Point the sink at the deck or at the automaton, and run the sim only when it
## is both selected AND actually being sent — a sim stepping into a panel that is
## switched off is pure waste.
func _apply_ddp_source() -> void:
	if _ddp != null:
		_ddp.set_mode(DdpOutput.Mode.INDEPENDENT if _ddp_source == 1 \
			else DdpOutput.Mode.MIRROR)
	if _life != null:
		_life.set_running(_ddp_source == 1 and _ddp_enabled)


## Push the selected rate into the sim. One writer, called from build, from the
## cycle button and from nothing else.
func _apply_life_rate() -> void:
	if _life == null:
		return
	if _life_rate == 0:
		_life.clock_mode = LifeSource.Clock.FREE
	else:
		_life.clock_mode = LifeSource.Clock.BEAT
		_life.gens_per_beat = float(LIFE_RATE_PER_BEAT[_life_rate])


func _cycle_life_rate() -> void:
	_life_rate = (_life_rate + 1) % LIFE_RATE_NAMES.size()
	_settings_dirty = true
	_apply_life_rate()
	if _btn_life_rate != null:
		_btn_life_rate.text = "Life rate: %s" % LIFE_RATE_NAMES[_life_rate]
	_flash_status("LIFE RATE: %s" % LIFE_RATE_NAMES[_life_rate])


func _cycle_ddp_source() -> void:
	_ddp_source = (_ddp_source + 1) % DDP_SOURCE_NAMES.size()
	_settings_dirty = true
	_apply_ddp_source()
	if _btn_ddp_source != null:
		_btn_ddp_source.text = "LED source: %s" % DDP_SOURCE_NAMES[_ddp_source]
	# LIFE is 64x64 natively, so the fit modes have nothing to do — say so rather
	# than leaving a control that silently stops mattering.
	var note := " — NATIVE 64x64, NO FIT" if _ddp_source == 1 else ""
	_flash_status("LED SOURCE: %s%s" % [DDP_SOURCE_NAMES[_ddp_source], note])


## SQUASH -> CROP -> LETTERBOX -> SQUASH. A cycle rather than three radio rows
## because the only way to choose is to look at the panel and compare, and a
## cycle button keeps your eyes on the panel instead of the phone.
##
## ⚠️ CROP DISCARDS 44% OF THE FRAME WIDTH (1920 -> the centre 1080). That is
## the trade, not a bug: it is the only one of the three that neither distorts
## the picture nor wastes rows, and on a 64x64 panel both of those are worse
## than losing the edges. Say so in the flash so it is never a surprise mid-set.
func _cycle_ddp_fit() -> void:
	_ddp_fit_mode = (_ddp_fit_mode + 1) % DDP_FIT_NAMES.size()
	_settings_dirty = true
	if _ddp != null:
		_ddp.fit_mode = _ddp_fit_mode
	if _btn_ddp_fit != null:
		_btn_ddp_fit.text = "LED fit: %s" % DDP_FIT_NAMES[_ddp_fit_mode]
	var note := ""
	match _ddp_fit_mode:
		1: note = " — SIDES CROPPED"
		2: note = " — BARS TOP/BOTTOM"
		_: note = " — ASPECT IGNORED"
	_flash_status("LED FIT: %s%s" % [DDP_FIT_NAMES[_ddp_fit_mode], note])


func _prompt_ddp_ip() -> void:
	var dlg := M8Dialog.prompt(_chrome_layer, "LED PANEL IP",
		"DDP TARGET ON PORT %d. MUST MATCH STATIC_IP IN THE FIRMWARE'S SECRETS.H."
			% DdpOutput.DDP_PORT,
		_ddp_target_ip, "SET", func(t: String) -> void: _apply_ddp_ip(t))
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


## Validate before committing. A malformed address is REFUSED rather than
## clamped or half-applied: DDP is fire-and-forget UDP, so a bad destination
## fails silently — packets leave, nothing arrives, and there is no error to
## read. Refusing at the point of entry is the only place it can be visible.
func _apply_ddp_ip(text: String) -> void:
	var ip := text.strip_edges()
	if not ip.is_valid_ip_address():
		_flash_status("NOT AN IP ADDRESS — UNCHANGED")
		return
	_ddp_target_ip = ip
	_settings_dirty = true
	if _ddp != null:
		_ddp.target_ip = ip
		# Re-open so the new destination takes effect immediately rather than at
		# the next enable — a performer changing the IP means "now".
		if _ddp_enabled:
			_ddp.set_enabled(false)
			_ddp.set_enabled(true)
	if _btn_ddp_ip != null:
		_btn_ddp_ip.text = "Panel IP: %s" % ip
	_flash_status("LED PANEL: %s" % ip)


# --- Clip source (Video / Drive / Camera) --------------------------------

# Route the active source into the ShaderSlot. Effects + warp run downstream of
# this, so they apply identically to a video clip or the live camera. Camera is
# only powered while it is the active source (battery + lazy permission prompt).
func _apply_source() -> void:
	if _btn_source != null:
		_btn_source.text = _nav_value(SOURCE_NAMES[_source])
	# ⚠️ Only feed ShaderSlot the raw source when masks are NOT in the chain. While they
	# are, ShaderSlot's input is MaskWorld (see _refresh_output_source) and writing the
	# clip texture here would silently unhook the masks from the output.
	if _source == ClipSource.CAMERA:
		# M6 routing: tracking holds the lens → publish ITS camera; otherwise
		# CameraServer as ever. Never both — that pair is the Session-33 wedge.
		_cam_via_tracking = _track_camera != null and _tracking != null \
				and _tracking.is_running()
		# §13.7.4: with camera_via_camerax the deck takes the lens through the
		# TRACKING plugin even when nothing is being tracked — Preview only, no
		# detector, no graph, cheaper than tracking. That is the ONLY way the
		# camera controls (zoom, AE/AWB lock, exposure, torch) can exist on the
		# deck at all: Godot's CameraFeed API has none of them and cannot be
		# made to. It also retires the last CameraServer client, so the §2.1
		# two-client wedge stops being REACHABLE rather than merely avoided.
		# ⚠️ Opt-in (default false): this changes how the deck acquires the
		# camera, which is precisely the class of change that wedged the app on
		# 2026-09-10, and it has never run on a device.
		if not _cam_via_tracking and _track_camera_only and _tracking != null \
				and _tracking.available():
			camera_engine.stop()
			var refuse := _tracking.start(_track_lens, "camera")
			if refuse == "":
				_cam_via_tracking = true
				_track_camera.start()
			else:
				_flash_status("CAMERA-X: %s" % refuse.to_upper())
				camera_engine.start()
		elif _cam_via_tracking:
			camera_engine.stop()
			_track_camera.start()
		else:
			if _track_camera != null:
				_track_camera.stop()
			camera_engine.start()
		var cam_tex := _cam_texture()
		if not _masks_own():
			shader_slot.set_input(cam_tex)
		if _region_comp != null:
			_region_comp.set_source(cam_tex)
	else:
		# VIDEO and DRIVE both play through ClipEngine (Drive clips are cached
		# into the same clips folder), so they share one texture source.
		# ...but the camera stays up while the VIDEO LINK is streaming it — a
		# deck-source flick on the cam phone must not black out the main phone.
		if not _link_uses_camera:
			camera_engine.stop()
			if _track_camera != null:
				_track_camera.stop()
			_cam_via_tracking = false
		# While MixWorld owns the deck image (lane B armed), ShaderSlot samples
		# the MIX — writing the raw deck texture here would unhook it, the same
		# failure mode as the masks guard above.
		if not _masks_own():
			shader_slot.set_input(_source_texture())
		if _lane_b_live():
			_deck_a_rect.texture = clip_engine.active_texture()
		# Regions sample the SOURCE — which is the MIX while lane B is live
		# (spec §3.1: masks apply to the mix). Raw deck A here made lane B and
		# the crossfade invisible whenever any mask region existed.
		if _region_comp != null:
			_region_comp.set_source(_source_texture())
	# ⚠️ THE ONE AUTHORITY, ALWAYS. A source flip changes what _source_texture()
	# returns, and only _refresh_output_source gates MixWorld's update mode —
	# without this, CAMERA→VIDEO with lane B armed sampled a never-rendered
	# disabled MixWorld: black output live. (Idempotent; cheap.)
	_refresh_output_source()


# The deck's live decoder flipped. Re-point everything that samples it — unless the
# camera currently owns the output, in which case the deck texture isn't on screen
# and _apply_source() will pick up the new one when the source switches back.
func _on_active_texture_changed(tex: Texture2D) -> void:
	if _source == ClipSource.CAMERA:
		return
	# Same guard as _apply_source: while masks are chained, ShaderSlot's input is
	# MaskWorld and must not be overwritten by the deck's texture. While MixWorld
	# owns the image, the flip re-points lane A's rect INSIDE the mix instead.
	if _lane_b_live():
		_deck_a_rect.texture = tex
	elif not _masks_own():
		shader_slot.set_input(tex)
	if _region_comp != null:
		_region_comp.set_source(_source_texture())   # the mix while lane B is live


func _set_source(mode: int) -> void:
	# §2.1's gate ROUTES now, it no longer refuses (M6): tracking owns the
	# lens and publishes it, so CAMERA lands on the tracking feed instead of
	# opening a second CameraServer client (that pair is the Session-33 wedge,
	# and it is still never allowed — _apply_source stops one before starting
	# the other). The lens is whichever one TRACKING holds; say so, because
	# the operator asking for CAMERA may be expecting the rear one.
	var via_track := mode == ClipSource.CAMERA and _tracking != null \
			and _tracking.is_running()
	_source = clampi(mode, 0, SOURCE_NAMES.size() - 1)
	_apply_source()
	_settings_dirty = true
	if via_track:
		_flash_status("SOURCE: CAMERA VIA TRACKING (%s LENS)"
				% ("FRONT" if _track_lens == "front" else "REAR"))
	else:
		_flash_status("SOURCE: %s" % SOURCE_NAMES[_source].to_upper())


## SRC: VIDEO <-> CAMERA. DRIVE is no longer offered (2026-09-30): Drive clips
## are downloaded into the clips folder and play as VIDEO, so as a source it was
## a second name for the same thing. The enum keeps its slot (saved as an int);
## a saved DRIVE comes back as VIDEO.
func _cycle_source() -> void:
	_close_panels()
	_set_source(ClipSource.CAMERA if _source != ClipSource.CAMERA else ClipSource.VIDEO)


# The camera feed could not be acquired (no CameraServer feed / permission denied):
# fall back to the video source so the deck keeps running.
func _on_camera_failed(reason: String) -> void:
	# A keystone calibration had borrowed the lens: end it first. That puts the
	# deck's own source back, so the fallback below only fires when the DECK was
	# on CAMERA — and RETRY goes back to what was actually being attempted.
	var was_calib := _calib != null and _calib.active
	if was_calib:
		_calib.abort()
	if _source == ClipSource.CAMERA:
		_source = ClipSource.VIDEO
		_apply_source()
		_settings_dirty = true
	# A hard failure, not a passing notice: show the M8 error modal with a RETRY
	# that re-selects the camera, instead of a toast that vanishes in 2.5 s.
	var retry: Callable = _enter_calibration if was_calib \
			else func(): _set_source(ClipSource.CAMERA)
	var dlg := M8Dialog.error(_chrome_layer, "CAMERA UNAVAILABLE", reason, retry)
	dlg.theme = _theme         # CanvasLayer breaks theme inheritance


# --- Tap tempo -----------------------------------------------------------

func _tap_tempo() -> void:
	# Tap logic + beat grid live in BeatClock now; it emits bpm_changed on a new
	# tempo, which updates the label + marks settings dirty via _on_bpm_changed.
	BeatClock.tap()
	# N4: a tap that lands the SAME bpm still realigned the grid — tell the
	# slaves now rather than letting law v2 discover the phase jump in 3 bars.
	_send_link_beat()
	_flash_status("TAP… %.1f BPM" % BeatClock.bpm)


func _update_bpm_label() -> void:
	if _lbl_bpm != null:
		_lbl_bpm.text = "%.0f" % BeatClock.bpm


# --- Manual BPM entry ----------------------------------------------------
# Tapping the BPM readout types an exact tempo. A MODAL rather than an inline field
# on the nav bar: a permanently focusable LineEdit down there is one mis-tap from
# the Android IME covering the whole deck mid-set, and a modal also gives CANCEL,
# so opening it never commits a tempo.

func _prompt_bpm() -> void:
	var dlg := M8Dialog.prompt(_chrome_layer, "SET BPM",
		"TEMPO IN BPM (%.0f-%.0f). TAP TEMPO STILL SETS THE DOWNBEAT."
			% [BeatClock.BPM_MIN, BeatClock.BPM_MAX],
		"%.0f" % BeatClock.bpm, "SET", func(t: String) -> void: _apply_bpm_text(t),
		M8Dialog.M8_GREEN, PackedStringArray(["IOI", "COMB", "PERC"]),
		func(d: M8Dialog, which: String) -> void: _detect_bpm_into(d, which))
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


## DETECT: ask TempoDetect for a proposal and write it into the field. It is a
## PROPOSAL — the performer still presses SET, and nothing reaches BeatClock until
## they do.
##
## ⚠️ THAT CONFIRMATION STEP IS THE FEATURE, NOT A COURTESY. Two spikes failed to
## build a confidence measure that could separate a right answer from a wrong one
## (AUTO_BPM_SPEC.md: 64% precision, then no separation at all), so the estimator is
## NOT allowed to move the deck by itself. Putting a human in the loop sidesteps the
## unsolved problem: on steady electronic this proposes ~132 against a true 130 and
## you accept; on breakbeat it proposes ~117 against 85, you see it is wrong, and you
## dismiss it. A bad proposal costs one glance instead of a retimed set.
##
## The estimator is always collecting, so this answers instantly rather than making
## the performer stand still for 20 seconds mid-set.
## `which` is the engine the performer picked: IOI, COMB or PERC. Buttons rather
## than one hidden constant, so the algorithms can be compared against a known track
## by tapping each in turn — and so a performer can fall back to whichever handles
## their material if they disagree.
func _detect_bpm_into(dlg: M8Dialog, which: String) -> void:
	if not GlobalBus.mic_active:
		_want_mic()
		dlg.set_body("DETECT LISTENS TO THE ROOM — ALLOW THE MIC, PLAY MUSIC 20 S, TAP AGAIN"
			if not GlobalBus.mic_denied else _mic_blocked_text())
		return
	# ⚠️ Log ALL THREE on every press regardless of which was tapped: one press then
	# yields a directly comparable row on identical audio, instead of needing three.
	# ⚠️ PERC is asynchronous — it runs ~1 s of FFTs on a worker thread and would stall
	# the deck inline. Tapping it STARTS a run and reports when done; the other three
	# answer instantly from data already collected.
	if which == "PERC":
		if TempoDetect.percival_running():
			dlg.set_body("PERC: ANALYSING…")
			return
		if not TempoDetect.percival_ready.is_connected(_on_percival_ready):
			TempoDetect.percival_ready.connect(_on_percival_ready)
		_perc_dialog = dlg
		if TempoDetect.start_percival():
			dlg.set_body("PERC: ANALYSING %.0f s…" % TempoDetect.PERC_SEC)
		else:
			dlg.set_body("PERC: %s" % str(TempoDetect.estimate_all()["perc"]["reason"]))
		return

	var all := TempoDetect.estimate_all()
	var parts: Array[String] = []
	for k: String in ["ioi", "comb"]:
		var e: Dictionary = all[k]
		parts.append("%s=%s conf=%.2f" % [k.to_upper(),
			("%.1f" % float(e["bpm"])) if bool(e["ok"]) else "--", float(e["conf"])])
	print("[TempoDetect] %s | picked=%s" % [" | ".join(parts), which])

	var r: Dictionary = all[which.to_lower()]
	if not bool(r["ok"]):
		# ⚠️ Never fabricate a number here. A wrong tempo the performer cannot
		# distinguish from a right one is the exact failure this whole design avoids.
		dlg.set_body("%s: %s" % [which, str(r["reason"])])
		return
	var bpm: float = r["bpm"]
	dlg.set_field("%.0f" % bpm)
	dlg.set_body("%s: %.1f BPM (CONF %.2f) — PRESS SET TO ACCEPT"
		% [which, bpm, float(r["conf"])])


## The Percival worker finished. Fill the dialog if it is still open — the performer
## may have cancelled during the ~1 s analysis, which is not an error.
func _on_percival_ready(r: Dictionary) -> void:
	# ⚠️ `oct` is logged because the octave decision is otherwise INVISIBLE on device.
	# It was in the return Dictionary and in the synthetic test from the start, but not
	# here — so the first real-material run could not answer whether the stage fired at
	# all, which was the whole point of that run.
	print("[TempoDetect] PERC=%s conf=%.2f oct=x%.1f frames=%d ms=%d %s" % [
		("%.1f" % float(r.get("bpm", 0.0))) if bool(r.get("ok", false)) else "--",
		float(r.get("conf", 0.0)), float(r.get("oct", 1.0)),
		int(r.get("frames", 0)), int(r.get("ms", 0)), str(r.get("reason", ""))])
	if _perc_dialog == null or not is_instance_valid(_perc_dialog):
		return
	if not bool(r.get("ok", false)):
		_perc_dialog.set_body("PERC: %s" % str(r.get("reason", "FAILED")))
		return
	var bpm: float = r["bpm"]
	_perc_dialog.set_field("%.0f" % bpm)
	_perc_dialog.set_body("PERC: %.1f BPM (CONF %.2f, %d ms) — PRESS SET"
		% [bpm, float(r["conf"]), int(r.get("ms", 0))])


## Commit typed text as the tempo. Everything downstream is already wired: set_bpm
## clamps, emits bpm_changed, and _on_bpm_changed updates the label and marks the
## settings dirty — so nothing here has to touch the label or persistence.
func _apply_bpm_text(text: String) -> void:
	var t := text.strip_edges()
	# ⚠️ VALIDATE FIRST. to_float() answers 0.0 for anything unparseable, which
	# set_bpm would silently clamp to BPM_MIN — a wrong tempo that looks deliberate
	# and would have the deck cutting at 40 with no indication why.
	if not t.is_valid_float():
		_flash_status("BPM UNCHANGED — '%s' IS NOT A NUMBER" % t)
		return
	BeatClock.set_bpm(t.to_float())
	# ⚠️ NO reset_grid() HERE, DELIBERATELY. tap() realigns the grid because a tap IS
	# a downbeat — the performer is marking WHERE the beat falls. Typing a number
	# corrects the RATE only and must leave the grid's phase alone, so a manual entry
	# mid-bar cannot shunt every beat-synced consumer (SEQUENTIAL, the sequencer's
	# slot clock, BEAT FLIP on GRID) onto a new downbeat under the performer.
	# Consequence to expect: typing 120 and tapping 120 give the same RATE but
	# different alignment. That asymmetry is the feature.
	#
	# Read the tempo BACK rather than echoing the input: an out-of-range number is
	# clamped by set_bpm, so typing 500 must report 300, not 500.
	_flash_status("BPM %.0f" % BeatClock.bpm)


# --- Effects -------------------------------------------------------------

func _cycle_effect() -> void:
	_effect_index = (_effect_index + 1) % _effects.size()
	_apply_effect()


func _apply_effect() -> void:
	var effect := _effects[_effect_index]
	if effect.shader == null:
		shader_slot.set_shader(preload("res://shaders/passthrough.gdshader"))
	else:
		shader_slot.set_shader(effect.shader)
	# Feedback buffer on only for effects that declare they need history. Set
	# BEFORE the params push so `prev_frame` is bound when the material is fresh.
	shader_slot.set_history_enabled(bool(effect.get("history", false)))
	# Multi-frame ring, gated the same way and independently of the 1-frame
	# history above. Configure BEFORE enabling so the first prime uses the real
	# band count and axis rather than painting the atlas twice.
	if bool(effect.get("slices", false)):
		shader_slot.set_slice_bands(int(_slitscan_span))
		shader_slot.set_slice_axis(_slitscan_direction)
	shader_slot.set_slice_history_enabled(bool(effect.get("slices", false)))
	# Off/passthrough has no `intensity` uniform — let _process skip the write.
	_effect_has_intensity = effect.shader != null
	_last_intensity = -1.0   # force one push into the freshly-swapped material
	# A fresh material: its tunables are their own bases again, and the target
	# rows name this effect's FX A / FX B.
	_mod_fx_base.clear()
	_mod_fx_written.clear()
	_refresh_mod_rows()
	if _btn_effect != null:
		_btn_effect.text = _nav_value(str(effect.name))
	_apply_effect_params()      # push this effect's saved uniforms into the new material
	_update_fx_buttons()        # highlight the active effect in the FX panel
	_rebuild_fx_settings()      # show the selected effect's tunables
	_settings_dirty = true
	print("[fx] %s" % effect.name)
	_flash_status("EFFECT: %s" % str(effect.name).to_upper())


# Push the current effect's tunable uniforms into the active ShaderSlot material.
# (intensity is driven every frame in _process; these are the static tweakables.)
func _apply_effect_params() -> void:
	var mat := shader_slot.get_shader_material()
	if mat == null:
		return
	if str(_effects[_effect_index].name) == "ASCII":
		mat.set_shader_parameter("columns", _ascii_columns)
		mat.set_shader_parameter("spacing", _ascii_spacing)
		mat.set_shader_parameter("mode", _ascii_mode)
		mat.set_shader_parameter("text_len", mini(_ascii_text.length(), 64))
		mat.set_shader_parameter("text_chars", _ascii_text_codes())
		mat.set_shader_parameter("alphabet", _ascii_alphabet())
	elif str(_effects[_effect_index].name) == "Glitch":
		# intensity is NOT pushed here — _process owns it every frame.
		mat.set_shader_parameter("block_count", _glitch_block_count)
		mat.set_shader_parameter("block_size", _glitch_block_size)
		mat.set_shader_parameter("block_aspect", _glitch_block_aspect)
	elif str(_effects[_effect_index].name) == "Bloom":
		# intensity is NOT pushed here — _process owns it every frame.
		mat.set_shader_parameter("threshold", _bloom_threshold)
		mat.set_shader_parameter("radius", _bloom_radius)
	elif str(_effects[_effect_index].name) == "Displace":
		# intensity is NOT pushed here — _process owns it every frame.
		mat.set_shader_parameter("scale", _displace_scale)
		mat.set_shader_parameter("speed", _displace_speed)
		mat.set_shader_parameter("pattern", _displace_pattern)
	elif str(_effects[_effect_index].name) == "Trails":
		# intensity is NOT pushed here — _process owns it every frame. Nor is
		# prev_frame: ShaderSlot binds that when it enables the history buffer.
		mat.set_shader_parameter("decay", _trails_decay)
		mat.set_shader_parameter("blend", _trails_blend)
	elif str(_effects[_effect_index].name) == "Slit-Scan":
		# intensity is NOT pushed here — _process owns it every frame. Nor are
		# slices/slices_bound/bands/write_index: ShaderSlot owns the ring and
		# pushes those, so `span` reaches the shader as the ring's band count
		# rather than as a uniform of its own.
		mat.set_shader_parameter("direction", _slitscan_direction)
	elif str(_effects[_effect_index].name) == "Solarize":
		# intensity is NOT pushed here — _process owns it every frame.
		mat.set_shader_parameter("mode", _solarize_mode)
		mat.set_shader_parameter("threshold", _solarize_threshold)
	elif str(_effects[_effect_index].name) == "HUD Rings":
		mat.set_shader_parameter("steps", _rings_steps)
		mat.set_shader_parameter("rings", _rings_count)
		mat.set_shader_parameter("ring_scale", _rings_scale)
	elif str(_effects[_effect_index].name) == "HUD":
		mat.set_shader_parameter("mode", _hud_mode)
		mat.set_shader_parameter("hud_scale", _hud_scale)
		mat.set_shader_parameter("weight", _hud_weight)
		mat.set_shader_parameter("readout", _hud_readout)
		# points are pushed EVERY FRAME by _push_crowd_uniforms, same as Crowd
	elif str(_effects[_effect_index].name) == "Crowd":
		mat.set_shader_parameter("mode", _crowd_fx_mode)
		mat.set_shader_parameter("reach", _crowd_fx_reach)
		mat.set_shader_parameter("sink", _crowd_fx_sink)
		mat.set_shader_parameter("push", _crowd_fx_push)
		# the slots themselves are pushed EVERY FRAME by _push_crowd_uniforms —
		# this path only runs on an effect/param change, and a crowd that only
		# moved when a slider did would be a very odd instrument.


## Per-slot data into the ONE array uniform (§13.5). x arrives from the tracker
## already in audience-view space — the §4.2 mirror happens on the way out, so
## nothing here has to know which lens is live.
##
## ⚠️ A slot inside its §13.3 grace window still reports present=1 and holds its
## last position. That is deliberate all the way to the wall: an occluded
## performer must not make the visual blink out and back.
func _push_crowd_uniforms() -> void:
	var mat := shader_slot.get_shader_material()
	if mat == null or mat.shader == null:
		return
	var arr := PackedVector4Array()
	arr.resize(8)
	var n := 0
	# ⚠️ LANDMARK MODE FILLS THIS TOO. The points array was crowd-only, which
	# meant every point-driven effect went dark the moment you switched to face
	# tracking — and hands only EXIST in landmark mode, so "an effect on the
	# hands" was unreachable by construction. Head is point 0, hand is point 1;
	# `size` carries head_size / a nominal hand size so radii still scale.
	if _tracking != null and _tracking.is_running() and _tracking.mode() == "landmark":
		var h := _tracking.head()
		if _tracking.presence() >= 0.5:
			# ⚠️ head_size is INTER-OCULAR / frame width (§4). A head is roughly
			# 3x that tall, and crowd mode's `size` is a body's HEIGHT — so
			# without this the same scale slider means two different things and
			# the HUD renders 5-10x too small on a face.
			var hs := maxf(_tracking.value_at(TrackingEngine.IDX_HEAD_SIZE), 0.05) * 3.0
			arr[n] = Vector4(h.x, h.y, hs, 1.0)
			n += 1
		if _tracking.hand_present():
			var hd := _tracking.hand()
			arr[n] = Vector4(hd.x, hd.y, 0.12, 1.0)
			n += 1
	elif _tracking != null and _tracking.is_running() and _tracking.mode() == "crowd":
		var ct := _tracking.crowd
		n = mini(ct.slots, 8)
		# ⚠️ MAP CAMERA SPACE -> DECK UV. The tracker's coordinates are in the
		# ANALYSIS frame; the deck shows the PREVIEW frame after the OES chain
		# (rot 270, mirror, cover-fit). Composing that chain for the measured
		# rot=270 / mirror=false gives, for a deck pixel (U,V):
		#     analysis_x = 1 - U
		#     analysis_y = 0.5 + (0.5 - V) * fit
		# so the inverse — what this needs — is:
		#     U = 1 - raw_x          V = 0.5 - (raw_y - 0.5)/fit     h = size/fit
		# Feeding raw coordinates straight in put the box on the wrong side AND
		# made it taller than the frame (fit 0.75 => 1.33x), which rendered as
		# two full-height vertical lines.
		var fit := 1.0
		if _track_camera != null and _cam_via_tracking:
			fit = maxf(_track_camera.last_fit, 0.001)
		for si in n:
			var rx := ct.slot_raw(si, CrowdTracker.CH_X)
			var ry := ct.slot_raw(si, CrowdTracker.CH_Y)
			var rs := ct.slot_raw(si, CrowdTracker.CH_SIZE)
			# ⚠️ NOT 1.0 - rx. The derivation of the OES chain said the deck was
			# horizontally flipped relative to the analysis frame, and ONE person
			# near centre could never disprove it (raw 0.48 vs flipped 0.52 are
			# the same place). TWO people showed it immediately: the boxes landed
			# on each other's subjects. Settable so it stays testable rather than
			# being another derivation taken on trust.
			var dx := (1.0 - rx) if _crowd_fx_flip else rx
			var dy := 0.5 - (ry - 0.5) / fit
			var dh := rs / fit
			# ⚠️ CLAMP INTO THE FRAME, HERE, WHERE IT PRINTS. A subject close to
			# the lens reports a box taller than the deck can show (measured:
			# raw 0.83 of a 4:3 analysis frame, then a 0.75 cover-fit = 1.11 of
			# the 16:9 deck), so its horizontal edges fall outside and only two
			# vertical lines render — correct geometry, unreadable result.
			var top := clampf(dy - dh * 0.5, 0.05, 0.95)
			var bot := clampf(dy + dh * 0.5, 0.05, 0.95)
			dy = (top + bot) * 0.5
			dh = maxf(bot - top, 0.02)
			arr[si] = Vector4(dx, dy, dh,
				ct.slot_raw(si, CrowdTracker.CH_PRESENT))
		# once a second, so the mapping is CHECKABLE against a screenshot rather
		# than another derivation taken on trust
		if ct.count() > 0 and Engine.get_process_frames() % 60 == 0:
			print("[crowdfx] slot0 raw=%.2f,%.2f,%.2f -> deck=%.2f,%.2f,h=%.2f (top %.2f bot %.2f) fit=%.3f flip=%s" % [
				ct.slot_raw(0, CrowdTracker.CH_X), ct.slot_raw(0, CrowdTracker.CH_Y),
				ct.slot_raw(0, CrowdTracker.CH_SIZE),
				arr[0].x, arr[0].y, arr[0].z,
				arr[0].y - arr[0].z * 0.5, arr[0].y + arr[0].z * 0.5, fit, str(_crowd_fx_flip)])
	mat.set_shader_parameter("crowd", arr)
	mat.set_shader_parameter("crowd_n", n)
	# Radii are circles only if the shader knows the frame's shape; without this
	# every "circle" is an ellipse on a 16:9 deck.
	var sz := output_world.size
	mat.set_shader_parameter("aspect",
		float(sz.x) / maxf(float(sz.y), 1.0) if sz.y > 0 else 1.777)


# Custom-text → a 64-long int array of glyph codes (A-Z 0..25, 0-9 26..35, else 36).
func _ascii_text_codes() -> PackedInt32Array:
	var codes := PackedInt32Array()
	var up := _ascii_text.to_upper()
	for i in up.length():
		if codes.size() >= 64:
			break
		var c := up.unicode_at(i)
		if c >= 65 and c <= 90:          # A-Z → 0..25
			codes.append(c - 65)
		elif c >= 48 and c <= 57:        # 0-9 → 26..35
			codes.append(26 + (c - 48))
		else:
			codes.append(36)             # space / blank
	while codes.size() < 64:             # shader wants a fixed-size int[64]
		codes.append(36)
	return codes


# 37 bit-packed 5x5 glyphs (A-Z, 0-9, space) authored as readable rows.
# Bit b = col + row*5 (row 0 = top), matching ascii.gdshader's glyph_px().
func _ascii_alphabet() -> PackedInt32Array:
	var pats := [
		"01110 10001 11111 10001 10001", "11110 10001 11110 10001 11110",  # A B
		"01111 10000 10000 10000 01111", "11110 10001 10001 10001 11110",  # C D
		"11111 10000 11110 10000 11111", "11111 10000 11110 10000 10000",  # E F
		"01111 10000 10011 10001 01111", "10001 10001 11111 10001 10001",  # G H
		"11111 00100 00100 00100 11111", "00111 00010 00010 10010 01100",  # I J
		"10001 10010 11100 10010 10001", "10000 10000 10000 10000 11111",  # K L
		"10001 11011 10101 10001 10001", "10001 11001 10101 10011 10001",  # M N
		"01110 10001 10001 10001 01110", "11110 10001 11110 10000 10000",  # O P
		"01110 10001 10101 01110 00011", "11110 10001 11110 10010 10001",  # Q R
		"01111 10000 01110 00001 11110", "11111 00100 00100 00100 00100",  # S T
		"10001 10001 10001 10001 01110", "10001 10001 10001 01010 00100",  # U V
		"10001 10001 10101 11011 10001", "10001 01010 00100 01010 10001",  # W X
		"10001 01010 00100 00100 00100", "11111 00010 00100 01000 11111",  # Y Z
		"01110 10011 10101 11001 01110", "00100 01100 00100 00100 01110",  # 0 1
		"01110 10001 00110 01000 11111", "11110 00001 00110 00001 11110",  # 2 3
		"00010 00110 01010 11111 00010", "11111 10000 11110 00001 11110",  # 4 5
		"01110 10000 11110 10001 01110", "11111 00001 00010 00100 01000",  # 6 7
		"01110 10001 01110 10001 01110", "01110 10001 01111 00001 01110",  # 8 9
		"00000 00000 00000 00000 00000",                                    # space
	]
	var out := PackedInt32Array()
	for p: String in pats:
		var clean := p.replace(" ", "")   # 25 chars, row-major
		var g := 0
		for i in clean.length():
			if clean[i] == "1":
				g |= (1 << i)
		out.append(g)
	return out


# --- Macropad input probe (DIAGNOSTIC ONLY — nothing is mapped) ----------
#
# TEMPORARY. A QMK macropad (2 rotary encoders + 8 keys) is attached through
# the USB-C hub; this makes every event it sends visible in logcat so each
# control can be identified BEFORE anything is wired to it. It observes only —
# it never calls set_input_as_handled(), so no event is consumed and no
# existing behaviour changes. Delete this block and its two call sites (the
# first line of _input, and _probe_announce in _ready) to remove it, or flip
# INPUT_PROBE to false to silence it.
#
# Hooked into _input rather than _unhandled_input on purpose: _unhandled_input
# only receives what the GUI declined, so a key the focused control swallowed
# would never appear — which is exactly the case that would read as "the pad
# sent nothing".
#
# On device the pad enumerates as `fjgh kb8knob v.1.0` (RP2040, VID 0x2E8A /
# PID 0x0011) across FOUR kernel nodes — keyboard, Mouse, System Control and
# Consumer Control. The descriptors advertise generic HID boilerplate (a full
# 104-key set, the whole consumer page), so they say nothing about what is
# actually mapped. Only pressing the keys does. Two consequences shape what is
# logged below:
#
#  - The Mouse node exposes REL_WHEEL / REL_HWHEEL, a very common QMK encoder
#    default, and Godot delivers those as InputEventMouseButton WHEEL_* — not
#    as keys and not as joypad events. Hence the explicit mouse branch.
#  - An encoder mapped to KEY_VOLUMEUP/DOWN on Consumer Control may be eaten by
#    Android as a system volume change and never reach Godot at all. A knob
#    that logs NOTHING is therefore a QMK mapping question, not a broken probe.
const INPUT_PROBE := false

## Rate-limit clocks and suppressed-event counters, keyed by event family. Touch
## and mouse-motion arrive at pointer rates and would bury the pad's few lines.
var _probe_last: Dictionary = {}
var _probe_skipped: Dictionary = {}

const PROBE_MOUSE_NAMES := {
	MOUSE_BUTTON_LEFT: "LEFT", MOUSE_BUTTON_RIGHT: "RIGHT", MOUSE_BUTTON_MIDDLE: "MIDDLE",
	MOUSE_BUTTON_WHEEL_UP: "WHEEL_UP", MOUSE_BUTTON_WHEEL_DOWN: "WHEEL_DOWN",
	MOUSE_BUTTON_WHEEL_LEFT: "WHEEL_LEFT", MOUSE_BUTTON_WHEEL_RIGHT: "WHEEL_RIGHT",
	MOUSE_BUTTON_XBUTTON1: "XBUTTON1", MOUSE_BUTTON_XBUTTON2: "XBUTTON2",
}


## True when `key` may print again. Never drops silently — the count of
## suppressed events is reported on the next line that does get through, so a
## flood is visible as a number rather than as absence.
func _probe_rate_ok(key: String, gap_ms: int) -> bool:
	var now := Time.get_ticks_msec()
	var last: int = int(_probe_last.get(key, -1000000))
	if now - last < gap_ms:
		_probe_skipped[key] = int(_probe_skipped.get(key, 0)) + 1
		return false
	_probe_last[key] = now
	var n: int = int(_probe_skipped.get(key, 0))
	if n > 0:
		_probe_skipped[key] = 0
		print("[probe] ...%d %s events suppressed since the last line" % [n, key])
	return true


func _probe_announce() -> void:
	print("[probe] ============ INPUT PROBE ACTIVE ============")
	print("[probe] Diagnostic only — NOTHING is mapped to the pad yet.")
	print("[probe] all events : adb logcat -s godot:* | grep '\\[probe\\]'")
	print("[probe] pad only   : ...that, then | grep -vE 'TOUCH|MOUSEMOVE'")
	# emulate_mouse_from_touch is ON in project.godot, so a finger on the screen
	# ALSO produces mouse events. Say so here rather than let a screen tap get
	# mistaken for an encoder click — compare the dev= field to tell them apart.
	print("[probe] NOTE: emulate_mouse_from_touch=true — screen taps also emit MOUSE events; compare dev=")
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		print("[probe] joypads: NONE connected (a QMK pad normally binds as HID keyboard, not a joypad)")
	else:
		for id in pads:
			print("[probe] joypad %d: name=%s guid=%s" % [id, Input.get_joy_name(id), Input.get_joy_guid(id)])
	# …and if one appears later (the pad re-enumerating, a replug), say so.
	Input.joy_connection_changed.connect(func(id: int, connected: bool) -> void:
		print("[probe] JOYPAD %s: id=%d name=%s" %
			["CONNECTED" if connected else "DISCONNECTED", id,
			Input.get_joy_name(id) if connected else "-"]))


## Print one line per event. Deliberately exhaustive: the catch-all at the end
## is the branch that matters if a knob arrives as something unanticipated.
func _probe_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		# keycode / physical_keycode / key_label are printed SEPARATELY and not
		# collapsed: a QMK layer can send a keycode whose label and physical
		# position disagree, and which of the three is stable is the whole
		# question when it comes to mapping this later.
		print("[probe] KEY       dev=%d %-4s keycode=%d(%s) physical=%d(%s) label=%d(%s) unicode=%d echo=%s" % [
			k.device, "DOWN" if k.pressed else "UP",
			k.keycode, OS.get_keycode_string(k.keycode),
			k.physical_keycode, OS.get_keycode_string(k.physical_keycode),
			k.key_label, OS.get_keycode_string(k.key_label),
			k.unicode, str(k.echo)])
	elif event is InputEventJoypadButton:
		var jb := event as InputEventJoypadButton
		print("[probe] JOYBTN    dev=%d %-4s button=%d pressure=%.3f" % [
			jb.device, "DOWN" if jb.pressed else "UP", jb.button_index, jb.pressure])
	elif event is InputEventJoypadMotion:
		var jm := event as InputEventJoypadMotion
		# An encoder reported as an axis can stream at frame rate — rate-limit per
		# AXIS so a busy axis can never hide a quiet one.
		if _probe_rate_ok("JOYAXIS%d" % jm.axis, 120):
			print("[probe] JOYAXIS   dev=%d axis=%d value=%+.4f" % [jm.device, jm.axis, jm.axis_value])
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# THE LIKELY ENCODER PATH — a QMK knob mapped to the mouse wheel lands
		# here, not in InputEventKey. Never rate-limited: wheel steps are the
		# signal, and they are low-volume.
		print("[probe] MOUSEBTN  dev=%d %-4s button=%d(%s) factor=%.2f pos=(%.0f,%.0f) dbl=%s" % [
			mb.device, "DOWN" if mb.pressed else "UP", mb.button_index,
			PROBE_MOUSE_NAMES.get(mb.button_index, "?"), mb.factor,
			mb.position.x, mb.position.y, str(mb.double_click)])
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _probe_rate_ok("MOUSEMOVE", 400):
			print("[probe] MOUSEMOVE dev=%d rel=(%+.1f,%+.1f) pos=(%.0f,%.0f)" % [
				mm.device, mm.relative.x, mm.relative.y, mm.position.x, mm.position.y])
	elif event is InputEventMIDI:
		var m := event as InputEventMIDI
		print("[probe] MIDI      dev=%d msg=%d ch=%d pitch=%d vel=%d ctrl=%d val=%d" % [
			m.device, m.message, m.channel, m.pitch, m.velocity,
			m.controller_number, m.controller_value])
	elif event is InputEventScreenTouch or event is InputEventScreenDrag:
		# The operator's own fingers, not the pad — kept (so the log is honestly
		# "every event") but rate-limited hard, and tagged TOUCH so it greps out.
		if _probe_rate_ok("TOUCH", 500):
			print("[probe] TOUCH     dev=%d %s" % [event.device, event.as_text()])
	else:
		# The branch that earns the probe: anything not anticipated above prints
		# its class and full text, so an unexpected encoder encoding is legible
		# rather than invisible.
		print("[probe] OTHER     dev=%d class=%s %s" % [
			event.device, event.get_class(), event.as_text()])


# --- Input (desktop keyboard shortcuts; device uses the control bar) ------

# A three-finger tap anywhere toggles Performance Mode (enter or exit). Tracked
# in _input so it works regardless of which controls the fingers land on.
func _input(event: InputEvent) -> void:
	if INPUT_PROBE:
		_probe_input(event)   # observes only — never consumes (see the block above)
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = true
			_row_press_pos = event.position
			_row_moved = 0.0
			_row_suppressed = false
			_help_swallow = false
			# Help: in HELP MODE a tap on a row shows its card instead of acting;
			# otherwise a HOLD does. Either way only with one finger down. The
			# decision waits a frame, until the GUI knows what is under the finger.
			if _touches.size() == 1:
				_help_hold_pos = event.position
				if _help_mode:
					_help_intercept.call_deferred(event.position)
				else:
					_help_hold_timer.start()
			else:
				_help_hold_timer.stop()
			# Don't hijack multi-finger corner dragging while warp-editing — but
			# never while chrome is hidden: with the editor invisible no corner
			# can be dragged, and the gesture is the only touch way back out of
			# PERFORM (entering it with warp open would otherwise trap the UI).
			var warping := ((_warp != null and _warp.active) \
					or (_calib != null and _calib.active)) and not _perf_mode
			if _touches.size() >= 3 and not _three_finger_fired and not warping:
				_three_finger_fired = true
				_toggle_perf()
				get_viewport().set_input_as_handled()
		else:
			# Belt and braces over the drag accumulator below: a FAST swipe can
			# deliver DOWN+UP with barely any drag events between them, so the
			# accumulator alone can miss it and let the row fire (the same trap
			# ClipGrid._press documents). _input runs ahead of GUI picking, so this
			# is set before the Button turns the release into `pressed`.
			if _row_press_pos.distance_to(event.position) > PANEL_TAP_SLOP:
				_row_suppressed = true
			_help_hold_timer.stop()
			_touches.erase(event.index)
			if _touches.is_empty():
				_three_finger_fired = false   # re-arm once all fingers lift

	# Drag-to-scroll the docked sidebar. The list rows are Buttons with
	# MOUSE_FILTER_STOP, so they swallow the drag before the ScrollContainer ever
	# sees it — which left anything past the fold (e.g. the ASCII effect, last in
	# a 7-item list) UNREACHABLE by touch. Handled here in _input, which runs
	# ahead of GUI picking.
	elif event is InputEventScreenDrag:
		# Past the slop this touch is a scroll, not a tap, and _add_button_row
		# swallows its press. Set on the DRAG rather than at release so it does not
		# depend on _input beating the Button to the release event.
		_row_moved += absf(event.relative.x) + absf(event.relative.y)
		if _row_moved > PANEL_TAP_SLOP:
			_row_suppressed = true
			_help_hold_timer.stop()   # a scroll is not a hold
		for sc in _panel_scrolls:
			if sc != null and is_instance_valid(sc) and sc.is_visible_in_tree() \
					and sc.get_global_rect().has_point(event.position):
				sc.scroll_vertical -= int(event.relative.y)
				break


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_SPACE:
			_cycle_effect()
		KEY_RIGHT:
			clip_engine.next_clip()
		KEY_LEFT:
			clip_engine.prev_clip()
		KEY_M:
			_cycle_mode()
		KEY_T:
			_tap_tempo()
		KEY_R:
			_rescan()
		KEY_W:
			_enter_warp()
		KEY_P:
			_toggle_perf()


# --- Control bar UI (touch buttons + readouts) ---------------------------

func _build_controls() -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 0)
	# Span the viewport width (anchored to a CanvasLayer = anchors to the viewport)
	# with room for up to two wrapped rows; identical to a single row when it fits.
	bar.anchor_right = 1.0
	bar.offset_left = 0.0
	bar.offset_top = 0.0
	bar.offset_right = 0.0
	bar.offset_bottom = 96.0
	bar.add_theme_constant_override("h_separation", 0)
	# M8 top-bar backdrop: translucent black strip with a thin cyan underline.
	var bar_bg := Panel.new()
	bar_bg.anchor_right = 1.0
	bar_bg.offset_top = 0.0
	bar_bg.offset_bottom = 96.0
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar_sb := StyleBoxFlat.new()
	bar_sb.bg_color = Color(0, 0, 0, 1)   # solid black nav strip
	bar_sb.border_color = Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.5)
	bar_sb.border_width_bottom = 1
	bar_bg.add_theme_stylebox_override("panel", bar_sb)
	_bar_bg = bar_bg
	_ui_add(bar_bg)

	_ui_add(bar)
	_main_bar = bar

	# M8 cells: a tiny dim ABBREVIATION above its VALUE, thin green divider between.
	# Abbreviations: PREV NEXT MODE FX SRC TAP WRP MSK LIB PERF.
	bar.add_child(_m8_cell("PREV", "◄", func(): clip_engine.prev_clip())[0])
	bar.add_child(_m8_cell("NEXT", "►", func(): clip_engine.next_clip())[0])
	_cell_mode = _m8_cell("MODE", MODE_NAMES[_mode], func(): _toggle_mode_panel())
	_btn_mode = _cell_mode[1]; bar.add_child(_cell_mode[0])
	_cell_fx = _m8_cell("FX", str(_effects[_effect_index].name), func(): _toggle_fx_panel())
	_btn_effect = _cell_fx[1]; bar.add_child(_cell_fx[0])
	var c_src := _m8_cell("SRC", SOURCE_NAMES[_source], func(): _cycle_source())
	_btn_source = c_src[1]; bar.add_child(c_src[0])
	_cell_tap = _m8_cell("TAP", "●", func(): _tap_tempo())
	bar.add_child(_cell_tap[0])
	_cell_wrp = _m8_cell("WRP", "CORNERS", func(): _enter_warp())
	bar.add_child(_cell_wrp[0])
	_cell_msk = _m8_cell("MSK", "POLYGON", func(): _enter_masks())
	bar.add_child(_cell_msk[0])
	_cell_lib = _m8_cell("LIB", "SOURCES", func(): _toggle_params())
	bar.add_child(_cell_lib[0])
	bar.add_child(_m8_cell("PERF", "QUEUE", func(): _enter_perf())[0])
	# REC last, next to BPM — a transport action, not a mode panel. Its value is
	# the remaining record-time when idle ("42M") so the storage limit is known
	# BEFORE arming, and elapsed ("12:34") while recording. Both stay well inside
	# NAV_MAX_CHARS; see _nav_value for why that matters.
	_cell_rec = _m8_cell("REC", "OFF", func(): _toggle_rec())
	bar.add_child(_cell_rec[0])

	# The TAP dot pulses on the beat — driven by the GlobalBus SIGNAL, never polled
	# per frame (see the performance notes).
	GlobalBus.beat.connect(_pulse_tap_dot)
	# Audio-advance now rides the same onset the TAP dot flashes on, so what the
	# performer SEES pulsing is exactly what cuts the deck (spec §0 fix).
	GlobalBus.beat.connect(_on_audio_onset)
	# Mic PCM -> recorder. GlobalBus only emits while a recording asked for it.
	GlobalBus.pcm_captured.connect(_on_pcm_captured)

	# BPM readout, right end of the bar: big amber number in the pixel font. A BUTTON
	# (was a bare VBoxContainer) so it can open manual tempo entry — the same
	# Button-wrapping-a-VBox shape _m8_cell uses, so the bar stays consistent.
	#
	# ⚠️ normal/hover are TRANSPARENT on purpose: the old VBoxContainer carried an
	# add_theme_stylebox_override("panel", ...) that never drew anything, because
	# VBoxContainer has no `panel` stylebox. Matching the resting look means matching
	# what actually rendered — nothing — so converting this to a Button is invisible
	# until pressed. (The intended left border is still not drawn; left alone rather
	# than smuggling a visual change into a behaviour commit.)
	var bpm_cell := Button.new()
	bpm_cell.focus_mode = Control.FOCUS_NONE
	bpm_cell.custom_minimum_size = Vector2(150, 96)
	var bpm_flat := StyleBoxFlat.new()
	bpm_flat.bg_color = Color(0, 0, 0, 0)
	bpm_flat.set_corner_radius_all(0)
	bpm_cell.add_theme_stylebox_override("normal", bpm_flat)
	bpm_cell.add_theme_stylebox_override("hover", bpm_flat)
	bpm_cell.add_theme_stylebox_override("pressed", _cell_stylebox(true))
	bpm_cell.pressed.connect(_prompt_bpm)
	var bpm_box := VBoxContainer.new()
	bpm_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bpm_box.alignment = BoxContainer.ALIGNMENT_CENTER
	bpm_box.add_theme_constant_override("separation", 3)
	bpm_box.mouse_filter = Control.MOUSE_FILTER_IGNORE   # taps belong to the button
	bpm_cell.add_child(bpm_box)
	_lbl_bpm = _make_label("%.0f" % BeatClock.bpm)
	_lbl_bpm.add_theme_font_override("font", FONT_PIXEL)
	_lbl_bpm.add_theme_font_size_override("font_size", 22)
	_lbl_bpm.add_theme_color_override("font_color", M8_GREEN)
	_lbl_bpm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var bpm_lab := _make_label("BPM")
	bpm_lab.add_theme_font_size_override("font_size", 12)
	bpm_lab.add_theme_color_override("font_color", M8_LABEL)
	bpm_lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bpm_box.add_child(_lbl_bpm)
	bpm_box.add_child(bpm_lab)
	bar.add_child(bpm_cell)

	# Bottom status bar (see _build_status_bar).
	_build_status_bar()

	# Move the transient status flash clear of the control bar.
	status.offset_top = 130.0
	status.offset_bottom = 350.0


# M8 bottom status bar: a full-width black strip pinned to the bottom edge, with
# "CLIP 13/28 · name.mp4" on the LEFT and the output state on the RIGHT — exactly
# the reference layout. Anchored (not absolutely positioned), so it follows the
# viewport without any per-frame repositioning.
func _build_status_bar() -> void:
	var bar := PanelContainer.new()
	bar.anchor_left = 0.0
	bar.anchor_right = 1.0
	bar.anchor_top = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_top = -STATUSBAR_H
	bar.offset_bottom = 0.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)
	sb.set_corner_radius_all(0)
	sb.border_color = M8_LINE
	sb.border_width_top = 1
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	bar.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# LEFT: CLIP XX/XX · filename.mp4
	_lbl_clip = _make_label("CLIP 0/0")
	_lbl_clip.add_theme_font_size_override("font_size", 20)
	_lbl_clip.add_theme_color_override("font_color", M8_DIMTEXT)
	_lbl_clip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_clip.clip_text = true
	row.add_child(_lbl_clip)

	# RIGHT: the REC indicator, then FPS, then OUT.
	#
	# ⚠️ M8_RED here is a DELIBERATE, DOCUMENTED exception to the single-accent
	# rule. Session 9b deleted the cyan/amber/orange aliases and reserved M8_RED
	# for errors/destructive actions — but a recording indicator is the one place
	# red universally means "recording", not "something is wrong", and §2 of
	# SET_RECORDING_SPEC.md asks for a dot that cannot be mistaken for anything
	# else. Do not "correct" this back to green.
	#
	# This lives in the UI CanvasLayer (_ui_add), which is structurally OUTSIDE
	# OutputWorld — so it can never reach the projector. That is a requirement,
	# not an accident: chrome on the wall would ruin a set.
	_dot_rec = Panel.new()
	_dot_rec.custom_minimum_size = Vector2(16, 16)
	_dot_rec.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot_sb := StyleBoxFlat.new()
	dot_sb.bg_color = M8_RED
	dot_sb.set_corner_radius_all(8)
	_dot_rec.add_theme_stylebox_override("panel", dot_sb)
	_dot_rec.visible = false
	row.add_child(_dot_rec)

	_lbl_rec = _make_label("REC 0:00")
	_lbl_rec.add_theme_font_size_override("font_size", 20)
	_lbl_rec.add_theme_color_override("font_color", M8_RED)
	_lbl_rec.visible = false
	row.add_child(_lbl_rec)

	var rec_sep := _make_label("  ")
	rec_sep.add_theme_font_size_override("font_size", 20)
	row.add_child(rec_sep)

	# LINK stats sit left of FPS, built hidden: _update_link_stats (1 Hz, only
	# ticking while the link is enabled) is the sole shower/hider. The divider
	# is a separate label so it can vanish with the readout — a stranded " · "
	# next to FPS would read as a broken bar.
	_lbl_link = _make_label("")
	_lbl_link.add_theme_font_size_override("font_size", 20)
	_lbl_link.add_theme_color_override("font_color", M8_DIMTEXT)
	_lbl_link.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_lbl_link.visible = false
	row.add_child(_lbl_link)

	_lbl_link_sep = _make_label(" · ")
	_lbl_link_sep.add_theme_font_size_override("font_size", 20)
	_lbl_link_sep.add_theme_color_override("font_color", M8_LABEL)
	_lbl_link_sep.visible = false
	row.add_child(_lbl_link_sep)

	# FPS readout, then OUT. The nav bar has no room for an FPS cell — its
	# ten cells already clip a 12-char value like KALEIDOSCOPE, and a second fixed
	# cell next to BPM would start clipping SEQUENTIAL too — so the diagnostic
	# lives here, where there is space.
	_lbl_fps = _make_label("FPS --")
	_lbl_fps.add_theme_font_size_override("font_size", 20)
	_lbl_fps.add_theme_color_override("font_color", M8_DIMTEXT)
	_lbl_fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_lbl_fps)

	var sep := _make_label(" · ")
	sep.add_theme_font_size_override("font_size", 20)
	sep.add_theme_color_override("font_color", M8_LABEL)
	row.add_child(sep)

	_lbl_out = _make_label("OUT")
	_lbl_out.add_theme_font_size_override("font_size", 20)
	_lbl_out.add_theme_color_override("font_color", M8_DIMTEXT)
	_lbl_out.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_lbl_out)

	bar.add_child(row)
	_status_bar = bar
	_ui_add(bar)

	# 1 Hz blink for the REC dot. A Timer, not a _process write — see _rec_blink.
	var blink := Timer.new()
	blink.wait_time = 0.6
	blink.autostart = true
	blink.timeout.connect(_rec_blink)
	add_child(blink)


# An M8 nav cell: a clickable Button holding a tiny dim ABBREVIATION over its
# larger VALUE. Returns [cell_button, value_label, label_label] so callers can
# update the value and light the whole cell when its panel is open.
func _m8_cell(label: String, value: String, on_press: Callable) -> Array:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(96, NAVBAR_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # even cells across the bar
	b.clip_text = true
	b.add_theme_stylebox_override("normal", _cell_stylebox(false))
	b.add_theme_stylebox_override("hover", _cell_stylebox(false))
	b.add_theme_stylebox_override("pressed", _cell_stylebox(true))
	b.pressed.connect(func() -> void:
		if _help_swallow:
			return
		on_press.call())
	_help_register(b, "NAV/%s" % label, "nav")
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 6)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = label.to_upper()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", _font_label)        # wide-tracked micro caps
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", M8_LABEL)   # dim-white label
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := Label.new()
	v.text = _nav_value(value)   # abbreviated + capped so nav values never clip
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_theme_font_size_override("font_size", 20)
	v.add_theme_color_override("font_color", M8_TEXT)    # white value
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(l)
	vb.add_child(v)
	b.add_child(vb)
	return [b, v, l]


# Nav-cell frame: black with a thin green divider between cells; ACTIVE (its panel
# is open) = a full green border box + faint green wash, per the reference.
func _cell_stylebox(active: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(4)
	if active:
		sb.bg_color = Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.10)
		sb.border_color = M8_GREEN
		sb.set_border_width_all(2)
	else:
		sb.bg_color = Color(0, 0, 0, 0)
		sb.border_color = Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.22)
		sb.border_width_right = 1
	return sb


# Light a nav cell (frame + label + value) green while its panel is open.
func _set_cell_active(cell: Array, active: bool) -> void:
	if cell.size() < 3:
		return
	var b := cell[0] as Button
	var v := cell[1] as Label
	var l := cell[2] as Label
	b.add_theme_stylebox_override("normal", _cell_stylebox(active))
	b.add_theme_stylebox_override("hover", _cell_stylebox(active))
	v.add_theme_color_override("font_color", M8_GREEN if active else M8_TEXT)
	l.add_theme_color_override("font_color", M8_GREEN if active else M8_LABEL)


func _make_button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text.to_upper()
	b.focus_mode = Control.FOCUS_NONE          # don't keep focus after a touch
	b.custom_minimum_size = Vector2(0, 64)
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_constant_override("h_separation", 6)
	b.pressed.connect(on_press)
	return b


func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 20)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never intercept warp drags
	return l


# --- Params panel (collapsible sliders/toggles) --------------------------

func _build_params_panel() -> void:
	_params_panel = _make_panel()
	_params_vbox = _panel_root_vbox
	var sections: Array = []

	# ── Sources & library (the browsers moved off the live bar) ──
	_add_collapsible("SOURCES & LIBRARY", false, sections)
	_add_button_row("Clip Grid…", func(): _toggle_clip_grid())
	if Storage.is_legacy():
		# A beta1/beta2 linked folder still plays (STORAGE_REWORK_PLAN §E1): its
		# clips are copied into PVJ once, and imports wait until then — they
		# would land where this mode does not look.
		_add_button_row("Copy clips into PVJ…", func(): _copy_into_pvj())
	else:
		# Everything the performer brings in is COPIED into PVJ's own storage
		# through the system picker (Drive, Downloads, USB…) — no storage
		# permission. A starter pack goes straight from its zip into its own chip.
		_add_button_row("Import clips…", func(): _import("files"))
		_add_button_row("Import folder…", func(): _import("folder"))
		_add_button_row("Import pack (.zip)…", func(): _import("pack"))
		if Storage.old_folder_label() != "":
			_add_button_row("Re-import old clips folder…", func(): _reimport_old_folder())
		# The demo clips that ship in the build — and where more come from (an
		# ACTION_VIEW to the browser: no INTERNET permission).
		_add_button_row("Load demo clips", func(): _load_demo_clips())
	_add_button_row("Get more clips…", func(): _open_more_clips())
	# The raw-path browser needs broad storage access, which Android builds no
	# longer ask for; it stays for desktop runs.
	if not Storage.available():
		_add_button_row("Local Files…", func(): _toggle_local_browser())
	_add_button_row("Recordings…", func(): _toggle_rec_browser())
	_add_button_row("Storage…", func(): _open_storage_panel())
	if Features.CLIP_SERVER:
		_add_button_row("Clip Server…", func(): _toggle_clip_browser())
	if Features.DRIVE_OAUTH:
		_add_button_row("Google Drive…", func(): _toggle_drive_browser())
	_add_button_row("Rescan library", func(): _rescan())

	# ── Output ──
	_add_collapsible("OUTPUT", false, sections)
	# Display mode — DUAL (ExoPlayer on HDMI, UI on phone) vs MIRROR (Android
	# mirrors the phone so warp/effects reach the projector). Persisted.
	_btn_display = _add_button_row("Display: %s" % DISPLAY_MODE_NAMES[_display_mode],
		func(): _cycle_display_mode())
	# MIRROR fill: COVER fills the projector width (crops ~21% top/bottom), FIT keeps
	# the whole frame letterboxed. No effect in DUAL. Persisted.
	_btn_mirror_fill = _add_button_row("Mirror fill: %s" % MIRROR_FILL_NAMES[_mirror_fill],
		func(): _cycle_mirror_fill())
	# Rotates the PHONE UI only — the projector is fed from OutputWorld and does
	# not follow (see the _ui_flipped block). For the hub-on-the-right rig.
	_add_toggle_row("Flip UI 180", _ui_flipped, func(on: bool): _set_ui_flip(on))
	# The ident loop on the projector while no clip is loaded (beta2 §2.3).
	_add_toggle_row("Idle screen", _idle_enabled, func(on: bool):
		_idle_enabled = on
		_settings_dirty = true
		_update_idle_output())
	# LED panel + Life automaton rows — pro only (Features.LED_DDP).
	if Features.LED_DDP:
		_build_led_rows()
	# Recording segment length. Rolling to a new file costs nothing (the encoder
	# is never restarted), so this trades file count against how much a crash or
	# a pulled cable can destroy. At ~92 MB/min the default 5 min is ~450 MB.
	_add_slider_row("Rec segment", float(REC_SEG_MIN_LO), float(REC_SEG_MIN_HI), 1.0,
		float(_rec_seg_minutes), " min",
		func(v: float): _rec_seg_minutes = int(v); _settings_dirty = true)
	# Record the mic alongside the picture. v1 is the DEFAULT INPUT DEVICE — the
	# phone mic — with no source selection; a USB-C audio adapter presents as
	# that same input, so line-in largely works incidentally.
	_add_toggle_row("Rec audio", _rec_audio,
		func(on: bool): _rec_audio = on; _settings_dirty = true)

	# Video link — pro only (Features.TD_PVJ_LINK).
	if Features.TD_PVJ_LINK:
		_build_link_section(sections)

	# OSC in/out — pro only (Features.OSC).
	if Features.OSC:
		_build_osc_section(sections)

	# ── Mask image (raster alpha mask over the whole output) ──
	_add_collapsible("MASK IMAGE", false, sections)
	_btn_mask_img = _add_button_row("Mask img: none…", func(): _toggle_mask_browser())
	_btn_mask_fit = _add_button_row("Mask fit: %s" % _mask_overlay.fit_name(),
		func(): _cycle_mask_fit())
	_add_toggle_row("Mask invert", _mask_overlay.invert,
		func(on: bool): _mask_overlay.set_invert(on); _mask_overlay.save())
	_add_slider_row("Mask opacity", 0.0, 1.0, 0.01, _mask_overlay.opacity, "",
		func(v: float): _mask_overlay.set_opacity(v); _mask_overlay.save_debounced())
	_refresh_mask_rows()   # show the restored file name / fit

	# (AUTO-SWITCH and AUDIO SPEED both moved to the Mode panel — see _build_mode_panel.)


## Library ▸ OUTPUT rows for the LED panel (DDP) and its Life source. Split
## out of _build_params_panel so the public build can skip them whole.
func _build_led_rows() -> void:
	# LED panel (DDP over WiFi). MIRROR: the panel shows the same composited
	# frame as the projector, downsampled on the GPU to 64x64 — the phone only
	# ever reads back 12 KB. Off allocates nothing at all. Persisted.
	_add_toggle_row("LED panel", _ddp_enabled, func(on: bool): _set_ddp_enabled(on))
	_btn_ddp_ip = _add_button_row("Panel IP: %s" % _ddp_target_ip,
		func(): _prompt_ddp_ip())
	# 16:9 into a 1:1 panel — SQUASH distorts, CROP loses the sides, LETTERBOX
	# wastes 28 of 64 rows. No default is right for every source; this is chosen
	# at the panel. Persisted.
	_btn_ddp_fit = _add_button_row("LED fit: %s" % DDP_FIT_NAMES[_ddp_fit_mode],
		func(): _cycle_ddp_fit())
	# DECK (the composited output) or LIFE (the cellular automaton). Persisted.
	_btn_ddp_source = _add_button_row("LED source: %s" % DDP_SOURCE_NAMES[_ddp_source],
		func(): _cycle_ddp_source())
	# Skips to the next rule immediately; the automaton also cycles on its own
	# every hold_secs. 14 life-like rules, each with the seed density and style
	# it looks best from — see life_source.gd RULES.
	# FREE runs on gen_hz; the others lock generations to the beat clock, ON the
	# beat rather than merely at the right rate. Persisted.
	_btn_life_rate = _add_button_row("Life rate: %s" % LIFE_RATE_NAMES[_life_rate],
		func(): _cycle_life_rate())
	_btn_life_rule = _add_button_row("Life rule: —",
		func():
			if _life != null:
				_life.next_rule())
	# 40-60 is the working range (spec §5). Dropping to 30 halves both the
	# readback and the two tap passes and is still usable on a 64x64 panel —
	# that is the documented fallback if the deck's frame time suffers.
	_add_slider_row("LED send rate", 15.0, 60.0, 1.0, _ddp_send_fps, " fps",
		func(v: float):
			_ddp_send_fps = v
			if _ddp != null:
				_ddp.send_fps = v
			_settings_dirty = true)


## Library ▸ VIDEO LINK. Split out of _build_params_panel so the public build
## (no link) can skip the section whole.
func _build_link_section(sections: Array) -> void:
	# ── Video link (Stage 0 MJPEG mesh — spec R3: peers by NAME, never an IP) ──
	_add_collapsible("VIDEO LINK", false, sections)
	# Live build/teardown — the settings.cfg round-trip the first landing
	# required is gone. Persisted like everything else here.
	_add_toggle_row("Video link", _link_enabled, func(on: bool): _set_link_enabled(on))
	# MAIN receives + composites, CAM serves its camera. Flipping mid-run
	# rebuilds the mesh so the receive side follows the role.
	_btn_link_role = _add_button_row("Link role: %s" % _link_role.to_upper(),
		func(): _cycle_link_role())
	_add_toggle_row("Auto-pull cam", _link_auto_pull_cam,
		func(on: bool):
			_link_auto_pull_cam = on
			if on:
				_link_pull_stopped = false   # re-arming the reflex overrides an operator STOP
			_settings_dirty = true)
	# (Stage 3.3: "Layer alpha" moved onto each peer row below — one level per
	# peer, keyed by name. The old saved value lives on as the default for a
	# peer nobody has adjusted.)
	# The §9 latency stamp, live: burn this device's clock into the stream and
	# mirror it on this screen. A panel row because measurement nights END —
	# with no row, turning it off again took exactly the settings.cfg surgery
	# this section exists to retire, and the stamp leaked into show frames.
	_add_toggle_row("Latency stamp", _link_debug_counter,
		func(on: bool): _set_link_debug_counter(on))
	# N4 slave tuning: subtracts the fixed one-way delivery bias from every
	# incoming beat line before the law measures. Only matters on a SLAVE
	# (role cam); harmless elsewhere. Set from a latency-stamp session.
	_add_slider_row("Phase trim", -100.0, 100.0, 1.0, _phase_trim_ms, " ms",
		func(v: float): _phase_trim_ms = v; _settings_dirty = true)
	# The peer list lives in its own VBox so peers_changed can repaint it
	# without touching the rows above — see _refresh_link_peer_rows.
	_link_peer_vbox = VBoxContainer.new()
	_link_peer_vbox.add_theme_constant_override("separation", 8)
	_params_vbox.add_child(_link_peer_vbox)
	_refresh_link_peer_rows()


# Hide all the settings panels (Mode / FX / Library). Called whenever another
# control is used, so a panel never lingers over the live view or other tools.
# Flash the TAP cell's dot green on a detected beat, then fade back to white.
# One-shot tween per beat (no per-frame work when the room is quiet).
func _pulse_tap_dot() -> void:
	if _cell_tap.size() < 2:
		return
	var dot := _cell_tap[1] as Label
	if _tap_dot_tween != null and _tap_dot_tween.is_valid():
		_tap_dot_tween.kill()
	dot.add_theme_color_override("font_color", M8_GREEN)
	_tap_dot_tween = create_tween()
	_tap_dot_tween.tween_interval(0.08)
	_tap_dot_tween.tween_callback(func(): dot.add_theme_color_override("font_color", M8_TEXT))


# Keep the WRP / MSK cell values showing live state rather than static words.
func _refresh_nav_values() -> void:
	if _cell_wrp.size() >= 2 and _warp != null:
		# Surface the warp MODE on the deck bar too — a live mesh is worth
		# knowing about without opening the editor (mirrors the MSK cell).
		# NAV_MAX_CHARS is 8, so the mesh form abbreviates SLOT to S rather
		# than clipping "SLOT 1 3x3" down to a meaningless "SLOT 1 3".
		var wrp := "SLOT %d" % _warp.current_slot()
		if quad_warp.mesh_mode:
			wrp = "S%d %dx%d" % [_warp.current_slot(),
				quad_warp.grid_cols, quad_warp.grid_rows]
		(_cell_wrp[1] as Label).text = _nav_value(wrp)
	if _cell_msk.size() >= 2 and _region_comp != null:
		# While the mask editor is open it reports DRAWING / EDITING; otherwise
		# (and whenever it is idle) fall back to the mask count.
		var state := ""
		if _region_editor != null:
			state = _region_editor.nav_state()
		if state == "":
			var n := _region_comp.region_count()
			state = "POLYGON" if n == 0 else "%d MASK%s" % [n, "" if n == 1 else "S"]
		(_cell_msk[1] as Label).text = _nav_value(state)


# Light a nav cell (green border + green label AND value) while its panel is open.
func _refresh_cell_highlights() -> void:
	_set_cell_active(_cell_mode, _mode_panel != null and _mode_panel.visible)
	_set_cell_active(_cell_fx, _fx_panel != null and _fx_panel.visible)
	_set_cell_active(_cell_lib, _params_panel != null and _params_panel.visible)


func _close_panels() -> void:
	if _mode_panel != null:
		_mode_panel.visible = false
	if _fx_panel != null:
		_fx_panel.visible = false
	if _params_panel != null:
		_params_panel.visible = false
	_refresh_cell_highlights()


func _toggle_params() -> void:
	var show_it := not _params_panel.visible
	_close_panels()
	_params_panel.visible = show_it
	if show_it:
		_sync_osc_rows()   # the phone's IP may have changed since boot
	_refresh_cell_highlights()


# The Mode panel: pick the switch mode + tune its settings, all in one place
# (opened by the Mode bar button). Built by temporarily pointing the row helpers
# The FX panel: pick an effect + tune its shader uniforms (mirrors the Mode panel).
func _build_fx_panel() -> void:
	_fx_panel = _make_panel()
	_params_vbox = _panel_root_vbox
	var sections: Array = []

	_add_collapsible("EFFECT", true, sections)
	_fx_buttons.clear()
	for i in _effects.size():
		var idx := i
		_fx_buttons.append(_add_button_row(str(_effects[idx].name), func(): _set_effect(idx)))
	_update_fx_buttons()

	_add_collapsible("EFFECT SETTINGS", false, sections)
	_fx_settings_box = _params_vbox    # rebuilt per selected effect
	_rebuild_fx_settings()


func _toggle_fx_panel() -> void:
	var show_it := not _fx_panel.visible
	_close_panels()
	_fx_panel.visible = show_it
	_refresh_cell_highlights()
	if show_it:
		# 13 rows run well past the fold, so opening on a late entry (Solarize is
		# last) showed a list with no sign of what was actually selected. Deferred:
		# the panel was hidden until a line ago, so the ScrollContainer has no
		# usable rect until layout has run.
		_scroll_fx_to_active.call_deferred()


## Bring the active effect's row into view when the FX panel opens.
func _scroll_fx_to_active() -> void:
	if _fx_panel == null or not _fx_panel.visible:
		return
	if _effect_index < 0 or _effect_index >= _fx_buttons.size():
		return
	var row: Button = _fx_buttons[_effect_index]
	if row == null or not is_instance_valid(row) or not row.is_visible_in_tree():
		return   # EFFECT section collapsed — there is no row to reveal
	var sc := _fx_panel.get_child(0) as ScrollContainer
	if sc != null:
		sc.ensure_control_visible(row)


func _set_effect(i: int) -> void:
	_effect_index = clampi(i, 0, _effects.size() - 1)
	_apply_effect()


func _update_fx_buttons() -> void:
	for i in _fx_buttons.size():
		_fx_buttons[i].text = str(_effects[i].name).to_upper()
		_style_list_item(_fx_buttons[i], i == _effect_index)


# Rebuild the EFFECT SETTINGS rows for the currently-selected effect.
func _rebuild_fx_settings() -> void:
	if _fx_settings_box == null:
		return
	for c in _fx_settings_box.get_children():
		c.queue_free()
	_ascii_mode_buttons.clear()   # freed with the old rows
	_displace_pattern_buttons.clear()   # ditto
	_trails_blend_buttons.clear()       # ditto
	_slitscan_dir_buttons.clear()       # ditto
	_solarize_mode_buttons.clear()      # ditto
	var prev := _params_vbox
	_params_vbox = _fx_settings_box
	var prev_section := _help_section
	_help_section = "FX %s" % str(_effects[_effect_index].name).to_upper()
	match str(_effects[_effect_index].name):
		"RGB Shift":
			_add_shader_slider("amount", 0.0, 0.05, 0.001, 0.02, "")
		"Kaleidoscope":
			_add_shader_slider("segments", 2.0, 16.0, 1.0, 6.0, "")
		"Feedback":
			_add_shader_slider("zoom", 0.0, 0.2, 0.005, 0.07, "")
			_add_shader_slider("rotation", 0.0, 0.4, 0.005, 0.06, "")
			_add_shader_slider("decay", 0.5, 0.98, 0.01, 0.82, "")
		"Pixelate":
			_add_shader_slider("coarse_blocks", 4.0, 64.0, 1.0, 16.0, "")
		"Chroma":
			_add_shader_slider("amount", 0.0, 0.08, 0.002, 0.025, "")
			_add_shader_slider("jitter", 0.0, 0.02, 0.001, 0.004, "")
		"HUD":
			# ⚠️ Scale needs a WIDE range because the two modes feed it different
			# things: crowd `size` is box HEIGHT (0.3-0.9) while landmark
			# `head_size` is INTER-OCULAR over frame width (0.05-0.15). One
			# number, two meanings, an order of magnitude apart — which is why
			# the HUD came out tiny on a face and sane on a body.
			_add_shader_slider("hud_scale", 0.2, 8.0, 0.1, 3.0, "x")
			_add_shader_slider("weight", 0.001, 0.02, 0.0005, 0.0035, "")
		"HUD Rings":
			_add_shader_slider("ring_scale", 0.3, 10.0, 0.1, 4.0, "x")
			_add_shader_slider("steps", 8.0, 64.0, 4.0, 32.0, "")
			_add_shader_slider("rings", 1.0, 7.0, 1.0, 5.0, "")
			_add_shader_slider("thickness", 0.002, 0.05, 0.002, 0.02, "")
		"ASCII":
			_build_ascii_settings()
		"Glitch":
			_build_glitch_settings()
		"Bloom":
			_build_bloom_settings()
		"Displace":
			_build_displace_settings()
		"Trails":
			_build_trails_settings()
		"Slit-Scan":
			_build_slitscan_settings()
		"Solarize":
			_build_solarize_settings()
		_:
			var l := Label.new()
			l.text = "NO SETTINGS"
			l.add_theme_font_size_override("font_size", 20)
			l.add_theme_color_override("font_color", M8_LABEL)
			_params_vbox.add_child(_row_wrap(l))
	_params_vbox = prev
	_help_section = prev_section


# ASCII-specific settings: density, spacing, glyph mode, custom text, quality.
func _build_ascii_settings() -> void:
	_add_slider_row("Density", 40.0, 240.0, 4.0, _ascii_columns, "",
		func(v: float): _ascii_columns = v; _set_ascii_param("columns", v))
	# SPACING: glyph size within its cell. 1.0 = the original tight grid, >1.0
	# opens black gaps between characters, <1.0 crowds them together. Writes the
	# uniform live — no rebuild.
	_add_slider_row("Spacing", 0.0, 2.0, 0.05, _ascii_spacing, "",
		func(v: float): _ascii_spacing = v; _set_ascii_param("spacing", v))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for i in ASCII_MODE_NAMES.size():
		var idx := i
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 22)
		b.text = ASCII_MODE_NAMES[idx].to_upper()
		b.pressed.connect(func(): _set_ascii_mode(idx))
		_ascii_mode_buttons.append(b)
		row.add_child(b)
	_params_vbox.add_child(_row_wrap(row))
	_update_ascii_mode_buttons()
	# Custom text field (used in "Custom text" mode).
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "TEXT"
	lbl.custom_minimum_size = Vector2(120, 0)
	lbl.add_theme_font_size_override("font_size", 20)
	var edit := LineEdit.new()
	edit.text = _ascii_text
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 60)
	edit.add_theme_font_size_override("font_size", 20)
	edit.text_changed.connect(func(t: String): _set_ascii_text(t))
	_ascii_text_edit = edit
	trow.add_child(lbl)
	trow.add_child(edit)
	_params_vbox.add_child(_row_wrap(trow))

	# QUALITY: FULL / HALF / FAST. NOTE this resizes the shared ShaderSlot stage,
	# so it affects EVERY effect, not just ASCII — it lives here because that is
	# where it was asked for, but consider moving it to Library > OUTPUT.
	var qcap := Label.new()
	qcap.text = "QUALITY"
	qcap.add_theme_font_override("font", _font_label)
	qcap.add_theme_font_size_override("font_size", 15)
	qcap.add_theme_color_override("font_color", M8_LABEL)
	_params_vbox.add_child(_row_wrap(qcap))

	var qrow := HBoxContainer.new()
	qrow.add_theme_constant_override("separation", 8)
	_quality_buttons.clear()
	for i in QUALITY_NAMES.size():
		var qi := i
		var qb := Button.new()
		qb.focus_mode = Control.FOCUS_NONE
		qb.custom_minimum_size = Vector2(0, 56)
		qb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		qb.add_theme_font_size_override("font_size", 20)
		qb.text = QUALITY_NAMES[qi].to_upper()
		qb.pressed.connect(func(): _set_quality(qi))
		_quality_buttons.append(qb)
		qrow.add_child(qb)
	_params_vbox.add_child(_row_wrap(qrow))
	_update_quality_buttons()


func _update_quality_buttons() -> void:
	for i in _quality_buttons.size():
		var b := _quality_buttons[i]
		if not is_instance_valid(b):
			continue
		var on := i == _quality
		b.add_theme_color_override("font_color", M8_GREEN if on else M8_TEXT)
		if on:
			b.add_theme_stylebox_override("normal",
				_btn_stylebox(Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.10), M8_GREEN, 1.0))
		else:
			b.remove_theme_stylebox_override("normal")


# Resize the shader stage. Called on boot (no flash) and from the QUALITY chips.
func _apply_quality() -> void:
	var qsize: Vector2i = QUALITY_SIZES[_quality]
	shader_slot.size = qsize
	# The warp mesh's UVs are NORMALIZED (S18), so a viewport resize no longer
	# strands them — but the source must still be re-pointed here, and it must
	# go through the chooser: while masks own the output QuadWarp samples
	# MaskWorld, and pointing it at shader_slot here would steal the source back.
	_refresh_output_source()
	_update_quality_buttons()


func _set_quality(q: int) -> void:
	_quality = clampi(q, 0, QUALITY_NAMES.size() - 1)
	_apply_quality()
	_settings_dirty = true
	var sz: Vector2i = QUALITY_SIZES[_quality]
	_flash_status("QUALITY: %s (%dx%d)" % [QUALITY_NAMES[_quality].to_upper(), sz.x, sz.y])


# Light the active ASCII glyph-mode chip green-on-green (M8 active button).
func _update_ascii_mode_buttons() -> void:
	for i in _ascii_mode_buttons.size():
		var b := _ascii_mode_buttons[i]
		if not is_instance_valid(b):
			continue
		var on := i == _ascii_mode
		b.add_theme_color_override("font_color", M8_GREEN if on else M8_TEXT)
		if on:
			b.add_theme_stylebox_override("normal",
				_btn_stylebox(Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.10), M8_GREEN, 1.0))
		else:
			b.remove_theme_stylebox_override("normal")


func _set_ascii_mode(m: int) -> void:
	_ascii_mode = clampi(m, 0, ASCII_MODE_NAMES.size() - 1)
	_set_ascii_param("mode", _ascii_mode)
	_update_ascii_mode_buttons()
	_flash_status("ASCII: %s" % ASCII_MODE_NAMES[_ascii_mode].to_upper())


## The ASCII custom text — the ONE setter for the TEXT field and /pvj/fx/ascii/text
## (OSC_NAMESPACE_SPEC.md §5). Capped at the shader's 64 cells; letters and digits
## show, anything else is a blank cell (_ascii_text_codes).
func _set_ascii_text(t: String) -> void:
	_ascii_text = t.left(ASCII_TEXT_MAX)
	_set_ascii_param("text_len", _ascii_text.length())
	_set_ascii_param("text_chars", _ascii_text_codes())
	# Keep the field in step when the change came from OSC. Setting .text from
	# code does not emit text_changed, so this cannot loop.
	if is_instance_valid(_ascii_text_edit) and _ascii_text_edit.text != _ascii_text:
		_ascii_text_edit.text = _ascii_text
	_settings_dirty = true


## /pvj/fx/ascii/text — a message ON SCREEN (owner's call, SESSION_45): it takes
## over the look — FX = ASCII, mode = Custom, the cells spell the text. Each step
## is the FX panel's own call (_set_effect / _set_ascii_mode / _set_ascii_text),
## so the panel shows what happened and the performer can undo it with a tap.
func _show_ascii_message(t: String) -> void:
	# The shader repeats the text cell after cell; without a gap the copies run
	# together ("…LOGOSHELLO LOGOSHELLO…", seen on the Pixel 8). One trailing space
	# separates them, room permitting. Typed text (the TEXT field) is left as typed.
	var msg := t.strip_edges()
	if msg.length() < ASCII_TEXT_MAX:
		msg += " "
	_set_ascii_text(msg)   # first, so the effect swap below pushes the new text
	var ascii_i := -1
	for i in _effects.size():
		if str(_effects[i].name) == "ASCII":
			ascii_i = i
	if ascii_i >= 0 and _effect_index != ascii_i:
		_set_effect(ascii_i)
	if _ascii_mode != ASCII_MODE_CUSTOM:
		_set_ascii_mode(ASCII_MODE_CUSTOM)
	var shown := _ascii_text.strip_edges().to_upper()
	_flash_status("OSC: TEXT %s" % (shown.left(24) + ("…" if shown.length() > 24 else "")))


func _set_ascii_param(uniform: String, value) -> void:
	var mat := shader_slot.get_shader_material()
	if mat != null and str(_effects[_effect_index].name) == "ASCII":
		mat.set_shader_parameter(uniform, value)


# Glitch settings: the two CHARACTER controls, plus a line naming where the
# master lives. Count and size shape the look; `intensity` is the modulated one
# and is deliberately NOT a slider here — _process rewrites that uniform every
# frame from the audio level, so a slider on it would be overwritten under your
# finger. The fader is its control, exactly as for every other effect.
func _build_glitch_settings() -> void:
	# Expected blocks on a full-intensity burst frame. Reads as a count because
	# the shader divides it by the cell count per layer — the number means the
	# same thing at any block size.
	_add_slider_row("Block count", GLITCH_COUNT_MIN, GLITCH_COUNT_MAX, 5.0,
		_glitch_block_count, "",
		func(v: float):
			_glitch_block_count = v
			_set_glitch_param("block_count", v)
			_settings_dirty = true)
	# Base block size as a % of frame width. The shader spreads the count over
	# half / base / double this size, so blocks vary instead of tiling evenly.
	_add_slider_row("Block size", GLITCH_SIZE_MIN, GLITCH_SIZE_MAX, 0.5,
		_glitch_block_size, "%",
		func(v: float):
			_glitch_block_size = v
			_set_glitch_param("block_size", v)
			_settings_dirty = true)
	# Shape, in stops about square (see the shader): the caption carries the sign
	# convention because "0.00" alone doesn't say which way the slider stretches.
	_add_slider_row("Block aspect  (- tall / + wide)",
		GLITCH_ASPECT_MIN, GLITCH_ASPECT_MAX, 0.25, _glitch_block_aspect, "",
		func(v: float):
			_glitch_block_aspect = v
			_set_glitch_param("block_aspect", v)
			_settings_dirty = true)
	var gl := Label.new()
	gl.text = "INTENSITY: FADER / AUDIO"
	gl.add_theme_font_size_override("font_size", 20)
	gl.add_theme_color_override("font_color", M8_LABEL)
	_params_vbox.add_child(_row_wrap(gl))


func _set_glitch_param(uniform: String, value) -> void:
	var mat := shader_slot.get_shader_material()
	if mat != null and str(_effects[_effect_index].name) == "Glitch":
		mat.set_shader_parameter(uniform, value)


# Bloom settings: the two CHARACTER controls, plus the line naming where the
# master lives. Same shape as _build_glitch_settings — `intensity` is not a
# slider here because _process rewrites that uniform every frame.
func _build_bloom_settings() -> void:
	# Luma a pixel must exceed before it blooms. Low values glow the whole frame
	# (mid-tones included), high values pick out only speculars and lights.
	_add_slider_row("Threshold", BLOOM_THRESHOLD_MIN, BLOOM_THRESHOLD_MAX, 0.02,
		_bloom_threshold, "",
		func(v: float):
			_bloom_threshold = v
			_set_bloom_param("threshold", v)
			_settings_dirty = true)
	# Spread, as a % of frame width — the same unit as Glitch's block size.
	_add_slider_row("Radius", BLOOM_RADIUS_MIN, BLOOM_RADIUS_MAX, 0.25,
		_bloom_radius, "%",
		func(v: float):
			_bloom_radius = v
			_set_bloom_param("radius", v)
			_settings_dirty = true)
	var bl := Label.new()
	bl.text = "INTENSITY: FADER / AUDIO"
	bl.add_theme_font_size_override("font_size", 20)
	bl.add_theme_color_override("font_color", M8_LABEL)
	_params_vbox.add_child(_row_wrap(bl))


func _set_bloom_param(uniform: String, value) -> void:
	var mat := shader_slot.get_shader_material()
	if mat != null and str(_effects[_effect_index].name) == "Bloom":
		mat.set_shader_parameter(uniform, value)


# Displace settings: the two CHARACTER controls, plus the line naming where the
# master lives. Same shape as the glitch/bloom builders.
func _build_displace_settings() -> void:
	# PATTERN chips first — they change what the two sliders below mean, so the
	# captions are written per mode (see _displace_captions).
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for i in DISPLACE_PATTERN_NAMES.size():
		var idx := i
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 22)
		b.text = DISPLACE_PATTERN_NAMES[idx].to_upper()
		b.pressed.connect(func(): _set_displace_pattern(idx))
		_displace_pattern_buttons.append(b)
		row.add_child(b)
	_params_vbox.add_child(_row_wrap(row))
	_update_displace_pattern_buttons()

	var caps := _displace_captions()
	# NOISE: feature size (broad swells → fine ripple).
	# RADIAL: ring spacing — same direction, higher is tighter.
	_add_slider_row(caps[0], DISPLACE_SCALE_MIN, DISPLACE_SCALE_MAX, 0.25,
		_displace_scale, "",
		func(v: float):
			_displace_scale = v
			_set_displace_param("scale", v)
			_settings_dirty = true)
	# NOISE: flow rate. RADIAL: how fast rings travel outward. 0 freezes either —
	# still warped, just not moving.
	_add_slider_row(caps[1], DISPLACE_SPEED_MIN, DISPLACE_SPEED_MAX, 0.05,
		_displace_speed, "x",
		func(v: float):
			_displace_speed = v
			_set_displace_param("speed", v)
			_settings_dirty = true)
	var dl := Label.new()
	dl.text = "INTENSITY: FADER / AUDIO"
	dl.add_theme_font_size_override("font_size", 20)
	dl.add_theme_color_override("font_color", M8_LABEL)
	_params_vbox.add_child(_row_wrap(dl))


# Trails settings: one CHARACTER control. Same shape as the others — intensity
# is absent because _process owns that uniform every frame.
func _build_trails_settings() -> void:
	# BLEND chips. No rebuild on switch (unlike Displace's patterns) — decay means
	# the same thing in both blends, so the caption below doesn't change.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for i in TRAILS_BLEND_NAMES.size():
		var idx := i
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 22)
		b.text = TRAILS_BLEND_NAMES[idx].to_upper()
		b.pressed.connect(func(): _set_trails_blend(idx))
		_trails_blend_buttons.append(b)
		row.add_child(b)
	_params_vbox.add_child(_row_wrap(row))
	_update_trails_blend_buttons()
	# Persistence. The top of the range is the convergence ceiling, not taste:
	# see TRAILS_DECAY_MAX.
	_add_slider_row("Decay  (persistence)", TRAILS_DECAY_MIN, TRAILS_DECAY_MAX, 0.01,
		_trails_decay, "",
		func(v: float):
			_trails_decay = v
			_set_trails_param("decay", v)
			_settings_dirty = true)
	var tl := Label.new()
	tl.text = "INTENSITY: FADER / AUDIO"
	tl.add_theme_font_size_override("font_size", 20)
	tl.add_theme_color_override("font_color", M8_LABEL)
	_params_vbox.add_child(_row_wrap(tl))


# Slit-Scan settings: two CHARACTER controls, same shape as the others. No
# rebuild on the direction switch (the Trails pattern, not the Displace one) —
# span means the same thing on either axis, so the caption below doesn't change.
func _build_slitscan_settings() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for i in SLITSCAN_DIR_NAMES.size():
		var idx := i
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 22)
		b.text = SLITSCAN_DIR_NAMES[idx].to_upper()
		b.pressed.connect(func(): _set_slitscan_direction(idx))
		_slitscan_dir_buttons.append(b)
		row.add_child(b)
	_params_vbox.add_child(_row_wrap(row))
	_update_slitscan_dir_buttons()
	# FRAMES back, which is also the strip count — see _slitscan_span. At 60fps
	# the top of the range is about 1.5 seconds and 12 px strips.
	_add_slider_row("Span  (frames back)", SLITSCAN_SPAN_MIN, SLITSCAN_SPAN_MAX, 1.0,
		_slitscan_span, "",
		func(v: float):
			_slitscan_span = v
			# Goes to the RING, not to a shader uniform: it repartitions the atlas.
			if str(_effects[_effect_index].name) == "Slit-Scan":
				shader_slot.set_slice_bands(int(v))
			_settings_dirty = true)
	var sl := Label.new()
	sl.text = "INTENSITY: FADER / AUDIO"
	sl.add_theme_font_size_override("font_size", 20)
	sl.add_theme_color_override("font_color", M8_LABEL)
	_params_vbox.add_child(_row_wrap(sl))


func _set_slitscan_param(uniform: String, value) -> void:
	var mat := shader_slot.get_shader_material()
	if mat != null and str(_effects[_effect_index].name) == "Slit-Scan":
		mat.set_shader_parameter(uniform, value)


func _set_slitscan_direction(d: int) -> void:
	_slitscan_direction = clampi(d, 0, SLITSCAN_DIR_NAMES.size() - 1)
	_set_slitscan_param("direction", _slitscan_direction)
	# The WRITER has to band the same axis the effect reads, or the ring gets
	# filled across one axis and sampled on the other.
	if str(_effects[_effect_index].name) == "Slit-Scan":
		shader_slot.set_slice_axis(_slitscan_direction)
	_update_slitscan_dir_buttons()
	_settings_dirty = true
	# Name which way TIME runs, not just the band orientation — "horizontal" alone
	# doesn't say which edge is live, and that is the thing you are choosing.
	if _slitscan_direction == 1:
		_flash_status("SLIT-SCAN: VERTICAL — TIME DEEPENS LEFT TO RIGHT")
	else:
		_flash_status("SLIT-SCAN: HORIZONTAL — TIME DEEPENS TOP TO BOTTOM")


# Light the active direction chip (same treatment as Trails' blend chips).
func _update_slitscan_dir_buttons() -> void:
	for i in _slitscan_dir_buttons.size():
		var b := _slitscan_dir_buttons[i]
		if not is_instance_valid(b):
			continue
		var on := i == _slitscan_direction
		b.add_theme_color_override("font_color", M8_GREEN if on else M8_TEXT)
		if on:
			b.add_theme_stylebox_override("normal",
				_btn_stylebox(Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.10), M8_GREEN, 1.0))
		else:
			b.remove_theme_stylebox_override("normal")


# Solarize settings: a mode chip row, plus the threshold slider ONLY in
# SOLARIZE — INVERT ignores that uniform, and a control that visibly does
# nothing reads as a broken effect.
func _build_solarize_settings() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for i in SOLARIZE_MODE_NAMES.size():
		var idx := i
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 22)
		b.text = SOLARIZE_MODE_NAMES[idx].to_upper()
		b.pressed.connect(func(): _set_solarize_mode(idx))
		_solarize_mode_buttons.append(b)
		row.add_child(b)
	_params_vbox.add_child(_row_wrap(row))
	_update_solarize_mode_buttons()

	if _solarize_mode == 1:
		# Where the tone flip sits. Hardest away from the middle — at 0.5 a pixel
		# inverts to roughly itself, so the slider does its visible work at the
		# ends. See the shader header.
		_add_slider_row("Threshold  (tone flip)", SOLARIZE_THRESHOLD_MIN,
			SOLARIZE_THRESHOLD_MAX, 0.01, _solarize_threshold, "",
			func(v: float):
				_solarize_threshold = v
				_set_solarize_param("threshold", v)
				_settings_dirty = true)
	var sl := Label.new()
	sl.text = "INTENSITY: FADER / AUDIO"
	sl.add_theme_font_size_override("font_size", 20)
	sl.add_theme_color_override("font_color", M8_LABEL)
	_params_vbox.add_child(_row_wrap(sl))


func _set_solarize_param(uniform: String, value) -> void:
	var mat := shader_slot.get_shader_material()
	if mat != null and str(_effects[_effect_index].name) == "Solarize":
		mat.set_shader_parameter(uniform, value)


func _set_solarize_mode(m: int) -> void:
	_solarize_mode = clampi(m, 0, SOLARIZE_MODE_NAMES.size() - 1)
	_set_solarize_param("mode", _solarize_mode)
	_update_solarize_mode_buttons()
	_settings_dirty = true
	# The threshold row appears/disappears with the mode, so the rows are rebuilt
	# — DEFERRED, since this runs from the pressed() of a button the rebuild
	# frees (the Displace precedent).
	call_deferred("_rebuild_fx_settings")
	if _solarize_mode == 1:
		_flash_status("SOLARIZE: TONES ABOVE THRESHOLD FLIP")
	else:
		_flash_status("INVERT: WHOLE FRAME")


# Light the active mode chip green-on-green (same treatment as ASCII's modes).
func _update_solarize_mode_buttons() -> void:
	for i in _solarize_mode_buttons.size():
		var b := _solarize_mode_buttons[i]
		if not is_instance_valid(b):
			continue
		var on := i == _solarize_mode
		b.add_theme_color_override("font_color", M8_GREEN if on else M8_TEXT)
		if on:
			b.add_theme_stylebox_override("normal",
				_btn_stylebox(Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.10), M8_GREEN, 1.0))
		else:
			b.remove_theme_stylebox_override("normal")


func _set_trails_param(uniform: String, value) -> void:
	var mat := shader_slot.get_shader_material()
	if mat != null and str(_effects[_effect_index].name) == "Trails":
		mat.set_shader_parameter(uniform, value)


func _set_trails_blend(b: int) -> void:
	_trails_blend = clampi(b, 0, TRAILS_BLEND_NAMES.size() - 1)
	_set_trails_param("blend", _trails_blend)
	_update_trails_blend_buttons()
	_settings_dirty = true
	# Name the consequence, not just the mode — MAX on bright footage looks like
	# nothing happened, and the status line is where that gets said.
	if _trails_blend == 1:
		_flash_status("TRAILS: MAX — LIGHT TRAILS, NEEDS DARK CONTENT")
	else:
		_flash_status("TRAILS: MIX — GHOSTS ANY CONTENT")


# Light the active blend chip green-on-green (same treatment as ASCII's modes).
func _update_trails_blend_buttons() -> void:
	for i in _trails_blend_buttons.size():
		var b := _trails_blend_buttons[i]
		if not is_instance_valid(b):
			continue
		var on := i == _trails_blend
		b.add_theme_color_override("font_color", M8_GREEN if on else M8_TEXT)
		if on:
			b.add_theme_stylebox_override("normal",
				_btn_stylebox(Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.10), M8_GREEN, 1.0))
		else:
			b.remove_theme_stylebox_override("normal")


func _set_displace_param(uniform: String, value) -> void:
	var mat := shader_slot.get_shader_material()
	if mat != null and str(_effects[_effect_index].name) == "Displace":
		mat.set_shader_parameter(uniform, value)


# Slider captions for the active pattern — the two controls keep their roles but
# not their nouns, and "SCALE" alone doesn't tell you it sets ring spacing.
func _displace_captions() -> Array:
	if _displace_pattern == 1:
		return ["Scale  (ring spacing)", "Speed  (radiation)"]
	return ["Scale  (feature size)", "Speed  (flow)"]


func _set_displace_pattern(p: int) -> void:
	_displace_pattern = clampi(p, 0, DISPLACE_PATTERN_NAMES.size() - 1)
	_set_displace_param("pattern", _displace_pattern)
	_update_displace_pattern_buttons()
	_settings_dirty = true
	# The captions belong to the mode, so the rows are rebuilt — DEFERRED, since
	# this runs from the pressed() of a button that the rebuild frees.
	call_deferred("_rebuild_fx_settings")
	_flash_status("DISPLACE: %s" % DISPLACE_PATTERN_NAMES[_displace_pattern].to_upper())


# Light the active pattern chip green-on-green (same treatment as ASCII's modes).
func _update_displace_pattern_buttons() -> void:
	for i in _displace_pattern_buttons.size():
		var b := _displace_pattern_buttons[i]
		if not is_instance_valid(b):
			continue
		var on := i == _displace_pattern
		b.add_theme_color_override("font_color", M8_GREEN if on else M8_TEXT)
		if on:
			b.add_theme_stylebox_override("normal",
				_btn_stylebox(Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.10), M8_GREEN, 1.0))
		else:
			b.remove_theme_stylebox_override("normal")


# A slider that writes directly to a uniform on the active ShaderSlot material.
func _add_shader_slider(uniform: String, minv: float, maxv: float, step: float,
		value: float, suffix: String) -> void:
	_add_slider_row(uniform.capitalize(), minv, maxv, step, value, suffix,
		func(v: float):
			var mat := shader_slot.get_shader_material()
			if mat != null:
				mat.set_shader_parameter(uniform, v))


# at this panel's vbox, then _build_params_panel repoints them at the Library vbox.
func _build_mode_panel() -> void:
	_mode_panel = _make_panel()
	_params_vbox = _panel_root_vbox
	var sections: Array = []

	_add_collapsible("SWITCH MODE", true, sections)   # expanded by default (the main control)
	_mode_buttons.clear()
	for i in MODE_NAMES.size():
		var idx := i
		_mode_buttons.append(_add_button_row(MODE_NAMES[idx], func(): _set_mode(idx)))
	_update_mode_buttons()

	_add_collapsible("MODE SETTINGS", false, sections)
	# Sequential/BPM uses the TAP button + BPM label on the bar.
	# LFO sweep time (seconds for one full ping-pong), BPM-independent.
	_add_slider_row("LFO sec/clip", 0.05, 4.0, 0.05, _lfo_sec_per_clip, " s",
		func(v: float): _lfo_sec_per_clip = v)
	# Random dwell between switches (0 = instant hard cut).
	_add_slider_row("Random rate", 0.0, 4.0, 0.05, _random_interval_sec, " s",
		func(v: float): _random_interval_sec = v)
	_add_toggle_row("Audio-switch on", _audio_switch_enabled,
		func(on: bool):
			_audio_switch_enabled = on
			_settings_dirty = true
			if on:
				_want_mic())
	# ONSET / KICK / HATS — the same words BEAT FLIP's TRIGGER row uses.
	_audio_band_btn = _add_button_row(_audio_band_label(), func(): _cycle_audio_band())

	# Sequencer 2.0 Stage 1.1 — the WIP surface. Arm the second deck and ride
	# the blend from here; the gig controls (strip chips, PERF crossfader)
	# land in Stage 1.3.
	_add_collapsible("LANE B", false, sections)
	_lane_b_arm_toggle = _add_toggle_row("Arm lane B", _lane_b_armed,
		func(on: bool): _set_lane_b_armed(on))
	# The destination switch (DUAL_PHONE_B_DECK_SPEC §5): one knob, persisted.
	# CLIPS = engine B plays clips (Stage 1 as shipped); PEER = the phone slot's
	# stream IS deck B (remote cam or remote deck — whichever was pulled); TD =
	# the TD slot's SRT stream (2C). A cycle, not a toggle, since Stage 3.2 gave
	# the rig two receivers and "the incoming stream" stopped being one thing.
	if Features.TD_PVJ_LINK:   # PEER/TD are link streams; public lane B is CLIPS
		_lane_b_src_btn = _add_button_row("B source: %s" % LANE_B_SOURCE_NAMES[_lane_b_source],
			func(): _cycle_lane_b_source())
	# The operator's row demotes any running automation (performer wins).
	_add_slider_row("Crossfade", 0.0, 1.0, 0.01, _xfade, "",
		func(v: float): _set_xfade_manual(v); _settings_dirty = true)
	_xfade_mode_btn = _add_button_row("Xfade mode: %s" % XFADE_MODE_NAMES[_xfade_mode],
		func(): _cycle_xfade_mode())
	_xfade_every_btn = _add_button_row("Beat every: %d" % int(XFADE_EVERY[_xfade_every_idx]),
		func(): _cycle_xfade_every())
	var sw0 := int(XFADE_SWITCH[_xfade_switch_idx])
	_xfade_switch_btn = _add_button_row(
		"Switch: %s" % ("CUT" if sw0 == 0 else "%d beats" % sw0),
		func(): _cycle_xfade_switch())
	_xfade_lfo_btn = _add_button_row(
		"LFO period: %d bars" % int(XFADE_LFO_BARS[_xfade_lfo_bars_idx]),
		func(): _cycle_xfade_lfo())
	_lane_b_auto_toggle = _add_toggle_row("B pattern auto", _lane_b.auto,
		func(on: bool): _set_lane_b_auto(on))
	_add_slider_row("B bar offset", 0.0, 8.0, 1.0, float(_lane_b.bar_offset), " bt",
		func(v: float): _lane_b.bar_offset = int(v); _settings_dirty = true)

	# Everything that reads the mic, in one block — this is the PER-VENUE tuning,
	# and it has to be adjustable from the room rather than baked in at build time.
	# Order matters: gain sets the working range, the floor decides what counts as
	# silence within it, sensitivity shapes the rate on top. Tuning them in any other
	# order means re-doing the ones above.
	_add_collapsible("AUDIO INPUT", false, sections)
	# FIRST row: the mic is never requested at launch, so this is where a new
	# performer turns it on — and where a refusal is explained.
	_btn_mic = _add_button_row(_mic_label(), func(): _want_mic())
	# The meter goes FIRST: every slider under it is set by watching this, so it has
	# to be on screen at the same time as the control being dragged.
	_add_scope_row("Input level")
	_add_slider_row("Input gain", AUDIO_GAIN_MIN, AUDIO_GAIN_MAX, 0.5, _audio_gain, "x",
		func(v: float): _set_audio_gain(v); _settings_dirty = true)
	# The control that makes a noisy room usable. Raise it until the deck stops
	# cutting on room tone between tracks; see the measurement in audio_bus.gd.
	_floor_slider = _add_slider_row("Noise floor", AUDIO_FLOOR_MIN, AUDIO_FLOOR_MAX, 0.01,
		_audio_floor, "", func(v: float): _set_audio_floor(v); _settings_dirty = true)
	# …or let the room set it. Directly under the slider it writes, so the result of
	# a learn is visible as a number in the control the performer already understands.
	_learn_btn = _add_button_row(_learn_label(), func(): _toggle_learn_floor())
	# Onset sensitivity, not a level threshold. 1.05 = fires on almost any jump,
	# 3.0 = only big hits. Live control: this is track-dependent (spec §2.4).
	_add_slider_row("Onset sens", AUDIO_SENS_MIN, AUDIO_SENS_MAX, 0.05, _audio_sensitivity, "x",
		func(v: float): _set_audio_sensitivity(v); _settings_dirty = true)

	# The matrix sits directly after AUDIO INPUT because it CONSUMES what that
	# block tunes: gain/floor/sensitivity shape the sources, this routes them.
	# Collapsed by default so it cannot crowd a live set.
	_build_mod_matrix_section(sections)
	_build_tracking_section(sections)

	# …and the TRIGGER channel directly after it. Same sources, opposite character:
	# the matrix drives a value every frame, this fires an event. Collapsed too.
	_build_flip_section(sections)

	# Third section — audio-reactive video speed (louder = faster, 1x..10x).
	_add_collapsible("AUDIO SPEED", false, sections)
	_add_toggle_row("Audio speed on", _speed_ramp_enabled,
		func(on: bool):
			_speed_ramp_enabled = on
			_settings_dirty = true
			if on:
				_want_mic())
	_add_slider_row("Max speed", 1.0, SPEED_MAX_CEIL, 0.5, _speed_max, "x",
		func(v: float): _speed_max = v; _settings_dirty = true)

	# HELP — last, and small: the cards themselves are under every control.
	_add_collapsible("HELP", false, sections)
	var hold := Label.new()
	hold.text = "HOLD ANY CONTROL FOR HALF A SECOND TO READ WHAT IT DOES."
	hold.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hold.add_theme_font_size_override("font_size", 18)
	hold.add_theme_color_override("font_color", M8_LABEL)
	_params_vbox.add_child(_row_wrap(hold))
	_help_mode_toggle = _add_toggle_row("Help mode", _help_mode, func(on: bool): _set_help_mode(on))
	_add_button_row("Show the welcome tour", func(): _show_tour(0))

	# ABOUT — the version, which build, and where to write (beta2 §3). The
	# links are browser intents: no INTERNET permission needed.
	_add_collapsible("ABOUT", false, sections)
	_add_button_row("Version: %s" % Storage.app_version(), func(): pass)
	_add_button_row("Build: %s" % ("pro" if Features.PRO else "public"), func(): pass)
	_add_button_row("Support: c-u.studio/tools/pvj/support…", func():
		_flash_status("OPENING C-U.STUDIO/TOOLS/PVJ/SUPPORT…")
		OS.shell_open(SUPPORT_URL))
	_add_button_row("Privacy policy…", func():
		_flash_status("OPENING THE PRIVACY POLICY…")
		OS.shell_open(PRIVACY_URL))
	var credit := Label.new()
	credit.name = "FfmpegCredit"
	credit.text = FFMPEG_CREDIT
	credit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	credit.add_theme_font_size_override("font_size", 18)
	credit.add_theme_color_override("font_color", M8_LABEL)
	_params_vbox.add_child(_row_wrap(credit))
	_add_button_row("Open-source licences…", func():
		_flash_status("OPENING THE OPEN-SOURCE LICENCES…")
		OS.shell_open(LICENCES_URL))


func _toggle_mode_panel() -> void:
	var show_it := not _mode_panel.visible
	_close_panels()
	_mode_panel.visible = show_it
	_refresh_cell_highlights()


# M8 menus DOCK as a full-height LEFT SIDEBAR (not a floating overlay): from just
# under the nav bar down to the bottom status bar, SIDEBAR_FRAC of the viewport
# width, solid black with a single green edge on the right. Rows are full-bleed
# (no side padding) so a selected row's green block runs edge-to-edge, like the
# reference. The section list scrolls vertically when it overflows.
const SIDEBAR_FRAC := 0.35     ## sidebar width as a fraction of the viewport
const SIDEBAR_MIN_W := 420.0   ## …but never narrower than this
const NAVBAR_H := 96.0
const STATUSBAR_H := 52.0
const CHROME_FADE := 0.2 ## nav/status bar fade when entering or leaving an editor

func _make_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.anchor_left = 0.0
	p.anchor_right = SIDEBAR_FRAC
	p.anchor_top = 0.0
	p.anchor_bottom = 1.0
	p.offset_left = 0.0
	p.offset_right = 0.0
	p.offset_top = NAVBAR_H          # docked under the nav bar
	p.offset_bottom = -STATUSBAR_H   # …down to the bottom status bar
	p.custom_minimum_size = Vector2(SIDEBAR_MIN_W, 0)
	p.visible = false
	p.add_theme_stylebox_override("panel", _sidebar_stylebox())
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel_scrolls.append(scroll)   # for drag-to-scroll (see _input)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 0)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)
	p.add_child(scroll)
	_ui_add(p)
	_panel_root_vbox = vb
	return p


# The docked sidebar: SOLID pure black (no video bleed-through — the reference
# sidebar is opaque), zero padding so rows are full-bleed, one green right edge.
func _sidebar_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(0)
	sb.border_color = Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.35)
	sb.border_width_right = 1
	return sb


func _panel_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)                # pure black — no dark greys
	sb.set_corner_radius_all(0)                    # M8 = sharp corners
	sb.set_content_margin_all(16)
	sb.border_color = Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.35)
	sb.set_border_width_all(1)
	return sb


# One theme on the root Window → the whole app takes the M8 look: translucent
# black chrome, thin cyan borders, Departure Mono pixel font, and the signature
# ORANGE selection highlight (pressed/active).
func _apply_global_theme() -> void:
	var theme := Theme.new()
	theme.default_font = _font_body     # Departure Mono, tight tracking
	theme.default_font_size = 20
	# ⚠️ default_font alone is NOT enough here: our Controls hang off a CanvasLayer,
	# which breaks the Control/Window theme-owner chain, so the Window theme's
	# DEFAULTS never resolve for them. Set the font per class explicitly, and see
	# _ui_add() which assigns this theme to each top-level Control we build.
	for cls in ["Label", "Button", "CheckButton", "LineEdit", "Tree", "OptionButton",
			"PopupMenu", "RichTextLabel"]:
		theme.set_font("font", cls, _font_body)
	theme.set_stylebox("panel", "PanelContainer", _panel_stylebox())
	theme.set_stylebox("panel", "Panel", _panel_stylebox())
	# Buttons: black, thin green edge; pressed = solid green with black text.
	theme.set_stylebox("normal", "Button", _btn_stylebox(Color(0, 0, 0, 1), M8_GREEN, 0.25))
	theme.set_stylebox("hover", "Button", _btn_stylebox(Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.10), M8_GREEN, 0.5))
	theme.set_stylebox("pressed", "Button", _btn_stylebox(M8_GREEN, M8_GREEN, 1.0))
	theme.set_stylebox("disabled", "Button", _btn_stylebox(Color(0, 0, 0, 1), M8_GREEN, 0.08))
	theme.set_color("font_color", "Button", M8_TEXT)
	theme.set_color("font_hover_color", "Button", M8_GREEN)
	theme.set_color("font_pressed_color", "Button", BRAND_DARK)     # black on green
	theme.set_color("font_disabled_color", "Button", M8_LABEL)
	theme.set_color("font_color", "Label", M8_TEXT)
	theme.set_font("font", "LineEdit", _font_body)
	theme.set_color("font_color", "LineEdit", M8_TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", M8_LABEL)
	theme.set_color("caret_color", "LineEdit", M8_GREEN)
	theme.set_color("selection_color", "LineEdit", Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.3))
	theme.set_stylebox("normal", "LineEdit", _btn_stylebox(Color(0, 0, 0, 1), M8_GREEN, 0.35))
	theme.set_stylebox("focus", "LineEdit", _btn_stylebox(Color(0, 0, 0, 1), M8_GREEN, 1.0))
	# Tree (the playlist): pure black, green selection, no default blue.
	theme.set_stylebox("panel", "Tree", _panel_stylebox())
	theme.set_color("font_color", "Tree", M8_TEXT)
	theme.set_color("font_selected_color", "Tree", M8_GREEN)
	theme.set_color("guide_color", "Tree", M8_LINE)
	theme.set_stylebox("selected", "Tree", _btn_stylebox(Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.12), M8_GREEN, 0.0))
	theme.set_stylebox("selected_focus", "Tree", _btn_stylebox(Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.12), M8_GREEN, 0.0))
	var focus := StyleBoxFlat.new()
	focus.draw_center = false
	theme.set_stylebox("focus", "Button", focus)
	# Unified M8 scrollbars (browsers etc.): thin dark track, green grabber.
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0, 0, 0, 0.3)
	track.content_margin_left = 9    # ~18 px grabber: a usable touch target
	track.content_margin_right = 9
	var grab := StyleBoxFlat.new()
	grab.bg_color = Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.35)
	var grab_hi := StyleBoxFlat.new()
	grab_hi.bg_color = Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.6)
	for sb_name in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", sb_name, track)
		theme.set_stylebox("grabber", sb_name, grab)
		theme.set_stylebox("grabber_highlight", sb_name, grab_hi)
		theme.set_stylebox("grabber_pressed", sb_name, grab_hi)
	# Consistent menu typography sizes across all panels.
	theme.set_font_size("font_size", "Label", 20)
	theme.set_font_size("font_size", "Button", 20)
	theme.set_font_size("font_size", "LineEdit", 22)
	# M8 slider: a SOLID green bar filled from the left edge over a faint green
	# track — no thumb/grabber widget at all, on both H and V sliders.
	var empty_img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	empty_img.fill(Color(0, 0, 0, 0))
	var empty_tex := ImageTexture.create_from_image(empty_img)
	for slider_name in ["HSlider", "VSlider"]:
		var groove := StyleBoxFlat.new()
		groove.bg_color = Color(M8_GREEN.r, M8_GREEN.g, M8_GREEN.b, 0.14)  # faint track
		groove.set_corner_radius_all(0)
		var fill := StyleBoxFlat.new()
		fill.bg_color = M8_GREEN                                           # bright fill
		fill.set_corner_radius_all(0)
		# The bar is 8 px thick; the margins are what give a bare StyleBox its size.
		if slider_name == "HSlider":
			groove.content_margin_top = 4
			groove.content_margin_bottom = 4
			fill.content_margin_top = 4
			fill.content_margin_bottom = 4
		else:
			groove.content_margin_left = 4
			groove.content_margin_right = 4
			fill.content_margin_left = 4
			fill.content_margin_right = 4
		theme.set_stylebox("slider", slider_name, groove)
		theme.set_stylebox("grabber_area", slider_name, fill)
		theme.set_stylebox("grabber_area_highlight", slider_name, fill)
		# No thumb: every grabber icon is a transparent 2x2.
		theme.set_icon("grabber", slider_name, empty_tex)
		theme.set_icon("grabber_highlight", slider_name, empty_tex)
		theme.set_icon("grabber_disabled", slider_name, empty_tex)
		theme.set_constant("grabber_offset", slider_name, 0)
		theme.set_constant("center_grabber", slider_name, 0)
	_theme = theme
	get_window().theme = theme


# Add a top-level Control to the UI CanvasLayer WITH the global theme attached.
# Theme inheritance walks parent Controls/Windows; a CanvasLayer is neither, so
# anything parented straight to it resolves nothing from get_window().theme and
# falls back to Godot's default look (proportional font, round slider thumbs).
# Assigning the theme on each top-level Control fixes the whole subtree under it.
func _ui_add(c: Control) -> void:
	c.theme = _theme
	status.get_parent().add_child(c)   # <-- the ONE raw add; everything else uses _ui_add


func _btn_stylebox(bg: Color, border: Color, border_a: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(10)
	sb.border_color = Color(border.r, border.g, border.b, border_a)
	sb.set_border_width_all(1)
	return sb


# A collapsible section: a tappable cyan header that shows/hides its rows.
# ACCORDION: opening a section closes the others in the same panel, so the panel
# stays compact and never scrolls or clips. `sections` is a per-panel list.
# Subsequent _add_* rows land inside this section until the next _add_collapsible.
func _add_collapsible(title: String, expanded: bool, sections: Array) -> void:
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	content.visible = expanded
	# The header is bare green text on black — NOT a boxed button. It must stay
	# green in every state (the global Button theme would invert it to black-on-
	# green when touched, which reads as a selected row rather than a header).
	var header := Button.new()
	header.focus_mode = Control.FOCUS_NONE
	header.custom_minimum_size = Vector2(0, 70)
	header.add_theme_font_size_override("font_size", 20)
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		header.add_theme_color_override(state, M8_GREEN)
	for state in ["normal", "hover", "pressed", "focus"]:
		header.add_theme_stylebox_override(state, _header_stylebox())
	header.text = ("[-]  " if expanded else "[+]  ") + title.to_upper()
	sections.append({"header": header, "content": content, "title": title})
	_help_section = title
	_help_register(header, title, "header")
	header.pressed.connect(func():
		if _help_swallow:
			return
		var show_this: bool = not content.visible
		for s: Dictionary in sections:   # accordion — collapse all first
			s["content"].visible = false
			s["header"].text = "[+]  " + str(s["title"]).to_upper()
		if show_this:
			content.visible = true
			header.text = "[-]  " + title.to_upper())
	_panel_root_vbox.add_child(header)
	_panel_root_vbox.add_child(content)
	_params_vbox = content


# The sidebar itself has no padding (so selected rows are full-bleed); non-list
# rows get their inset from this wrapper instead.
func _row_wrap(row: Control) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 18)
	m.add_theme_constant_override("margin_right", 18)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	m.add_child(row)
	return m


# M8 stepper: a small SQUARE green-outlined box holding a - or +.
func _stepper(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(62, 62)
	b.add_theme_font_size_override("font_size", 24)
	b.add_theme_color_override("font_color", M8_GREEN)
	b.add_theme_color_override("font_hover_color", M8_GREEN)
	b.add_theme_color_override("font_pressed_color", BRAND_DARK)
	b.add_theme_stylebox_override("normal", _btn_stylebox(Color(0, 0, 0, 0), M8_GREEN, 0.8))
	b.add_theme_stylebox_override("hover", _btn_stylebox(Color(0, 0, 0, 0), M8_GREEN, 1.0))
	b.add_theme_stylebox_override("pressed", _btn_stylebox(M8_GREEN, M8_GREEN, 1.0))
	# Now that the slider itself is drag-immune these are the ONLY way to adjust
	# a tunable, so they must not fire on a scroll either — same guard, same
	# reasoning as _add_button_row (see PANEL_TAP_SLOP).
	b.pressed.connect(func() -> void:
		if _row_suppressed:
			return
		on_press.call())
	return b


## Adds a slider block: a dim wide-tracked CAPTION over a
## "[−] [====filled bar====] [+]  value" row. The − / + steppers make it precise
## and touch-friendly (tap instead of drag), avoiding the drag-vs-scroll fight.
func _add_slider_row(text: String, minv: float, maxv: float, step: float,
		value: float, suffix: String, on_change: Callable, parent: Control = null) -> HSlider:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.add_theme_font_override("font", _font_label)
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", M8_LABEL)
	block.add_child(lbl)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var slider := HSlider.new()
	slider.min_value = minv
	slider.max_value = maxv
	slider.step = step
	slider.value = value
	slider.focus_mode = Control.FOCUS_NONE
	# DRAG-IMMUNE: the steppers either side are the only way to move this. A
	# panel section taller than the screen has to be scrolled through, and an
	# HSlider under the finger scrubs on the way past — silently, and it
	# PERSISTS. It cost MOD MATRIX its base (0.15 -> 0.00) and slot 1's depth
	# (1.6 -> 2.0) during step-2 testing, found only by reading settings.cfg.
	# 94bb951 gave Buttons the same immunity; this is the other half of it, and
	# it matches why the steppers were added in the first place (Session 8:
	# "tap to adjust; drag-vs-scroll was the clunky feel").
	# ⚠️ The right-edge intensity FADER is a different widget (_build_intensity_
	# fader) and MUST stay draggable — it is a performance control, not a tunable.
	slider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slider.custom_minimum_size = Vector2(180, 62)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var val := Label.new()
	# Whole-number steps read as whole numbers ("30 Hz", not "30.00 Hz").
	var fmt := "%d%s" if step >= 1.0 else "%.2f%s"
	val.text = fmt % [roundi(value) if step >= 1.0 else value, suffix]
	val.custom_minimum_size = Vector2(110, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", 22)
	val.add_theme_color_override("font_color", M8_TEXT)

	slider.value_changed.connect(func(v: float):
		val.text = fmt % [roundi(v) if step >= 1.0 else v, suffix]
		on_change.call(v))

	var nudge := maxf(step, (maxv - minv) / 20.0)
	row.add_child(_stepper("-", func(): slider.value -= nudge))
	row.add_child(slider)
	row.add_child(_stepper("+", func(): slider.value += nudge))
	row.add_child(val)
	block.add_child(row)
	# parent (Stage 3.3): peer rows live in _link_peer_vbox, rebuilt on beacon
	# churn; null = the panel being built, as every other caller expects.
	var dest: Control = parent if parent != null else _params_vbox
	var wrap := _row_wrap(block)
	dest.add_child(wrap)
	_help_register(wrap, "%s/%s" % [_help_section, text])
	return slider


## A caption + a live number, no control. Same caption/value treatment as
## _add_slider_row so the figure lands in the SAME right-hand column as every
## slider's value — it reads as one of the rows, not a widget dropped on top.
## The owner writes to the returned Label (see _process).
func _add_readout_row(text: String) -> Label:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.add_theme_font_override("font", _font_label)
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", M8_LABEL)
	block.add_child(lbl)

	var val := Label.new()
	val.text = "0.00"
	val.custom_minimum_size = Vector2(110, 46)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", 22)
	val.add_theme_color_override("font_color", M8_GREEN)   # it MOVES — the accent earns it
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	block.add_child(val)

	var wrap := _row_wrap(block)
	_params_vbox.add_child(wrap)
	_help_register(wrap, "%s/%s" % [_help_section, text])
	return val


## Adds a captioned AudioScope. Same CAPTION treatment as _add_slider_row on
## purpose — the meter is the first ROW of the AUDIO INPUT block, not a foreign
## widget dropped on top of it, and its readout column lines up with the sliders'.
func _add_scope_row(text: String) -> AudioScope:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.add_theme_font_override("font", _font_label)
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", M8_LABEL)
	block.add_child(lbl)

	var scope := AudioScope.new()
	# Handed the font explicitly rather than resolved from the theme: these Controls
	# hang off a CanvasLayer, which breaks the theme-owner chain (see _apply_global_theme).
	scope.font = _font_body
	block.add_child(scope)

	var wrap := _row_wrap(block)
	_params_vbox.add_child(wrap)
	_help_register(wrap, "%s/%s" % [_help_section, text])
	return scope


## Adds a full-bleed sidebar row (an action, or a selectable list item that
## _style_list_item later marks active). Left-aligned, hairline-ruled, M8 style.
func _add_button_row(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text.to_upper()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 66)
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_stylebox_override("normal", _list_row_stylebox(false))
	b.add_theme_stylebox_override("hover", _list_row_stylebox(false))
	b.add_theme_stylebox_override("pressed", _list_row_stylebox(true))
	# Every panel list goes through here, so the drag-vs-tap guard covers all of
	# them at once (see PANEL_TAP_SLOP) — not just FX, which is merely where a
	# 13-row list made the bug unavoidable.
	b.pressed.connect(func() -> void:
		if _row_suppressed or _help_swallow:
			return
		on_press.call())
	_params_vbox.add_child(b)
	_help_register(b, "%s/%s" % [_help_section, text])
	return b


## Adds a "label  [toggle]" row to the params panel.
func _add_toggle_row(text: String, value: bool, on_toggle: Callable) -> CheckButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.custom_minimum_size = Vector2(190, 0)
	lbl.add_theme_font_size_override("font_size", 20)

	var chk := CheckButton.new()
	chk.button_pressed = value
	chk.focus_mode = Control.FOCUS_NONE
	chk.custom_minimum_size = Vector2(0, 56)
	chk.add_theme_font_size_override("font_size", 20)
	# Same hazard as the sliders and rows: a scroll that starts on a CheckButton
	# releases inside it and flips it. `toggled` fires AFTER the state changed,
	# so suppressing means putting it back — no_signal, or this re-enters.
	chk.toggled.connect(func(on: bool):
		if _row_suppressed:
			chk.set_pressed_no_signal(not on)
			return
		on_toggle.call(on))

	row.add_child(lbl)
	row.add_child(chk)
	var wrap := _row_wrap(row)
	_params_vbox.add_child(wrap)
	_help_register(wrap, "%s/%s" % [_help_section, text])
	return chk


# --- QuadWarp corner-pin editor ------------------------------------------

func _build_warp_editor() -> void:
	_warp = WarpEditor.new()
	_ui_add(_warp)
	_warp.setup(quad_warp)
	_warp.xform_provider = _output_to_screen
	_warp.output_size_provider = _output_size
	_warp.slot_changed.connect(func(_s: int): _refresh_nav_values())
	_warp.state_changed.connect(_refresh_nav_values)   # live QUAD/MESH on the WRP cell
	# Re-show the bar + fader when the user leaves warp-edit mode.
	_warp.closed.connect(_on_warp_closed)
	_warp.camera_requested.connect(_enter_calibration)
	# Test grid: rendered into ShaderSlot so it warps with the footage and shows
	# on the projector. The editor turns it off on close (never left on stage).
	_grid_overlay = GridOverlay.new()
	shader_slot.add_child(_grid_overlay)
	# Scoped to a REGION, GRID means that mask's CHECKER instead: the frame grid
	# sits on top of MaskWorld unwarped by the region, so it cannot show whether
	# the region's own warp is right; the checker is drawn THROUGH that warp.
	_warp.grid_toggled.connect(_on_warp_grid)


func _on_warp_grid(on: bool) -> void:
	if _warp_return_to_masks and _region_comp != null:
		_region_comp.set_checker(on)
	else:
		_grid_overlay.visible = on


## WARP pressed in the mask editor: swap the mask editor for the lattice editor,
## scoped to that region. The editor itself is unchanged — it just gets pointed
## at the region's WarpSurface instead of the global one, which is the entire
## per-region warp UI.
##
## ⚠️ Returning from it goes BACK TO THE MASK EDITOR, not to the deck, and the
## editor is re-pointed at the global warp on the way out — otherwise the next
## plain WRP press would silently edit whichever region was last touched.
func _enter_region_warp(index: int) -> void:
	if _region_comp == null or index < 0 or index >= _region_comp.region_count():
		return
	_warp_return_to_masks = true
	_region_editor.set_active(false)
	_set_overlays_visible(false)
	_close_panels()
	_warp.target_region(_region_comp, index)
	_warp.show_grid(_region_comp.checker)   # a CHECKER turned on in the mask editor stays on
	_warp.set_active(true)
	_flash_status("WARP · REGION %d" % (index + 1))


func _on_warp_closed() -> void:
	_warp.target_global(quad_warp)
	# The deck wants its bars back; mask mode does not (they cover the top of
	# the picture), so a return to the mask editor leaves them hidden.
	_set_overlays_visible(not _warp_return_to_masks)
	if _warp_return_to_masks:
		_warp_return_to_masks = false
		_region_editor.set_active(true)
		_region_editor.save_now()   # a region's warp lives in regions.cfg
	_refresh_nav_values()


func _enter_warp() -> void:
	_warp.target_global(quad_warp)   # plain WRP always means the GLOBAL warp
	# Hide the main bar + fader + settings panels so nothing overlaps the corner
	# handles; the warp editor shows its own centered controls + Done.
	_set_overlays_visible(false)
	_close_panels()
	_warp.set_active(true)


## Show/hide ALL deck chrome. Warp and mask mode are full-screen canvases, so
## the nav bar (and its backdrop), the bottom status bar, the VU strip and the
## intensity fader all go away — the editors provide their own minimal chrome.
## Fades over CHROME_FADE; `visible` is only cleared AFTER the fade so the bars
## stop accepting touches, and only set BEFORE a fade-in so they can be seen.
func _set_overlays_visible(v: bool) -> void:
	var chrome: Array[Control] = []
	for c in [_main_bar, _bar_bg, _status_bar, _meter, _fader, _fader_label]:
		if c != null and is_instance_valid(c):
			chrome.append(c)
	if chrome.is_empty():
		return
	if _chrome_tween != null and _chrome_tween.is_valid():
		_chrome_tween.kill()
	_chrome_tween = create_tween().set_parallel(true)
	for c in chrome:
		if v:
			c.visible = true
		_chrome_tween.tween_property(c, "modulate:a", 1.0 if v else 0.0, CHROME_FADE)
	if not v:
		_chrome_tween.chain().tween_callback(func() -> void:
			for c in chrome:
				if is_instance_valid(c):
					c.visible = false)


# --- Multi-region mask compositor ----------------------------------------

func _build_region_compositor() -> void:
	# MaskWorld (S17 / Option A): the pre-warp mask stage. The compositor renders
	# into this viewport and QuadWarp samples its texture whenever masks own the
	# output — so warp applies to the masked composite instead of being bypassed.
	# Size is LOCKED to the output basis (_output_px): masks are authored, saved
	# and normalized in this one space; the HDMI renegotiation branch resizes it
	# together with OutputWorld. Starts DISABLED — _refresh_output_source is the
	# one gate for both viewports' update modes.
	_mask_world = SubViewport.new()
	_mask_world.size = Vector2i(_output_px)
	_mask_world.render_target_update_mode = SubViewport.UPDATE_DISABLED
	output_world.add_child(_mask_world)
	# The compositor's regions sample the RAW active source and apply their own
	# per-region effect. Always visible — MaskWorld's update mode is the gate.
	_region_comp = RegionCompositor.new()
	_mask_world.add_child(_region_comp)
	_region_comp.setup(_effects)
	_region_comp.set_source(_source_texture())

	# Editor overlay lives on the UI CanvasLayer (input + drawing guides).
	var fx_names := PackedStringArray()
	for e in _effects:
		fx_names.append(str(e["name"]))
	_region_editor = RegionEditor.new()
	_ui_add(_region_editor)
	_region_editor.setup(_region_comp, fx_names, clip_engine.clips_dir)
	_region_editor.xform_provider = _output_to_screen
	_region_editor.output_size_provider = _output_size
	_region_editor.clip_list_provider = func(): return clip_engine.clips
	_region_editor.closed.connect(_on_region_editor_closed)
	# Mask mode KEEPS the nav/status bars; only its full-screen draw/edit hides
	# them, which the editor signals here.
	_region_editor.deck_chrome.connect(_set_overlays_visible)
	_region_editor.state_changed.connect(_refresh_nav_values)   # live MSK cell
	_region_editor.warp_region_requested.connect(_enter_region_warp)
	# The editor's guides ON THE PROJECTOR (outlines, points, the finger's
	# crosshair): a sibling drawn after the compositor, inside MaskWorld, so it
	# is warped and blitted with the masks. Shown only while the editor is open.
	var guides := MaskGuides.new()
	guides.editor = _region_editor
	guides.visible = false
	_mask_world.add_child(guides)


# --- Raster (image) mask ---------------------------------------------------

func _build_mask_overlay() -> void:
	# Added AFTER the region compositor so it draws above BOTH output paths
	# (QuadWarp and RegionCompositor) — that is what makes the two mask kinds
	# compose instead of exclude each other. Loaded synchronously (not deferred
	# like the polygon regions) because it has no dependence on screen px, and
	# the Library rows built right after need the restored values.
	_mask_overlay = MaskOverlay.new()
	output_world.add_child(_mask_overlay)
	_mask_overlay.load_saved()


# --- Camera keystone (CalibEditor) -----------------------------------------
# CAMERA_PROCEDURAL_MASKS_SPEC.md §1: project a pattern the app drew, see where
# the camera says it landed, and that is the camera<->projector calibration.
# Its first consumer is the global warp — point at the surface's four corners
# in the camera frame and the keystone follows.

func _build_calibration() -> void:
	# AFTER the raster mask: a mask image would multiply the markers darker.
	_calib_pattern = CalibPattern.new()
	output_world.add_child(_calib_pattern)
	_calib = CalibEditor.new()
	_ui_add(_calib)
	_calib.setup(quad_warp)
	_calib.camera_texture_provider = _cam_texture
	_calib.output_size_provider = _output_size
	_calib.gravity_provider = _calib_gravity
	_calib.heat_provider = func() -> int: return _heat
	_calib.spots_requested.connect(_calib_pattern.show_spots)
	_calib.step_changed.connect(_on_calib_step)
	# AUTO drives what the wall shows (dark / one disc / flood) frame by frame.
	_calib.pattern_requested.connect(_calib_pattern.show_mode)
	_calib.exposure_requested.connect(_on_calib_exposure)
	_calib.closed.connect(_on_calib_closed)


## CAM in the warp editor.
func _enter_calibration() -> void:
	# The pattern has to reach the projector AS OutputWorld, pixel for pixel.
	# MIRROR puts the phone's screen there and DUAL·PLAYER a raw clip, so
	# neither can carry it — refuse rather than solve against the wrong picture.
	if _hdmi != null and not (_display_mode == DisplayMode.DUAL \
			and _dual_feed == DualFeed.TEXTURE):
		_flash_status("CAMERA KEYSTONE NEEDS DISPLAY: DUAL·TEX")
		return
	# set_active, not DONE: the warp editor goes quiet without emitting `closed`,
	# so the deck chrome stays hidden and this opens over a clean canvas.
	_warp.set_active(false)
	_calib_prev_source = _source
	_calib.dry_run = not _tex_output_active
	_calib_pattern.out_size = _output_px
	_calib_pattern.show_mode(CalibPattern.Mode.ALL)
	_calib.move_to_front()
	_calib.set_active(true)   # -> step LIVE -> _on_calib_step takes the lens


## AUTO asks for the camera to be under-exposed while it reads the wall (see
## CalibEditor.AUTO_EV), and for normal exposure back afterwards (ev == 0).
## ⚠️ Only tracking's CameraX camera can do this — Godot's CameraFeed has no
## exposure control at all — so on the CameraServer path this is a no-op and
## AUTO works with whatever auto-exposure gives it.
func _on_calib_exposure(ev: float) -> void:
	if _tracking == null or not _cam_via_tracking or not _tracking.is_running():
		return
	if ev == 0.0:
		_tracking.set_exposure(_track_exposure)   # the operator's own setting
		return
	var r := _tracking.exposure_range()
	var step: float = r["step"]
	if step <= 0.0:
		return
	var index := clampi(_track_exposure + roundi(ev / step), int(r["min"]), int(r["max"]))
	_tracking.set_exposure(index)
	print("[calib] exposure %+.1f EV for AUTO (index %d, range %d..%d, step %.3f)"
			% [ev, index, int(r["min"]), int(r["max"]), step])


## Which way is down, in the camera's own frame (x right, y down, z into the
## scene) — CalibEditor's plumb line for WALL. Godot hands gravity over in the
## SCREEN's frame (x right, y up, z out of the glass towards the viewer, already
## turned for the display rotation), and the back camera looks out of the other
## side, so y and z flip.
## ⚠️ That is only true while the camera picture is upright on the screen, which
## holds for the CameraServer feed and has never been established for tracking's
## CameraX one (camera-orientation is its own history of traps) — so that path
## answers ZERO and WALL falls back to tapped plumb lines. Same answer when the
## sensor is silent, or says the phone is not roughly upright: then either the
## mapping or the way the phone is held is not what this assumes.
func _calib_gravity() -> Vector3:
	if _cam_via_tracking:
		return Vector3.ZERO
	var g := Input.get_gravity()
	if g.length() < 1.0:
		return Vector3.ZERO
	var down := Vector3(g.x, -g.y, -g.z).normalized()
	return down if down.y > 0.5 else Vector3.ZERO


func _on_calib_step(step: int) -> void:
	# LIVE and MARKERS: the pattern owns the wall. SURFACE and WALL: the deck
	# comes back, so the keystone is judged on real content while it is adjusted.
	_calib_pattern.visible = step == CalibEditor.Step.LIVE or step == CalibEditor.Step.MARKERS
	# The lens, if Camera2 said (0 = the editor's own estimate).
	_calib.focal_per_width = AndroidProbe.focal_per_width
	if step == CalibEditor.Step.LIVE:
		_calib_take_camera()
	elif step == CalibEditor.Step.SURFACE:
		_calib_return_source()


## Borrow the lens by making CAMERA the deck source, through _apply_source —
## the one place that knows whether CameraServer or tracking holds it (M6) and
## that never lets the two overlap. The pattern covers the output meanwhile, so
## the camera never reaches the wall and cannot film itself.
## ⚠️ Not _set_source: this is a loan, and must not be written to settings.cfg
## (_save_settings writes _calib_prev_source while one is out).
func _calib_take_camera() -> void:
	if _source == ClipSource.CAMERA:
		return
	_source = ClipSource.CAMERA
	_apply_source()


func _calib_return_source() -> void:
	if _calib_prev_source < 0 or _source == _calib_prev_source:
		return
	_source = _calib_prev_source
	_apply_source()


func _on_calib_closed(applied: bool) -> void:
	_calib_pattern.visible = false
	_calib_return_source()
	_calib_prev_source = -1
	# Back into the warp editor, where the result can be hand-tuned and — the
	# part that matters — SAVED: like DONE there, the calibration wrote no slot.
	_warp.set_active(true)
	if applied:
		print("[calib] keystone applied: corners %s" % [quad_warp.corners])
		# DONE wrote no slot (the warp editor's rule), and an unsaved keystone is
		# gone at the next start — which the first user found out by losing one.
		# So ask, naming the slot. Slot 1 is the one loaded at start.
		var slot := _warp.current_slot()
		var body := "SAVE IT TO WARP SLOT %d? UNSAVED, IT IS GONE WHEN THE APP RESTARTS." % slot
		if slot != 1:
			body += " (SLOT 1 IS THE ONE LOADED AT START.)"
		var dlg := M8Dialog.confirm(_chrome_layer, "KEEP THIS KEYSTONE", body, "SAVE SLOT %d" % slot,
			func() -> void:
				_warp.save_slot(slot)
				_flash_status("KEYSTONE SAVED TO SLOT %d" % slot),
			M8Dialog.M8_GREEN, "NOT NOW")
		dlg.theme = _theme         # CanvasLayer breaks theme inheritance


# --- Help cards ------------------------------------------------------------

func _help_register(c: Control, key: String, kind: String = "row") -> void:
	# "SECTION/  Caption" -> "SECTION/CAPTION": captions carry indent spaces.
	var parts := key.split("/")
	for i in parts.size():
		parts[i] = parts[i].strip_edges().to_upper()
	_help_targets.append([c, "/".join(parts), kind])


## The registered control under `pos`. Whatever the GUI says is under the
## finger decides — a registered row is only found if that control is the row
## or inside it. ⚠️ Not a rectangle test alone: the clip grid, the browsers
## and the editors sit OVER the panels, and a rectangle test found the LIB
## row behind a clip tile and answered a tap on the tile with a card. Without
## a hovered control (a desk, no touch) the rectangles decide, smallest first.
## Dead entries are dropped as they are met (the FX settings are rebuilt per
## effect).
func _help_target_at(pos: Vector2) -> Array:
	var best: Array = []
	var best_area := INF
	var alive: Array = []
	var hovered: Control = get_viewport().gui_get_hovered_control()
	for t: Array in _help_targets:
		if not is_instance_valid(t[0]):
			continue   # (untyped on purpose: typing a freed instance is itself an error)
		var c: Control = t[0]
		alive.append(t)
		if not c.is_visible_in_tree():
			continue
		if hovered != null and c != hovered and not c.is_ancestor_of(hovered):
			continue
		var r := c.get_global_rect()
		if (hovered != null or r.has_point(pos)) and r.get_area() < best_area:
			best_area = r.get_area()   # smallest wins: the strip sits inside the grid
			best = t
	_help_targets = alive
	return best


## A hold ended: the card for whatever is under the finger.
func _help_hold_fire() -> void:
	if _topmost_dialog() != null:
		return
	var t := _help_target_at(_help_hold_pos)
	if t.is_empty() or str(t[2]) == "area":
		return   # an area has a hold of its own (queue, reorder): help mode covers it
	if _help_show(str(t[1]), false):
		_row_suppressed = true
		_help_swallow = true


## HELP MODE: a tap on a row shows its card and does nothing else — ONCE; the
## mode switches itself off with the card, so the next tap acts again. (Sticky,
## it trapped the person who turned it on: the toggle to turn it off is itself
## a row.) Nav cells, section headers and the HELP rows are how you get around,
## so they always keep working (their cards are a hold away).
func _help_intercept(pos: Vector2) -> bool:
	if not _help_mode or _topmost_dialog() != null:
		return false
	var t := _help_target_at(pos)
	if t.is_empty() or str(t[2]) not in ["row", "area"] or str(t[1]).begins_with("HELP/"):
		return false
	_set_help_mode(false)
	_help_show(str(t[1]), true)
	_row_suppressed = true
	_help_swallow = true
	return true


## Show the card for `key`. False when there is none (a hold then does
## nothing; in help mode it says so).
func _help_show(key: String, in_help_mode: bool) -> bool:
	var card := HelpText.find(key)
	if card.is_empty():
		print("[help] no card for '%s'" % key)
		if in_help_mode:
			_flash_status("NO HELP CARD FOR THIS ONE YET")
		return false
	var body: String = card["body"]
	if in_help_mode:
		body += "\n\n(HELP MODE: ONE CARD PER TAP. HOLD ANY CONTROL FOR ITS CARD ANY TIME.)"
	var dlg := M8Dialog.note(_chrome_layer, card["title"], body)
	dlg.theme = _theme
	return true


func _set_help_mode(on: bool) -> void:
	_help_mode = on
	if is_instance_valid(_help_mode_toggle):
		_help_mode_toggle.set_pressed_no_signal(on)
	if on:
		status.text = "HELP MODE — THE NEXT TAP ON A CONTROL SHOWS ITS CARD"
		status.visible = true
		_status_token += 1   # no flash may take this line down while help mode is on
	else:
		status.visible = false


## The first-run tour: HelpText.TOUR, one card after another. Seen once,
## whether finished or skipped; MODE ▸ HELP brings it back.
func _show_tour(i: int) -> void:
	if i >= HelpText.tour().size():
		_finish_tour()
		return
	var last := i == HelpText.tour().size() - 1
	var card: Array = HelpText.tour()[i]
	var dlg := M8Dialog.confirm(_chrome_layer, "%s  (%d/%d)" % [card[0], i + 1, HelpText.tour().size()],
		card[1], "DONE" if last else "NEXT", func() -> void: _show_tour(i + 1), M8Dialog.M8_GREEN, "SKIP")
	dlg.cancelled.connect(_finish_tour)
	dlg.theme = _theme


func _finish_tour() -> void:
	if not _tour_seen:
		_tour_seen = true
		_settings_dirty = true


# --- Heat ------------------------------------------------------------------
# A phone driving a projector over HDMI cannot charge (one port) and heats up.
# At PowerManager's THERMAL_STATUS_CRITICAL Android DISABLES the external
# display: a black projector mid-set, and a replug to get it back. It happened
# three times on the day the camera keystone was built. So: watch the status,
# say so one step before, and ease off until it cools.

const HEAT_POLL_SEC := 5.0
const HEAT_WARN := 3     ## THERMAL_STATUS_SEVERE — the last step before the cut
const HEAT_CUT := 4      ## THERMAL_STATUS_CRITICAL — Android turns the projector off
const HEAT_CLEAR := 1    ## back down to this (LIGHT) before full rate returns
## The frame rate held while hot. Half the GPU's work; a VJ set at 30 fps is a
## worse picture, a black projector is no picture.
const HEAT_FPS := 30


func _build_heat_watch() -> void:
	if not AndroidProbe.available():
		return
	var timer := Timer.new()
	timer.wait_time = HEAT_POLL_SEC
	timer.autostart = true
	add_child(timer)
	timer.timeout.connect(_poll_heat)
	_poll_heat.call_deferred()
	# The lens, asked once, from its own call stack (it may fail: see AndroidProbe).
	_ask_camera.call_deferred()


func _ask_camera() -> void:
	AndroidProbe.ask_camera()
	print("[calib] lens: %s" % AndroidProbe.camera_note)


func _poll_heat() -> void:
	AndroidProbe.poll_thermal()
	_on_heat(AndroidProbe.thermal_status)


## React to a thermal status (also the verifier's way in — there is no heat on
## a desk).
func _on_heat(heat: int) -> void:
	if heat == _heat:
		return
	var was := _heat
	_heat = heat
	print("[heat] thermal status %d -> %d (headroom %.2f)" % [was, heat, AndroidProbe.thermal_headroom])
	if heat >= HEAT_WARN and not _heat_capped:
		_heat_capped = true
		_heat_prev_fps = Engine.max_fps
		if Engine.max_fps == 0 or Engine.max_fps > HEAT_FPS:
			Engine.max_fps = HEAT_FPS
	elif heat >= 0 and heat <= HEAT_CLEAR and _heat_capped:
		_heat_capped = false
		Engine.max_fps = _heat_prev_fps
		_flash_status("PHONE COOLER — FULL FRAME RATE AGAIN")
	if heat >= HEAT_CUT and was < HEAT_CUT:
		# A hard state, not a passing notice: it stays until dismissed.
		var dlg := M8Dialog.error(_chrome_layer, "PHONE TOO HOT",
			"AT THIS HEAT ANDROID SWITCHES THE PROJECTOR OFF. LET THE PHONE COOL, THEN REPLUG THE HDMI CABLE.")
		dlg.theme = _theme
	elif heat >= HEAT_WARN and was < HEAT_WARN:
		_flash_status("PHONE HOT — HOLDING %d FPS. ONE STEP MORE AND ANDROID CUTS THE PROJECTOR" % HEAT_FPS)
	if _calib != null and _calib.active:
		_calib.refresh_hint()


# --- Sequencer 2.0: MixWorld + the lane B deck (Stage 1.1) ------------------

## Build the blend bus + the second deck on FIRST arm — never at boot. R1: an
## unarmed lane B costs nothing, not even idle viewports.
func _ensure_lane_b() -> void:
	if _mix_world != null:
		return
	_mix_world = SubViewport.new()
	# ⚠️ Opaque black clear, NOT transparent_bg: MaskOverlay's black-overlay
	# multiply reads the composite against black (mask_overlay.gd:14) — a
	# transparent mix would let deck letterbox areas read as alpha through it.
	_mix_world.size = Vector2i(_output_px)
	_mix_world.render_target_update_mode = SubViewport.UPDATE_DISABLED
	output_world.add_child(_mix_world)
	# Render BEFORE the stages that sample it (same rule as MaskWorld in
	# _refresh_output_source).
	output_world.move_child(_mix_world, shader_slot.get_index())

	_deck_a_rect = _mix_rect()
	_deck_a_rect.texture = clip_engine.active_texture()
	_mix_world.add_child(_deck_a_rect)
	_deck_b_rect = _mix_rect()
	_deck_b_rect.modulate.a = _xfade
	_mix_world.add_child(_deck_b_rect)

	# The second deck. Its decoders must render before MixWorld samples them,
	# so it sits above the mix in tree order. Signals connect in the same frame
	# as add_child — ClipEngine._start is deferred exactly so this wiring lands
	# first (clip_engine.gd:83).
	_clip_engine_b = ClipEngine.new()
	_clip_engine_b.start_index = 1   # open on a different clip than deck A
	output_world.add_child(_clip_engine_b)
	output_world.move_child(_clip_engine_b, _mix_world.get_index())
	_clip_engine_b.active_texture_changed.connect(_on_lane_b_texture_changed)
	_clip_engine_b.swap_held.connect(_flash_held.bind("B"))
	_clip_engine_b.clip_failed.connect(_on_clip_failed)
	# The warm-cue provider is installed HERE, unconditionally — lane B has no
	# other modes, so the pattern's next slot is always the right thing to warm
	# (returns -1 on an empty pattern = no cue). Installing it only in the auto
	# toggle left auto-then-arm ordering cold-cutting every slot forever.
	_clip_engine_b.next_index_provider = func() -> int: return _lane_b_next_engine_index()
	_deck_b_rect.texture = _clip_engine_b.active_texture()

	# Deck B's ring in the clip grid. Deck A's echo arrives on the grid's own
	# clip_changed connection; B has to come from here, because the grid is
	# constructed with engine A and can only ever hear that one.
	_clip_engine_b.clip_changed.connect(_on_lane_b_clip_changed)

	_lane_b.engine = _clip_engine_b
	_ensure_lane_b_model()


## Engine B moved: repaint DECK B's ring in the grid (amber), leaving deck A's
## alone. The two rings are independent because both decks play at once.
func _on_lane_b_clip_changed(_name: String, index: int, _count: int) -> void:
	if _clip_grid == null or _clip_engine_b == null:
		return
	if index < 0 or index >= _clip_engine_b.clips.size():
		return
	_clip_grid.set_deck_active(1, ClipLibrary.id_for_path(_clip_engine_b.clips[index]))


## Lane B's model: its own pattern file, same persistence discipline as lane A
## (save on every model change; re-warm the cue when the arrangement changes).
## Separate from _ensure_lane_b so the strip can EDIT lane B's pattern before
## the deck has ever been armed.
func _ensure_lane_b_model() -> void:
	if _lane_b_model_loaded:
		return
	_lane_b_model_loaded = true
	if FileAccess.file_exists(SEQUENCE_B_PATH):
		var res := ResourceLoader.load(SEQUENCE_B_PATH) as Sequence
		if res != null:
			_lane_b.sequence = res
	_lane_b.sequence.changed.connect(_save_sequence_b)
	_lane_b.sequence.changed.connect(_push_grid_decks)   # the B badges follow the pattern
	_lane_b.sequence.changed.connect(func() -> void:
		if _lane_b_drives():
			_clip_engine_b.recue())


func _mix_rect() -> TextureRect:
	var r := TextureRect.new()
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	return r


func _on_lane_b_texture_changed(tex: Texture2D) -> void:
	# Source guard (hazard 3): a swap emitted mid-switch must not clobber the
	# NET face — the CLIP branch of _apply_lane_b_source rebinds on the way back.
	if _deck_b_rect != null and _lane_b_source == LaneBSource.CLIP:
		_deck_b_rect.texture = tex


func _set_lane_b_armed(on: bool) -> void:
	if on == _lane_b_armed:
		return
	_lane_b_armed = on
	_push_perf_lane_b()
	if on:
		_ensure_lane_b()
		_deck_a_rect.texture = clip_engine.active_texture()
		# Source-aware wake: CLIP wakes engine B (and recues if driving); NET
		# binds the incoming stream to the B face and leaves the engine asleep.
		_apply_lane_b_source()
	elif _clip_engine_b != null:
		# Disarm = the lane sleeps where it stands: no decode pump, no render
		# target clears. Re-arming resumes the same clip (R1 is about cost,
		# not about forgetting state).
		_clip_engine_b.set_rendering(false)
		_clip_engine_b.process_mode = Node.PROCESS_MODE_DISABLED
		if _strip_lane == 1 and _seq_strip != null:
			_seq_strip.set_playhead(0.0)   # stopped clock, honest strip
		# Lane B released the stream — the over-the-top layer may return.
		_refresh_link_layer_visibility()
	if _lane_b_arm_toggle != null:
		_lane_b_arm_toggle.set_pressed_no_signal(on)   # panel row mirrors reality
	_refresh_output_source()
	_settings_dirty = true
	print("[lane_b] %s" % ("ARMED" if on else "disarmed"))


func _set_xfade(v: float) -> void:
	_xfade = clampf(v, 0.0, 1.0)
	if _perf_strip != null and _perf_strip.visible:
		_perf_strip.set_xfade(_xfade)   # change-gated inside; ignored mid-drag
	if _deck_b_rect == null:
		return
	# Change-gated like every colour write (spec §4.4): gesture-rate slider
	# events only touch the rect when the value moved visibly or hit an end.
	if absf(_deck_b_rect.modulate.a - _xfade) > 0.02 or _xfade == 0.0 or _xfade == 1.0:
		_deck_b_rect.modulate.a = _xfade


# --- Crossfade automation (XF1: MANUAL | BEAT hard-cut) ---------------------

## The automation's write path: same value authority as the operator's
## (_set_xfade, change-gated), but never demotes the mode.
func _drive_xfade(v: float) -> void:
	_set_xfade(v)


## The OPERATOR's write path: any hand on the crossfade drops the automation
## instantly — the performer always wins, never fights a mode live.
func _set_xfade_manual(v: float) -> void:
	if _xfade_mode != XfadeMode.MANUAL:
		_set_xfade_mode(XfadeMode.MANUAL)
		_flash_status("XFADE: MANUAL (override)")
	_set_xfade(v)


func _set_xfade_mode(m: int) -> void:
	if m == _xfade_mode:
		return
	_xfade_mode = m
	_xfade_beat_count = 0
	# A mode change abandons any in-flight fade WHERE IT IS — the demote case
	# is the performer grabbing the fader, and it must not keep moving.
	_xfade_anim_t = -1.0
	# Seed the toggle from where the fader actually IS, so entering BEAT
	# mid-way flips to the far deck first rather than snapping back.
	_xfade_target = 1.0 if _xfade >= 0.5 else 0.0
	if _xfade_mode_btn != null:
		_xfade_mode_btn.text = "Xfade mode: %s" % XFADE_MODE_NAMES[m]
	_settings_dirty = true
	print("[xfade] mode %s" % XFADE_MODE_NAMES[m])


## BEAT mode (XF1): the flip-trigger shape — count beats, fire every Nth,
## hard-cut the fader to the other deck. Fade-over-beats arrives in XF2.
func _on_xfade_beat(_index: int) -> void:
	if _xfade_mode != XfadeMode.BEAT and _xfade_mode != XfadeMode.LFO:
		return
	# Nothing to fade to: unarmed lane B idles the automation (R1 — the
	# never-armed session pays one enum compare per beat and nothing else).
	if not _lane_b_armed or _deck_b_rect == null:
		return
	_xfade_beat_count += 1
	if _xfade_mode == XfadeMode.LFO:
		return   # LFO only COUNTS here; _tick_xfade turns beats into the sweep
	if _xfade_beat_count % int(XFADE_EVERY[_xfade_every_idx]) != 0:
		return
	_xfade_target = 0.0 if _xfade_target >= 0.5 else 1.0
	var sw := int(XFADE_SWITCH[_xfade_switch_idx])
	if sw == 0:
		_drive_xfade(_xfade_target)             # CUT — the XF1 punch
	else:
		# XF2: fade over N beats from wherever the fader IS (a retarget
		# mid-fade — Switch longer than Every — just reverses smoothly).
		_xfade_anim_from = _xfade
		_xfade_anim_t = 0.0
	print("[xfade] BEAT -> %s%s" % [("B" if _xfade_target >= 0.5 else "A"),
		"" if sw == 0 else " over %db" % sw])


## XF2: the fade animation, tempo-locked. Runs only while a fade is in
## flight (_xfade_anim_t >= 0) — idle cost is one float compare per frame.
## Writes ride _set_xfade's existing 0.02 change gate: a slow fade lands as
## ~50 imperceptible steps instead of per-frame rect writes.
func _tick_xfade(delta: float) -> void:
	# XF3: the LFO sweep — a bar-locked triangle glued to the grid. Position =
	# beats since mode entry (counted by _on_xfade_beat) + the within-beat
	# fraction from BeatClock.phase, over the period. 0 → A, midpoint → B,
	# period → A: every sweep starts and ends on a downbeat-of-the-period, and
	# because the position is DERIVED from the clock (not integrated), tempo
	# changes and N4's slave nudges cannot drift it.
	if _xfade_mode == XfadeMode.LFO:
		if _lane_b_armed and _deck_b_rect != null:
			var period_beats := float(int(XFADE_LFO_BARS[_xfade_lfo_bars_idx])
				* BeatClock.beats_per_bar)
			var within := fmod(BeatClock.phase * float(BeatClock.beats_per_bar), 1.0)
			var t := fposmod((float(_xfade_beat_count) + within) / period_beats, 1.0)
			_drive_xfade(1.0 - absf(2.0 * t - 1.0))
		return
	if _xfade_anim_t < 0.0:
		return
	var sw := int(XFADE_SWITCH[_xfade_switch_idx])
	if sw <= 0:
		# Switch flipped to CUT mid-fade — land immediately.
		_xfade_anim_t = -1.0
		_drive_xfade(_xfade_target)
		return
	_xfade_anim_t = minf(_xfade_anim_t + delta * BeatClock.bpm / 60.0 / float(sw), 1.0)
	_drive_xfade(lerpf(_xfade_anim_from, _xfade_target, _xfade_anim_t))
	if _xfade_anim_t >= 1.0:
		_xfade_anim_t = -1.0


## XF4: AUDIO — the transient decides WHEN, the toggle decides WHERE, and the
## Switch param decides HOW (cut or fade, same as BEAT). The refractory is the
## audio-switch idiom verbatim: a snare roll must not strobe the mix.
func _on_xfade_onset() -> void:
	if _xfade_mode != XfadeMode.AUDIO:
		return
	if not _lane_b_armed or _deck_b_rect == null:
		return
	var now := Time.get_ticks_msec()
	if _xfade_audio_last_ms >= 0 \
			and now - _xfade_audio_last_ms < int(AUDIO_REFRACTORY_SEC * 1000.0):
		return
	_xfade_audio_last_ms = now
	_xfade_target = 0.0 if _xfade_target >= 0.5 else 1.0
	var sw := int(XFADE_SWITCH[_xfade_switch_idx])
	if sw == 0:
		_drive_xfade(_xfade_target)
	else:
		_xfade_anim_from = _xfade
		_xfade_anim_t = 0.0
	print("[xfade] ONSET -> %s%s lvl=%.3f" % [("B" if _xfade_target >= 0.5 else "A"),
		"" if sw == 0 else " over %db" % sw, GlobalBus.level])


func _cycle_xfade_mode() -> void:
	var i := XFADE_MODES_AVAILABLE.find(_xfade_mode)
	_set_xfade_mode(XFADE_MODES_AVAILABLE[(i + 1) % XFADE_MODES_AVAILABLE.size()])


func _cycle_xfade_lfo() -> void:
	_xfade_lfo_bars_idx = (_xfade_lfo_bars_idx + 1) % XFADE_LFO_BARS.size()
	if _xfade_lfo_btn != null:
		_xfade_lfo_btn.text = "LFO period: %d bars" % int(XFADE_LFO_BARS[_xfade_lfo_bars_idx])
	_settings_dirty = true


func _cycle_xfade_switch() -> void:
	_xfade_switch_idx = (_xfade_switch_idx + 1) % XFADE_SWITCH.size()
	if _xfade_switch_btn != null:
		var sw := int(XFADE_SWITCH[_xfade_switch_idx])
		_xfade_switch_btn.text = "Switch: %s" % ("CUT" if sw == 0 else "%d beats" % sw)
	_settings_dirty = true


func _cycle_xfade_every() -> void:
	_xfade_every_idx = (_xfade_every_idx + 1) % XFADE_EVERY.size()
	_xfade_beat_count = 0
	if _xfade_every_btn != null:
		_xfade_every_btn.text = "Beat every: %d" % int(XFADE_EVERY[_xfade_every_idx])
	_settings_dirty = true


# --- Lane B source: CLIPS | PEER | TD (DUAL_PHONE_B_DECK_SPEC N1, SEQ2 3.2) ---

## True while lane B owns an incoming link stream, either slot. THAT slot's
## over-the-top layer stands down for exactly this window (a stream shows in
## one place, no double-draw); the other slot's layer is unaffected.
func _lane_b_owns_stream() -> bool:
	return _lane_b_armed and _lane_b_source != LaneBSource.CLIP


## The NetSource lane B's face reads for the current source. null for CLIPS, or
## when that slot does not exist (link off; TD before its first ensure).
func _lane_b_net_source() -> NetSource:
	match _lane_b_source:
		LaneBSource.NET:
			return _net_source
		LaneBSource.TD:
			return _net_source_td
	return null


## Who lane B's remote verbs (N4 seq auto/slot) are aimed at: the provider of
## the stream lane B actually SHOWS. Before the split this was simply "whoever
## was pulled", because only one thing could be. {} = nobody streaming there.
func _lane_b_provider() -> Dictionary:
	if not _lane_b_owns_stream():
		return {}
	if _lane_b_source == LaneBSource.TD:
		if _td_rx_ip == "":
			return {}
		return {"ip": _td_rx_ip, "ctrl": _td_rx_ctrl_port, "who": "TD"}
	if _link_rx_ip == "":
		return {}
	return {"ip": _link_rx_ip, "ctrl": _link_rx_ctrl_port, "who": "PEER"}


## Point lane B's face at its source. Called on arm (source-aware wake), on a
## source flip, and at boot-restore via the arm path. Safe before first arm
## (_deck_b_rect null = nothing to point yet; the arm path lands here again).
func _apply_lane_b_source() -> void:
	if _deck_b_rect == null:
		return
	# TD builds its slot on demand. A stream source with no slot to read cannot
	# show anything — fall back out loud (hazard 1 family; also the boot-restore
	# path when [link] enabled=false).
	if _lane_b_source == LaneBSource.TD:
		_ensure_td_source()
	var ns := _lane_b_net_source()
	if _lane_b_source != LaneBSource.CLIP and ns == null:
		_lane_b_source = LaneBSource.CLIP
		_push_lane_b_src_btn()
		_flash_status("LANE B: NET NEEDS VIDEO LINK — USING CLIPS")
	if ns != null and _lane_b_source != LaneBSource.CLIP:
		if ns.get_codec() == "h264":
			# The ExternalTexture rule (LINK_OES_SHADER): white placeholder as
			# geometry, the video arrives through the samplerExternalOES
			# uniform, modulate (the crossfade!) rides vertex COLOR. One
			# material for both slots — the sampler is re-pointed on every flip.
			if _lane_b_net_mat == null:
				var sh := Shader.new()
				sh.code = LINK_OES_SHADER
				_lane_b_net_mat = ShaderMaterial.new()
				_lane_b_net_mat.shader = sh
			_lane_b_net_mat.set_shader_parameter("link_tex", ns.get_texture())
			var img := Image.create(1, 1, false, Image.FORMAT_RGB8)
			img.fill(Color.WHITE)
			_deck_b_rect.texture = ImageTexture.create_from_image(img)
			_deck_b_rect.material = _lane_b_net_mat
		else:
			_deck_b_rect.material = null
			_deck_b_rect.texture = ns.get_texture()
		# Engine B sleeps where it stands — hardware MediaCodec replaces the
		# GoZen pair while a stream owns the face (a cost win, and R1-shaped).
		if _clip_engine_b != null:
			_clip_engine_b.set_rendering(false)
			_clip_engine_b.process_mode = Node.PROCESS_MODE_DISABLED
		# Freshness owns VISIBILITY only (LOST = pure deck A) — never the
		# crossfade (hazard 5: modulate.a belongs to the operator).
		_deck_b_rect.visible = ns.freshness() != NetSource.Freshness.LOST
	else:
		# Hazard 3 ordering: rebind the engine texture BEFORE waking it, so a
		# swap emitted mid-switch lands on a rect that already left the OES
		# material behind.
		_deck_b_rect.material = null
		_deck_b_rect.visible = true
		if _clip_engine_b != null:
			_deck_b_rect.texture = _clip_engine_b.active_texture()
			if _lane_b_armed:
				_clip_engine_b.process_mode = Node.PROCESS_MODE_INHERIT
				_clip_engine_b.set_rendering(true)
				if _lane_b_drives():
					_clip_engine_b.recue()
	_refresh_link_layer_visibility()
	_push_lane_b_badge()   # covers the link-off fallback and the teardown degrade


## The strip's B chip mirrors the source ("B·NET" / "B·TD") wherever it changes —
## including the fallback paths inside _apply_lane_b_source.
func _push_lane_b_badge() -> void:
	if _seq_strip != null:
		_seq_strip.set_lane_b_badge(["", "NET", "TD"][_lane_b_source])


## The B source row's label, pushed from every path that moves the source
## (cycle, OSC, fallbacks, load) so the panel can never show a stale one.
func _push_lane_b_src_btn() -> void:
	if _lane_b_src_btn != null:
		_lane_b_src_btn.text = ("B source: %s" % LANE_B_SOURCE_NAMES[_lane_b_source]).to_upper()


func _cycle_lane_b_source() -> void:
	_set_lane_b_source((_lane_b_source + 1) % LANE_B_SOURCE_NAMES.size())


func _set_lane_b_source(src: int) -> void:
	if src == _lane_b_source:
		return
	if src != LaneBSource.CLIP and _net_source == null:
		_flash_status("LANE B: NET NEEDS VIDEO LINK ON")
		_push_lane_b_src_btn()
		return
	_lane_b_source = src
	_apply_lane_b_source()
	_push_lane_b_src_btn()
	_push_lane_b_badge()   # apply() early-returns before the first arm — push anyway
	_push_perf_lane_b()
	_settings_dirty = true
	print("[lane_b] source: %s" % LANE_B_SOURCE_NAMES[_lane_b_source])
	_flash_status("LANE B SRC: %s" % LANE_B_SOURCE_NAMES[_lane_b_source])


## One place computes BOTH over-the-top layers' visibility, per slot: freshness
## (LOST hides, R5) AND lane B ownership (a stream shows in one place).
func _refresh_link_layer_visibility() -> void:
	if _link_layer != null and _net_source != null:
		_link_layer.visible = _net_source.freshness() != NetSource.Freshness.LOST \
			and not (_lane_b_armed and _lane_b_source == LaneBSource.NET)
	if _td_layer != null and _net_source_td != null:
		_td_layer.visible = _net_source_td.freshness() != NetSource.Freshness.LOST \
			and not (_lane_b_armed and _lane_b_source == LaneBSource.TD)


# --- Lane B sequencing (Stage 1.2, SEQ2 §3.2) -------------------------------
# Lane B has no modes: its whole vocabulary is "the pattern plays on the grid".
# So its drive predicate is armed ∧ auto ∧ non-empty — no _mode term.

func _lane_b_drives() -> bool:
	# The CLIP term (N1): with NET on the face there is no local deck to
	# drive — the sequencer stands down, the pattern survives untouched.
	return _lane_b_armed and _lane_b.auto and not _lane_b.sequence.is_empty() \
		and _lane_b_source == LaneBSource.CLIP


## Mirror of _seq_next_engine_index for the B deck (same warm-cue discipline:
## the provider must resolve exactly the way the advance will, or every step
## pays the cold demux — measured 307-430 ms at 1080p, spike S2).
func _lane_b_next_engine_index() -> int:
	if _lane_b.sequence.is_empty():
		return -1
	var slot := (_lane_b.index + 1) % _lane_b.sequence.size()
	return _engine_index_for_clip_id(_lane_b.sequence.get_id(slot), _clip_engine_b)


func _advance_lane_b_to(index: int) -> void:
	_lane_b.index = index
	if _strip_lane == 1 and _seq_strip != null:
		_seq_strip.set_active(index)
	var ci := _engine_index_for_clip_id(_lane_b.sequence.get_id(index), _clip_engine_b)
	if ci >= 0:
		_clip_engine_b.jump(ci)


func _set_lane_b_auto(on: bool) -> void:
	# Model-side work needs no deck: auto can be armed from the strip before
	# the lane is — it simply starts driving once _lane_b_armed flips true.
	_ensure_lane_b_model()
	_lane_b.auto = on
	if _seq_strip != null and _strip_lane == 1:
		_seq_strip.set_auto(on)
	if _lane_b_auto_toggle != null:
		_lane_b_auto_toggle.set_pressed_no_signal(on)   # panel row mirrors reality
	_settings_dirty = true
	# Stagger (spike S2, advisory-by-default): start the count bar_offset beats
	# LATE so the two lanes' cue windows interleave instead of colliding.
	_lane_b.beat_count = -_lane_b.bar_offset if on else 0
	if on and _lane_b.sequence.is_empty():
		# First-run convenience: adopt lane A's pattern, else the first four
		# clips — arming a sequencer must produce motion. (The grid + strip
		# now edit lane B directly; this only fills an EMPTY pattern.)
		if not _lane_a.sequence.is_empty():
			_lane_b.sequence.from_array(_lane_a.sequence.to_array())
		else:
			var ids: Array[String] = []
			for p in clip_engine.clips.slice(0, 4):
				var id := ClipLibrary.id_for_path(p)
				if id != "":
					ids.append(id)
			_lane_b.sequence.from_array(ids)
	if _lane_b_drives():
		# Resume in place like lane A's arming rule: only a fresh run (no
		# position yet) jumps; re-enabling mid-set stays put and cuts on the
		# next boundary — no unquantized hard restart at slot 0.
		if _lane_b.index < 0:
			_advance_lane_b_to(0)
		else:
			_clip_engine_b.recue()
	elif not on and _strip_lane == 1 and _seq_strip != null:
		_seq_strip.set_playhead(0.0)   # a stopped clock must not advertise motion
	print("[lane_b] auto %s (%d slots, offset %d)" %
		["ON" if on else "off", _lane_b.sequence.size(), _lane_b.bar_offset])


func _save_sequence_b() -> void:
	ResourceSaver.save(_lane_b.sequence, SEQUENCE_B_PATH)


## A lane skipped a cut (cue not warm). Make it VISIBLE — silent skipping at a
## gig reads as a bug (SEQ2 §3.3). Strip flash when the grid is open; always a
## log line (the engine's own HELD log carries the numbers).
func _flash_held(lane_tag: String) -> void:
	if _seq_strip != null:
		_seq_strip.flash("HELD · %s" % lane_tag)


## Hazard §4.1: any library rescan must walk BOTH engines — engine B keeps its
## own clips array and cue bookkeeping, and a stale list makes pattern slots
## resolve to -1 (silent holds) or lets it cue a deleted file.
func _rescan_engine_b() -> void:
	if _clip_engine_b == null:
		return
	_clip_engine_b.scan()
	if _lane_b_drives():
		_clip_engine_b.recue()


# "" = the picker's NO MASK IMAGE row — the clear action lives in the browser
# (like the VIDEO picker's FOLLOW DECK row) because a fifth panel row would
# overflow the no-scroll sidebar on the 1080-tall panel.
func _on_mask_image_selected(path: String) -> void:
	if path == "":
		_mask_overlay.clear_mask()
		_mask_overlay.save()
		_flash_status("MASK IMAGE CLEARED")
	elif _mask_overlay.set_mask(path):
		_mask_overlay.save()
		_flash_status("MASK IMAGE: %s" % path.get_file())
	else:
		_flash_status("CANNOT READ %s AS AN IMAGE" % path.get_file())
	if _mask_browser != null:
		_mask_browser.visible = false
	_refresh_mask_rows()


func _cycle_mask_fit() -> void:
	_mask_overlay.cycle_fit()
	_mask_overlay.save()
	_refresh_mask_rows()


func _refresh_mask_rows() -> void:
	if _btn_mask_img != null:
		var f := _mask_overlay.mask_path.get_file()
		_btn_mask_img.text = ("MASK IMG: %s" % f if f != "" else "MASK IMG: NONE…").to_upper()
	if _btn_mask_fit != null:
		_btn_mask_fit.text = "MASK FIT: %s" % _mask_overlay.fit_name()


# Lazily build + toggle the mask-image picker: the LocalBrowser scene in SELECT
# mode (image extensions, no copy) — same breadcrumb interaction as Local Files.
func _toggle_mask_browser() -> void:
	# Android: the system image picker copies the file into app storage (no
	# storage permission). Backing out of it offers to clear the current mask.
	if Storage.pick_image():
		_close_panels()
		return
	if _mask_browser == null:
		_mask_browser = preload("res://scenes/LocalBrowser.tscn").instantiate() as Control
		_mask_browser.visible = false
		_mask_browser.set("select_only", true)   # set before _ready
		_mask_browser.set("exts", PackedStringArray(MaskOverlay.IMAGE_EXTS))
		_mask_browser.set("clear_label", "NO MASK IMAGE")
		_mask_browser.theme = _theme          # CanvasLayer breaks theme inheritance
		_chrome_layer.add_child(_mask_browser)
		_mask_browser.connect("file_selected", _on_mask_image_selected)
		var title := _mask_browser.get_node_or_null("VBox/Toolbar/Title") as Label
		if title != null:
			title.text = "  MASK IMAGE  "
	_mask_browser.visible = not _mask_browser.visible
	if _mask_browser.visible:
		_close_panels()
		_chrome_layer.move_child(_mask_browser, -1)


func _enter_masks() -> void:
	# The nav bar + status bar go for the WHOLE of mask mode (2026-10-01): the
	# nav bar sat over the top of the picture, and a point up there could not
	# be reached. The editor's own bar has DONE; closing it brings them back
	# (_on_region_editor_closed).
	_close_panels()
	_set_overlays_visible(false)
	_mask_edit_active = true
	_refresh_output_source()   # MaskWorld owns the output while authoring
	# While authoring, the phone previews the PRE-WARP MaskWorld texture: masks
	# are drawn in content space, so the editor's handles only align with what
	# the preview shows if the preview skips the warp. The projector keeps the
	# warped OutputWorld — DUAL·TEX reads the viewport RID, not this TextureRect.
	_preview.texture = _mask_world.get_texture()
	_region_editor.set_active(true)


func _on_region_editor_closed() -> void:
	_mask_edit_active = false
	_region_comp.set_checker(false)   # a mapping aid — never left on stage
	_preview.texture = output_world.get_texture()   # back to the warped output
	_set_overlays_visible(true)
	_refresh_region_routing()


# Masks own the output when any exist (shown on MaskWorld's black clear color);
# with none, fall back to the normal full-screen QuadWarp path.
func _refresh_region_routing() -> void:
	if _region_comp == null:
		return
	_refresh_output_source()
	_last_region_intensity = -1.0   # force one push so NEW masks get the value
	_refresh_nav_values()


## The one authority on what QuadWarp samples (S17 / Option A). Masks own the
## output when any exist or while the mask editor is authoring; the swap is a
## SOURCE swap — QuadWarp stays visible on both paths, so warp always applies.
## Every quad_warp.set_source() after boot must come through here: a blind
## set_source(shader_slot) elsewhere would steal the output back from MaskWorld.
## Side effects, deliberately centralized:
##  - the test grid reparents into the active pre-warp viewport, so it warps
##    with (and reaches) the output on both paths;
##  - the idle pre-warp stage stops rendering — with masks up, ShaderSlot goes
##    UPDATE_DISABLED (the saving the old visibility swap never realised);
##  - later global-FX-over-masks chain (MaskWorld → ShaderSlot → QuadWarp) is
##    a source swap inside this one function.
## Safe to call before _build_region_compositor (boot _apply_quality): falls
## back to the plain ShaderSlot path.
## True while the mask compositor owns the pre-warp image.
func _masks_own() -> bool:
	return _region_comp != null and (_region_comp.has_regions() or _mask_edit_active)


## Whichever engine currently backs the CAMERA source (M6). Both expose the
## same SubViewport API, which is exactly why routing is a one-line choice.
func _cam_texture() -> Texture2D:
	if _cam_via_tracking and _track_camera != null:
		return _track_camera.get_texture()
	return camera_engine.get_texture()


## The texture the deck is currently producing, before any effect.
func _source_texture() -> Texture2D:
	if _source == ClipSource.CAMERA:
		return _cam_texture()
	if _lane_b_live():
		return _mix_world.get_texture()
	return clip_engine.active_texture()


## True while the MixWorld blend owns the deck image — but only once the mix
## holds a rendered frame (_mix_warmed). During the one-frame warm-up after a
## wake, the mix renders without owning the output yet, so the handoff is
## seamless instead of one black/stale frame.
func _lane_b_live() -> bool:
	return _mix_should_render() and _mix_warmed


## The mix should be RENDERING (armed + built; camera bypasses the mix — lane B
## is a CLIP lane; SRC CAMERA replaces the whole deck, as today). Distinct from
## _lane_b_live: rendering starts one frame before the output routes to it.
func _mix_should_render() -> bool:
	return _lane_b_armed and _mix_world != null and _source != ClipSource.CAMERA


## Route the pre-warp image into QuadWarp.
##
## ⚠️ THIS IS NOW A CHAIN, NOT A SOURCE SWAP. It used to point QuadWarp straight at
## MaskWorld and set shader_slot to UPDATE_DISABLED, which meant the GLOBAL FX chain
## was switched off entirely whenever a single mask existed — the nav-bar FX cell still
## changed _effect_index but nothing rendered it. Reported as "effects aren't playing
## in mask mode"; it was bypassed by design (the S17 routing), not broken.
##
##   was:  ClipEngine -> MaskWorld ---------------> QuadWarp   (ShaderSlot orphaned)
##   now:  ClipEngine -> MaskWorld -> ShaderSlot -> QuadWarp
##
## ⚠️ COSTS ONE EXTRA FULL-FRAME 1080p PASS while masks are active — the same pass the
## un-masked path already pays, but the masked path used to skip it. With a feedback
## effect (Trails, Slit-Scan: another ~8 MB each way, see shader_slot.gd) plus up to
## MAX_DECODERS mask decoders, this is the combination to watch for dropped frames.
func _refresh_output_source() -> void:
	# ⚠️ MixWorld wake-up, BEFORE any routing below: flipping a slept (or
	# brand-new) render target to UPDATE_ALWAYS gives it no valid content until
	# this frame has drawn, and sampling it in the same frame presents one
	# black/stale frame — the arm flash. Clearing the warm flag FIRST makes
	# every _lane_b_live()/_source_texture() in this very call keep the old
	# route; the one-shot re-runs this function after the mix has rendered
	# once, and only then does the (visually identical) handoff happen. Covers
	# every wake path through this authority: arm, re-arm, CAMERA→VIDEO.
	if _mix_world != null and _mix_should_render() \
			and _mix_world.render_target_update_mode == SubViewport.UPDATE_DISABLED:
		_mix_warmed = false
		if not RenderingServer.frame_post_draw.is_connected(_on_mix_warmed):
			RenderingServer.frame_post_draw.connect(_on_mix_warmed, CONNECT_ONE_SHOT)
	var masks_own := _masks_own()
	# ⚠️ Render order matters now that one feeds the other. _mask_world is added to
	# output_world AFTER ShaderSlot, so without this it would render second and
	# ShaderSlot would sample a frame-old composite.
	if masks_own and _mask_world != null and _mask_world.get_index() > shader_slot.get_index():
		output_world.move_child(_mask_world, shader_slot.get_index())
	shader_slot.set_input(_mask_world.get_texture() if masks_own else _source_texture())
	quad_warp.set_source(shader_slot.get_texture())
	# ShaderSlot now runs on BOTH paths — it is the last stage before the warp.
	shader_slot.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if _mask_world != null:
		_mask_world.render_target_update_mode = \
			SubViewport.UPDATE_ALWAYS if masks_own else SubViewport.UPDATE_DISABLED
	if _mix_world != null:
		# Same gate discipline as MaskWorld — and MixWorld must render BEFORE
		# whichever stage samples it: ShaderSlot directly, or MaskWorld's
		# regions when masks own the output (they sample _source_texture()).
		if _lane_b_live():
			var want := shader_slot.get_index()
			if _mask_world != null:
				want = mini(want, _mask_world.get_index())
			if _mix_world.get_index() > want:
				output_world.move_child(_mix_world, want)
			if _region_comp != null:
				_region_comp.set_source(_source_texture())
		# _mix_should_render, not _lane_b_live: the warm-up frame must RENDER
		# while the output still shows the old route (see the wake block above).
		_mix_world.render_target_update_mode = \
			SubViewport.UPDATE_ALWAYS if _mix_should_render() \
			else SubViewport.UPDATE_DISABLED
	# ⚠️ The test grid lives in ShaderSlot on BOTH paths now. It is an alignment tool —
	# its job is showing straightness on the wall — so it stays ABOVE the masks rather
	# than being cut up by them. It does sit downstream of the effect shader, so a
	# heavy effect will colour the grid; that is the accepted trade for keeping it
	# unmasked.
	if _grid_overlay != null and _grid_overlay.get_parent() != shader_slot:
		_grid_overlay.reparent(shader_slot, false)   # keep anchors, not global pos
	print("[route] quad_warp <- ShaderSlot <- %s" % ["MaskWorld" if masks_own else "source"])


# One rendered frame after a MixWorld wake: the target now holds real content
# (deck A + deck B at the current crossfade — at the handoff instant that IS
# the image the old route was showing), so the switch is invisible. A disarm
# or CAMERA flip during the warm frame leaves the flag down and changes
# nothing — the next wake re-schedules through _refresh_output_source.
func _on_mix_warmed() -> void:
	if _mix_warmed or not _mix_should_render():
		return
	_mix_warmed = true
	_refresh_output_source()


# --- Storage: the library and its imports (core/storage.gd, layout 2) ---------
#
# The library is PVJ's own user://clips. IMPORT CLIPS / FOLDER / PACK are jobs
# on the plugin's worker: pick → plan (import_planned) → run → progress → finish.
# Nothing heavy runs here: this side shows the strip, asks only when the plan
# does not fit, and rescans once at the end — keeping both decks on their clips.

## First run: the eight demo clips are already playing, so bringing your own is
## an offer. Any answer (an import, NOT NOW, tap outside) closes it for good.
func _prompt_first_import() -> void:
	var rows := [
		{"text": "IMPORT CLIPS…"},
		{"text": "IMPORT FOLDER…"},
		{"text": "IMPORT PACK (.ZIP)…"},
		{"text": "NOT NOW — KEEP THE DEMO CLIPS"},
	]
	var dlg := M8Dialog.pick(_chrome_layer, "PLAY YOUR OWN CLIPS?", rows, func(i: int) -> void:
		Storage.finish_setup()
		if i < 3:
			_import(["files", "folder", "pack"][i]),
		M8Dialog.M8_GREEN, 1,
		"PVJ comes with eight demo clips. To play your own, pick videos, a folder or a "
		+ "starter pack (.zip): PVJ copies them into its own storage, and your files stay "
		+ "where they are. You can do this later in LIB ▸ SOURCES & LIBRARY.")
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance
	dlg.cancelled.connect(func(): Storage.finish_setup())


## LIB ▸ IMPORT CLIPS / IMPORT FOLDER / IMPORT PACK: the system picker, then a
## plan. Refused while recording: the picker pauses the GL thread that feeds
## the encoder, and a copy would eat the recording's reserve.
func _import(kind: String) -> void:
	_close_panels()
	if not Storage.available():
		_flash_status("IMPORT NEEDS THE ANDROID BUILD")
		return
	if _rec_active:
		_flash_status("STOP REC FIRST")
		return
	if _imp_job != 0 or Storage.import_busy():
		_flash_status("AN IMPORT IS ALREADY RUNNING")
		return
	if Storage.is_legacy():
		_flash_status("COPY YOUR CLIPS FOLDER INTO PVJ FIRST")
		return
	match kind:
		"files": Storage.import_files()
		"folder": Storage.import_folder(false)
		"pack": Storage.import_pack()


func _on_import_planned(job: int, plan: Dictionary) -> void:
	if _imp_job == 0 and _imp_strip != null:
		_imp_strip.visible = false   # COPY's "READING…" line; _run_import shows it again
	if job == 0:
		_flash_status("NOTHING IMPORTED")
		return
	if job < 0:
		_flash_status("AN IMPORT IS ALREADY RUNNING")
		return
	var err := str(plan.get("error", ""))
	if err != "":
		Storage.discard_import(job)
		_flash_status("IMPORT FAILED — %s" % err.to_upper())
		return
	if _rec_active:
		Storage.discard_import(job)
		_flash_status("STOP REC FIRST")
		return
	_imp_copies = int(plan.get("copies", 0)) if not bool(plan.get("streamed", false)) else -1
	_imp_kind = str(plan.get("kind", ""))
	_imp_total = _imp_copies + _count_action(plan, "skip")
	if bool(plan.get("fits", true)):
		_run_import(job, false)
		return
	var free := maxi(0, int(plan.get("free", 0)) - int(plan.get("reserve", 0)))
	var dlg := M8Dialog.confirm(_chrome_layer, "NOT ENOUGH SPACE",
		("NEEDS %s · %s FREE\n\nIMPORT WHAT FITS copies the clips that fit, in order; the "
		+ "rest are listed as NO SPACE. PVJ keeps 512 MB free for recording.")
			% [_fmt_bytes(int(plan.get("bytes", 0))), _fmt_bytes(free)],
		"IMPORT WHAT FITS", func(): _run_import(job, true), M8Dialog.M8_RED)
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance
	dlg.cancelled.connect(func():
		Storage.discard_import(job)
		_flash_status("NOTHING IMPORTED"))


func _run_import(job: int, fit_only: bool) -> void:
	if _rec_active:
		Storage.discard_import(job)
		_flash_status("STOP REC FIRST")
		return
	if not Storage.run_import(job, fit_only):
		_flash_status("IMPORT FAILED TO START")
		return
	_imp_job = job
	_show_import_strip("IMPORTING…", true)


func _on_import_progress(job: int, file_name: String, i: int, n: int, done: int, total: int) -> void:
	if job != _imp_job or _imp_label == null or _imp_cancelling:
		return
	var verb := "COPYING INTO PVJ" if _imp_kind == "mirror" else "IMPORTING"
	var t := ("%s %d/%d · %s" % [verb, i, n, file_name]) if n > 0 else ("%s %d · %s" % [verb, i, file_name])
	if total > 0:
		t += " · %d/%d MB" % [done >> 20, total >> 20]
	elif done > 0:
		t += " · %d MB" % (done >> 20)
	_imp_label.text = t.to_upper()


func _on_import_finished(job: int, res: Dictionary) -> void:
	if job != _imp_job:
		return
	_imp_job = 0
	_imp_cancelling = false
	if _imp_kind == "mirror":
		_on_copy_finished(res)
		return
	var files: Array = res.get("files", [])
	if not files.is_empty():
		_after_import(files)
	var text := _import_summary(res)
	print("[storage] import #%d: %s" % [job, text])
	_show_import_strip(text, false, _import_details(res))


## New clips are in user://clips: rescan both decks without moving them, and
## put the newcomers in the live set when there is one (they used to arrive
## PARKED, which read as "the import did nothing"). Not for a mirror
## (`join_live` false): an old folder coming back meets the live set it was
## curated with, and a clip parked there stays parked.
func _after_import(files: Array, join_live: bool = true) -> void:
	var was_empty := clip_engine.clips.is_empty()
	_rescan_keep_deck()
	if join_live and not clip_engine.live_set.is_empty():
		var live: Array[String] = []
		for p: String in clip_engine.clips:
			if clip_engine.is_live(p):
				live.append(p)
		for r: Variant in files:
			var p := Storage.resolve(clip_engine.clips_dir, str(r))
			if p != "" and not live.has(p):
				live.append(p)
		clip_engine.set_live(live)
		_save_playlist_live()
	if was_empty or clip_engine.player == null:
		clip_engine.play_index(0)
	_update_idle_output()


## Rescan both engines and keep each deck on the clips it is playing and has
## cued (by path — a bare scan() leaves the indices naming other clips), then
## re-apply the saved play order. Every "clips arrived" path ends here.
func _rescan_keep_deck() -> void:
	clip_engine.scan_keeping_deck()
	_load_playlist_order()
	if clip_engine.player != null and clip_engine.cued_index() < 0:
		clip_engine.recue()
	if _clip_engine_b != null:
		_clip_engine_b.scan_keeping_deck()
		if _lane_b_drives() and _clip_engine_b.cued_index() < 0:
			_clip_engine_b.recue()


## "IMPORTED 12 INTO PACK · 3 ALREADY IN PVJ · 1 NOT A VIDEO" — one line for the strip.
func _import_summary(res: Dictionary) -> String:
	var imported := int(res.get("imported", 0))
	var dups := int(res.get("duplicates", 0))
	var failed: Array = res.get("failed", [])
	var folder := str(res.get("folder", ""))
	var stopped := str(res.get("stopped", ""))
	var of_n := (" OF %d" % _imp_copies) if _imp_copies >= 0 else ""
	var parts: PackedStringArray = []
	if bool(res.get("cancelled", false)):
		parts.append("CANCELLED — %d%s IMPORTED" % [imported, of_n])
	elif stopped == "no space":
		parts.append("OUT OF SPACE — %d%s IMPORTED" % [imported, of_n])
	elif stopped != "":
		parts.append("IMPORT STOPPED (%s) — %d IMPORTED" % [stopped.to_upper(), imported])
	elif imported == 0 and dups == 0 and failed.is_empty():
		parts.append("NOTHING IMPORTED")
	else:
		parts.append("IMPORTED %d%s" % [imported, (" INTO " + folder) if folder != "" and imported > 0 else ""])
	if dups > 0:
		parts.append("%d ALREADY IN PVJ" % dups)
	var reasons := {}
	for f: Variant in failed:
		var r := str((f as Dictionary).get("reason", "FAILED"))
		reasons[r] = int(reasons.get(r, 0)) + 1
	for r: String in reasons:
		parts.append("%d %s" % [reasons[r], r])
	var warn: Array = res.get("warnings", [])
	if not warn.is_empty():
		parts.append("%d MAY STUTTER" % warn.size())
	if int(res.get("renamed", 0)) > 0:
		parts.append("%d RENAMED" % int(res.get("renamed", 0)))
	if int(res.get("not_a_clip", 0)) > 0:
		parts.append("%d NOT A CLIP" % int(res.get("not_a_clip", 0)))
	var deep := int(res.get("too_deep", 0))
	if deep > 0:
		parts.append("%d FOLDER%s TOO DEEP" % [deep, "" if deep == 1 else "S"])
	return " · ".join(parts).to_upper()


## The per-file lines DETAILS lists: failures first, then warnings.
func _import_details(res: Dictionary) -> Array:
	var out: Array = []
	for f: Variant in res.get("failed", []):
		out.append("%s — %s" % [str(f.get("name", "")), str(f.get("reason", ""))])
	for w: Variant in res.get("warnings", []):
		out.append("%s — %s" % [str(w.get("name", "")), str(w.get("reason", ""))])
	return out


static func _fmt_bytes(b: int) -> String:
	if b >= (1 << 30):
		return "%.1f GB" % (float(b) / float(1 << 30))
	if b < (1 << 20):
		return "%d KB" % (b >> 10)   # not "0 MB" for the panel's OTHER / a small cache
	return "%d MB" % (b >> 20)


## The import strip: one line under the control bar, over the grid when it is
## open, never modal — the deck stays playable. While a job runs its button
## is CANCEL; afterwards it shows the summary, with DETAILS when files failed.
func _show_import_strip(text: String, running: bool, details: Array = []) -> void:
	if _imp_strip == null:
		_imp_strip = PanelContainer.new()
		_imp_strip.name = "ImportStrip"
		_imp_strip.anchor_left = 0.0
		_imp_strip.anchor_right = 1.0
		_imp_strip.offset_left = 40.0
		_imp_strip.offset_right = -40.0
		_imp_strip.offset_top = 130.0
		_imp_strip.offset_bottom = 196.0
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0.92)
		sb.border_color = M8_GREEN
		sb.set_border_width_all(2)
		sb.content_margin_left = 16.0
		sb.content_margin_right = 8.0
		_imp_strip.add_theme_stylebox_override("panel", sb)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		_imp_strip.add_child(row)
		_imp_label = Label.new()
		_imp_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_imp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_imp_label.clip_text = true
		_imp_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_imp_label.add_theme_font_size_override("font_size", 20)
		_imp_label.add_theme_color_override("font_color", M8_TEXT)
		row.add_child(_imp_label)
		_imp_btn = Button.new()
		_imp_btn.custom_minimum_size = Vector2(150, 56)
		_imp_btn.focus_mode = Control.FOCUS_NONE
		_imp_btn.add_theme_font_size_override("font_size", 20)
		_imp_btn.pressed.connect(_on_import_strip_button)
		row.add_child(_imp_btn)
		_imp_strip.theme = _theme
		_chrome_layer.add_child(_imp_strip)
	_imp_running = running
	_imp_details = details
	_imp_label.text = text
	_imp_btn.text = "CANCEL" if running else ("DETAILS" if not details.is_empty() else "OK")
	_imp_strip.visible = true
	_chrome_layer.move_child(_imp_strip, -1)   # over the clip grid when it is open
	_imp_token += 1
	if not running:
		var token := _imp_token
		# With DETAILS to read, the line waits longer (the button is the way in).
		await get_tree().create_timer(30.0 if not details.is_empty() else 6.0).timeout
		if token == _imp_token and _imp_strip != null:
			_imp_strip.visible = false


func _on_import_strip_button() -> void:
	if _imp_running:
		if not _imp_cancelling:
			_imp_cancelling = true
			Storage.cancel_import()
			_imp_label.text = "CANCELLING…"
		return
	_imp_strip.visible = false
	if _imp_details.is_empty():
		return
	var rows: Array = []
	for line: String in _imp_details.slice(0, 12):
		rows.append({"text": line})
	if _imp_details.size() > 12:
		rows.append({"text": "… AND %d MORE (SEE THE LOG)" % (_imp_details.size() - 12), "enabled": false})
	var dlg := M8Dialog.pick(_chrome_layer, "IMPORT — DETAILS", rows, Callable(), M8Dialog.M8_GREEN, 1)
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


func _count_action(plan: Dictionary, action: String) -> int:
	var n := 0
	for it: Variant in plan.get("items", []):
		if str((it as Dictionary).get("action", "")) == action:
			n += 1
	return n


# --- Migration from a linked folder (STORAGE_REWORK_PLAN §E) -------------------
#
# LEGACY: a beta1/beta2 tester's linked folder still plays and curates. COPY
# CLIPS INTO PVJ mirrors it into user://clips (same layout → every clip id,
# slot, mask and thumbnail stays valid) while the deck keeps playing; the
# library switches at the NEXT START, never live — decks, masks and thumbnails
# hold the folder's paths, and a live switch would cut the set.
# UNREACHABLE: the old folder is gone; RE-IMPORT OLD CLIPS FOLDER mirrors it
# back from wherever it is now, and the kept curation finds its clips.

## After the splash, once: the copy offer for a linked folder.
func _offer_copy_into_pvj() -> void:
	Storage.mark_copy_offered()
	var s := Storage.legacy_summary()
	var dlg := M8Dialog.confirm(_chrome_layer, "PVJ NOW KEEPS ITS OWN COPY OF YOUR CLIPS",
		("Copy %d clips (%s) from %s into PVJ? Sequences, masks and settings stay as they are, "
		+ "and your files in %s are not changed. The deck keeps playing while it copies.\n\n"
		+ "LATER: PVJ plays from the folder as before — LIB ▸ SOURCES & LIBRARY ▸ COPY CLIPS INTO PVJ.")
			% [int(s.n), _fmt_bytes(int(s.bytes)), Storage.folder_label(), Storage.folder_label()],
		"COPY CLIPS", func(): _copy_into_pvj(), M8Dialog.M8_GREEN, "LATER")
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


func _copy_into_pvj() -> void:
	_close_panels()
	if Storage.switch_pending():
		_ask_restart("Your clips are already copied into PVJ. PVJ plays its own copy from the next start.")
		return
	if _rec_active:
		_flash_status("STOP REC FIRST")
		return
	if _imp_job != 0 or Storage.import_busy():
		_flash_status("AN IMPORT IS ALREADY RUNNING")
		return
	if not Storage.copy_into_pvj():
		_flash_status("NO CLIPS FOLDER TO COPY")
		return
	_show_import_strip("READING %s…" % Storage.folder_label().to_upper(), true)


## After the splash, once: the old folder could not be reached.
func _notice_old_folder() -> void:
	var label := Storage.old_folder_notice()
	Storage.clear_old_folder_notice()
	var dlg := M8Dialog.confirm(_chrome_layer, "YOUR CLIPS FOLDER CAN'T BE REACHED",
		("Your clips folder '%s' can't be reached any more. PVJ now keeps its own copy of "
		+ "your clips: re-import that folder and your sequences, masks and settings find "
		+ "their clips again — nothing of them was deleted.\n\nLater: LIB ▸ SOURCES & LIBRARY "
		+ "▸ RE-IMPORT OLD CLIPS FOLDER.") % label,
		"RE-IMPORT FOLDER", func(): _reimport_old_folder(), M8Dialog.M8_GREEN, "LATER")
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


## The old folder, picked again and mirrored (keep its layout → the same ids).
func _reimport_old_folder() -> void:
	_close_panels()
	if _rec_active:
		_flash_status("STOP REC FIRST")
		return
	if _imp_job != 0 or Storage.import_busy():
		_flash_status("AN IMPORT IS ALREADY RUNNING")
		return
	if not Storage.import_folder(true):
		_flash_status("IMPORT NEEDS THE ANDROID BUILD")


## A mirror finished: the legacy copy, or the re-import of an old folder. Only a
## complete one counts (a file that is not a video was never playable anyway);
## anything short of that stays as it was and says what is missing — RETRY is
## cheap, because finished files are skipped.
func _on_copy_finished(res: Dictionary) -> void:
	var blocking := 0
	for f: Variant in res.get("failed", []):
		if not str((f as Dictionary).get("reason", "")) in ["NOT A VIDEO", "UNSUPPORTED TYPE"]:
			blocking += 1
	var done := int(res.get("imported", 0)) + int(res.get("duplicates", 0))
	var ok := blocking == 0 and not bool(res.get("cancelled", false)) and str(res.get("stopped", "")) == ""
	print("[storage] copy into PVJ: %d of %d present, %d failed%s" % [done, _imp_total, blocking,
		"" if ok else " — NOT switching"])
	var legacy := Storage.is_legacy()
	for r: Variant in res.get("displaced", []):
		Storage.drop_thumbnail(str(r))   # the name now belongs to the folder's clip
	if not legacy:
		var files: Array = res.get("files", [])
		if not files.is_empty():
			_after_import(files, false)
	if not ok:
		_show_import_strip(_import_summary(res), false, _import_details(res))
		var dlg := M8Dialog.confirm(_chrome_layer, "COPIED %d OF %d — %s" % [done, _imp_total,
				"CANCELLED" if bool(res.get("cancelled", false)) else "%d FAILED" % blocking],
			("Nothing has changed: PVJ keeps playing %s. RETRY copies the rest — the clips "
			+ "already copied are skipped.") % ("from the folder" if legacy else "what it has"),
			"RETRY", func(): _copy_into_pvj() if legacy else _reimport_old_folder(), M8Dialog.M8_RED, "LATER")
		dlg.theme = _theme   # CanvasLayer breaks theme inheritance
		return
	_imp_strip.visible = false
	if legacy:
		Storage.mark_switch_pending()
		_ask_restart("DONE — %d clips are in PVJ. PVJ plays its own copy from the next start; "
			% done + "until then the deck keeps playing from the folder.")
	else:
		Storage.old_folder_restored()
		_ask_restart("DONE — %d clips are back in PVJ. Masks and sequences pick them up at the next start." % done)


## RESTART NOW (Godot's restart: ProcessPhoenix in godot-lib) or LATER.
func _ask_restart(body: String, title: String = "COPIED INTO PVJ") -> void:
	var dlg := M8Dialog.confirm(_chrome_layer, title, body + "\n\nRESTART NOW stops the deck.",
		"RESTART NOW", func() -> void:
			_save_settings()
			print("[storage] restart for the new library")
			OS.set_restart_on_exit(true)
			get_tree().quit(),
		M8Dialog.M8_GREEN, "LATER")
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


# --- LIB ▸ Storage… (STORAGE_REWORK_PLAN §F) -----------------------------------

## Asks the plugin to measure (off the main thread); the panel opens on the answer.
func _open_storage_panel() -> void:
	_close_panels()
	_storage_panel_wanted = true
	Storage.request_report()


func _on_storage_report(r: Dictionary) -> void:
	if not _storage_panel_wanted:
		return
	_storage_panel_wanted = false
	if r.has("error"):
		_flash_status("STORAGE: %s" % str(r.error).to_upper())
		return
	var rows: Array = []
	var acts: Array[Callable] = []
	var clips_n := int(r.get("top_n", 0))
	var clips_b := int(r.get("top_bytes", 0))
	for f: Variant in r.get("folders", []):
		clips_n += int(f.get("n", 0))
		clips_b += int(f.get("bytes", 0))
	var cache_b := int(r.get("cache_total", 0))
	# CLEAR TEMPORARY FILES empties the cache dir except a legacy folder's play
	# copies (Storage.clear_temporary), so that is what it says it frees.
	var clear_b := cache_b - (int(r.get("cache_clips", 0)) if Storage.is_legacy() else 0)
	# OTHER: the rest of app storage — settings, sequences, masks, Godot's shader
	# cache. In a legacy folder's mode the clips are not in app storage at all.
	var own_clips_b := 0 if Storage.is_legacy() else clips_b
	var other_b := maxi(0, int(r.get("files_total", 0)) - own_clips_b)
	if Storage.is_legacy():
		var s := Storage.legacy_summary()
		rows.append({"text": "FOLDER %s · %d CLIPS · %s — NOT COPIED YET" % [Storage.folder_label().to_upper(),
			int(s.n), _fmt_bytes(int(s.bytes))], "enabled": false})
		acts.append(Callable())
		rows.append({"text": "COPY CLIPS INTO PVJ…"})
		acts.append(func(): _copy_into_pvj())
	else:
		rows.append({"text": "TOP LEVEL · %s · %s" % [_n_clips(int(r.get("top_n", 0))), _fmt_bytes(int(r.get("top_bytes", 0)))],
			"enabled": false})
		acts.append(Callable())
		for f: Variant in r.get("folders", []):
			var name := str(f.get("name", ""))
			var n := int(f.get("n", 0))
			var b := int(f.get("bytes", 0))
			rows.append({"text": "%s · %s · %s · REMOVE" % [name.to_upper(), _n_clips(n), _fmt_bytes(b)]})
			acts.append(func(): _confirm_remove_folder(name, n, b))
	rows.append({"text": "CLEAR TEMPORARY FILES · %s" % _fmt_bytes(clear_b)})
	acts.append(func(): _confirm_clear_temporary())
	rows.append({"text": "SAVE SETUP…"})
	acts.append(func(): _save_setup())
	rows.append({"text": "RESTORE SETUP…"})
	acts.append(func(): _restore_setup())
	var free := int(r.get("free", -1))
	var body := "CLIPS %s · %d · CACHE %s · OTHER %s · PHONE FREE %s" % [_fmt_bytes(clips_b), clips_n,
		_fmt_bytes(cache_b), _fmt_bytes(other_b), _fmt_bytes(free) if free >= 0 else "?"]
	var dlg := M8Dialog.pick(_chrome_layer, "STORAGE", rows, func(i: int) -> void:
		if i >= 0 and i < acts.size() and acts[i].is_valid():
			acts[i].call(),
		M8Dialog.M8_GREEN, 1, body)
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


static func _n_clips(n: int) -> String:
	return "%d CLIP%s" % [n, "" if n == 1 else "S"]


## The paths of the clips in library folder `folder` (the last scan).
func _clips_in_folder(folder: String) -> Array[String]:
	var out: Array[String] = []
	for p: String in clip_engine.clips:
		if Storage.folder_of(p) == folder:
			out.append(p)
	return out


func _confirm_remove_folder(folder: String, n: int, bytes: int) -> void:
	var paths := _clips_in_folder(folder)
	for p: String in paths:
		if clip_engine.current_index >= 0 and clip_engine.current_index < clip_engine.clips.size() \
				and clip_engine.clips[clip_engine.current_index] == p:
			_flash_status("CAN'T REMOVE — IT'S PLAYING")   # the status line holds ~30 characters
			return
		if _clip_engine_b != null and _clip_engine_b.current_index >= 0 \
				and _clip_engine_b.current_index < _clip_engine_b.clips.size() \
				and _clip_engine_b.clips[_clip_engine_b.current_index] == p:
			_flash_status("CAN'T REMOVE — ON DECK B")
			return
	if paths.size() >= clip_engine.clips.size():
		_flash_status("AT LEAST ONE CLIP MUST REMAIN")
		return
	var dlg := M8Dialog.confirm(_chrome_layer, "REMOVE %s" % folder.to_upper(),
		("Remove the folder %s from PVJ? Its %d clips (%s) are deleted from PVJ; the files you "
		+ "imported them from are not touched. Sequences drop them; saved slots keep their names.")
			% [folder, n, _fmt_bytes(bytes)],
		"REMOVE", func() -> void: _remove_folder(folder), M8Dialog.M8_RED)
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


## Folder REMOVE: the files, their thumbnails, their ids in BOTH lanes, the
## play order and live set — the same repairs as a clip REMOVE, done once.
func _remove_folder(folder: String) -> void:
	var paths := _clips_in_folder(folder)
	var ids := {}
	var keys := PackedStringArray()
	for p: String in paths:
		var id := ClipLibrary.id_for_path(p)
		ids[id] = true
		keys.append(Storage.rel(p))
		var cd := ClipLibrary.get_clip(id)
		if cd != null and cd.thumb_cache_path != "":
			DirAccess.remove_absolute(ProjectSettings.globalize_path(cd.thumb_cache_path))
	if not Storage.delete_folder(folder):
		_flash_status("REMOVE FAILED — %s" % folder.to_upper())
		return
	_rescan_keep_deck()
	if not clip_engine.live_set.is_empty():
		var live: Array[String] = []
		for p: String in clip_engine.clips:
			if clip_engine.is_live(p):
				live.append(p)
		# All-live is the EMPTY set (see _remove_clip_file); the last live clips gone → all live.
		if live.size() == clip_engine.clips.size() or live.is_empty():
			clip_engine.set_live([])
		else:
			clip_engine.set_live(live)
	_ensure_lane_b_model()
	for lane: SeqLane in [_lane_a, _lane_b]:
		for i: int in range(lane.sequence.size() - 1, -1, -1):
			if ids.has(lane.sequence.get_id(i)):
				_remove_seq_slot(i, lane)
	ClipLibrary.rebuild()   # (_rescan_keep_deck re-warmed a cue that was in the folder)
	_save_playlist_order(keys)
	_save_playlist_live(keys)
	_flash_status("REMOVED %s — %d CLIPS" % [folder.to_upper(), paths.size()])


## SAVE SETUP…: sequences, slots, masks, warp, calibration and settings into one
## zip (no clips) — what survives an uninstall (§E2).
func _save_setup() -> void:
	_save_settings()   # the zip carries what is on screen now
	if not Storage.save_setup():
		_flash_status("SETUP NEEDS THE ANDROID BUILD")


## RESTORE SETUP…: on a fresh library, bring the clips back first — sequences and
## masks find their clips by where they sat in the folder. Either order works:
## the guards keep every key until the clips are there.
func _restore_setup() -> void:
	if _rec_active:
		_flash_status("STOP REC FIRST")
		return
	if Storage.library_is_demo_only():
		var dlg := M8Dialog.confirm(_chrome_layer, "RESTORE SETUP",
			("PVJ has no clips of yours yet. Re-import your old clips folder first? Sequences and "
			+ "masks find their clips by where they sat in that folder.\n\nRESTORE NOW works too: "
			+ "everything is kept until the clips come back."),
			"RE-IMPORT FOLDER", func(): _reimport_old_folder(), M8Dialog.M8_GREEN, "RESTORE NOW")
		dlg.theme = _theme   # CanvasLayer breaks theme inheritance
		dlg.cancelled.connect(func(): _pick_setup_zip())
		return
	_pick_setup_zip()


func _pick_setup_zip() -> void:
	var dlg := M8Dialog.confirm(_chrome_layer, "RESTORE SETUP",
		("Replace this phone's sequences, slots, masks, warp, calibration and settings with the "
		+ "ones in a PVJ setup zip? Your clips are not touched. PVJ restarts to use it."),
		"PICK THE ZIP", func(): Storage.restore_setup(), M8Dialog.M8_RED)
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


func _on_setup_done(kind: String, status: String) -> void:
	if status == "cancelled":
		_flash_status("NOTHING SAVED" if kind == "save" else "NOTHING RESTORED")
		return
	if status.begins_with("error:"):
		_flash_status("%s FAILED — %s" % ["SAVE SETUP" if kind == "save" else "RESTORE",
			status.substr(6).to_upper()])
		return
	var n := status.substr(3).to_int()
	if kind == "save":
		_flash_status("SETUP SAVED — %d FILES" % n)
		return
	_ask_restart("SETUP READ — %d files. It takes over when PVJ starts again." % n, "RESTORE SETUP")


func _confirm_clear_temporary() -> void:
	var dlg := M8Dialog.confirm(_chrome_layer, "CLEAR TEMPORARY FILES",
		"Delete thumbnails, temporary copies and leftovers? Thumbnails are made again when needed; "
		+ "your clips, sequences, masks and settings are not touched.", "CLEAR", func() -> void:
			var n := Storage.clear_temporary()
			ThumbnailService.request_all()   # regenerated in the background
			_flash_status("TEMPORARY FILES CLEARED — %d FILES" % n),
		M8Dialog.M8_RED)
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


## LIB ▸ LOAD DEMO CLIPS, and the empty grid's button: the eight clips that
## ship in the build, into the library. Idempotent (by name).
func _load_demo_clips() -> void:
	_close_panels()
	if Storage.is_legacy():
		_flash_status("COPY YOUR CLIPS FOLDER INTO PVJ FIRST")
		return
	_flash_status("LOADING DEMO CLIPS…")
	Storage.load_demo_clips()


func _on_demo_clips_done(copied: int, skipped: int) -> void:
	if copied > 0:
		var was_empty := clip_engine.clips.is_empty()
		_rescan_keep_deck()
		if was_empty or clip_engine.player == null:
			clip_engine.play_index(0)
		_update_idle_output()
	if copied == 0 and skipped == 0:
		_flash_status("NO DEMO CLIPS IN THIS BUILD")
	elif copied == 0:
		_flash_status("DEMO CLIPS ALREADY IN PVJ (%d)" % skipped)
	else:
		_flash_status("DEMO CLIPS — %d ADDED TO PVJ" % copied)


## LIB ▸ GET MORE CLIPS: the starter packs on c-u.studio, in the system
## browser. An ACTION_VIEW intent — the app itself needs no INTERNET permission.
func _open_more_clips() -> void:
	_close_panels()
	_flash_status("OPENING C-U.STUDIO/TOOLS/PVJ…")
	OS.shell_open(MORE_CLIPS_URL)


# --- Idle screen (beta2 §2.3) ---------------------------------------------

## The idle screen is wanted when: it is on, an external display plugin
## exists, and the deck has nothing to play. Starts or stops the loop and, in
## DUAL·TEX, re-points the bridge at the right viewport. Cheap when nothing
## changed, so every "clips may have changed" path calls it.
func _update_idle_output() -> void:
	var want := _idle_enabled and _hdmi != null and clip_engine.clips.is_empty() \
			and _display_mode == DisplayMode.DUAL
	if want == _idle_active:
		return
	_idle_active = want
	if want:
		if not _ensure_idle_world():
			_idle_active = false
			return
		_idle_world.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		if _idle_player.is_open():
			_idle_player.play()
		print("[hdmi] idle screen ON (no clip loaded)")
	elif _idle_world != null:
		_idle_player.pause()
		_idle_world.render_target_update_mode = SubViewport.UPDATE_DISABLED
		print("[hdmi] idle screen OFF")
	if _tex_output_active:
		_refresh_output_texture(true)
	elif _hdmi_enabled:
		_push_clip_to_hdmi(clip_engine.current_index)


## The idle viewport, built on first use: a 720p SubViewport with the ident
## loop in a GoZen player (muted, looping). Only the bridge reads its
## texture. False without the clip file.
func _ensure_idle_world() -> bool:
	if _idle_world != null:
		return true
	var path := Storage.idle_clip_path()
	if path == "":
		return false
	_idle_world = SubViewport.new()
	_idle_world.name = "IdleWorld"
	_idle_world.size = IDLE_SIZE
	_idle_world.disable_3d = true
	_idle_world.transparent_bg = false
	_idle_world.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_idle_world)
	_idle_player = VideoPlayback.new()
	_idle_player.enable_audio = false
	_idle_player.loop = true
	_idle_player.enable_auto_play = true
	_idle_player.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_idle_player.size = Vector2(IDLE_SIZE)
	_idle_world.add_child(_idle_player)
	_idle_player.set_video_path(path)
	return true


func _on_mask_image_picked(path: String) -> void:
	if path != "":
		_on_mask_image_selected(path)
		return
	if _mask_overlay.mask_path == "":
		return
	var dlg := M8Dialog.confirm(_chrome_layer, "MASK IMAGE",
		"No new image chosen. Clear the current mask image (%s)?" % _mask_overlay.mask_path.get_file(),
		"CLEAR", func(): _on_mask_image_selected(""))
	dlg.theme = _theme


func _rescan() -> void:
	_rescan_keep_deck()   # keeps both decks on their clips and re-applies the saved order
	var n := clip_engine.clips.size()
	# If clips appeared (was empty) or the current index is now stale, (re)start.
	if n > 0 and (clip_engine.player == null or clip_engine.current_index >= n):
		clip_engine.play_index(0)
	_update_idle_output()
	_flash_status("RESCANNED — %d CLIP(S)" % n)


# --- Clip browser (laptop clip server / Google Drive) --------------------

# Lazily build the browser overlay (scenes/ClipBrowser.tscn → clip_browser_ui.gd)
# and toggle it. Its load_clip_requested downloads the clip into the local clips
# folder, then ClipEngine plays it.
func _toggle_clip_browser() -> void:
	if _clip_browser == null:
		_clip_browser = (load("res://scenes/ClipBrowser.tscn") as PackedScene).instantiate() as Control
		_clip_browser.visible = false   # start hidden so the first toggle shows it
		_clip_browser.theme = _theme          # CanvasLayer breaks theme inheritance
		_chrome_layer.add_child(_clip_browser)
		# load_clip_requested lives on the instanced script, not on Control —
		# connect by name so static typing doesn't reject it.
		_clip_browser.connect("load_clip_requested", _on_clip_load_requested)
		var close_btn := _clip_browser.get_node_or_null("VBox/Toolbar/CloseBtn") as Button
		if close_btn != null:
			close_btn.pressed.connect(func(): _clip_browser.visible = false)
	_clip_browser.visible = not _clip_browser.visible
	if _clip_browser.visible:
		_params_panel.visible = false
		_chrome_layer.move_child(_clip_browser, -1)   # raise to top of the UI layer


# Lazily build + toggle the Google Drive folder browser. Its script self-wires its
# Close button and drives DriveAuth/DriveClient; downloads land in clips_dir and are
# picked up via _on_drive_download_done.
func _toggle_drive_browser() -> void:
	if _drive_browser == null:
		_drive_browser = (load("res://scenes/DriveBrowser.tscn") as PackedScene).instantiate() as Control
		_drive_browser.visible = false
		_drive_browser.theme = _theme          # CanvasLayer breaks theme inheritance
		_chrome_layer.add_child(_drive_browser)
	_drive_browser.visible = not _drive_browser.visible
	if _drive_browser.visible:
		_params_panel.visible = false
		_chrome_layer.move_child(_drive_browser, -1)


# Lazily build + toggle the LOCAL device-file browser (DCIM/Movies/Downloads).
# Reuses the Drive-browser interaction; its clip_imported lands a copied clip in
# clips_dir and we pick it up via _on_local_clip_imported (same as a Drive add).
func _toggle_local_browser() -> void:
	if _local_browser == null:
		_local_browser = preload("res://scenes/LocalBrowser.tscn").instantiate() as Control
		_local_browser.visible = false
		_local_browser.set("dest_dir", clip_engine.clips_dir)   # set before _ready
		_local_browser.theme = _theme          # CanvasLayer breaks theme inheritance
		_chrome_layer.add_child(_local_browser)
		_local_browser.connect("clip_imported", _on_local_clip_imported)
	_local_browser.visible = not _local_browser.visible
	if _local_browser.visible:
		_params_panel.visible = false
		_chrome_layer.move_child(_local_browser, -1)


# --- Recordings browser (watch a set back on the phone) ---------------------
#
# The SAME LocalBrowser scene, rooted at REC_DIR: set_<timestamp>/ folders are
# the top level and partNN.mp4 the leaves, so the existing folder navigation is
# the set→part browse. select_only is what makes it READ-ONLY — that mode was
# built for the mask picker and already means "emit the path, never import", so
# nothing here can put a recording into clips_dir, the deck, or the output.
func _toggle_rec_browser() -> void:
	if _rec_browser == null:
		_rec_browser = preload("res://scenes/LocalBrowser.tscn").instantiate() as Control
		_rec_browser.visible = false
		# All of these must be set BEFORE add_child: _ready() calls _open_root(),
		# which reads root_dir (the same "set before _ready" rule the mask
		# picker's comment records).
		_rec_browser.set("root_dir", _rec_dir)
		_rec_browser.set("root_label", "RECORDINGS")
		_rec_browser.set("select_only", true)
		_rec_browser.set("exts", PackedStringArray(["mp4"]))
		_rec_browser.set("show_share", true)
		_rec_browser.set("summarize_folders", true)
		_rec_browser.theme = _theme            # CanvasLayer breaks theme inheritance
		_chrome_layer.add_child(_rec_browser)
		_rec_browser.connect("file_selected", _on_recording_open)
		_rec_browser.connect("file_share_requested", _on_recording_share)
		# PVJ lists only the files it wrote itself: after a reinstall Android hides
		# the older ones from it (no media permission) — they are still there.
		var foot := Label.new()
		foot.text = ("RECORDINGS FROM BEFORE A REINSTALL ARE STILL IN MOVIES/%s — "
			+ "OPEN THEM IN PHOTOS OR FILES.") % _rec_dir.get_file().to_upper()
		foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		foot.add_theme_font_size_override("font_size", 16)
		foot.add_theme_color_override("font_color", M8_LABEL)
		var vbox := _rec_browser.get_node_or_null("VBox") as VBoxContainer
		if vbox != null:
			vbox.add_child(foot)
	_rec_browser.visible = not _rec_browser.visible
	if _rec_browser.visible:
		_params_panel.visible = false
		_chrome_layer.move_child(_rec_browser, -1)


func _on_recording_open(path: String) -> void:
	if path == "":
		return
	_report_recording(_hdmi.openRecording(path) if _hdmi != null else "no-plugin",
		path, "OPENING")


func _on_recording_share(path: String) -> void:
	_report_recording(_hdmi.shareRecording(path) if _hdmi != null else "no-plugin",
		path, "SHARING")


# Kotlin answers with a token rather than throwing, so every outcome has to be
# turned into something the user can act on — silently doing nothing when a tap
# fails is the worst version of this.
func _report_recording(result: Variant, path: String, verb: String) -> void:
	var res := str(result)
	var msg := ""
	match res:
		"ok":
			msg = "%s %s" % [verb, path.get_file()]
		"busy-recording":
			msg = "STOP RECORDING FIRST — PLAYBACK WOULD INTERRUPT IT"
		"no-player":
			msg = "NO APP ON THIS PHONE CAN PLAY IT"
		"missing-file":
			msg = "FILE IS GONE — REFRESH"
		"not-shareable":
			msg = "CANNOT SHARE FROM THAT FOLDER"
		"no-plugin":
			msg = "RECORDING PLAYBACK NEEDS THE ANDROID BUILD"
		_:
			msg = "FAILED: %s" % res.to_upper()
	print("[rec] %s %s -> %s" % [verb, path, res])
	_flash_status(msg)
	if _rec_browser != null:
		_rec_browser.call("set_status", msg)


# Lazily build + toggle the ClipGrid (the visual browser, Step 3). Follows the
# same overlay pattern as the playlist: set .theme (a CanvasLayer breaks theme
# inheritance to the first Control level), add to ui_layer, hand it the deck.
func _toggle_clip_grid() -> void:
	if _clip_grid == null:
		_build_sequencer()
	_clip_grid.visible = not _clip_grid.visible
	if _clip_grid.visible:
		_close_panels()
		_chrome_layer.move_child(_clip_grid, -1)
		_clip_grid.on_shown()
		# Both sequences and both decks can have moved while the grid was closed,
		# and it holds no model of its own — hand it the current picture.
		_push_grid_decks()


# Build the sequencer overlay: the ClipGrid plus its FolderTabBar (step 4). The
# tab bar emits intent (folder_selected) which we wire to ClipGrid.set_folder —
# no widget touches another widget or the engine directly (Architecture §4).
func _build_sequencer() -> void:
	_clip_grid = ClipGrid.new()
	_clip_grid.visible = false
	_clip_grid.theme = _theme
	_chrome_layer.add_child(_clip_grid)
	_clip_grid.setup(clip_engine, _font_label)

	# NOTE: add each widget to the tree (its _ready builds the child nodes) BEFORE
	# calling setup(), which touches those nodes — setup-before-add would hit nulls.
	_folder_tabs = FolderTabBar.new()
	_clip_grid.mount_header_center(_folder_tabs)   # add_child -> _ready builds _row
	_folder_tabs.setup(_font_label)                # now the buttons exist
	_folder_tabs.set_active(_clip_grid.current_folder())
	_folder_tabs.folder_selected.connect(_clip_grid.set_folder)
	# The empty grid's three buttons (beta2 §2.3) — the LIB rows' actions.
	_clip_grid.empty_action.connect(func(a: String):
		if a == "demo":
			_load_demo_clips()
		elif a == "pack":
			_import("pack")
		elif a == "more":
			_open_more_clips())

	# The bottom slot row renders the Sequence model (Step 5). Grid intent (tap =
	# activate, long-press = grab) and strip intent (tap = jump) both land on
	# pipeline handlers below — no widget calls the engine directly.
	_seq_strip = SequenceStrip.new()
	_clip_grid.add_child(_seq_strip)   # child of the grid → shows/hides + moves with it, draws on top
	_seq_strip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_seq_strip.offset_top = -SequenceStrip.STRIP_H
	_seq_strip.offset_bottom = 0.0
	_seq_strip.setup(_lane_a.sequence, _font_label)
	_clip_grid.set_bottom_inset(SequenceStrip.STRIP_H)
	# Help cards. The grid and the strip have holds of their own (queue, reorder),
	# so their cards are HELP MODE only ("area"); the strip's buttons take a hold.
	_help_register(_clip_grid, "CLIP GRID", "area")
	_help_register(_seq_strip, "SEQUENCER", "area")
	for hb: Array in _seq_strip.help_buttons():
		_help_register(hb[0], "SEQUENCER/%s" % hb[1])
	_clip_grid.press_gate = func() -> bool: return _help_swallow
	_seq_strip.press_gate = func() -> bool: return _help_swallow

	_clip_grid.clip_activated.connect(_on_grid_clip_activated)
	_clip_grid.clip_park_toggled.connect(_on_grid_park_toggled)
	_clip_grid.clip_reorder_requested.connect(_on_grid_reorder)
	_clip_grid.clip_remove_requested.connect(_on_grid_remove_requested)
	_clip_grid.clip_grab_started.connect(_on_grid_grab_started)
	_clip_grid.clip_grab_moved.connect(_on_grid_grab_moved)
	_clip_grid.clip_grab_ended.connect(_on_grid_grab_ended)
	_seq_strip.slot_selected.connect(_on_seq_slot_selected)
	_seq_strip.reorder_requested.connect(_on_seq_reorder_requested)
	_seq_strip.auto_advance_toggled.connect(_on_seq_auto_toggled)
	_seq_strip.shuffle_pressed.connect(_on_seq_shuffle)
	_seq_strip.beats_per_slot_changed.connect(_on_seq_bps_changed)
	_seq_strip.save_slot_pressed.connect(_on_seq_save_slot)
	_seq_strip.load_menu_requested.connect(_on_seq_load_menu)
	_seq_strip.clear_slot_pressed.connect(_on_seq_clear_slot)
	_seq_strip.clear_pressed.connect(_on_seq_clear)
	_seq_strip.lane_selected.connect(_on_strip_lane_selected)
	# PUSH the (restored) BPS into the strip — the old pull from the widget's
	# default is what kept beats_per_slot resetting every launch (R6 debt).
	_seq_strip.set_beats_per_slot(_lane_a.beats_per_slot)
	_seq_strip.set_auto(_lane_a.auto)
	_push_lane_b_badge()     # restored lane_b_source lands on the B chip
	_refresh_slot_labels()   # show what's stored in each numbered slot
	# SEQ2 deck colour: the grid wears the armed lane's hue and carries the A/B
	# membership badges, and its DECK filter is the on-demand "split".
	_clip_grid.deck_filter_changed.connect(_on_grid_deck_filter)
	_clip_grid.set_armed_lane(_strip_lane)
	_push_grid_decks()


## Strip A|B chip: swap the strip's model + every chip state to the other lane.
## The hidden lane keeps running — only the view changes.
func _on_strip_lane_selected(lane: int) -> void:
	_strip_lane = lane
	if lane == 1:
		_ensure_lane_b_model()
	var L := _lane_for_strip()
	_seq_strip.set_model(L.sequence)
	_seq_strip.set_active(L.index)
	_seq_strip.set_beats_per_slot(L.beats_per_slot)
	_seq_strip.set_auto(L.auto)
	_seq_strip.set_playhead(0.0)
	# The grid follows the same lane: green for A, amber for B, across the title,
	# the drop target and an optimistic tap. One dim word used to carry this.
	if _clip_grid != null:
		_clip_grid.set_armed_lane(lane)
		_push_grid_decks()


## Push both lanes into the grid: which clips each SEQUENCE owns (the A/B
## badges, and what the DECK filter narrows to) and which clip each DECK is
## playing (the two rings). The grid holds no model — it renders what it is
## handed — so this is the one place the two are kept in step.
func _push_grid_decks() -> void:
	if _clip_grid == null:
		return
	_clip_grid.set_membership(_lane_a.sequence.to_array(), _lane_b.sequence.to_array())
	_clip_grid.set_deck_active(0, _current_clip_id(clip_engine))
	_clip_grid.set_deck_active(1, _current_clip_id(_clip_engine_b))


## The ClipLibrary id an engine is playing, or "" when it has none. Engine B is
## absent until lane B is first armed, which reads as "no ring", not an error.
func _current_clip_id(e: ClipEngine) -> String:
	if e == null or e.current_index < 0 or e.current_index >= e.clips.size():
		return ""
	return ClipLibrary.id_for_path(e.clips[e.current_index])


## The grid's DECK filter moved. The grid re-filters itself; pipeline only says
## so out loud, since the open grid covers the status bar.
func _on_grid_deck_filter(mode: int) -> void:
	_grid_flash(["DECK: ALL", "DECK: A ONLY", "DECK: B ONLY"][mode])


# Resolve a ClipLibrary id to the engine's clip index, or -1 if it no longer names a
# present clip. THE one resolver: the cue-target provider (_seq_next_engine_index)
# and the jump below must agree exactly, or the back decoder warms a different clip
# from the one the cut asks for and jump() misses its warm path.
func _engine_index_for_clip_id(id: String, engine: ClipEngine = null) -> int:
	# Both engines scan the same folder, so ClipLibrary's id→path mapping holds
	# for either — but each engine has its OWN clips order (hazard §4.7): always
	# resolve against the engine that will jump.
	var e := engine if engine != null else clip_engine
	return e.clips.find(ClipLibrary.path_for(id))


# Resolve a ClipLibrary id to the engine's clip index and jump the deck (the
# warm-aware manual path). The one place widget intent reaches the engine.
#
# No swap() of our own here: clip_engine.jump() already opens with
# `if idx == _cued_index and _cue_ready: swap()`, so once _apply_cue_target warms
# the sequence's next clip this call IS the warm pointer flip. Re-implementing that
# check here would just give it a second place to drift out of sync.
func _jump_to_clip_id(id: String) -> void:
	var ci := _engine_index_for_clip_id(id)
	if ci >= 0:
		clip_engine.jump(ci)


# Grid tap: play immediately on the SELECTED lane's deck (SEQ2 §3.6 — the grid
# arms per-lane). Playing off-sequence leaves the strip's active slot where it
# was — the sequence position is independent of ad-hoc grid plays.
func _on_grid_clip_activated(id: String) -> void:
	if _strip_lane == 1:
		# _grid_flash, not _flash_status: the open grid covers the status bar.
		if _clip_engine_b == null or not _lane_b_armed:
			_grid_flash("LANE B NOT ARMED")
			return
		if _lane_b_source != LaneBSource.CLIP:
			_grid_flash("LANE B IS %s — SET B SRC: CLIPS" % LANE_B_SOURCE_NAMES[_lane_b_source])
			return
		var ci := _engine_index_for_clip_id(id, _clip_engine_b)
		if ci >= 0:
			_clip_engine_b.jump(ci)
		else:
			_grid_flash("NOT IN DECK B — RESCAN")   # silence reads as broken
		return
	_jump_to_clip_id(id)


# Grid tap in CURATE mode: flip this clip's LIVE/PARKED flag (Option C step 2). This is
# the same live_set the playlist checkboxes wrote, so RANDOM/LFO immediately pick from
# the grid-curated pool — live_indices() reads it at cue time, no other plumbing.
#
# ⚠️ set_live() is WHOLE-SET, not incremental, so one tap has to rebuild the entire live
# list. Walking clip_engine.clips (not the library) keeps the paths in the engine's own
# order and its own identity space; ClipLibrary.path_for bridges the grid's id across.
func _on_grid_park_toggled(id: String) -> void:
	var path := ClipLibrary.path_for(id)
	if path == "":
		return   # id no longer names a present clip (renamed/deleted under us)
	var live_paths: Array[String] = []
	for p: String in clip_engine.clips:
		var live := clip_engine.is_live(p)
		if p == path:
			live = not live
		if live:
			live_paths.append(p)

	# ⚠️ REFUSED, NOT CLAMPED. An empty live set is indistinguishable from "no curation"
	# downstream — is_live() answers `live_set.is_empty() or has(path)`, so parking the
	# LAST clip would silently unpark all of them and hand RANDOM the whole library. The
	# playlist checkboxes have this inversion today; the grid declines instead.
	if live_paths.is_empty():
		_grid_flash("AT LEAST ONE CLIP MUST STAY LIVE")
		return

	var parked := not live_paths.has(path)
	# All-live is encoded as the EMPTY set (see is_live) — collapse to it, or a full
	# list would read as curation and defeat the "nothing parked" default.
	if live_paths.size() == clip_engine.clips.size():
		clip_engine.set_live([])
	else:
		clip_engine.set_live(live_paths)
	# The dead-code call: this existed with the docstring "e.g. after the playlist parks
	# a clip" but nothing ever called it, so ClipData.is_live went stale and the grid's
	# LIVE/PARKED views never refreshed. It is wired up now.
	ClipLibrary.refresh_live()
	_save_playlist_live()

	# The back decoder may be holding the clip we just parked, in which case the next cut
	# would still play it and the park would look ignored. Re-warm ONLY in that case —
	# recueing on every tap would burn a ~195 ms demux per clip while curating.
	var ci := clip_engine.cued_index()
	if parked and ci >= 0 and ci < clip_engine.clips.size() and clip_engine.clips[ci] == path:
		clip_engine.recue()

	var cd := ClipLibrary.get_clip(id)
	_grid_flash("%s — %s" % ["PARKED" if parked else "LIVE",
		cd.display_name.to_upper() if cd != null else id])


# Feedback while the CLIP GRID overlay is up.
#
# ⚠️ NOT _flash_status(). The status label and the grid are siblings in _chrome_layer,
# and showing the grid does move_child(_clip_grid, -1) — so the grid's opaque background
# covers the status flash exactly when curating is happening. The strip is a CHILD of
# the grid and draws above it, which is why the slot save/load messages already go
# there. A refusal the performer cannot see is the same as no refusal at all.
func _grid_flash(msg: String) -> void:
	if _seq_strip != null:
		_seq_strip.flash(msg)


## Grid reorder (Option C step 3): move `moved_id` to sit immediately before
## `target_id` in the deck's clip order — the order SEQUENTIAL walks, which the playlist
## panel used to be the only way to change.
##
## ⚠️ THE MOVE IS DEFINED IN THE **FULL** ORDER, NOT THE VISIBLE ONE. The grid shows
## filtered views (ALL / LIVE / PARKED) that are SUBSEQUENCES of clip_engine.clips, so
## dragging one LIVE clip in front of another says nothing about the parked clips
## interleaved between them. Reinserting at the target's absolute position leaves every
## other clip exactly where it was — the only reading that behaves identically from any
## view.
func _on_grid_reorder(moved_id: String, target_id: String) -> void:
	# ⚠️ FIRST, AND BEFORE THE EARLY RETURNS BELOW. This release path emits reorder
	# INSTEAD of clip_grab_ended, so nothing else ever tears the drag down — the floating
	# proxy stayed on screen for the rest of the session (the "stuck thumbnail") and the
	# strip kept its insertion marker.
	_end_grid_drag()
	var from_path := ClipLibrary.path_for(moved_id)
	var to_path := ClipLibrary.path_for(target_id)
	if from_path == "" or to_path == "" or from_path == to_path:
		return
	var order: Array[String] = clip_engine.clips.duplicate()
	if order.find(from_path) < 0 or order.find(to_path) < 0:
		return
	order.remove_at(order.find(from_path))
	# ⚠️ Re-find the target AFTER the removal. When the moved clip sat in front of it the
	# target shifts down by one, and a stale index drops the clip a slot late.
	order.insert(order.find(to_path), from_path)

	# set_order re-finds the PLAYING clip by path, so a reorder never interrupts playback.
	clip_engine.set_order(order)
	# The warm decoder still holds whatever the OLD order said came next, which after a
	# move is usually no longer the right clip. set_order keeps _cued_index pointing at
	# the same FILE across the reorder; this re-warms the one the new order actually
	# wants. Cheap here — a reorder is a deliberate act with the grid overlay up.
	clip_engine.recue()
	ClipLibrary.rebuild()   # ids follow clip_engine.clips; refreshes every folder view
	_save_playlist_order()

	var cd := ClipLibrary.get_clip(moved_id)
	_grid_flash("MOVED — %s" % (cd.display_name.to_upper() if cd != null else moved_id))


## Grid remove (Option C step 4): delete a clip FROM THE DEVICE. Long-press with CURATE
## armed. This is the one capability the playlist panel had that the grid did not, and
## the panel cannot retire until it lives here — `remove_absolute` on a clip file exists
## nowhere else in the app.
##
## Refusals happen HERE, before the dialog, so the performer is never asked to confirm
## something that will then be declined.
func _on_grid_remove_requested(id: String) -> void:
	var path := ClipLibrary.path_for(id)
	if path == "":
		return   # id no longer names a present clip

	# ⚠️ REFUSED: the deck is decoding this file. Deleting it out from under a running
	# ExoPlayer is the one removal that can take the output down mid-set, and there is
	# no reading of "remove the clip you are watching" worth that risk.
	if clip_engine.current_index >= 0 and clip_engine.current_index < clip_engine.clips.size() \
			and clip_engine.clips[clip_engine.current_index] == path:
		_grid_flash("CAN'T REMOVE THE PLAYING CLIP")
		return
	# …and deck B is a deck too: deleting the file it is decoding takes the
	# projected mix down the same way.
	if _clip_engine_b != null and _clip_engine_b.current_index >= 0 \
			and _clip_engine_b.current_index < _clip_engine_b.clips.size() \
			and _clip_engine_b.clips[_clip_engine_b.current_index] == path:
		_grid_flash("CAN'T REMOVE — PLAYING ON DECK B")
		return
	if clip_engine.clips.size() <= 1:
		_grid_flash("AT LEAST ONE CLIP MUST REMAIN")
		return
	# Same inversion the park handler refuses: an empty live set READS as "no curation"
	# downstream (is_live answers live_set.is_empty() or has), so removing the last live
	# clip would silently hand RANDOM the whole parked library.
	if not clip_engine.live_set.is_empty():
		var remaining_live := 0
		for p: String in clip_engine.clips:
			if p != path and clip_engine.is_live(p):
				remaining_live += 1
		if remaining_live == 0:
			_grid_flash("AT LEAST ONE CLIP MUST STAY LIVE")
			return

	var cd := ClipLibrary.get_clip(id)
	var label := cd.display_name.to_upper() if cd != null else id
	var dlg := M8Dialog.confirm(_chrome_layer, "REMOVE CLIP",
		("Delete %s from your folder %s? The file is gone for good." % [label, Storage.folder_label()])
			if Storage.is_legacy() else
		("Remove %s from PVJ? PVJ's copy is deleted; the file you imported it from is not touched." % label),
		"REMOVE", func() -> void: _remove_clip_file(id, path), M8Dialog.M8_RED)
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


# Delete the file and repair every structure that referenced it: play order, live set,
# sequence slots, the warm decoder, thumbnails, and both persisted keys.
func _remove_clip_file(id: String, path: String) -> void:
	var cd := ClipLibrary.get_clip(id)
	var label := cd.display_name.to_upper() if cd != null else id
	var thumb := cd.thumb_cache_path if cd != null else ""   # read BEFORE rebuild drops cd

	# Today's order minus the removed clip — scan() below returns the folder to
	# alphabetical, so this is what puts the curated order back.
	var order: Array[String] = []
	for p: String in clip_engine.clips:
		if p != path:
			order.append(p)
	# The playing clip, captured BEFORE the rescan — see the current_index note below.
	var cur_path := ""
	if clip_engine.current_index >= 0 and clip_engine.current_index < clip_engine.clips.size():
		cur_path = clip_engine.clips[clip_engine.current_index]

	var gone_key := Storage.rel(path)   # before the delete: the savers must not keep it
	if not Storage.delete(path):   # SAF-aware (a tree document or a real file)
		_grid_flash("REMOVE FAILED — %s" % label)
		return

	clip_engine.scan()
	clip_engine.set_order(order)
	# ⚠️ scan() REPLACES clips with a fresh alphabetical list and leaves current_index
	# alone, so in between those two calls the index names a DIFFERENT clip — and
	# set_order's own "re-resolve the playing clip by path" reads that wrong path and
	# faithfully restores the wrong one. Re-point it from the path captured above. (The
	# playing clip is never the removed one; that case is refused before the dialog.)
	if cur_path != "":
		var ci := clip_engine.clips.find(cur_path)
		if ci >= 0:
			clip_engine.current_index = ci

	# live_set is keyed by PATH, so the deleted entry would linger as a ghost member.
	if not clip_engine.live_set.is_empty():
		var live_paths: Array[String] = []
		for p: String in clip_engine.clips:
			if clip_engine.is_live(p):
				live_paths.append(p)
		# All-live is encoded as the EMPTY set — collapse to it rather than writing a
		# full list, which would read as curation.
		if live_paths.size() == clip_engine.clips.size():
			clip_engine.set_live([])
		else:
			clip_engine.set_live(live_paths)

	# Sequence slots pointing at the gone clip — in BOTH lanes (hazard §4.1: a
	# reindex walks both). LAST FIRST, so the earlier indices stay valid as they
	# are removed; _remove_seq_slot moves each lane's playhead correctly.
	_ensure_lane_b_model()
	for lane: SeqLane in [_lane_a, _lane_b]:
		for i: int in range(lane.sequence.size() - 1, -1, -1):
			if lane.sequence.get_id(i) == id:
				_remove_seq_slot(i, lane)

	# ⚠️ ALWAYS recue, never conditionally. cued_index() is an index into the PRE-removal
	# clips array, so after the rescan it can neither be trusted to name the deleted file
	# nor to name the same clip it did before. One demux on a deliberate destructive
	# action beats reasoning about stale bookkeeping.
	clip_engine.recue()
	_rescan_engine_b()

	# The clip's own derived data. Leaving it is not merely untidy: ids are basename
	# hashes, so re-adding a file with the same name would inherit the OLD thumbnail.
	if thumb != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(thumb))
	# LEGACY. Nothing writes local_<file>.jpg any more (ClipEngine._capture_thumb was
	# deleted with the playlist panel that read it), but every phone updated from an
	# older build still has a folder full of them. Harmless to attempt; no-ops once the
	# stragglers are gone.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		"user://thumb_cache/local_%s.jpg" % path.get_file()))

	ClipLibrary.rebuild()   # drops the id; folder_updated reloads the open grid
	_save_playlist_order(PackedStringArray([gone_key]))
	_save_playlist_live(PackedStringArray([gone_key]))
	_grid_flash("REMOVED — %s" % label)


## Persist the clip ORDER to playlist.cfg.
##
## ⚠️ LOAD-THEN-MERGE, mirroring _save_playlist_live(). That one must not clobber
## "order"; this one must not clobber "live". Two writers, one file — the merge is the
## only thing stopping them erasing each other's work. (Both writers are now in this
## file; the retired panel used to be a third, writing both keys at once.)
##
## ⚠️ AND A KEY MERGE: a saved key whose clip is not here right now (an old clips
## folder not copied into PVJ yet) keeps its place at the end, so a missing clip
## never erases the curated order (STORAGE_REWORK_PLAN §E). `drop_key` is the
## clips that left on purpose (REMOVE, a removed folder).
func _save_playlist_order(drop: PackedStringArray = PackedStringArray()) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PLAYLIST_PATH)   # keep "live"; a missing file is fine
	var names: PackedStringArray = []
	for p: String in clip_engine.clips:
		names.append(Storage.rel(p))   # relative keys, as _load_playlist_order expects
	names = Storage.keep_unresolved(clip_engine.clips_dir, names,
		cfg.get_value("playlist", "order", PackedStringArray()), drop)
	cfg.set_value("playlist", "order", names)
	cfg.save(PLAYLIST_PATH)


# Persist the live subset to playlist.cfg.
#
# ⚠️ LOAD-THEN-MERGE. This file also holds "order" (written by _save_playlist_order);
# a bare set_value+save from here would drop the saved play order on the floor.
#
# Keys are RELATIVE paths like "order" (a bare name at the top level, so older
# files read the same; the loader resolves both). They used to be basenames,
# which put a sub-folder clip's live state on any clip of the same name.
# Missing clips keep their keys (the merge in _save_playlist_order).
func _save_playlist_live(drop: PackedStringArray = PackedStringArray()) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PLAYLIST_PATH)   # keep "order"; a missing file is fine (stays empty)
	if clip_engine.live_set.is_empty():
		# Nothing parked. The ABSENCE of the key is what means "all live" to
		# _load_playlist_order, so this must erase rather than write an empty list.
		if cfg.has_section_key("playlist", "live"):
			cfg.erase_section_key("playlist", "live")
	else:
		var names: PackedStringArray = []
		for p: String in clip_engine.clips:
			if clip_engine.is_live(p):
				names.append(Storage.rel(p))
		names = Storage.keep_unresolved(clip_engine.clips_dir, names,
			cfg.get_value("playlist", "live", PackedStringArray()), drop)
		cfg.set_value("playlist", "live", names)
	cfg.save(PLAYLIST_PATH)


# Grid long-press starts a grab (Step 6): float a proxy that follows the finger,
# and let the strip preview an insertion index under it.
func _on_grid_grab_started(id: String, tex: Texture2D, global_pos: Vector2) -> void:
	_drag_clip_id = id
	if _drag_proxy == null:
		_drag_proxy = TextureRect.new()
		_drag_proxy.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_drag_proxy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_drag_proxy.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_drag_proxy.modulate = Color(1, 1, 1, 0.85)
		_chrome_layer.add_child(_drag_proxy)
	_drag_proxy.texture = tex
	_drag_proxy.size = Vector2(180, 101)
	_chrome_layer.move_child(_drag_proxy, -1)
	_drag_proxy.visible = true
	_position_drag_proxy(global_pos)
	_seq_strip.external_drop_preview(global_pos)


func _on_grid_grab_moved(global_pos: Vector2) -> void:
	_position_drag_proxy(global_pos)
	_seq_strip.external_drop_preview(global_pos)


# Release: insert at the strip's index if dropped on it, else append to the end
# (a long-press with no drag to the strip is still a quick "add to sequence").
func _on_grid_grab_ended(global_pos: Vector2) -> void:
	var idx := _seq_strip.external_drop_commit(global_pos)
	var dropped_id := _drag_clip_id
	_end_grid_drag()
	if dropped_id == "":
		return
	var cd := ClipLibrary.get_clip(dropped_id)
	var nm := cd.display_name.to_upper() if cd != null else dropped_id
	var L := _lane_for_strip()
	var lane_tag := "A" if _strip_lane == 0 else "B"
	if idx >= 0:
		L.sequence.insert(idx, dropped_id)
		_flash_status("INSERTED %s — %s" % [lane_tag, nm])
	else:
		L.sequence.append(dropped_id)
		_flash_status("QUEUED %s — %s" % [lane_tag, nm])


# Tear down a grid drag: hide the floating proxy, drop the strip's insertion marker,
# forget the dragged id. Both release meanings must end here — the queue/insert path
# (_on_grid_grab_ended) and the reorder path (_on_grid_reorder).
func _end_grid_drag() -> void:
	if _drag_proxy != null:
		_drag_proxy.visible = false
	if _seq_strip != null:
		_seq_strip.external_drop_cancel()
	_drag_clip_id = ""


func _position_drag_proxy(global_pos: Vector2) -> void:
	_drag_proxy.position = global_pos - _drag_proxy.size * 0.5


# Strip internal reorder drop: mutate the model; its `changed` rebuilds the view.
func _on_seq_reorder_requested(kind: int, from_index: int, to_index: int) -> void:
	var L := _lane_for_strip()
	if kind == SequenceStrip.REORDER_MOVE:
		L.sequence.move(from_index, to_index)
		# Keep the active-slot pointer on the SAME clip through the reorder. A move is
		# remove-at-from then insert-at-to, so the playhead shifts if either crosses it
		# (not only when the playing slot itself is the one dragged).
		if L.index >= 0:
			if L.index == from_index:
				L.index = to_index
			else:
				var idx := L.index
				if from_index < idx:
					idx -= 1
				if to_index <= idx:
					idx += 1
				L.index = idx
			_seq_strip.set_active(L.index)
	elif kind == SequenceStrip.REORDER_REMOVE:
		_remove_seq_slot(from_index)


# Remove a slot (dragged off the strip) WITHOUT cutting the deck. The active-slot
# pointer shifts so the sequence continues sensibly:
#  • a slot BEFORE the playhead → everything shifts left → _lane_a.index decrements.
#  • the PLAYING slot itself → the deck keeps playing that (now orphaned) clip; point
#    _lane_a.index at r-1 so AUTO's next advance lands on the clip that shifted into r
#    (the natural "next"), wrapping at the ends. No slot is highlighted meanwhile,
#    since the playing clip is no longer in the strip.
#  • a slot AFTER the playhead → _lane_a.index unchanged.
func _remove_seq_slot(r: int, lane: SeqLane = null) -> void:
	# ⚠️ EXPLICIT LANE. This used to read _lane_for_strip() unconditionally, so
	# _remove_clip_file (which walks lane A's ids) deleted slots from whichever
	# lane the strip happened to SHOW — persisted corruption of both patterns.
	var L := lane if lane != null else _lane_for_strip()
	if r < 0 or r >= L.sequence.size():
		return
	var playing_removed := (r == L.index)
	if r < L.index:
		L.index -= 1
	elif playing_removed:
		L.index = r - 1
	L.sequence.remove_at(r)   # emits changed → strip rebuild + autosave
	L.index = clampi(L.index, -1, L.sequence.size() - 1)
	if _seq_strip != null and L == _lane_for_strip():
		_seq_strip.set_active(-1 if playing_removed else L.index)
	# The deck is never touched here — the current clip keeps playing.


# CLEAR wipes the whole sequence. Destructive → confirm first (M8 red). The deck
# keeps playing; auto-advance simply has nothing to step through until refilled.
func _on_seq_clear() -> void:
	var L := _lane_for_strip()
	if L.sequence.is_empty():
		return
	var dlg := M8Dialog.confirm(_chrome_layer, "CLEAR SEQ %s" % ("A" if _strip_lane == 0 else "B"),
		"Remove all %d slots? The playing clip keeps going." % L.sequence.size(),
		"CLEAR", func() -> void:
			L.sequence.clear()
			L.index = -1
			_seq_strip.set_active(-1)
			L.beat_count = 0,
		M8Dialog.M8_RED)
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


# --- Auto-advance + shuffle (Step 7) -------------------------------------

func _on_seq_auto_toggled(enabled: bool) -> void:
	# Lane B's run/stop is its own simple law (armed ∧ auto ∧ non-empty).
	if _strip_lane == 1:
		# N4: with lane B on NET the strip IS the remote instrument's face —
		# AUTO commands the streaming peer's lane A (the local lane B
		# sequencer is inert behind the CLIP term anyway). Bar-quantized at
		# the receiver, like every remote ask.
		var prov := _lane_b_provider()
		if not prov.is_empty() and _link_control != null:
			_link_control.send_seq_auto(str(prov["ip"]), int(prov["ctrl"]), "a", enabled)
			_seq_strip.flash("→ %s AUTO %s @ BAR" % [str(prov["who"]), "ON" if enabled else "OFF"])
			return
		_set_lane_b_auto(enabled)
		return
	_set_lane_a_auto(enabled)


## Lane A's auto-advance, callable from the strip AND from a remote seq verb
## (N4) — extracted verbatim from the strip handler.
func _set_lane_a_auto(enabled: bool) -> void:
	_lane_a.auto = enabled
	_lane_a.beat_count = 0
	# Who drives just changed, so the warm clip is wrong either way: arming means the
	# back decoder holds the PLAYLIST's next instead of the sequence's, disarming means
	# the reverse. Re-point the provider before anything else reads it.
	#
	# The suppressed re-warm: when the branch below jumps to slot 0, that jump cues
	# slot 0 itself. Recueing here first would open slot 0 on the back decoder and then
	# have the jump restart the very same open a line later (cue() only short-circuits
	# on an index that is already READY), costing a wasted ~195 ms demux at arm time.
	#
	# Via _seq_drives(), so arming AUTO in a mode the sequence does not own is inert:
	# no jump to slot 0, no provider change, and no beat-grid realign that BEAT FLIP
	# would feel. The button still lights, and it takes effect on entering SEQUENTIAL.
	var arming_jump := _seq_drives() and _lane_a.index < 0
	_apply_cue_target(not arming_jump)
	if _seq_drives():
		# Start the run from a defined slot: keep the current position, or slot 0.
		if arming_jump:
			_advance_sequence_to(0)
		BeatClock.reset_grid()   # a fresh downbeat so the first slot is a full slot
	elif _seq_strip != null:
		_seq_strip.set_playhead(0.0)


func _on_seq_bps_changed(beats: int) -> void:
	var L := _lane_for_strip()
	L.beats_per_slot = maxi(1, beats)
	L.beat_count = 0
	_settings_dirty = true


func _on_seq_shuffle() -> void:
	var L := _lane_for_strip()
	if L.sequence.is_empty():
		return
	# Fisher–Yates on the model, keeping the currently-playing clip; find its new
	# slot afterwards so the active highlight + auto-advance pointer follow it.
	var kept := L.sequence.shuffle_fisher_yates(L.index)   # rebuilds the strip
	if kept != "":
		L.index = L.sequence.find_id(kept)
		_seq_strip.set_active(L.index)
	L.beat_count = 0
	_flash_status("SHUFFLED · %d" % L.sequence.size())


# Beat tick for the SEQUENCER auto-advance (distinct from the deck's SEQUENTIAL
# switch clock). Counts beats and steps the sequence every beats-per-slot.
func _on_seq_beat(_index: int) -> void:
	# PRE-EXISTING FIX (predates Piece 1): this gated on _lane_a.auto and never on _mode,
	# so an armed AUTO stepped the arrangement in EVERY mode — including MANUAL, where
	# it overwrote a deliberately tapped clip a few beats later (the "snap-back"), and
	# RANDOM/LFO, where it ran as a second clock against theirs. _seq_drives() carries
	# the mode test, so the sequencer now only advances where the sequence is the
	# declared source.
	# Lane B steps first (independent clock, own beats-per-slot, staggered start).
	# Its beat_count can be negative right after auto-on — that IS the stagger.
	if _lane_b_drives():
		_lane_b.beat_count += 1
		if _lane_b.beat_count >= _lane_b.beats_per_slot:
			_lane_b.beat_count = 0
			_advance_lane_b_to((_lane_b.index + 1) % _lane_b.sequence.size())
	if not _seq_drives():
		return
	_lane_a.beat_count += 1
	if _lane_a.beat_count >= _lane_a.beats_per_slot:
		_lane_a.beat_count = 0
		var next := (_lane_a.index + 1) % _lane_a.sequence.size()   # wrap at the end
		_advance_sequence_to(next)


# Jump deck A to slot `index`, move the active highlight, reset the playhead.
# The strip only follows while it is SHOWING lane A (the hidden lane keeps
# running without touching the view).
func _advance_sequence_to(index: int) -> void:
	_lane_a.index = index
	if _strip_lane == 0 and _seq_strip != null:
		_seq_strip.set_active(index)
	_jump_to_clip_id(_lane_a.sequence.get_id(index))


# Strip tap: make that slot the SELECTED lane's active position and jump its deck.
func _on_seq_slot_selected(index: int) -> void:
	var L := _lane_for_strip()
	L.index = index
	_seq_strip.set_active(index)
	if _strip_lane == 1:
		if _clip_engine_b != null and _lane_b_armed:
			if _lane_b_source != LaneBSource.CLIP:
				_grid_flash("LANE B IS %s — SET B SRC: CLIPS" % LANE_B_SOURCE_NAMES[_lane_b_source])
				return
			var ci := _engine_index_for_clip_id(L.sequence.get_id(index), _clip_engine_b)
			if ci >= 0:
				_clip_engine_b.jump(ci)
			else:
				_grid_flash("NOT IN DECK B — RESCAN")
		else:
			_grid_flash("LANE B NOT ARMED")
	else:
		_jump_to_clip_id(L.sequence.get_id(index))


# --- Sequence persistence (Step 5; SessionStore takes this over later) ----

func _load_sequence() -> void:
	if FileAccess.file_exists(SEQUENCE_PATH):
		var res := ResourceLoader.load(SEQUENCE_PATH) as Sequence
		if res != null:
			_lane_a.sequence = res
	# Persist on every model change (append/insert/move/remove/shuffle) — the model
	# only mutates on discrete edits, never per drag-frame, so this is a cheap write.
	_lane_a.sequence.changed.connect(_save_sequence)
	# ...and re-warm, because an edit can change which clip comes next. ONE connection
	# rather than a call at each edit site: every mutator (append/insert/move/remove_at/
	# clear/shuffle_fisher_yates/from_array) emits `changed`, so this also covers the
	# grid->strip drop and a numbered-slot load. Connected here, after the resource
	# swap above, so it survives loading a saved sequence at boot.
	_lane_a.sequence.changed.connect(_on_sequence_changed)
	_lane_a.sequence.changed.connect(_push_grid_decks)   # the A badges follow the pattern


func _save_sequence() -> void:
	ResourceSaver.save(_lane_a.sequence, SEQUENCE_PATH)


# The arrangement was edited. Only matters while the sequence is driving — otherwise
# the provider isn't reading it and recue() would be a wasted demux.
#
# ⚠️ Must not touch _seq_strip: _load_sequence() connects this during _ready(), but
# _build_sequencer() is lazy (first grid toggle), so this can fire with a null strip.
func _on_sequence_changed() -> void:
	if _seq_drives():
		_apply_cue_target()


# --- Named slot save/load (warp-slot pattern) ----------------------------

func _slot_path(slot: int) -> String:
	return "%s/slot_%d.tres" % [SEQUENCES_DIR, slot]


# Read each slot's stored label (blank = empty/unlabeled) so the strip can show
# what's in each numbered slot. Tiny files; loaded once at build + after a save.
func _refresh_slot_labels() -> void:
	var labels := PackedStringArray()
	var exists: Array[bool] = []
	for n: int in range(1, SEQ_SLOT_COUNT + 1):
		var p := _slot_path(n)
		var lbl := ""
		var has := FileAccess.file_exists(p)
		if has:
			var res := ResourceLoader.load(p) as Sequence
			lbl = res.label if res != null else ""
		labels.append(lbl)
		exists.append(has)
	if _seq_strip != null:
		_seq_strip.set_slot_labels(labels)
	# PerfStrip reads the SAME bank: A3 and B3 load one saved pattern into two
	# different lanes, so one read feeds both rows.
	if _perf_strip != null:
		_perf_strip.set_slots(labels, exists)


# Save the CURRENT arrangement to a numbered slot, as an independent snapshot (a
# duplicate, so the slot's label doesn't leak onto the live working sequence).
func _on_seq_save_slot(slot: int, label: String) -> void:
	DirAccess.make_dir_recursive_absolute(SEQUENCES_DIR)
	var snap := Sequence.new()
	snap.entries = _lane_for_strip().sequence.entries.duplicate()
	snap.label = label
	var err := ResourceSaver.save(snap, _slot_path(slot))
	if err != OK:
		_seq_strip.flash("SLOT %d SAVE FAILED" % slot)
		return
	_refresh_slot_labels()
	var suffix := " · %s" % label.to_upper() if label != "" else ""
	_seq_strip.flash("SAVED SLOT %d%s" % [slot, suffix])


# LOAD opens a picker over the six slots: "3  WARMUP · 12 CLIPS", empty ones dim,
# "EMPTY" and untappable, the armed slot (what SAVE / DEL act on) filled and led
# by a ▶ — in front, where a long name's ellipsis cannot cut it. Picking one ARMS
# it in the strip (so SAVE / DEL then act on the pattern now in the lane) and
# loads it through the same path the button used to. Reads the slot files the
# same way _refresh_slot_labels does — tiny, on a tap.
func _on_seq_load_menu() -> void:
	var rows: Array = []
	var armed := _seq_strip.current_slot()
	for n: int in range(1, SEQ_SLOT_COUNT + 1):
		var p := _slot_path(n)
		var res: Sequence = null
		if FileAccess.file_exists(p):
			res = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE) as Sequence
		var mark := "▶ " if n == armed else "  "
		if res == null:
			rows.append({"text": "%s%d   EMPTY" % [mark, n], "enabled": false, "marked": n == armed})
			continue
		var nm := res.label.to_upper() if res.label != "" else "UNTITLED"
		var count := res.entries.size()
		rows.append({"text": "%s%d   %s · %d CLIP%s" % [mark, n, nm, count, "" if count == 1 else "S"],
			"enabled": true, "marked": n == armed})
	var lane_b := _strip_lane == 1
	var dlg := M8Dialog.pick(_chrome_layer, "LOAD INTO LANE %s" % ("B" if lane_b else "A"), rows,
		func(i: int) -> void:
			_seq_strip.arm_slot(i + 1)
			_on_seq_load_slot(i + 1),
		M8Palette.AMBER if lane_b else M8Palette.GREEN)
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


# Load a numbered slot into the working arrangement WITHOUT interrupting playback:
# replace the strip contents, leave the current clip playing. Dangling clip ids
# (renamed/deleted files — ids are basename hashes) are skipped, never fatal, and
# the dropped count is reported.
func _on_seq_load_slot(slot: int) -> void:
	# N4: with lane B on NET, the strip's slot bank IS the remote instrument's
	# bank — LOAD commands the streaming peer's lane A instead of editing the
	# dormant local model. Bar-quantized at the receiver.
	var prov: Dictionary = _lane_b_provider() if _strip_lane == 1 else {}
	if not prov.is_empty() and _link_control != null:
		_link_control.send_seq_slot(str(prov["ip"]), int(prov["ctrl"]), "a", slot, "bar")
		_seq_strip.flash("→ %s SLOT %d @ BAR" % [str(prov["who"]), slot])
		return
	_load_seq_slot_into(_lane_for_strip(), slot)


## Load a numbered slot into a LANE's working arrangement — the strip's LOAD
## and a remote seq verb (N4) share this path. Strip touches are guarded: a
## remote ask can land before the strip has ever been built.
func _load_seq_slot_into(L: SeqLane, slot: int, force: bool = false) -> void:
	var p := _slot_path(slot)
	if not FileAccess.file_exists(p):
		if _seq_strip != null:
			_seq_strip.flash("SLOT %d EMPTY" % slot)
		return
	var res := ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE) as Sequence
	if res == null:
		if _seq_strip != null:
			_seq_strip.flash("SLOT %d UNREADABLE" % slot)
		return
	# Skip entries whose id no longer resolves to a present clip.
	var kept: Array[String] = []
	for id: String in res.entries:
		if ClipLibrary.get_clip(id) != null:
			kept.append(id)
	var dropped := res.entries.size() - kept.size()
	# Clips KNOWN to be missing (an old folder not copied in yet): loading would
	# autosave a trimmed working sequence. Ask first; the saved slot is never
	# touched either way. A remote load (no strip) just refuses.
	if dropped > 0 and Storage.clips_missing() and not force:
		var msg := "SLOT %d: %d CLIP%s NOT IN PVJ YET" % [slot, dropped, "" if dropped == 1 else "S"]
		if _seq_strip == null or not _seq_strip.is_visible_in_tree():
			print("[seq] %s — not loaded" % msg)
			if _seq_strip != null:
				_seq_strip.flash(msg)
			return
		var dlg := M8Dialog.confirm(_chrome_layer, msg,
			("Slot %d names %d clip%s that are not in PVJ yet. Re-import your old clips folder "
			+ "first (LIB ▸ SOURCES & LIBRARY) and the slot loads whole.\n\nLOAD ANYWAY puts "
			+ "the other %d in the working sequence; the saved slot keeps all of them.")
				% [slot, dropped, "" if dropped == 1 else "s", kept.size()],
			"LOAD ANYWAY", func() -> void: _load_seq_slot_into(L, slot, true), M8Dialog.M8_RED)
		dlg.theme = _theme   # CanvasLayer breaks theme inheritance
		return

	L.sequence.from_array(kept)   # emits changed → strip rebuilds + autosave
	# Keep the current clip playing; just re-point the active slot at it if
	# present. (Lane A only — lane B's playhead is its own pattern position.)
	if L == _lane_a:
		_resync_seq_index_to_current()

	_refresh_slot_labels()   # reflect the loaded slot's label in the field
	var suffix := " · %d DROPPED" % dropped if dropped > 0 else ""
	if _seq_strip != null:
		_seq_strip.flash("LOADED SLOT %d%s" % [slot, suffix])
	print("[seq] slot %d -> lane %s (%d ids%s)" % [slot,
		"A" if L == _lane_a else "B", kept.size(), suffix])
	if _perf_strip != null:
		_perf_strip.set_active_slot(0 if L == _lane_a else 1, slot)   # clears its pending pulse


# Delete a saved slot's file + label (frees a slot filled during testing; clears a
# stale label). Destructive → M8-red confirm, so fat-fingering SAVE's neighbour
# mid-set can't wipe an arrangement. Empty slot = nothing to do.
func _on_seq_clear_slot(slot: int) -> void:
	var p := _slot_path(slot)
	if not FileAccess.file_exists(p):
		_seq_strip.flash("SLOT %d EMPTY" % slot)
		return
	var dlg := M8Dialog.confirm(_chrome_layer, "CLEAR SLOT %d" % slot,
		"Delete the saved arrangement in slot %d? The working sequence is untouched." % slot,
		"DELETE", func() -> void:
			DirAccess.remove_absolute(p)
			_refresh_slot_labels()   # clears the stale label from the field
			_seq_strip.flash("CLEARED SLOT %d" % slot),
		M8Dialog.M8_RED)
	dlg.theme = _theme   # CanvasLayer breaks theme inheritance


# Re-point the sequence's active slot at whatever clip is currently on the deck,
# without cutting it. Resets the beat counter so a running AUTO gives the freshly
# loaded slot a full slot before advancing (no immediate stall/jump).
func _resync_seq_index_to_current() -> void:
	var L := _lane_for_strip()
	L.index = -1
	# No deck yet (lane B before first arm): -1 is the honest state — resolving
	# against deck A would highlight a slot the absent deck isn't playing.
	var e: ClipEngine = L.engine
	if e != null and e.current_index >= 0 and e.current_index < e.clips.size():
		var cur_id := ClipLibrary.id_for_path(e.clips[e.current_index])
		L.index = L.sequence.find_id(cur_id)
	# The strip is built with the clip grid, on first open. A slot load that does
	# not come FROM the strip — OSC /pvj/seq/slot, a link seq verb, the PERF strip —
	# lands here on a launch that never opened the grid, where this call was a
	# SCRIPT ERROR on Nil (found by the PERF strip's first device run, 9a).
	if _seq_strip != null:
		_seq_strip.set_active(L.index)
	L.beat_count = 0


# A Drive clip finished downloading into clips_dir: make the engine aware of it,
# restore saved order (the new file appends at the end), and start playback if idle.
# The grid refreshes itself off ClipLibrary, which rebuilds on clips_ready.
# PRO only. Drive downloads land in the engine's clips folder (the on-device cache)
# so the existing GoZen scan/play path picks them up unchanged. (Pro's OAuth browser
# writes files by path, so with a SAF folder picked it can only use app storage.)
func _wire_drive_client() -> void:
	var drive_client: Node = get_node("/root/DriveClient")
	drive_client.set("cache_dir", Storage.APP_CLIPS if Storage.is_virtual(clip_engine.clips_dir) \
			else clip_engine.clips_dir)
	drive_client.connect("download_done", _on_drive_download_done)


func _on_drive_download_done(_file_id: String, local_path: String) -> void:
	clip_engine.scan()
	_rescan_engine_b()
	_load_playlist_order()
	if clip_engine.player == null and not clip_engine.clips.is_empty():
		clip_engine.play_index(0)
	_flash_status("DRIVE READY — %s" % local_path.get_file())


# A local file finished importing into clips_dir: same path as a Drive add —
# rescan, restore order, start playback if idle.
func _on_local_clip_imported(local_path: String) -> void:
	clip_engine.scan()
	_rescan_engine_b()
	_load_playlist_order()
	if clip_engine.player == null and not clip_engine.clips.is_empty():
		clip_engine.play_index(0)
	_flash_status("IMPORTED — %s" % local_path.get_file())


# Restore the saved play order (keys relative to the clips dir in
# user://playlist.cfg — bare names at the top level, "sub/name" below; a bare
# name from an older save is resolved into a sub-folder too) onto the engine.
func _load_playlist_order() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PLAYLIST_PATH) != OK:
		return
	var names: PackedStringArray = cfg.get_value("playlist", "order", PackedStringArray())
	if not names.is_empty():
		var paths: Array[String] = []
		for n: String in names:
			var f := Storage.resolve(clip_engine.clips_dir, n)
			paths.append(f if f != "" else clip_engine.clips_dir.path_join(n))
		clip_engine.set_order(paths)
	# Restore the live subset (parked clips). Absent/empty = all clips live.
	var live_names: PackedStringArray = cfg.get_value("playlist", "live", PackedStringArray())
	if not live_names.is_empty():
		var live_paths: Array[String] = []
		for n: String in live_names:
			var f := Storage.resolve(clip_engine.clips_dir, n)
			live_paths.append(f if f != "" else clip_engine.clips_dir.path_join(n))
		clip_engine.set_live(live_paths)


# Download a clip from the server into ClipEngine's clips folder, then play it.
func _on_clip_load_requested(url: String, filename: String) -> void:
	var dest := clip_engine.clips_dir.path_join(filename)
	var http := HTTPRequest.new()
	add_child(http)
	http.download_file = dest
	http.request_completed.connect(func(_result, code, _headers, _body):
		http.queue_free()
		if code == 200:
			clip_engine.scan()
			var idx := clip_engine.clips.find(dest)
			if idx == -1:
				for i in clip_engine.clips.size():
					if clip_engine.clips[i].get_file() == filename:
						idx = i
						break
			if idx != -1:
				clip_engine.play_index(idx)
			_flash_status("LOADED — %s" % filename)
			if _clip_browser != null:
				_clip_browser.visible = false
		else:
			_flash_status("DOWNLOAD FAILED — %s (HTTP %d)" % [filename, code])
	)
	if http.request(url) != OK:
		http.queue_free()
		_flash_status("REQUEST ERROR — %s" % filename)
	else:
		_flash_status("DOWNLOADING — %s…" % filename)


# --- Manual intensity fader (big right-edge slider) ----------------------

func _build_intensity_fader() -> void:
	_fader = VSlider.new()
	_fader.min_value = 0.0
	_fader.max_value = 3.0
	_fader.step = 0.01
	_fader.value = _manual_intensity
	_fader.focus_mode = Control.FOCUS_NONE
	# While the user is touching the fader, override the audio-driven intensity.
	_fader.drag_started.connect(func(): _intensity_override = true)
	_fader.drag_ended.connect(func(_changed: bool): _intensity_override = false)
	_fader.value_changed.connect(func(v: float): _manual_intensity = v)
	_ui_add(_fader)

	_fader_label = _make_label("FX")
	_ui_add(_fader_label)
	_position_fader()


# Lay out the FX intensity fader + audio meter as a right-edge PAIR: fader on the
# left, meter immediately to its right, sharing one vertical span. The small "FX"
# label sits at the BOTTOM of the pair (it used to be up by the BPM readout, which
# it crowded). The pair's bottom clears the anchored status bar; when the ClipGrid
# overlay is open it covers this whole area (opaque bg), so there's no clash with
# the bottom-anchored SequenceStrip.
func _position_fader() -> void:
	if _fader == null:
		return
	var sz := _ui_size()
	const FW := 70.0          # fader width
	const GAP := 12.0         # fader↔meter
	const MARGIN := 18.0      # pair↔right edge
	const TOP := 110.0
	const LABEL_H := 34.0     # room below the pair for the FX caption
	# Meter hugs the right edge; the fader sits immediately to its left.
	var meter_x := sz.x - MARGIN - M8Meter.BAR_W
	var fader_x := meter_x - GAP - FW
	var bottom := sz.y - STATUSBAR_H - LABEL_H
	var height := maxf(bottom - TOP, 120.0)
	_fader.position = Vector2(fader_x, TOP)
	_fader.size = Vector2(FW, height)
	if _meter != null:
		_meter.position = Vector2(meter_x, TOP)
		_meter.size = Vector2(M8Meter.BAR_W, height)
	if _fader_label != null:
		# Centred under the whole pair, at the bottom.
		_fader_label.position = Vector2(fader_x, TOP + height + 6.0)
		_fader_label.size = Vector2(meter_x + M8Meter.BAR_W - fader_x, LABEL_H)
		_fader_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


# --- Audio level meter (M8 MIXER style: vertical segmented bar) ---
# Built as the right half of the FX fader + meter PAIR; _position_fader lays out
# both together (see there). It self-updates (own _process) — pipeline only sizes
# and positions it.

func _build_meter() -> void:
	_meter = M8Meter.new()
	_ui_add(_meter)
	_position_fader()   # lay out the fader + meter + label pair now both exist


# Bottom-bar FPS readout. Sampled every FPS_SAMPLE_SEC (a per-frame Label.text
# write would itself queue a redraw + relayout 60x a second — exactly the kind of
# cost the rest of _process was cleaned up to avoid), and only written when the
# whole number actually changes. Goes RED below FPS_WARN so dropped frames during
# a set are visible at a glance.
func _update_fps(delta: float) -> void:
	if _lbl_fps == null:
		return
	_fps_accum += delta
	if _fps_accum < FPS_SAMPLE_SEC:
		return
	_fps_accum = 0.0
	var fps := int(Engine.get_frames_per_second())
	if fps == _last_fps:
		return
	_last_fps = fps
	# While the frame rate is held down for heat, say so where the number is —
	# the warning itself is a flash that is gone in seconds.
	_lbl_fps.text = ("HOT · FPS %d" if _heat_capped else "FPS %d") % fps
	# Track the applied colour in its OWN tri-state (-1 = never applied). Deriving
	# it from the previous fps meant that if the FIRST sample was already below
	# FPS_WARN, "changed?" compared false-to-false and the label stayed dim — the
	# warning never appeared until the rate first went good and then bad again.
	var is_ok := 1 if fps >= FPS_WARN else 0
	if is_ok != _fps_ok_state:
		_fps_ok_state = is_ok
		_lbl_fps.add_theme_color_override("font_color", M8_DIMTEXT if is_ok == 1 else M8_RED)


# Bottom-bar LINK readout, ticked at 1 Hz by LinkStatsTimer (the cadence is
# load-bearing — see _build_link). Hidden entirely while the link is idle: a
# pull that never happened prints nothing. But a stream that ONCE FLOWED and
# died STAYS on the bar in red — a cam stream dying mid-show is exactly the
# thing the operator must see, and hiding it made LOST bit-identical to "link
# idle" on any device that wasn't also sending. The one exception is an
# operator STOP (_link_pull_stopped): a death the operator ordered is not an
# alarm, and the row stands down with the stream.
func _update_link_stats() -> void:
	if _lbl_link == null:
		return
	var tx_on := _net_sender != null and _net_sender.is_active()
	var fresh: int = NetSource.Freshness.LOST
	var rx_frames := 0
	var rx: Dictionary = {}
	if _net_source != null:
		fresh = _net_source.freshness()
		rx = _net_source.get_stats()
		rx_frames = int(rx["frames_ok"])
	var rx_on := fresh != NetSource.Freshness.LOST
	var rx_shown := rx_on or (rx_frames > 0 and not _link_pull_stopped)
	# Stage 3.2: the TD slot reports alongside. Shown while we dial it OR frames
	# flow — a dial that never lands must read LOST in red, not vanish.
	var td_fresh: int = NetSource.Freshness.LOST
	var td: Dictionary = {}
	if _net_source_td != null:
		td_fresh = _net_source_td.freshness()
		td = _net_source_td.get_stats()
	var td_shown := _td_rx_ip != "" or td_fresh != NetSource.Freshness.LOST
	var shown := tx_on or rx_shown or td_shown
	if _lbl_link.visible != shown:
		_lbl_link.visible = shown
		_lbl_link_sep.visible = shown
	if not shown:
		return
	var text := "LINK"
	if tx_on:
		var tx := _net_sender.get_stats()
		text += " TX %.0ffps %.1fMb rb%.1f en%.1f" % [tx["fps"],
				float(tx["kbps"]) / 1000.0, tx["readback_ms"], tx["encode_ms"]]
	if rx_shown:
		text += " RX %.0ffps %.1fMb de%.1f %s" % [rx["fps"],
				float(rx["kbps"]) / 1000.0, rx["decode_ms"], LINK_FRESH_NAMES[fresh]]
	if td_shown:
		text += " TD %.0ffps %.1fMb de%.1f %s" % [float(td.get("fps", 0.0)),
				float(td.get("kbps", 0.0)) / 1000.0, float(td.get("decode_ms", 0.0)),
				LINK_FRESH_NAMES[td_fresh]]
	_lbl_link.text = text
	# Same tri-state trick as the FPS colour above, same failure mode avoided:
	# a FIRST sample already degraded must still turn the label red.
	var is_live := 0 if (rx_shown and fresh != NetSource.Freshness.LIVE) \
			or (td_shown and td_fresh != NetSource.Freshness.LIVE) else 1
	if is_live != _link_lbl_state:
		_link_lbl_state = is_live
		_lbl_link.add_theme_color_override("font_color", M8_DIMTEXT if is_live == 1 else M8_RED)



# --- Splash screen (brief branded overlay on launch) ---------------------

## The in-app splash plays the ident clip (tools/ident/make_splash_organic.py:
## a 0.2 s hold on frame 135, then frames 135-225 of the organic loop at 720p,
## COLLECTIVE unconscious eroding into PVJ, 3.2 s) over the same still the
## engine's boot splash shows, which is the clip's first frame as the screen
## scales it — so the hand-over is invisible. The hold absorbs the 4-5 frames
## GoZen skips when it starts (it presents the frame at the elapsed time), so
## what is lost is still, not motion. PVJ is held from 2.7 s in, and that is
## when the subtitle and the credit fade in under it. A tap skips.
const SPLASH_CLIP_LEN := 3.2        # s — the clip, 97 frames at 30 fps
const SPLASH_WORD_AT := 2.7         # s — the PVJ hold starts (clip frame 81)
const SPLASH_LABELS_IN := 0.4       # s — subtitle + credit fade-in
const SPLASH_READ := 1.2            # s — on the finished frame, to read the credit
const SPLASH_STILL_HOLD := 1.5      # s — no clip in the build: hold the still
const SPLASH_OPEN_TIMEOUT := 2.0    # s — the clip never opened: fall back
const SPLASH_FADE := 0.6            # s — fade out

var _splash_tween: Tween = null


func _build_splash() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128                       # above all other UI
	add_child(layer)

	var bg := ColorRect.new()
	bg.theme = _theme          # own CanvasLayer -> needs the theme explicitly too
	bg.color = Color.BLACK     # continues the boot splash (black, the ident frame)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow taps while showing
	layer.add_child(bg)

	# The same ident frame the boot splash shows (beta2 §2.2), so the hand-over
	# from the engine's splash to this one is invisible. The clip plays on top
	# of it; the still stays underneath for the frames before the decoder opens.
	var frame := TextureRect.new()
	frame.texture = load("res://branding/pvj-splash-1080.png")
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(frame)

	# The clip sits between the still and the labels: added here so the labels
	# draw OVER it (in a landscape window the clip fills the full height, right
	# across the strip the labels sit in). Opened at the end of this function.
	var clip := Storage.splash_clip_path()
	var video: VideoPlayback = null
	if clip != "":
		video = VideoPlayback.new()
		video.enable_audio = false
		video.loop = false
		video.enable_auto_play = true
		video.mouse_filter = Control.MOUSE_FILTER_IGNORE
		video.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.add_child(video)

	# What the letters stand for sits low, in the deck's green. The credit is a
	# footer, small and dim, like the line on a record sleeve — it must not
	# compete with the name.
	var sub := Label.new()
	sub.text = "PORTABLE VJ MIXER"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	sub.offset_top = -130.0
	sub.offset_bottom = -84.0
	sub.add_theme_font_size_override("font_size", 34)
	sub.add_theme_color_override("font_color", M8_GREEN)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(sub)

	var credit := Label.new()
	credit.text = "BY COLLECTIVE UNCONSCIOUS   ·   C-U.STUDIO"
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	credit.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	credit.offset_top = -72.0
	credit.offset_bottom = -40.0
	credit.add_theme_font_override("font", _font_label)   # the wide-tracked micro caps
	credit.add_theme_font_size_override("font_size", 16)
	credit.add_theme_color_override("font_color", M8_LABEL)
	credit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(credit)

	# A tap ends it early (the clip keeps playing under the fade).
	bg.gui_input.connect(func(ev: InputEvent) -> void:
		if (ev is InputEventScreenTouch or ev is InputEventMouseButton) and ev.is_pressed():
			_end_splash(layer, bg))

	if video == null:
		_splash_tween = create_tween()
		_splash_tween.tween_interval(SPLASH_STILL_HOLD)   # long enough to read the credit (2026-09-30)
		_splash_tween.tween_callback(_end_splash.bind(layer, bg))
		return

	# The clip: the labels wait for PVJ. The decoder opens on a worker and
	# playback_started fires from the frame it is picked up on; the still is
	# what shows until then.
	sub.modulate.a = 0.0
	credit.modulate.a = 0.0
	var started := [false]
	video.playback_started.connect(func() -> void:
		if started[0] or not is_instance_valid(layer):
			return
		started[0] = true
		_splash_tween = create_tween()
		_splash_tween.tween_interval(SPLASH_WORD_AT)
		_splash_tween.tween_property(sub, "modulate:a", 1.0, SPLASH_LABELS_IN)
		_splash_tween.parallel().tween_property(credit, "modulate:a", 1.0, SPLASH_LABELS_IN)
		_splash_tween.tween_interval(SPLASH_CLIP_LEN - SPLASH_WORD_AT - SPLASH_LABELS_IN + SPLASH_READ)
		_splash_tween.tween_callback(_end_splash.bind(layer, bg)))
	# The clip never opened (a broken file, a decoder that would not start):
	# the old splash, labels and all, so the launch is never stuck here.
	get_tree().create_timer(SPLASH_OPEN_TIMEOUT).timeout.connect(func() -> void:
		if started[0] or not is_instance_valid(layer):
			return
		started[0] = true
		push_warning("[splash] clip did not start in %.1f s: %s" % [SPLASH_OPEN_TIMEOUT, clip])
		video.queue_free()
		sub.modulate.a = 1.0
		credit.modulate.a = 1.0
		_splash_tween = create_tween()
		_splash_tween.tween_interval(SPLASH_STILL_HOLD)
		_splash_tween.tween_callback(_end_splash.bind(layer, bg)))
	video.set_video_path(clip)


## Fade the splash out and free it (modulate cascades to the labels and the
## clip). Idempotent: the tap, the timer and the tween may all call it.
func _end_splash(layer: CanvasLayer, bg: ColorRect) -> void:
	if not is_instance_valid(layer) or bg.has_meta("ending"):
		return
	bg.set_meta("ending", true)
	if _splash_tween != null and _splash_tween.is_valid():
		_splash_tween.kill()
	_splash_tween = create_tween()
	_splash_tween.tween_property(bg, "modulate:a", 0.0, SPLASH_FADE)
	_splash_tween.tween_callback(layer.queue_free)
	_splash_tween.tween_callback(BootTiming.mark.bind("splash gone — interactive"))


# --- Misc ----------------------------------------------------------------

## The OUTPUT pixel space — the fixed OutputWorld resolution. Warp corners,
## mask points and their presets all live here. (Before the OutputWorld move
## this returned the phone window size; the name kept its meaning.)
func _output_size() -> Vector2:
	return _output_px


# Cached so the 60 Hz path never calls get_viewport_rect().
# _cached_size is refreshed in _on_resize, which is the only time it can change.
func _ui_size() -> Vector2:
	if _cached_size == Vector2.ZERO:
		_cached_size = get_viewport_rect().size
	return _cached_size


## Output px -> screen px for the preview: uniform scale + centering offset,
## matching the preview TextureRect's stretch mode. FIT = min-scale (KEEP_ASPECT_
## CENTERED); COVER = max-scale (KEEP_ASPECT_COVERED, offset goes negative as the
## cropped band overflows). The editors route touches and overlay drawing through
## this, so warp/mask handles land on the same pixels the preview shows — in COVER
## the corners in the cropped top/bottom band sit just off-screen (switch to FIT to
## grab them precisely).
func _output_to_screen() -> Transform2D:
	var ui := _ui_size()
	var s := maxf(ui.x / _output_px.x, ui.y / _output_px.y) if _preview_covers() \
		else minf(ui.x / _output_px.x, ui.y / _output_px.y)
	var off := (ui - _output_px * s) * 0.5
	return Transform2D(0.0, Vector2(s, s), 0.0, off)


## The phone's view of the output: an aspect-fit TextureRect at the BOTTOM of
## the UI layer (below all chrome). MOUSE_FILTER_IGNORE — it must never eat a
## tap; input still lands on the chrome and the 3-finger gesture in _input.
func _build_preview() -> void:
	_preview = TextureRect.new()
	_preview.texture = output_world.get_texture()
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_preview_fill()   # FIT or COVER per the restored display + fill mode
	ui_layer.add_child(_preview)
	ui_layer.move_child(_preview, 0)
	# The chrome container sits above the preview; all UI construction parents
	# into it (via _ui_add and the browser/grid call sites). Itself transparent
	# to input — children keep their own mouse filters.
	_chrome_layer = Control.new()
	_chrome_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_chrome_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chrome_layer.theme = _theme
	ui_layer.add_child(_chrome_layer)
	status.reparent(_chrome_layer)   # the status flash is chrome too


func _on_resize() -> void:
	# The nav bar, sidebar panels and status bar are all ANCHORED (and the
	# preview re-fits itself), so they follow the viewport on their own — only
	# the hand-positioned bits need fixing up. The output is a FIXED 1920x1080
	# and never tracks the window.
	_cached_size = get_viewport_rect().size   # the one place the cache is refreshed
	_position_fader()   # repositions the FX fader + meter + label pair


func _on_clips_ready(count: int) -> void:
	_load_playlist_order()   # restore saved play order before the first clip plays
	# ClipEngine plays start_index right after this signal: point it at the saved
	# clip by key when that clip is here (the index is the fallback).
	if _saved_clip_key != "":
		var p := Storage.resolve(clip_engine.clips_dir, _saved_clip_key)
		var i := clip_engine.clips.find(p) if p != "" else -1
		if i >= 0:
			clip_engine.start_index = i
	_flash_status("%d CLIP(S) LOADED" % count)


func _on_clip_changed(clip_name: String, index: int, count: int) -> void:
	BootTiming.mark("first clip on the deck")
	if _lbl_clip != null:
		_lbl_clip.text = "CLIP %d/%d · %s" % [index + 1, count, clip_name]
	_osc_out_clip = clip_name   # /pvj/out/clip echo (change-detected downstream)
	_settings_dirty = true   # remember the active clip (debounced flush)
	_update_idle_output()
	_push_clip_to_hdmi(index)


# Push the active clip to the HDMI Presentation (raw, looped, muted). No-op in
# MIRROR mode (_hdmi_enabled false) — there Android mirrors the phone instead.
func _push_clip_to_hdmi(index: int) -> void:
	if _hdmi != null and _hdmi_enabled and clip_engine.clips.is_empty() and _idle_enabled:
		# DUAL·PLAYER with nothing to play: ExoPlayer loops the ident instead.
		var idle := Storage.idle_clip_path()
		if idle != "":
			_hdmi.playOnHdmi(idle)
			_hdmi_presentation_active = true
		return
	if _hdmi != null and _hdmi_enabled and index >= 0 and index < clip_engine.clips.size():
		_hdmi.playOnHdmi(clip_engine.clips[index])
		# Once a Presentation exists, the external display is claimed into "extend"
		# mode and won't revert to mirroring without an HDMI replug — remember this
		# so MIRROR can warn the user (see _set_display_mode).
		_hdmi_presentation_active = true


# On resume, re-assert the HDMI clip (the Presentation may have been torn down).
# On pause/close, flush settings immediately so nothing is lost when backgrounded.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		# Files copied in while PVJ was in the background (a file manager, a
		# USB cable): one cheap stamp query, a rescan only when it moved.
		if Storage.folder_changed_since_scan():
			_rescan()
		_update_idle_output()
		_push_clip_to_hdmi(clip_engine.current_index)   # no-op unless DUAL·PLAYER
		# DUAL·TEX: the Kotlin side rebuilds its Presentation itself on resume,
		# but if Godot's GL context was recreated the texture name changed —
		# re-send it (harmless when unchanged).
		if _tex_output_active:
			_send_output_texture()
	elif what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _settings_dirty:
			_settings_dirty = false
			_save_settings()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_requested()


# --- Android BACK (S24 §3) -----------------------------------------------
#
# BACK USED TO QUIT POCKETVJ INSTANTLY, from anywhere, with no confirmation —
# mid-dialog, mid-set, output and all. SceneTree.quit_on_go_back defaults to true
# and quits AFTER propagating the notification, so this handler only reaches the
# app at all because project.godot turns that default off. Both halves are the fix;
# neither works alone.
#
# THE RULE: BACK ALWAYS DOES THE SAFE THING. It dismisses the topmost thing that is
# open and one level at a time; it never commits a value, never deletes, and never
# quits. On the bare deck it does nothing but say so — Home and Recents still leave
# the app the normal way.
func _on_back_requested() -> void:
	# 1. Performance mode hides ALL chrome, so nothing below this line is even on
	#    screen to be dismissed — it has to come first. Gives perf mode a second way
	#    out beside the three-finger tap, which is worth having on its own.
	if _perf_mode:
		_exit_perf()
		_flash_status("UI RESTORED")
		return

	# 2. Any modal box, wherever it is parented — the deck, the mask editor, the clip
	#    browser. Dismiss is CANCEL (see M8Dialog.dismiss), so BACK on SET BPM never
	#    sets a tempo and BACK on REMOVE CLIP never removes a clip.
	var dlg := _topmost_dialog()
	if dlg != null:
		dlg.dismiss()
		return

	# 3+4. The full-screen editors unwind themselves — they own their sub-state (NUM
	#      panels, the mask picker, the full-screen canvas), so the ladder ends here
	#      and handle_back() decides how deep the press goes.
	if _calib != null and _calib.active:
		_calib.handle_back()
		return
	if _warp != null and _warp.active:
		_warp.handle_back()
		return
	if _region_editor != null and _region_editor.active:
		_region_editor.handle_back()
		return

	# 5. The stacked overlays. Every one of these raises itself with
	#    move_child(x, -1) when shown, so CHILD ORDER IS DRAW ORDER and the highest
	#    visible index is the one the performer is actually looking at. Resolving by
	#    stacking instead of a fixed priority is what makes a browser opened on top of
	#    the grid close first — a hard-coded order would guess wrong half the time.
	var top := _topmost_overlay()
	if top != null:
		if top == _clip_grid:
			_clip_grid.handle_back()   # armed CURATE disarms before the grid closes
		else:
			top.hide()                 # every browser self-wires the same on its Close
		return

	# 6. The docked sidebars (MODE / FX / LIBRARY). _close_panels also un-highlights
	#    the nav cell, so the bar can't be left claiming a panel that is gone.
	if (_mode_panel != null and _mode_panel.visible) \
			or (_fx_panel != null and _fx_panel.visible) \
			or (_params_panel != null and _params_panel.visible):
		_close_panels()
		return

	# 7. The bare deck: NOTHING HAPPENS. Silence would be indistinguishable from a
	#    hang, so the status line says the button is dead on purpose — but no dialog
	#    goes over the live output, and there is no path from here to a quit.
	_flash_status("BACK IS DISABLED — HOME OR RECENTS TO LEAVE")


## The dialog on top, or null. M8Dialogs join M8Dialog.GROUP on build, which is what
## lets this find boxes parented to the mask editor and the clip browser rather than
## only the deck's own. Group order follows tree order, so the LAST live one is the
## most recently opened; the queued-for-deletion check keeps a box that was dismissed
## this same frame from swallowing the press.
func _topmost_dialog() -> M8Dialog:
	var found: M8Dialog = null
	for n in get_tree().get_nodes_in_group(M8Dialog.GROUP):
		var d := n as M8Dialog
		if d != null and is_instance_valid(d) and not d.is_queued_for_deletion():
			found = d
	return found


## The visible overlay drawn on top, or null. All of these are siblings in
## _chrome_layer, so get_index() ranks them by draw order — see the note in
## _on_back_requested about why the stacking is the authority here.
func _topmost_overlay() -> Control:
	var best: Control = null
	var best_index := -1
	for c: Control in [_clip_grid, _clip_browser, _drive_browser, _local_browser,
			_rec_browser, _mask_browser]:
		if c != null and is_instance_valid(c) and c.visible and c.get_index() > best_index:
			best = c
			best_index = c.get_index()
	return best


# --- Settings persistence (user://settings.cfg) --------------------------

func _flush_settings(delta: float) -> void:
	# Debounced write: coalesce rapid changes (e.g. auto clip switching) to ≤1/1.5 s.
	if not _settings_dirty:
		return
	_settings_accum += delta
	if _settings_accum >= 1.5:
		_settings_accum = 0.0
		_settings_dirty = false
		_save_settings()


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	# LOAD FIRST, then overwrite. A fresh ConfigFile writes ONLY the keys below,
	# so every key this function doesn't know about is dropped on the next save —
	# which is how settings.cfg has been clobbered before. The error is ignored on
	# purpose: first run has no file, and an unreadable one must not block the
	# save. Every key set below is overwritten anyway, so nothing stale survives.
	cfg.load(SETTINGS_PATH)
	cfg.set_value("deck", "mode", _mode)
	cfg.set_value("deck", "bpm", BeatClock.bpm)
	cfg.set_value("deck", "effect", _effect_index)
	cfg.set_value("deck", "clip", clip_engine.current_index)
	# The playing clip by KEY too: an index names another clip as soon as the
	# library changes (an import, a clip still missing). Boot prefers the key.
	if clip_engine.current_index >= 0 and clip_engine.current_index < clip_engine.clips.size():
		cfg.set_value("deck", "clip_key", Storage.rel(clip_engine.clips[clip_engine.current_index]))
	cfg.set_value("deck", "audio_switch", _audio_switch_enabled)
	cfg.set_value("deck", "audio_sens", _audio_sensitivity)
	cfg.set_value("deck", "audio_gain", _audio_gain)
	cfg.set_value("deck", "audio_floor", _audio_floor)
	cfg.set_value("deck", "display_mode", _display_mode)
	cfg.set_value("deck", "dual_feed", _dual_feed)
	cfg.set_value("deck", "mirror_fill", _mirror_fill)
	cfg.set_value("deck", "ui_flip", _ui_flipped)
	cfg.set_value("deck", "idle_screen", _idle_enabled)
	# A camera-keystone calibration BORROWS the camera source; what persists is
	# the source the deck had before it.
	cfg.set_value("deck", "source", _calib_prev_source if _calib_prev_source >= 0 else _source)
	cfg.set_value("deck", "speed_on", _speed_ramp_enabled)
	cfg.set_value("deck", "speed_max", _speed_max)
	cfg.set_value("deck", "quality", _quality)
	cfg.set_value("rec", "segment_minutes", _rec_seg_minutes)
	cfg.set_value("rec", "audio", _rec_audio)
	cfg.set_value("ddp", "enabled", _ddp_enabled)
	cfg.set_value("ddp", "target_ip", _ddp_target_ip)
	cfg.set_value("ddp", "send_fps", _ddp_send_fps)
	cfg.set_value("ddp", "fit_mode", _ddp_fit_mode)
	cfg.set_value("ddp", "source", _ddp_source)
	cfg.set_value("ddp", "life_rate", _life_rate)
	cfg.set_value("link", "enabled", _link_enabled)
	cfg.set_value("link", "role", _link_role)
	cfg.set_value("link", "name", _link_name)
	cfg.set_value("link", "auto_pull_cam", _link_auto_pull_cam)
	cfg.set_value("link", "layer_alpha", _link_layer_alpha)
	cfg.set_value("link", "peer_alpha", _peer_alpha)   # 3.3: ONE dict — names carry spaces ("Pixel 9a"), cfg keys cannot
	cfg.set_value("link", "debug_counter", _link_debug_counter)
	# The SETTING, not the effective codec — a phone whose plugin was missing
	# must keep asking for h264 so the next (fixed) APK honours the choice.
	cfg.set_value("link", "codec", _link_codec)
	cfg.set_value("link", "phase_trim_ms", _phase_trim_ms)
	cfg.set_value("link", "srt_latency_ms", _srt_latency_ms)
	cfg.set_value("osc", "enabled", _osc_enabled)
	cfg.set_value("osc", "port", _osc_port)
	cfg.set_value("osc", "out_enabled", _osc_out_enabled)
	cfg.set_value("osc", "out_targets", _osc_out_targets)
	cfg.set_value("osc", "out_rate_hz", _osc_out_rate)
	cfg.set_value("tracking", "enabled", _track_enabled)
	cfg.set_value("tracking", "lens", _track_lens)
	cfg.set_value("tracking", "zoom", _track_zoom)
	cfg.set_value("tracking", "crowd_slots", _track_crowd_slots)
	cfg.set_value("tracking", "ae_lock", _track_ae_lock)
	cfg.set_value("tracking", "exposure", _track_exposure)
	cfg.set_value("tracking", "torch", _track_torch)
	cfg.set_value("tracking", "filter_min_cutoff", _track_cutoff)
	cfg.set_value("tracking", "filter_beta", _track_beta)
	cfg.set_value("tracking", "inference_hz", _track_hz)
	cfg.set_value("tracking", "hands", _track_hands)
	cfg.set_value("tracking", "hands_only", _track_hands_only)
	# Same setting-not-outcome rule: "gpu" survives a fallback to the CPU
	# feed, so the next start (or APK) re-attempts the fast path.
	cfg.set_value("link", "encoder_feed", _link_encoder_feed)
	# Sequencer 2.0 (SEQ2 §3.7) — repays the standing beats_per_slot debt (R6).
	cfg.set_value("seq", "lane_a_bps", _lane_a.beats_per_slot)
	cfg.set_value("seq", "lane_b_bps", _lane_b.beats_per_slot)
	cfg.set_value("seq", "lane_b_armed", _lane_b_armed)
	cfg.set_value("seq", "lane_b_auto", _lane_b.auto)
	cfg.set_value("seq", "lane_b_bar_offset", _lane_b.bar_offset)
	cfg.set_value("seq", "lane_b_source", _lane_b_source)
	cfg.set_value("seq", "xfade", _xfade)
	cfg.set_value("seq", "xfade_mode", _xfade_mode)
	cfg.set_value("seq", "xfade_every", _xfade_every_idx)
	cfg.set_value("seq", "xfade_switch", _xfade_switch_idx)
	cfg.set_value("seq", "xfade_lfo", _xfade_lfo_bars_idx)
	# Flat scalar keys per slot rather than one packed array: a missing or damaged
	# key then falls back for THAT slot only instead of taking the whole matrix
	# with it, and it matches how every other tunable in this file is stored.
	cfg.set_value("mod", "enabled", _mod_enabled)
	cfg.set_value("mod", "base", _mod_base)
	cfg.set_value("mod", "master", _mod_master)
	for i in MOD_SLOTS:
		var s: Dictionary = _mod_slots[i]
		cfg.set_value("mod", "slot%d_src" % i, int(s["src"]))
		cfg.set_value("mod", "slot%d_depth" % i, float(s["depth"]))
		cfg.set_value("mod", "slot%d_pol" % i, int(s["pol"]))
		cfg.set_value("mod", "slot%d_dst" % i, int(s.get("dst", ModTarget.INTENSITY)))
		cfg.set_value("mod", "slot%d_curve" % i, int(s.get("curve", ModCurve.LIN)))
	cfg.set_value("deck", "audio_band", _audio_band)
	cfg.set_value("help", "tour_seen", _tour_seen)
	# BEAT FLIP. Runtime state (_flip_state, _flip_count, the hold) is deliberately
	# absent — it is a live animation, and restoring a frozen frame of one is the
	# same mistake as persisting an effect's `intensity`.
	cfg.set_value("flip", "enabled", _flip_enabled)
	cfg.set_value("flip", "div", _flip_div_index)
	cfg.set_value("flip", "mode", _flip_mode)
	cfg.set_value("flip", "axis", _flip_axis)
	cfg.set_value("flip", "trig", _flip_trig)
	cfg.set_value("flip", "source", _flip_source)
	cfg.set_value("flip", "treatment", _flip_treatment)
	cfg.set_value("flip", "rotate", _flip_rotate)
	cfg.set_value("flip", "rot_what", _flip_rot_what)
	# Glitch CHARACTER controls (its own section — these are effect flavour, not
	# deck state). `intensity` is deliberately absent: it is the modulated value,
	# so persisting it would restore a frozen frame of an animation.
	cfg.set_value("glitch", "block_count", _glitch_block_count)
	cfg.set_value("glitch", "block_size", _glitch_block_size)
	cfg.set_value("glitch", "block_aspect", _glitch_block_aspect)
	# Bloom character controls — same reasoning as [glitch]: flavour, not deck
	# state, and `intensity` stays out because it is the modulated value.
	cfg.set_value("bloom", "threshold", _bloom_threshold)
	cfg.set_value("bloom", "radius", _bloom_radius)
	cfg.set_value("displace", "scale", _displace_scale)
	cfg.set_value("displace", "speed", _displace_speed)
	cfg.set_value("displace", "pattern", _displace_pattern)
	cfg.set_value("trails", "decay", _trails_decay)
	cfg.set_value("trails", "blend", _trails_blend)
	cfg.set_value("slitscan", "direction", _slitscan_direction)
	cfg.set_value("slitscan", "span", _slitscan_span)
	cfg.set_value("solarize", "mode", _solarize_mode)
	cfg.set_value("solarize", "threshold", _solarize_threshold)
	cfg.save(SETTINGS_PATH)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return   # first run — keep defaults
	_mode = clampi(int(cfg.get_value("deck", "mode", _mode)), 0, MODE_NAMES.size() - 1)
	BeatClock.set_bpm(float(cfg.get_value("deck", "bpm", BeatClock.bpm)))   # setter clamps
	_effect_index = clampi(int(cfg.get_value("deck", "effect", _effect_index)), 0, _effects.size() - 1)
	_saved_clip_index = maxi(0, int(cfg.get_value("deck", "clip", 0)))
	_saved_clip_key = str(cfg.get_value("deck", "clip_key", ""))
	_audio_switch_enabled = bool(cfg.get_value("deck", "audio_switch", _audio_switch_enabled))
	# NOTE: deliberately a NEW key. The old "audio_thr" was an absolute mic level
	# (0.05..1.0); reading it as a ratio would silently mis-tune every existing install.
	_set_audio_sensitivity(float(cfg.get_value("deck", "audio_sens", _audio_sensitivity)))
	_set_audio_gain(float(cfg.get_value("deck", "audio_gain", _audio_gain)))
	_set_audio_floor(float(cfg.get_value("deck", "audio_floor", _audio_floor)))
	_display_mode = clampi(int(cfg.get_value("deck", "display_mode", _display_mode)), 0, DISPLAY_MODE_NAMES.size() - 1)
	_dual_feed = clampi(int(cfg.get_value("deck", "dual_feed", _dual_feed)), 0, DUAL_FEED_NAMES.size() - 1)
	_mirror_fill = clampi(int(cfg.get_value("deck", "mirror_fill", _mirror_fill)), 0, MIRROR_FILL_NAMES.size() - 1)
	# Absent key -> false = upright, which IS the pre-flip behaviour. A
	# settings.cfg written by any previous build therefore starts unrotated, and
	# only an explicit toggle changes that.
	_ui_flipped = bool(cfg.get_value("deck", "ui_flip", _ui_flipped))
	_idle_enabled = bool(cfg.get_value("deck", "idle_screen", _idle_enabled))
	_source = clampi(int(cfg.get_value("deck", "source", _source)), 0, SOURCE_NAMES.size() - 1)
	if _source == ClipSource.DRIVE:
		_source = ClipSource.VIDEO   # not offered any more; the clips are VIDEO
	_speed_ramp_enabled = bool(cfg.get_value("deck", "speed_on", _speed_ramp_enabled))
	_speed_max = clampf(float(cfg.get_value("deck", "speed_max", _speed_max)), 1.0, SPEED_MAX_CEIL)
	_quality = clampi(int(cfg.get_value("deck", "quality", _quality)), 0, QUALITY_NAMES.size() - 1)
	_rec_seg_minutes = clampi(int(cfg.get_value("rec", "segment_minutes", _rec_seg_minutes)),
		REC_SEG_MIN_LO, REC_SEG_MIN_HI)
	_rec_audio = bool(cfg.get_value("rec", "audio", _rec_audio))
	# A settings.cfg with no [ddp] section keeps the panel OFF rather than
	# inheriting whatever the last field build left — same rule the [flip]
	# section follows, and the one that matters most here: enabling an output
	# nobody asked for costs two viewport passes and a readback per frame.
	_ddp_enabled = bool(cfg.get_value("ddp", "enabled", _ddp_enabled))
	var ddp_ip := str(cfg.get_value("ddp", "target_ip", _ddp_target_ip))
	# Refuse a corrupt address on LOAD too, not just at the prompt — a hand-edited
	# or truncated settings.cfg would otherwise send every frame into nowhere with
	# no error, since UDP never reports a bad destination.
	if ddp_ip.is_valid_ip_address():
		_ddp_target_ip = ddp_ip
	else:
		push_warning("[ddp] ignoring invalid target_ip in settings.cfg: %s" % ddp_ip)
	_ddp_send_fps = clampf(float(cfg.get_value("ddp", "send_fps", _ddp_send_fps)), 1.0, 60.0)
	# clamped, not trusted: an out-of-range index would silently pick no branch in
	# _stretch_for() and land on SQUASH anyway, but by then the button label and
	# the actual behaviour would disagree.
	_ddp_fit_mode = clampi(int(cfg.get_value("ddp", "fit_mode", _ddp_fit_mode)),
		0, DDP_FIT_NAMES.size() - 1)
	_ddp_source = clampi(int(cfg.get_value("ddp", "source", _ddp_source)),
		0, DDP_SOURCE_NAMES.size() - 1)
	_life_rate = clampi(int(cfg.get_value("ddp", "life_rate", _life_rate)),
		0, LIFE_RATE_NAMES.size() - 1)
	# Same OFF-by-default rule as [ddp]: no [link] section, no sockets, no
	# threads, no beacon on the network. role is validated because an unknown
	# role would beacon fine but wire nothing locally — a silent half-peer.
	_link_enabled = bool(cfg.get_value("link", "enabled", _link_enabled))
	var link_role := str(cfg.get_value("link", "role", _link_role))
	if link_role in ["main", "cam"]:
		_link_role = link_role
	else:
		push_warning("[link] ignoring unknown role in settings.cfg: %s" % link_role)
	_link_name = str(cfg.get_value("link", "name", _link_name))
	_link_auto_pull_cam = bool(cfg.get_value("link", "auto_pull_cam", _link_auto_pull_cam))
	_link_layer_alpha = clampf(float(cfg.get_value("link", "layer_alpha", _link_layer_alpha)), 0.0, 1.0)
	# Stage 3.3 per-peer levels. Type-checked, never cast: a hand-edited or
	# foreign value degrades to "no saved levels" instead of throwing at boot.
	var pa: Variant = cfg.get_value("link", "peer_alpha", {})
	_peer_alpha.clear()
	if pa is Dictionary:
		for k in pa:
			_peer_alpha[str(k)] = clampf(float(pa[k]), 0.0, 1.0)
	_link_debug_counter = bool(cfg.get_value("link", "debug_counter", _link_debug_counter))
	# N4 slave law: the measured one-way delivery bias (S3: ~15 ms on this
	# WiFi). Set once with the latency stamp, then owned by cfg.
	_phase_trim_ms = clampf(float(cfg.get_value("link", "phase_trim_ms", _phase_trim_ms)),
		-200.0, 200.0)
	# §9-M8: the SRT ARQ window. Clamped to the plugin's own bounds so the
	# cfg and the Kotlin coerceIn can never disagree about what was applied.
	_srt_latency_ms = clampi(int(cfg.get_value("link", "srt_latency_ms", _srt_latency_ms)),
		10, 4000)
	_osc_enabled = bool(cfg.get_value("osc", "enabled", _osc_enabled))
	# S4 runs (read-only — see _s4_run). s4_delay lets the rig settle first:
	# streams connect, lane B's arm restore lands, shader caches warm.
	_s4_run = str(cfg.get_value("perf", "s4_run", ""))
	_s4_secs = clampf(float(cfg.get_value("perf", "s4_secs", 600.0)), 10.0, 3600.0)
	_s4_delay = clampf(float(cfg.get_value("perf", "s4_delay", 20.0)), 0.0, 600.0)
	_osc_port = clampi(int(cfg.get_value("osc", "port", _osc_port)), 1024, 65535)
	_osc_out_enabled = bool(cfg.get_value("osc", "out_enabled", _osc_out_enabled))
	_osc_out_targets = str(cfg.get_value("osc", "out_targets", _osc_out_targets))
	_osc_out_rate = clampi(int(cfg.get_value("osc", "out_rate_hz", _osc_out_rate)), 1, 60)
	_track_enabled = bool(cfg.get_value("tracking", "enabled", _track_enabled))
	_track_lens = "front" if str(cfg.get_value("tracking", "lens", _track_lens)) == "front" else "rear"
	# Publish-path rotation offset (M6 orientation), added to whatever CameraX
	# reports. ⚠️ 270 is MEASURED, not derived: on the P8 CameraX reports
	# rotationDegrees=0 while the SurfaceTexture matrix carries a 90° turn of
	# its own ((u,v)->(v,1-u), read off the device), and the deck samples in a
	# space where the net of the two is still a quarter turn out. A four-value
	# sweep with the beat-flip effect DISABLED (it has its own rotate stage and
	# will lie to you) put both lenses upright at 270 — front and rear alike,
	# so this needs no per-lens branch the way the viewer's spin does.
	# Settings-tunable because the next phone may well disagree.
	_track_pub_rot = int(cfg.get_value("tracking", "publish_rot", 270)) % 360
	_track_crowd_spike = bool(cfg.get_value("tracking", "crowd_spike", false))
	_track_delegate = "gpu" if str(cfg.get_value("tracking", "delegate", "cpu")) == "gpu" else "cpu"
	_track_crowd_model = str(cfg.get_value("tracking", "crowd_model", "edl0_int8"))
	# 720 is now MEASURED, not assumed (§13.7.1a, 2026-09-10): against a
	# ground truth of 2 people it detected 2.2 at confidence 0.62, where 480
	# under-detected at 1.7 and 1080 REGRESSED to 1.9 while costing latency.
	# The curve flattens at 720. It also doubled the landmark path's usable
	# range (0.8-1 m -> 2 m, operator-verified) for 16% throughput.
	_track_analysis_res = int(cfg.get_value("tracking", "analysis_res", 720))
	_track_crowd_score = clampf(float(cfg.get_value("tracking", "crowd_min_conf", 0.4)), 0.05, 0.9)
	_track_zoom = clampf(float(cfg.get_value("tracking", "zoom", 1.0)), 1.0, 10.0)
	_track_pub_mirror = int(cfg.get_value("tracking", "publish_mirror", 0))
	_track_crowd_osc_slots = bool(cfg.get_value("tracking", "crowd_osc_slots", false))
	_track_crowd_slots = clampi(int(cfg.get_value("tracking", "crowd_slots", 6)), 1, 8)
	_track_crowd_field_compat = bool(cfg.get_value("tracking", "crowd_field_compat", true))
	_crowd_fx_flip = bool(cfg.get_value("tracking", "crowd_fx_flip", false))
	_track_ae_lock = bool(cfg.get_value("tracking", "ae_lock", false))
	_track_exposure = int(cfg.get_value("tracking", "exposure", 0))
	_track_torch = bool(cfg.get_value("tracking", "torch", false))
	_track_camera_only = bool(cfg.get_value("tracking", "camera_via_camerax", false))
	# §13.6 tracker knobs. Applied to the live tracker so a settings reload
	# retunes it without a session rebuild — slots alone reallocates the
	# bank and therefore loses identities, which is why §13.6 marks it
	# restart-only and why it is applied first.
	if _tracking != null:
		var ct := _tracking.crowd
		var want_slots := clampi(int(cfg.get_value("tracking", "crowd_slots", 6)), 1, 8)
		if want_slots != ct.slots:
			ct.set_slots(want_slots)
		ct.min_conf = _track_crowd_score
		ct.max_jump = clampf(float(cfg.get_value("tracking", "crowd_max_jump", 0.18)), 0.02, 0.9)
		ct.acquire_frames = clampi(int(cfg.get_value("tracking", "crowd_acquire_frames", 4)), 1, 30)
		ct.grace_ms = clampi(int(cfg.get_value("tracking", "crowd_grace_ms", 900)), 0, 10000)
		ct.cooldown_ms = clampi(int(cfg.get_value("tracking", "crowd_slot_cooldown_ms", 1500)), 0, 20000)
		ct.energy_gain = clampf(float(cfg.get_value("tracking", "crowd_energy_gain", 6.0)), 0.1, 50.0)
		ct.filter_min_cutoff = _track_cutoff
		ct.filter_beta = _track_beta
	if _track_camera != null:
		_track_camera.rot_offset = _track_pub_rot
		_track_camera.mirror_override = _track_pub_mirror
	_track_cutoff = clampf(float(cfg.get_value("tracking", "filter_min_cutoff", _track_cutoff)), 0.1, 3.0)
	_track_beta = clampf(float(cfg.get_value("tracking", "filter_beta", _track_beta)), 0.0, 0.2)
	_track_hz = clampi(int(cfg.get_value("tracking", "inference_hz", _track_hz)), 5, 30)
	_track_hands = bool(cfg.get_value("tracking", "hands", _track_hands))
	_track_hands_only = bool(cfg.get_value("tracking", "hands_only", _track_hands_only))
	# [triggers] — every key in the section is a lane (§5.4); parsed into
	# TriggerLane objects at _build_trigger_lanes, after TrackingEngine
	# exists. Save-side needs nothing: _save_settings loads-then-overwrites,
	# so a section it never touches survives every save.
	if cfg.has_section("triggers"):
		for trig_key in cfg.get_section_keys("triggers"):
			_track_triggers_cfg[trig_key] = str(cfg.get_value("triggers", trig_key, ""))
	# Validated like role, and for the same reason: an unknown codec would pick
	# no body in NetSource and leave a beacon advertising a door nobody opened.
	# Absent key -> "jpeg" = the exact Stage 0 that ran before this key existed.
	var link_codec := str(cfg.get_value("link", "codec", _link_codec))
	if link_codec in LINK_CODECS:
		_link_codec = link_codec
	else:
		push_warning("[link] ignoring unknown codec in settings.cfg: %s" % link_codec)
	# Validated like codec, defaulting to "gpu": the v1 CPU readback is the
	# escape hatch (encoder_feed="cpu"), not the default — NetSender falls
	# back to it on its own when the APK or the encoder can't do the blit.
	var link_feed := str(cfg.get_value("link", "encoder_feed", _link_encoder_feed))
	if link_feed in ["gpu", "cpu"]:
		_link_encoder_feed = link_feed
	else:
		push_warning("[link] ignoring unknown encoder_feed in settings.cfg: %s" % link_feed)
	# Sequencer 2.0 (SEQ2 §3.7). Restored lane state lands in the SeqLane objects;
	# the strip picks it up at its lazy build (set_beats_per_slot push). Re-arming
	# the deck itself waits for _ready's chain wiring (_saved_lane_b_armed).
	# BPS snaps to the strip's option set so the button label and the actual
	# slot clock can never disagree (a hand-edited cfg is the only way off-set).
	_lane_a.beats_per_slot = _snap_bps(int(cfg.get_value("seq", "lane_a_bps", _lane_a.beats_per_slot)))
	_lane_b.beats_per_slot = _snap_bps(int(cfg.get_value("seq", "lane_b_bps", _lane_b.beats_per_slot)))
	_lane_b.bar_offset = clampi(int(cfg.get_value("seq", "lane_b_bar_offset", 2)), 0, 16)
	# Applied by the arm-restore path (after _build_link, so NET can bind — or
	# fall back out loud when the link is off). Clamped to the enum.
	_lane_b_source = clampi(int(cfg.get_value("seq", "lane_b_source", LaneBSource.CLIP)),
		LaneBSource.CLIP, LaneBSource.TD)
	if not Features.TD_PVJ_LINK:
		_lane_b_source = LaneBSource.CLIP
	_xfade = clampf(float(cfg.get_value("seq", "xfade", _xfade)), 0.0, 1.0)
	# Restored as saved (R6) but only to a mode this build implements — a cfg
	# from a newer build degrades to MANUAL instead of selecting a ghost.
	_xfade_mode = int(cfg.get_value("seq", "xfade_mode", _xfade_mode))
	if not XFADE_MODES_AVAILABLE.has(_xfade_mode):
		_xfade_mode = XfadeMode.MANUAL
	_xfade_every_idx = clampi(int(cfg.get_value("seq", "xfade_every", _xfade_every_idx)),
		0, XFADE_EVERY.size() - 1)
	_xfade_switch_idx = clampi(int(cfg.get_value("seq", "xfade_switch", _xfade_switch_idx)),
		0, XFADE_SWITCH.size() - 1)
	_xfade_lfo_bars_idx = clampi(int(cfg.get_value("seq", "xfade_lfo", _xfade_lfo_bars_idx)),
		0, XFADE_LFO_BARS.size() - 1)
	_saved_lane_b_armed = bool(cfg.get_value("seq", "lane_b_armed", false))
	_saved_lane_b_auto = bool(cfg.get_value("seq", "lane_b_auto", false))
	# THE MERGE PATH: every default here is the seed _mod_init_defaults() just
	# wrote, so a settings.cfg predating the matrix (no [mod] section at all)
	# leaves the deck on the legacy drive with slot 0 already reproducing it.
	_mod_enabled = bool(cfg.get_value("mod", "enabled", _mod_enabled))
	_mod_base = clampf(float(cfg.get_value("mod", "base", _mod_base)), 0.0, MOD_CEIL)
	for i in MOD_SLOTS:
		var s: Dictionary = _mod_slots[i]
		s["src"] = clampi(int(cfg.get_value("mod", "slot%d_src" % i, int(s["src"]))),
			0, MOD_SOURCE_NAMES.size() - 1)
		s["depth"] = clampf(float(cfg.get_value("mod", "slot%d_depth" % i, float(s["depth"]))),
			0.0, MOD_DEPTH_MAX)
		s["pol"] = clampi(int(cfg.get_value("mod", "slot%d_pol" % i, int(s["pol"]))),
			0, ModPolarity.INV)
		s["dst"] = clampi(int(cfg.get_value("mod", "slot%d_dst" % i, int(s.get("dst", ModTarget.INTENSITY)))),
			0, MOD_TARGET_NAMES.size() - 1)
		s["curve"] = clampi(int(cfg.get_value("mod", "slot%d_curve" % i, int(s.get("curve", ModCurve.LIN)))),
			0, MOD_CURVE_NAMES.size() - 1)
	_mod_master = clampf(float(cfg.get_value("mod", "master", _mod_master)), 0.0, 1.0)
	_audio_band = clampi(int(cfg.get_value("deck", "audio_band", _audio_band)), 0, TRIG_BAND_NAMES.size() - 1)
	_tour_seen = bool(cfg.get_value("help", "tour_seen", _tour_seen))
	# Same merge path as [mod]: every default is the in-memory one, so a
	# settings.cfg with no [flip] section keeps the feature OFF rather than
	# inventing a state for it. Clamped to the same constants the chips use, so a
	# hand-edited value can't select a chip that doesn't exist.
	_flip_enabled = bool(cfg.get_value("flip", "enabled", _flip_enabled))
	_flip_div_index = clampi(int(cfg.get_value("flip", "div", _flip_div_index)),
		0, FLIP_DIVS.size() - 1)
	_flip_mode = clampi(int(cfg.get_value("flip", "mode", _flip_mode)),
		0, FLIP_MODE_NAMES.size() - 1)
	_flip_axis = clampi(int(cfg.get_value("flip", "axis", _flip_axis)),
		0, FLIP_AXIS_NAMES.size() - 1)
	_flip_trig = clampi(int(cfg.get_value("flip", "trig", _flip_trig)),
		0, FLIP_TRIG_NAMES.size() - 1)
	# Absent key -> FlipSource.LEFT, which IS the pre-step-1 behaviour. A
	# settings.cfg written by the previous build therefore keeps its flip exactly
	# as it was, and only an explicit chip tap changes it.
	_flip_source = clampi(int(cfg.get_value("flip", "source", _flip_source)),
		0, FLIP_SOURCE_NAMES.size() - 1)
	# Absent key -> FlipTreatment.MIRROR, the pre-step-2 look.
	_flip_treatment = clampi(int(cfg.get_value("flip", "treatment", _flip_treatment)),
		0, FLIP_TREATMENT_NAMES.size() - 1)
	_flip_rotate = clampi(int(cfg.get_value("flip", "rotate", _flip_rotate)),
		0, FLIP_ROTATE_NAMES.size() - 1)
	_flip_rot_what = clampi(int(cfg.get_value("flip", "rot_what", _flip_rot_what)),
		0, FLIP_ROT_WHAT_NAMES.size() - 1)
	# Seed the cycle position from the restored treatment for the same reason
	# _set_flip_rotate does: the first rotation should move ON from what is
	# selected, not snap back to the start of the list.
	_flip_rotate_pos = maxi(0, FLIP_ROTATE_CYCLE.find(_flip_treatment))
	# Clamped to the SAME constants the sliders use, so a hand-edited or
	# out-of-range value can't put the material somewhere the UI can't reach.
	_glitch_block_count = clampf(float(cfg.get_value("glitch", "block_count",
		_glitch_block_count)), GLITCH_COUNT_MIN, GLITCH_COUNT_MAX)
	_glitch_block_size = clampf(float(cfg.get_value("glitch", "block_size",
		_glitch_block_size)), GLITCH_SIZE_MIN, GLITCH_SIZE_MAX)
	_glitch_block_aspect = clampf(float(cfg.get_value("glitch", "block_aspect",
		_glitch_block_aspect)), GLITCH_ASPECT_MIN, GLITCH_ASPECT_MAX)
	_bloom_threshold = clampf(float(cfg.get_value("bloom", "threshold",
		_bloom_threshold)), BLOOM_THRESHOLD_MIN, BLOOM_THRESHOLD_MAX)
	_bloom_radius = clampf(float(cfg.get_value("bloom", "radius",
		_bloom_radius)), BLOOM_RADIUS_MIN, BLOOM_RADIUS_MAX)
	_displace_scale = clampf(float(cfg.get_value("displace", "scale",
		_displace_scale)), DISPLACE_SCALE_MIN, DISPLACE_SCALE_MAX)
	_displace_speed = clampf(float(cfg.get_value("displace", "speed",
		_displace_speed)), DISPLACE_SPEED_MIN, DISPLACE_SPEED_MAX)
	_displace_pattern = clampi(int(cfg.get_value("displace", "pattern",
		_displace_pattern)), 0, DISPLACE_PATTERN_NAMES.size() - 1)
	_trails_decay = clampf(float(cfg.get_value("trails", "decay",
		_trails_decay)), TRAILS_DECAY_MIN, TRAILS_DECAY_MAX)
	_trails_blend = clampi(int(cfg.get_value("trails", "blend",
		_trails_blend)), 0, TRAILS_BLEND_NAMES.size() - 1)
	_slitscan_direction = clampi(int(cfg.get_value("slitscan", "direction",
		_slitscan_direction)), 0, SLITSCAN_DIR_NAMES.size() - 1)
	_slitscan_span = clampf(float(cfg.get_value("slitscan", "span",
		_slitscan_span)), SLITSCAN_SPAN_MIN, SLITSCAN_SPAN_MAX)
	_solarize_mode = clampi(int(cfg.get_value("solarize", "mode",
		_solarize_mode)), 0, SOLARIZE_MODE_NAMES.size() - 1)
	_solarize_threshold = clampf(float(cfg.get_value("solarize", "threshold",
		_solarize_threshold)), SOLARIZE_THRESHOLD_MIN, SOLARIZE_THRESHOLD_MAX)
	_hdmi_enabled = (_display_mode == DisplayMode.DUAL and _dual_feed == DualFeed.PLAYER)
	print("[settings] restored mode=%s bpm=%.0f fx=%d clip=%d aswitch=%s display=%s uiflip=%s" % [
		MODE_NAMES[_mode], BeatClock.bpm, _effect_index, _saved_clip_index,
		str(_audio_switch_enabled), _display_mode_label(), str(_ui_flipped)])
	# Audio input on its own line — it is the per-venue tuning, so it wants to be
	# greppable in a logcat when a room misbehaves.
	print("[settings] audio in: gain=%.1fx floor=%.2f sens=%.2fx" %
		[_audio_gain, _audio_floor, _audio_sensitivity])
	# Own line so "did my glitch survive the restart" is one grep, not an inference
	# from the picture.
	print("[settings] glitch: count=%.0f size=%.1f%% aspect=%.2f" %
		[_glitch_block_count, _glitch_block_size, _glitch_block_aspect])
	print("[settings] bloom: threshold=%.2f radius=%.2f%%" %
		[_bloom_threshold, _bloom_radius])
	print("[settings] displace: pattern=%s scale=%.2f speed=%.2fx" %
		[DISPLACE_PATTERN_NAMES[_displace_pattern], _displace_scale, _displace_speed])
	print("[settings] trails: blend=%s decay=%.2f" %
		[TRAILS_BLEND_NAMES[_trails_blend], _trails_decay])
	print("[settings] slitscan: direction=%s span=%.0f frames (=%.0f strips)" %
		[SLITSCAN_DIR_NAMES[_slitscan_direction], _slitscan_span, _slitscan_span])
	print("[settings] solarize: mode=%s threshold=%.2f" %
		[SOLARIZE_MODE_NAMES[_solarize_mode], _solarize_threshold])


func _on_clip_missing(_searched_dir: String) -> void:
	status.visible = true
	if _lbl_clip != null:
		_lbl_clip.text = "NO CLIPS"   # not the last folder's "CLIP n/N · name"
	_update_idle_output()
	if Storage.available():
		status.text = ("NO CLIPS IN %s\n\nLIB ▸ SOURCES & LIBRARY ▸ LOAD DEMO CLIPS,\n"
			+ "IMPORT CLIPS, IMPORT FOLDER OR IMPORT PACK (.ZIP).") % Storage.folder_label()
	else:
		status.text = "NO CLIPS FOUND IN:\n%s\n\nCOPY .MP4 FILES THERE, THEN RESCAN." \
				% ProjectSettings.globalize_path(_searched_dir)


# Show a status message, then hide it (unless superseded by a newer message).
# A deck skipped a clip that never opened (ClipEngine.OPEN_TIMEOUT_SEC): the grid
# says CAN'T PLAY, like a clip whose thumbnail never came.
func _on_clip_failed(path: String) -> void:
	ThumbnailService.mark_failed(ClipLibrary.id_for_path(path))
	_flash_status("CAN'T PLAY %s — SKIPPED" % path.get_file().get_basename().to_upper())


func _flash_status(text: String) -> void:
	status.visible = true
	status.text = text   # callers pass UPPERCASE; filenames keep their own case
	_status_token += 1
	var token := _status_token
	await get_tree().create_timer(2.5).timeout
	if token == _status_token:
		status.visible = false
