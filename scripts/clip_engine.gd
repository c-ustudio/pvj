class_name ClipEngine
extends Node
## Stage 1 of the PocketVJ pipeline — a two-decoder MANAGER.
##
## Owns two decode SubViewports (A and B), each with its own GoZen VideoPlayback.
## One is the FRONT (live, what the pipeline samples), the other the BACK (idle,
## and — once cue() lands — the one being loaded ahead of the beat).
##
##     ClipEngine (Node)
##     ├── DecoderA (SubViewport) └── VideoPlayback
##     └── DecoderB (SubViewport) └── VideoPlayback
##
## Downstream consumers sample active_texture() (the FRONT viewport's texture) and
## listen to active_texture_changed to re-point when the front flips. Re-pointing a
## ViewportTexture reference is free — no GPU copy.
##
## WHY TWO: measured on device (SESSION_10_TASK0.md), a switch costs ~150 ms, of
## which ~118 ms is the main thread BLOCKED in wait_for_task_completion() on a
## demux that already runs on a worker thread, plus ~25 ms of FFmpeg teardown in
## close(). None of that gets faster — but with a second decoder it happens while
## the front decoder keeps drawing, so it stops landing on the visible cut.
##
## THIS COMMIT IS THE RESTRUCTURE ONLY: play_index() still opens synchronously into
## the front decoder, exactly as before, so no performance change is expected yet.
## cue()/swap() are the next step (PocketVJ_v0.3_Preload_Fix_REV2.md §2.3-2.4).
##
## Holds the full clip LIST scanned from the clips folder and switches between
## them on demand (play_index/next/prev/random).
##
## Clips come from the folder the performer picked (a SAF tree, presented by the
## Storage autoload as the virtual dir saf://<label>) or, without one, app storage
## (user://clips). Every path handed to GoZen goes through Storage.playable().
## No storage permission is involved — see core/storage.gd.

const VIDEO_EXTS := ["mp4", "mov", "mkv", "webm", "m4v", "avi"]
const DECODER_SIZE := Vector2i(1920, 1080)   ## was the ClipEngine SubViewport's own size
## Instrument the deck players (SwitchProfiler -> logcat).
## OFF since Sequencer 2.0 Stage 1: SwitchProfiler is static state — two engines
## would interleave one capture buffer (and its own note said FALSE for shipping).
const PROFILE_DECK := false

signal clips_ready(count: int)                       ## clips scanned, >=1 found
signal clips_scanned(count: int)                     ## every scan(): the list was re-read (0 allowed)
signal clip_changed(clip_name: String, index: int, count: int)
signal clip_missing(searched_dir: String)            ## no clips in the folder
signal active_texture_changed(tex: Texture2D)        ## the FRONT decoder flipped
signal swap_held                                     ## a cut was skipped (cue not warm) — SEQ2 HELD flash
signal clip_failed(path: String)                     ## a clip never opened in OPEN_TIMEOUT_SEC — skipped

## The FRONT decoder's player. Kept under the old name because pipeline and the
## browsers use it (playback speed, "has a player yet?" checks) — it now means
## "the live player" and is re-pointed on every swap.
var player: VideoPlayback
var clips_dir: String
var clips: Array[String] = []   ## full paths, sorted alphabetically
var current_index: int = -1
var start_index: int = 0         ## clip to play first (set by pipeline from saved settings)

# --- The two decoders ----------------------------------------------------
var _dec_a: SubViewport
var _dec_b: SubViewport
var _ply_a: VideoPlayback
var _ply_b: VideoPlayback
var _front: SubViewport          ## live — active_texture() comes from here
var _back: SubViewport           ## idle / cued


func _ready() -> void:
	_dec_a = _make_decoder("DecoderA")
	_dec_b = _make_decoder("DecoderB")
	_ply_a = _player_of(_dec_a)
	_ply_b = _player_of(_dec_b)
	_front = _dec_a
	_back = _dec_b
	player = _ply_a
	# Only the live decoder renders. An idle 1920x1080 render target still costs a
	# clear every frame, so the back viewport stays UPDATE_DISABLED until it has a
	# clip to show (cue() will enable it). REV2 §2.1 says UPDATE_ALWAYS for both;
	# this is the same thing minus a per-frame clear of an empty target.
	_set_decoder_live(_front, true)
	_set_decoder_live(_back, false)

	# ⚠️ No OS.request_permissions() here any more: it asked for EVERY dangerous
	# permission in the manifest at launch (mic and camera included). Storage
	# needs none now, and the mic/camera are asked for where they are used.
	clips_dir = Storage.clips_dir()

	# Deferred so the pipeline can connect our signals first.
	_start.call_deferred()


