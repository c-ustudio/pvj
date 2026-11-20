extends Node
## GlobalBus — audio-reactive hub for PocketVJ.
##
## Captures mic / line-in (USB-C audio adapters present as the mic input) via an
## AudioEffectCapture on a dedicated, muted bus, computes a smoothed level + a
## simple beat pulse, and exposes them so any node (e.g. the ShaderSlot effects)
## can react without tight coupling. Poll `level`/`pulse` each frame, or connect
## to `beat` for onset-synced events.
##
## Requires `audio/driver/enable_input = true` (project.godot) and, on Android,
## the RECORD_AUDIO permission (granted via OS.request_permissions()).

signal beat                       ## emitted on a detected onset/beat
## An onset in ONE band (BAND_LOW / BAND_MID / BAND_HIGH): the kick, the body,
## the hats — AUDIO_REACTIVITY_SPEC.md §6.2. Same ratio test as `beat`, on
## that band's own envelope, with its own cooldown.
signal band_beat(band: int)
signal level_changed(value: float)
## Raw mic PCM for the set recorder — interleaved float32 stereo, exactly as the
## capture effect delivered it. Emitted only while `capture_pcm` is on.
## `pad_frames` is how many frames the capture ring DISCARDED since the last
## emit, so the recorder can fill the hole with precisely that much silence.
signal pcm_captured(pcm: PackedByteArray, frames: int, pad_frames: int)
## The mic went live (true) or a request for it was refused (false).
signal mic_state_changed(active: bool)

const INPUT_BUS_NAME := "MicCapture"
## The default 0.1 s ring is one GoZen clip-open away from overrunning — the
## Session-22 soak logged the deck stalling the main thread for >100 ms. An
## overrun is a permanent hole in a recording, so buy slack; the cost is a
## slightly larger buffer and nothing else.
const CAPTURE_BUFFER_SEC := 0.5

## Smoothed input level, ~0..1 (post-gain, clamped).
var level: float = 0.0
## Beat flash: jumps to 1.0 on each detected beat, eases back to 0.
var pulse: float = 0.0

# --- The analyser (spec §6.2) -----------------------------------------------
# Band envelopes, a hit follower and a brightness, all 0..1, all read per frame
# by the mod matrix. From the spectrum analyser that already sits on the mic
# bus for tempo detection — no second mic client, no extra capture.
#
# ⚠️ SELF-NORMALISED, ON PURPOSE. A band's raw magnitude depends on the room,
# the mic, the gain and the genre; a slider per band would be three more
# things to set per venue, blind. Instead each band is read against its OWN
# recent peak (a maximum that decays over PEAK_RELEASE_SEC): a kick makes
# `low` ~1.0 whether the room is loud or quiet, because the reference is the
# last kick. `level` stays as it was (absolute, gained) — it is what the
# legacy drive and the onset detector are measured against.
enum { BAND_LOW, BAND_MID, BAND_HIGH }
const BAND_HZ := [[20.0, 150.0], [150.0, 2000.0], [2000.0, 10000.0]]
## Log-spaced bands for the brightness centroid: 40 Hz to 10 kHz, one octave each.
const CENTROID_HZ := [40.0, 80.0, 160.0, 320.0, 640.0, 1280.0, 2560.0, 5120.0, 10240.0]
## A band's recent-peak reference falls back over this long: a breakdown a
## few bars long lets the bands come up to meet it; a bar's rest does not.
const PEAK_RELEASE_SEC := 6.0
## Raw magnitude below which a band is silence — the peak never falls under
## it, so a quiet room's noise is not stretched to 1.0. ⚠️ A guess pending a
## room: the mod panel's meters are how it gets measured.
@export var band_floor: float = 0.003
@export var band_attack: float = 30.0
@export var band_decay: float = 8.0
## A band onset is a SUDDEN rise in the band's RAW magnitude: above its slow
## running average by this ratio AND above where it was ~100 ms ago by
## band_beat_rise — the second test is what keeps a sound that merely started
## from firing once per cooldown while the average catches up. ⚠️ Raw, not the
## normalised envelope: a steady tone reads 1.0 there, and a hit on top of it
## is invisible.
@export var band_beat_threshold: float = 1.8
@export var band_beat_rise: float = 1.8
## `hit` falls to 1/e of itself over this long after an onset.
@export var hit_release: float = 0.4

## Low, mid, high band envelopes, 0..1 against the band's recent peak.
var low: float = 0.0
var mid: float = 0.0
var high: float = 0.0
## The hit follower: 1.0 on every `beat`, then an exponential fall (hit_release).
## Where `pulse` is a straight 0.25 s flash for the TAP dot, this is the
## "punch" a parameter follows.
var hit: float = 0.0
## Spectral brightness: the centroid of the log-spaced bands, 0 (all bass) to
## 1 (all air), smoothed. Timbre rather than loudness.
var bright: float = 0.0

var _band_peak: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0])
var _band_fast: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0])   ## raw, attack-smoothed
var _band_prev: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0])   ## raw, ~100 ms behind
var _band_avg: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0])    ## raw, slow
var _band_timer: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0])
## True once the mic capture pipeline is live.
var mic_active: bool = false
## True after the performer refused RECORD_AUDIO. Android stops showing the
## dialog after the second refusal, so the UI must point at system settings.
var mic_denied: bool = false

const MIC_PERMISSION := "android.permission.RECORD_AUDIO"
## While true, every drained buffer is also emitted as `pcm_captured`.
var capture_pcm: bool = false

## Tuning (live-adjustable — the deck's AUDIO INPUT panel drives gain,
## beat_threshold and beat_min_level; these are the first-run defaults).
@export var gain: float = 8.0            ## linear gain applied to raw RMS
@export var attack: float = 40.0         ## smoothing speed when level rises
@export var decay: float = 7.0           ## smoothing speed when level falls
@export var beat_threshold: float = 1.45 ## ratio over running avg to count a beat
## Noise floor: ignore onsets below this level. MEASURED, not guessed — replaying
## 749 logged onsets from a 20-minute capture (Session 23, phone mic, gain 8.0)
## against candidate floors, with each second labelled music/silent by a rolling
## level average:
##
##   onset level   n     median  p10    p90    max
##   MUSIC        591    0.653   0.419  0.803  0.974
##   SILENT       158    0.108   0.082  0.227  0.353
##
## The two populations barely touch, so 0.15 discards 77% of the silent-room fires
## (0.30/s of them at the old 0.08) and costs ZERO music onsets. 0.25 would remove
## 92% for 2 onsets out of 591 — deliberately not taken: every number above is one
## room at one gain, and a floor set too high re-creates the dead-deck failure the
## onset rewire just fixed. Conservative default; the panel raises it per venue.
@export var beat_min_level: float = 0.15
## ⚠️ UNEXPOSED AND LOAD-BEARING: this swallowed 3079 of 4034 onset candidates (76%)
## in the same capture, which makes it the real rate limiter on the detector — more
## so than the deck's own 0.2 s refractory. Left alone here on purpose; changing it
## needs its own measurement, not a slider added in passing.
@export var beat_cooldown: float = 0.12  ## min seconds between beats

var _capture: AudioEffectCapture
var _spectrum: AudioEffectSpectrumAnalyzerInstance   ## read by TempoDetect; null off-device
var _player: AudioStreamPlayer
var _avg_level: float = 0.0
var _last_emitted_level: float = -1.0   ## change-gates level_changed (see _process)
var _beat_timer: float = 0.0
var _discarded_base: int = 0            ## get_discarded_frames() at capture start
var _chan_logged: bool = false


func _ready() -> void:
	# Printed to Android logcat on launch — handy proof the autoload ran.
	print("[GlobalBus] online")
	if OS.get_name() == "Android":
		get_tree().on_request_permissions_result.connect(_on_permission_result)
	_setup_mic()