func _start() -> void:
	_log("clips_dir = %s" % clips_dir)
	if not Storage.is_virtual(clips_dir):
		DirAccess.make_dir_recursive_absolute(clips_dir)

	scan()
	if clips.is_empty():
		_log("no clips found")
		clip_missing.emit(clips_dir)
		return

	_log("found %d clip(s)" % clips.size())
	clips_ready.emit(clips.size())
	play_index(start_index)   # restored clip from settings (wraps if out of range)


## Rescan the clips folder (e.g. after dragging new files on over USB).
func scan() -> void:
	clips = _scan_clips()
	_dead.clear()   # a rescan or an import may have replaced the file: try it again
	# ⚠️ Every rescan path (RESCAN row, IMPORT PACK, LOAD DEMO CLIPS, a new folder,
	# resume, a Drive download) ends here — but clips_ready only fires from _start(),
	# so until beta2 the ClipLibrary (and with it the clip grid, the folder chips and
	# the empty-grid state) kept the LAUNCH list forever: imported clips never showed,
	# an emptied folder still listed the old clips. This is what the library follows.
	clips_scanned.emit(clips.size())


## scan(), keeping the deck on its clips: the playing and the cued clip are
## re-pointed BY PATH. A bare scan() replaces `clips` with a fresh alphabetical
## list and leaves both indices alone, so they name other clips until fixed —
## and set_order() would then "restore" those wrong ones (the trap
## pipeline._remove_clip_file documents). Bookkeeping only: no decoder is
## touched; a cued clip that went is dropped (swap holds, the next cue re-warms).
func scan_keeping_deck() -> void:
	var cur := clips[current_index] if current_index >= 0 and current_index < clips.size() else ""
	var cued := clips[_cued_index] if _cued_index >= 0 and _cued_index < clips.size() else ""
	scan()
	if cur != "":
		var ci := clips.find(cur)
		if ci >= 0:
			current_index = ci
	if cued != "":
		_cued_index = clips.find(cued)
		if _cued_index < 0:
			_cue_ready = false


## Reorder the (already scanned) clip list to match a saved play order. Paths in
## `order` that still exist are placed first in that order; any scanned clips not in
## the order (e.g. newly downloaded files) are appended; missing paths are dropped.
## The currently-playing clip is re-resolved by path so playback is not interrupted.
func set_order(order: Array[String]) -> void:
	if clips.is_empty():
		return
	var current_path: String = ""
	if current_index >= 0 and current_index < clips.size():
		current_path = clips[current_index]
	# ⚠️ THE BACK DECODER MUST BE RE-RESOLVED TOO. _cued_index is an INDEX, and swap()
	# does `current_index = _cued_index` then reports clips[current_index] — so after a
	# reorder the engine announces whichever clip has SLID INTO that slot while the
	# decoder is really holding the old one. Everything downstream that resolves from
	# current_index (the grid's active cell, the sequence playhead, the cue target) then
	# tracks a clip that is not playing, and AUTO can re-cue the same wrong target
	# forever — which reads as the deck hanging.
	var cued_path: String = ""
	if _cued_index >= 0 and _cued_index < clips.size():
		cued_path = clips[_cued_index]

	var reordered: Array[String] = []
	for p: String in order:
		if clips.has(p) and not reordered.has(p):
			reordered.append(p)
	for p: String in clips:
		if not reordered.has(p):
			reordered.append(p)
	clips = reordered

	if current_path != "":
		var idx: int = clips.find(current_path)
		if idx != -1:
			current_index = idx
	if cued_path != "":
		# find() returning -1 (the cued clip was removed) is the CORRECT outcome: swap()
		# then holds instead of flipping to a stale file, and the next cue re-warms.
		_cued_index = clips.find(cued_path)
		if _cued_index < 0:
			_cue_ready = false


func _scan_clips() -> Array[String]:
	return Storage.scan(clips_dir)