func _setup_mic() -> void:
	if not bool(ProjectSettings.get_setting("audio/driver/enable_input", false)):
		push_warning("[GlobalBus] audio/driver/enable_input is off — mic capture disabled")
		print("[GlobalBus] audio input disabled in project settings; no reactivity")
		return

	# Dedicated capture bus, MUTED so the mic isn't echoed back to the output.
	# The capture effect still receives the signal (effects run before mute).
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, INPUT_BUS_NAME)
	AudioServer.set_bus_mute(idx, true)

	_capture = AudioEffectCapture.new()
	_capture.buffer_length = CAPTURE_BUFFER_SEC
	AudioServer.add_bus_effect(idx, _capture)

	# Spectrum for TempoDetect's onset-strength envelope (AUTO_BPM_ALGORITHMS.md §3).
	#
	# ⚠️ THIS IS NOT A SECOND MIC CLIENT. Bus effects CHAIN — the analyzer sits after
	# the capture on the same bus and both see the same signal, so audio reactivity
	# and set recording are untouched. A second AudioEffectCapture would have starved
	# them; this cannot, which is what makes the envelope path cheap to try.
	var spec := AudioEffectSpectrumAnalyzer.new()
	spec.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
	AudioServer.add_bus_effect(idx, spec)
	# Effect 0 is the capture added above; the analyzer is effect 1.
	_spectrum = AudioServer.get_bus_effect_instance(idx, 1) as AudioEffectSpectrumAnalyzerInstance

	_player = AudioStreamPlayer.new()
	_player.stream = AudioStreamMicrophone.new()
	_player.bus = INPUT_BUS_NAME
	add_child(_player)

	# ⚠️ NEVER ask at launch (Play policy + the brief: permissions in context).
	# Godot's Android driver shows the RECORD_AUDIO dialog the moment input
	# starts, so the stream only starts here when the grant already exists — a
	# returning user keeps instant reactivity; a new one is asked by the first
	# feature that needs the mic (request_mic()).
	if _mic_permitted():
		_start_mic()
	else:
		print("[GlobalBus] mic idle — RECORD_AUDIO not granted; asked for in context")


func _mic_permitted() -> bool:
	return OS.get_name() != "Android" or OS.get_granted_permissions().has(MIC_PERMISSION)


func _start_mic() -> void:
	if mic_active or _player == null:
		return
	_player.play()
	mic_active = true
	mic_denied = false
	print("[GlobalBus] mic capture started on bus '%s' (spectrum=%s)"
		% [INPUT_BUS_NAME, str(_spectrum != null)])
	mic_state_changed.emit(true)


## Ask for the mic IN CONTEXT — called by the feature the performer just used
## (audio switch, DETECT, LEARN FLOOR, REC with audio, the Mic row). True if the
## mic is live now; false while the dialog is up (the answer arrives as
## mic_state_changed) or when input is disabled in the project.
func request_mic() -> bool:
	if mic_active:
		return true
	if _player == null:
		return false
	if _mic_permitted():
		_start_mic()
		return mic_active
	OS.request_permission(MIC_PERMISSION)
	return false


func _on_permission_result(permission: String, granted: bool) -> void:
	if permission != MIC_PERMISSION:
		return
	if granted:
		_start_mic()
	else:
		mic_denied = true
		print("[GlobalBus] RECORD_AUDIO refused — audio features stay silent")
		mic_state_changed.emit(false)


## The spectrum analyzer chained on the mic bus, or null if it could not be created.
## Callers MUST null-check — this is the one thing that differs off-device.
func spectrum() -> AudioEffectSpectrumAnalyzerInstance:
	return _spectrum


# --- raw PCM ring, for the Percival tempo engine -------------------------
# TempoDetect's PERC engine computes its OWN spectrum from raw samples rather than
# reading the visualiser-grade AudioEffectSpectrumAnalyzer (see
# TEMPO_PERCIVAL_SPEC.md §1 — that analyser smooths BEFORE differencing, which
# destroys the transient a flux detector exists to find).
#
# ⚠️ A TEE, NOT A SECOND DRAIN. _drain_capture() already consumes the capture buffer
# for the level/onset path that audio reactivity and BEAT FLIP depend on; draining it
# twice would give each consumer a torn fraction of the input. This copies what that
# one drain already read.
## ⚠️ Must exceed TempoDetect.PERC_SEC (20 s) or pcm_tail() can never satisfy a run
## and PERC reports NEED 20 s AUDIO forever. ~2 s of headroom.
const PCM_RING_SEC := 22.0
var _pcm: PackedFloat32Array = PackedFloat32Array()
var _pcm_cap: int = 0


func _tee_pcm(buffer: PackedVector2Array) -> void:
	if buffer.is_empty():
		return
	if _pcm_cap == 0:
		_pcm_cap = int(AudioServer.get_mix_rate() * PCM_RING_SEC)
	# Mono sum. The mic is one capsule; L and R carry the same signal on these
	# devices, but averaging is correct either way and costs nothing.
	for i: int in buffer.size():
		var v := buffer[i]
		_pcm.append((v.x + v.y) * 0.5)
	var over := _pcm.size() - _pcm_cap
	if over > 0:
		_pcm = _pcm.slice(over)


## A copy of the most recent `want_sec` of mono PCM, oldest first. Empty if there is
## not that much yet. ⚠️ Returns a COPY: the Percival engine analyses it on a worker
## thread, and handing out the live ring would race the audio thread's appends.
func pcm_tail(want_sec: float) -> PackedFloat32Array:
	var want := int(AudioServer.get_mix_rate() * want_sec)
	if _pcm.size() < want or want <= 0:
		return PackedFloat32Array()
	return _pcm.slice(_pcm.size() - want)


func pcm_seconds() -> float:
	var sr := AudioServer.get_mix_rate()
	return float(_pcm.size()) / sr if sr > 0.0 else 0.0


func _process(delta: float) -> void:
	if _capture == null:
		return

	var raw := _rms_of(_drain_capture())
	var target := clampf(raw * gain, 0.0, 1.0)
	# Asymmetric smoothing: snap up fast (attack), fall slower (decay).
	var speed := attack if target > level else decay
	level = lerpf(level, target, clampf(speed * delta, 0.0, 1.0))

	# Onset/beat: fire when level jumps above a multiple of its running average.
	_avg_level = lerpf(_avg_level, level, clampf(2.0 * delta, 0.0, 1.0))
	_beat_timer -= delta
	if level > _avg_level * beat_threshold and level > beat_min_level and _beat_timer <= 0.0:
		_beat_timer = beat_cooldown
		pulse = 1.0
		hit = 1.0
		beat.emit()

	pulse = maxf(0.0, pulse - delta * 4.0)

	# The analyser. Eleven range reads of the FFT the bus already computes; the
	# arithmetic is in the feeders so the verifier can drive them without a mic.
	if _spectrum != null:
		for b in 3:
			var m: Vector2 = _spectrum.get_magnitude_for_frequency_range(BAND_HZ[b][0], BAND_HZ[b][1],
				AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_AVERAGE)
			_feed_band(b, (m.x + m.y) * 0.5, delta)
		var mags := PackedFloat32Array()
		for i in CENTROID_HZ.size() - 1:
			var m: Vector2 = _spectrum.get_magnitude_for_frequency_range(CENTROID_HZ[i], CENTROID_HZ[i + 1],
				AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_AVERAGE)
			mags.append((m.x + m.y) * 0.5)
		_feed_centroid(mags, delta)
	_feed_hit(delta)
	# PERFORMANCE: only emit when the level actually moved. This fires at 60 Hz and
	# every consumer currently polls `level` directly instead, so the unconditional
	# emit was pure signal-dispatch overhead each frame.
	if absf(level - _last_emitted_level) > 0.002:
		_last_emitted_level = level
		level_changed.emit(level)


## One band's raw magnitude for this frame -> its envelope, and an onset if it
## jumped. Public for the verifier (and because a mic on a desk is not a room).
func _feed_band(band: int, mag: float, delta: float) -> void:
	_band_peak[band] = maxf(maxf(mag, _band_peak[band] * exp(-delta / PEAK_RELEASE_SEC)), band_floor)
	# Against the recent peak, with the floor taken off both, so silence is 0
	# rather than "as loud as it has recently been".
	var target := clampf((mag - band_floor) / maxf(_band_peak[band] - band_floor, 1e-6), 0.0, 1.0)
	var cur := _band_value(band)
	var speed := band_attack if target > cur else band_decay
	cur = lerpf(cur, target, clampf(speed * delta, 0.0, 1.0))
	_set_band_value(band, cur)
	# The onset test, on the raw magnitude (see band_beat_threshold).
	var fast := _band_fast[band]
	fast = lerpf(fast, mag, clampf((band_attack if mag > fast else band_decay) * delta, 0.0, 1.0))
	_band_fast[band] = fast
	_band_timer[band] -= delta
	if fast > _band_avg[band] * band_beat_threshold and fast > _band_prev[band] * band_beat_rise \
			and fast > band_floor * 2.0 and _band_timer[band] <= 0.0:
		_band_timer[band] = beat_cooldown
		band_beat.emit(band)
	_band_prev[band] = lerpf(_band_prev[band], fast, clampf(10.0 * delta, 0.0, 1.0))
	_band_avg[band] = lerpf(_band_avg[band], fast, clampf(2.0 * delta, 0.0, 1.0))