## Play the clip at list index `i` (wraps around the ends).
##
## Still a SYNCHRONOUS open into the FRONT decoder — identical to the pre-restructure
## behaviour, and it still costs the measured ~150 ms. cue()/swap() (REV2 §2.3-2.4)
## are what move that off the cut; this commit only puts the second decoder in place.
func play_index(i: int) -> void:
	if clips.is_empty():
		return
	var alive := _alive_from(wrapi(i, 0, clips.size()))
	if alive < 0:
		return   # every clip failed to open: keep whatever is on the deck
	current_index = alive
	_front_wait = 0.0
	var path := clips[current_index]
	# PROFILE (v0.3 Task 0): one capture per switch — no-op while `profile` is false.
	SwitchProfiler.begin("clip %d/%d · %s" % [current_index + 1, clips.size(), path.get_file()])
	var t_open := SwitchProfiler.now()
	player.set_video_path(Storage.playable(path))
	SwitchProfiler.span("set_video_path() RETURNED  <-- 'the open'", t_open)
	clip_changed.emit(path.get_file(), current_index, clips.size())
	SwitchProfiler.mark("clip_changed handlers done (HDMI push, labels)")


# Manual PREV/NEXT go through jump() so a forward tap uses the already-warm back
# decoder instead of re-opening the clip. Before boot (no player yet) fall back to
# play_index, which sets up the front decoder for the first time.
func next_clip() -> void:
	if _cued_index < 0:
		play_index(current_index + 1)
	else:
		jump(current_index + 1)


func prev_clip() -> void:
	# Step back over dead clips here: play_index/jump skip FORWARD, which from
	# a dead previous clip lands on the current one again.
	var i := _alive_from(current_index - 1, -1) if not clips.is_empty() else -1
	if i < 0:
		return
	if _cued_index < 0:
		play_index(i)
	else:
		jump(i)


## Jump to a random clip other than the current one.
func random_clip() -> void:
	if clips.size() <= 1:
		return
	var i := current_index
	while i == current_index:
		i = randi() % clips.size()
	play_index(i)


# --- Live set (active bank) vs parked library -----------------------------
# `live_set` holds the paths the AUTO-sequencer cycles. Empty = ALL clips live
# (the default, so behaviour is unchanged until the user parks some clips).
# Manual prev/next/play_index always reach every clip.

var live_set: Dictionary = {}

func is_live(path: String) -> bool:
	return live_set.is_empty() or live_set.has(path)


## Set the live subset by full paths. Empty array = all clips live.
func set_live(paths: Array[String]) -> void:
	live_set.clear()
	for p: String in paths:
		live_set[p] = true


## Indices (into `clips`) that are currently live, in order. Returns all when
## nothing is parked, so callers get the full list by default.
func live_indices() -> Array[int]:
	var out: Array[int] = []
	for i: int in clips.size():
		if is_live(clips[i]):
			out.append(i)
	return out


## The index the auto-sequencer would advance to next (wraps). Split out of
## next_live_clip() so cue() can target the same clip the switch clock will.
func next_live_index() -> int:
	var li: Array[int] = live_indices()
	if li.is_empty():
		return wrapi(current_index + 1, 0, maxi(clips.size(), 1))
	for i: int in li:
		if i > current_index:
			return i
	return li[0]


## Auto-sequencer: advance to the next live clip after the current one (wraps).
func next_live_clip() -> void:
	if clips.is_empty():
		return
	play_index(next_live_index())


## Auto-sequencer: a random live clip other than the current one.
func random_live_clip() -> void:
	var li: Array[int] = live_indices()
	if li.size() <= 1:
		if li.size() == 1:
			play_index(li[0])
		else:
			random_clip()
		return
	play_index(random_live_index())


## A random live index other than the current one (all clips when nothing parked).
## RANDOM's pick-and-remember (REV2 §3): pipeline's cue-target provider calls this
## ONCE at cue time; cue() then stores the result in _cued_index and swap() uses
## that same index — so the target is chosen when it is warmed, NOT re-rolled at
## the cut.
func random_live_index() -> int:
	var li: Array[int] = live_indices()
	if li.size() <= 1:
		return li[0] if li.size() == 1 else current_index
	var idx: int = current_index
	while idx == current_index:
		idx = li[randi() % li.size()]
	return idx


# --- Cue (preload into the back decoder) ---------------------------------
#
# REV2 §2.3. The whole point: the ~194 ms demux and the ~27 ms FFmpeg teardown
# happen HERE, in the slack between switches, instead of on the visible cut.
#
# Two things make that actually work, and both are load-bearing:
#   1. VideoPlayback._process no longer BLOCKS on wait_for_task_completion (see
#      the addon). Both decoders' _process run on the main thread, so a blocking
#      wait during a cue would freeze the front decoder's playback just as hard
#      as a switch does today — it would only move the freeze, not remove it.
#   2. The back viewport renders exactly ONE frame when its clip opens (below),
#      so the 1-4 ms of texture creation is pre-paid and the swap is a pointer
#      flip. It then stops rendering: a 1080p viewport we are not showing would
#      otherwise cost a full YUV->RGB pass every frame.

## Seconds to wait after a swap before cueing the following clip. cue() begins by
## tearing down the outgoing decoder's FFmpeg context (~27 ms, main thread), so
## cueing *immediately* at the swap would put that straight back onto the cut —
## which is the one thing swap() exists to avoid. A few frames of delay is plenty:
## at 123 BPM this still leaves ~400 ms of lead for a ~195 ms demux.
const CUE_DELAY_SEC := 0.08

var _cued_index: int = -1
var _cue_ready: bool = false
var _cue_delay: float = -1.0     ## counts down to the post-swap cue; <0 = idle
var _swap_holds: int = 0         ## swaps refused because the cue wasn't warm yet
var _swap_when_ready: bool = false  ## a jump() to an un-cued clip is loading; swap once warm

## Returns the index to warm next, or -1 for "don't cue". pipeline sets this per
## switch mode so the cue target matches what the switch clock will actually ask
## for — otherwise every cut falls back to an un-cued open.
var next_index_provider: Callable = Callable()


## Open clips[index] into the BACK decoder, paused on frame 0, ready to swap.
## Safe to call repeatedly; re-cueing the already-warm clip is a no-op.
func cue(index: int) -> void:
	if clips.is_empty():
		return
	var idx: int = _alive_from(wrapi(index, 0, clips.size()))
	if idx < 0:
		return
	if idx == _cued_index and clips[idx] == _cue_path and (_cue_ready or _cue_wait >= 0.0):
		return   # warm, or still opening: re-opening would restart the open timeout
	_cued_index = idx
	_cue_path = clips[idx]
	_cue_ready = false
	_cue_wait = 0.0
	var p: VideoPlayback = _player_of(_back)
	# The back decoder must NOT start playing when its worker finishes — it holds
	# frame 0 until swap() promotes it.
	p.enable_auto_play = false
	# set_video_path() calls close() internally, so the previously cued clip's
	# FFmpeg teardown lands here too — in slack, which is exactly where REV2 §2.4
	# wants it (closing at swap time would put it straight back on the cut).
	p.set_video_path(Storage.playable(clips[idx]))
	_log("cue -> #%d/%d %s on %s" % [idx + 1, clips.size(), clips[idx].get_file(), _back.name])


## Promote the cued clip to live. THE CUT.
##
## Pointer flip only: no close(), no open, no wait_for_task_completion. The
## outgoing decoder KEEPS its FFmpeg context — the next cue() tears it down, in
## slack (REV2 §2.4 step 4).
##
## If the cue isn't warm yet this HOLDS rather than blocks (REV2 §1): the current
## clip keeps playing and the caller can try again on the next beat. A dropped
## swap is better than a frozen deck, and it is what keeps a too-fast switch rate
## from collapsing the frame rate — the deck simply cuts less often than asked.
func swap() -> void:
	if clips.is_empty() or _cued_index < 0:
		return
	if not can_process():
		return   # a sleeping (disarmed) deck must never re-enable its renderer
	if not _cue_ready:
		_swap_holds += 1
		_log("swap HELD (#%d not warm yet) — holds=%d" % [_cued_index + 1, _swap_holds])
		swap_held.emit()   # silent skipping at a gig reads as a bug (SEQ2 §3.3)
		return

	var t: SubViewport = _front
	_front = _back
	_back = t
	player = _player_of(_front)

	# Incoming: start rendering (it already holds its frame 0) and play.
	_set_decoder_live(_front, true)
	var pf: VideoPlayback = _player_of(_front)
	pf.enable_auto_play = true
	pf.play()

	# Outgoing: stop rendering and pause. Context stays open until the next cue().
	_set_decoder_live(_back, false)
	_player_of(_back).pause()

	current_index = _cued_index
	_cue_ready = false
	active_texture_changed.emit(active_texture())
	clip_changed.emit(clips[current_index].get_file(), current_index, clips.size())
	# Warm the next one, but not on this frame — see CUE_DELAY_SEC.
	_cue_delay = CUE_DELAY_SEC