## The octave bands' magnitudes -> brightness.
func _feed_centroid(mags: PackedFloat32Array, delta: float) -> void:
	var total := 0.0
	var weighted := 0.0
	for i in mags.size():
		var m := maxf(mags[i] - band_floor * 0.5, 0.0)
		total += m
		weighted += m * float(i)
	var target := bright   # nothing to hear: hold
	if total > band_floor:
		target = weighted / (total * float(maxi(mags.size() - 1, 1)))
	bright = lerpf(bright, target, clampf(6.0 * delta, 0.0, 1.0))


func _feed_hit(delta: float) -> void:
	if hit > 0.0:
		hit *= exp(-delta / hit_release)
		if hit < 0.002:
			hit = 0.0


func _band_value(band: int) -> float:
	match band:
		BAND_LOW: return low
		BAND_MID: return mid
	return high


func _set_band_value(band: int, v: float) -> void:
	match band:
		BAND_LOW: low = v
		BAND_MID: mid = v
		_: high = v


## Start/stop forwarding mic PCM to the set recorder.
##
## The discard counter is cumulative and shared with whatever ran before, so it
## is re-baselined here — otherwise a recording would open by "padding" every
## overrun that happened since boot.
func begin_pcm_capture() -> void:
	if _capture == null:
		return
	# ⚠️ DROP WHATEVER IS ALREADY IN THE RING FIRST. The level meter only needs
	# the newest frames, so nothing here has been keeping the buffer drained —
	# at CAPTURE_BUFFER_SEC it can hold half a second of audio from BEFORE the
	# user pressed REC. Encoded, that stale block occupies the head of the track
	# and shifts every real sound after it LATE by up to 500 ms. Measured on the
	# 9a: a first chunk of 18432 frames (418 ms). It only stayed out of the file
	# by the race of the video clock not being established yet.
	_capture.clear_buffer()
	_discarded_base = _capture.get_discarded_frames()
	_chan_logged = false
	capture_pcm = true


func end_pcm_capture() -> void:
	capture_pcm = false


## Drain the capture ring ONCE per frame and hand the frames to everyone who
## wants them.
##
## ⚠️ THERE CAN ONLY BE ONE READER: get_buffer() REMOVES the frames it returns.
## A recorder calling it independently of the level meter would not read the
## same signal twice, it would take turns with it — each seeing a torn fraction
## of the input, quietly wrecking beat detection as well as the recording.
func _drain_capture() -> PackedVector2Array:
	var frames := _capture.get_frames_available()
	if frames <= 0:
		return PackedVector2Array()
	var buffer := _capture.get_buffer(frames)
	if capture_pcm and buffer.size() > 0:
		var discarded := _capture.get_discarded_frames()
		var pad := maxi(0, discarded - _discarded_base)
		_discarded_base = discarded
		if not _chan_logged:
			_chan_logged = true
			_log_channels(buffer)
		# to_byte_array() is a memcpy — no per-sample GDScript loop on the main
		# thread at 60 Hz. The downmix to mono happens in Kotlin.
		pcm_captured.emit(buffer.to_byte_array(), buffer.size(), pad)
	_tee_pcm(buffer)
	return buffer


## RMS of one drained buffer.
func _rms_of(buffer: PackedVector2Array) -> float:
	if buffer.size() == 0:
		return 0.0
	var sum := 0.0
	for f in buffer:
		sum += (f.x * f.x + f.y * f.y) * 0.5
	return sqrt(sum / float(buffer.size()))


## One-shot proof that the recorder's (L+R)/2 downmix is not halving a mono mic.
## Godot's Android driver is expected to write each mono input sample into BOTH
## channels; if it instead left R silent, the downmix would cost 6 dB — cheap to
## check once rather than assume.
func _log_channels(buffer: PackedVector2Array) -> void:
	var l := 0.0
	var r := 0.0
	for f in buffer:
		l += f.x * f.x
		r += f.y * f.y
	var n := float(buffer.size())
	print("[GlobalBus] capture channels: L rms=%.5f R rms=%.5f (%d frames @ %d Hz)" %
		[sqrt(l / n), sqrt(r / n), buffer.size(), int(AudioServer.get_mix_rate())])