## Manual jump to a specific clip (tap-a-slot, prev/next). REV2 §2.3.
##  - already warm on the back decoder  -> swap() now (instant).
##  - otherwise -> cue it and swap the instant it is ready. The current clip keeps
##    PLAYING until the cut (a ~195 ms hold, not a freeze or a frame-rate stall);
##    the post-swap auto-cue then re-warms the mode's next target.
## This is why tapping NEXT no longer re-opens a clip already cued on the back
## decoder — a forward tap in a forward mode hits the warm path.
func jump(index: int) -> void:
	if clips.is_empty():
		return
	# Skip dead clips HERE too: cue() would redirect a dead target to the clip
	# after it — often the one already warm — and return without a load, so
	# nothing would ever call swap() and NEXT would do nothing.
	var idx: int = _alive_from(wrapi(index, 0, clips.size()))
	if idx < 0:
		return
	if idx == _cued_index and _cue_ready:
		swap()
		return
	_swap_when_ready = true
	cue(idx)


## Re-warm the back decoder for the current mode's target — e.g. after a switch-mode
## change, when the clip the old mode cued is no longer the right one. Cancels any
## pending delayed cue.
func recue() -> void:
	_cue_delay = -1.0
	_cue_next()


func _process(delta: float) -> void:
	_watch_opens(delta)
	if _cue_delay < 0.0:
		return
	_cue_delay -= delta
	if _cue_delay <= 0.0:
		_cue_delay = -1.0
		_cue_next()


# Warm whatever the current switch mode will ask for next.
func _cue_next() -> void:
	var idx: int = next_live_index()
	if next_index_provider.is_valid():
		idx = int(next_index_provider.call())
	if idx < 0:
		return   # this mode can't predict its next clip (e.g. RANDOM, pre-step-6)
	cue(idx)


## Index currently cued into the back decoder (-1 = none).
func cued_index() -> int:
	return _cued_index


## True once the cued clip has opened AND rendered its first frame — i.e. a swap
## would be a pointer flip. swap() will use this to decide whether to hold.
func is_cue_ready() -> bool:
	return _cue_ready


# The back decoder finished opening. Render exactly one frame into it (creating +
# uploading the frame-0 texture now, off the cut), then stop rendering it.
func _finish_cue() -> void:
	_back.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	_cue_ready = true
	_log("cue ready on %s (#%d)" % [_back.name, _cued_index + 1])
	if _swap_when_ready:
		# A jump() was waiting on this clip. Cut to it now.
		_swap_when_ready = false
		swap()


# --- Decoders ------------------------------------------------------------

## The live decoder's texture. Downstream (ShaderSlot, RegionCompositor) samples
## this; it changes identity when the front flips, hence active_texture_changed.
func active_texture() -> ViewportTexture:
	return _front.get_texture()


## Build one decode viewport + its GoZen player.
func _make_decoder(vp_name: String) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = vp_name
	vp.size = DECODER_SIZE
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED   # _set_decoder_live() owns this
	add_child(vp)

	var p := VideoPlayback.new()
	p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	p.loop = true
	p.enable_auto_play = true
	# Clip audio is unused (VJ visuals; audio-reactivity is from the mic, HDMI audio
	# is separate ExoPlayer). Opening the audio track via FFmpeg on the main thread
	# was ~150-200ms per switch — measured in Session 8. It also means two decoders
	# can never double up audio.
	p.enable_audio = false
	p.debug = true
	p.profile = PROFILE_DECK
	p.video_loaded.connect(_on_loaded.bind(vp))
	vp.add_child(p)
	# Fill the viewport (cover) rather than letterbox-center.
	p.video_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	return vp


func _player_of(vp: SubViewport) -> VideoPlayback:
	return vp.get_child(0) as VideoPlayback


## Lane arming (Sequencer 2.0): stop/resume the FRONT render target without
## touching the cue machinery — the back decoder is already gated by cue()/swap().
## Pair with process_mode on this node to also stop the decode pump.
## Going dark also drops any pending auto-swap: a cue whose video_loaded landed
## in the disarm frame must not re-awaken the front viewport via _finish_cue.
func set_rendering(live: bool) -> void:
	_set_decoder_live(_front, live)
	if not live:
		_swap_when_ready = false


## A decoder only renders while it has something to show — an idle 1920x1080
## render target still pays a clear every frame.
func _set_decoder_live(vp: SubViewport, live: bool) -> void:
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if live \
		else SubViewport.UPDATE_DISABLED


# `vp` is the decoder that finished loading (bound at connect time), so this stays
# correct once the back decoder starts loading clips of its own.
func _on_loaded(vp: SubViewport) -> void:
	# PROFILE (v0.3 Task 0): video_loaded fires at the END of _update_video, i.e.
	# before this frame is drawn — so the NEXT frame_post_draw is the first frame
	# that actually contains the new clip.
	SwitchProfiler.mark("video_loaded emitted")
	_mark_first_frame()
	var p := _player_of(vp)
	# The back decoder is loading the CUED clip, not the current one.
	var idx: int = current_index if vp == _front else _cued_index
	if vp == _front:
		_front_wait = -1.0
	else:
		_cue_wait = -1.0
	_log("loaded #%d/%d on %s: %d fps · %d frames" % [
		idx + 1, clips.size(), vp.name,
		int(p.get_video_framerate()),
		p.get_video_frame_count(),
	])
	if vp == _front:
		# Warm the next clip while this one plays (target per switch mode, §3).
		_cue_next.call_deferred()
	else:
		_finish_cue()


# --- Clips that never open ----------------------------------------------
#
# GoZen emits nothing when an open fails (a damaged MKV/WebM/AVI, a codec the
# phone lacks): video_loaded just never comes. Without a timeout the cue stays
# "not warm" for ever, every swap HOLDS, and NEXT re-cues the same clip — the
# deck never leaves the current clip (or, at boot, stays black). A clip that has
# not opened after OPEN_TIMEOUT_SEC is marked dead for this scan, reported
# (the grid says CAN'T PLAY) and skipped. The time only runs while this node
# processes, so a disarmed deck — whose decoders are paused too — never times out.

## A healthy open is ~0.2 s (4K HEVC ~0.5 s); this is far above any of them.
const OPEN_TIMEOUT_SEC := 4.0

var _dead: Dictionary = {}       ## path -> true: never opened (until the next scan)
var _cue_wait: float = -1.0      ## seconds the back decoder's open has taken; <0 = none pending
var _cue_path: String = ""       ## the file that open is for (indices move on a rescan)
var _front_wait: float = -1.0    ## the same for a play_index() into the front decoder


func is_dead(path: String) -> bool:
	return _dead.has(path)


## `idx`, or the first clip after it (before it, step -1) that has not failed to
## open; -1 if none is left.
func _alive_from(idx: int, step: int = 1) -> int:
	for n in clips.size():
		var i := wrapi(idx + n * step, 0, clips.size())
		if not _dead.has(clips[i]):
			return i
	return -1


func _watch_opens(delta: float) -> void:
	# One long frame (a shader compile at boot) must not eat the whole timeout.
	delta = minf(delta, 0.1)
	if _cue_wait >= 0.0:
		_cue_wait += delta
		if _cue_wait > OPEN_TIMEOUT_SEC:
			_cue_wait = -1.0
			if _cued_index >= 0 and _cued_index < clips.size():
				var failed := _cued_index
				_give_up(clips[failed])
				_cued_index = -1
				# A jump() waiting on it (_swap_when_ready) lands on the next clip.
				cue(failed + 1)
	if _front_wait >= 0.0:
		_front_wait += delta
		if _front_wait > OPEN_TIMEOUT_SEC:
			_front_wait = -1.0
			if current_index >= 0 and current_index < clips.size():
				_give_up(clips[current_index])
				play_index(current_index + 1)


func _give_up(path: String) -> void:
	_dead[path] = true
	_log("%s never opened in %.0f s — CAN'T PLAY, skipped" % [path.get_file(), OPEN_TIMEOUT_SEC])
	clip_failed.emit(path)


# PROFILE (v0.3 Task 0) — strip with switch_profiler.gd.
func _mark_first_frame() -> void:
	if not SwitchProfiler.is_active():
		return
	await RenderingServer.frame_post_draw
	SwitchProfiler.mark("*** FIRST RENDERED FRAME of the new clip ***")


func _log(msg: String) -> void:
	print("[ClipEngine] %s" % msg)
