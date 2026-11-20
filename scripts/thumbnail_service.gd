extends Node
## ThumbnailService (autoload) — async clip thumbnails, disk-cached (sequencer Step 2).
##
## Cache: <cache dir>/thumbs/{clip_id}.webp (Storage.thumb_dir()), 256 px longest edge (path owned by
## ClipLibrary.ClipData.thumb_cache_path). Cache HIT -> load ImageTexture (cheap).
## MISS -> offscreen frame extraction, time-sliced on the main thread.
##
## Why main-thread extraction: GoZen textures are render-bound (main-thread). We
## keep it cheap and non-hitching three ways (PocketVJ_Architecture §7 risk 2):
##   - ONE extractor decoder, serialized — at most one generation in flight, so
##     the ~195 ms demux stays on GoZen's worker thread (async, Session 10 poll fix)
##     and only ONE small readback+encode touches the main thread at a time.
##   - the extractor viewport is tiny (256x144), so get_image() reads back 36k px,
##     not a 2 MP frame.
##   - generation is skipped on frames that were already heavy (a live clip switch),
##     so we never pile onto a busy frame.
## The grid shows a placeholder until `thumbnail_ready` arrives.
##
## A clip GoZen cannot open never produces a frame — and GoZen emits nothing on
## a failed open, so without a limit the queue waited on it forever and every
## later thumbnail stopped. GEN_TIMEOUT_SEC ends the wait: the clip is marked
## `thumbnail_failed` (the grid says CAN'T PLAY) and the queue moves on.

signal thumbnail_ready(clip_id: String, tex: Texture2D)
signal thumbnail_failed(clip_id: String)

const EXTRACT_SIZE := Vector2i(256, 144)           ## 16:9, 256 long edge, cheap readback
const LOAD_PER_FRAME := 3                           ## cache-hit loads per frame (cheap)
const LOAD_BUDGET_MS := 5.0                         ## hard cap on cache-hit loading per frame
const SLOW_FRAME_SEC := 0.020                       ## skip generation if the last frame was slower
const GEN_TIMEOUT_SEC := 5.0                        ## a clip that has not given a frame by then can't play

var _load_queue: Array[String] = []                ## ids with a cached thumb on disk
var _gen_queue: Array[String] = []                 ## ids needing extraction
var _pending: Dictionary = {}                      ## id -> true (queued or in flight; dedupe)

var _extractor_vp: SubViewport
var _extractor: VideoPlayback
var _busy_id: String = ""                          ## id currently extracting ("" = idle)
var _busy_since: float = 0.0                       ## when it started (Time ticks, s)
var _failed: Dictionary = {}                       ## id -> true: never gave a frame (this run)
var _gen_done: int = 0                              ## generated this run (logging only)
var _saving: Dictionary = {}                       ## id -> true: its .webp is being written off-thread


## Ask for a clip's thumbnail. Emits thumbnail_ready now-ish (cache) or later (gen).
func request(id: String) -> void:
	if id == "" or _pending.has(id) or _busy_id == id or _failed.has(id):
		return
	var cd := ClipLibrary.get_clip(id)
	if cd == null:
		return
	_pending[id] = true
	if FileAccess.file_exists(cd.thumb_cache_path) and not _saving.has(id):
		_load_queue.append(id)
	else:
		_gen_queue.append(id)


## Pre-warm the whole library's thumb cache in the background (pipeline calls this
## a couple of seconds after boot). GENERATES what is missing and nothing else: a
## thumbnail already on disk is loaded when a grid or strip cell asks for it
## (request()), not decoded at every launch for nobody to show — that work grew
## with the library. Idempotent — request() dedupes.
func request_all() -> void:
	var cached := 0
	for id: String in ClipLibrary.get_folder("all").clip_ids:
		var cd := ClipLibrary.get_clip(id)
		if cd != null and FileAccess.file_exists(cd.thumb_cache_path):
			cached += 1
		else:
			request(id)
	print("[Thumbs] prewarm: %d cached, %d to generate" % [cached, _gen_queue.size()])


func _process(delta: float) -> void:
	# Cache hits: cheap, a few per frame under a hard budget so a scroll can't stall.
	var t0 := Time.get_ticks_usec()
	var loads := 0
	while not _load_queue.is_empty() and loads < LOAD_PER_FRAME:
		_load_cached(_load_queue.pop_front())
		loads += 1
		if float(Time.get_ticks_usec() - t0) / 1000.0 >= LOAD_BUDGET_MS:
			break
	if _busy_id != "" and Time.get_ticks_msec() / 1000.0 - _busy_since > GEN_TIMEOUT_SEC:
		_give_up(_busy_id)
	# Generation: one at a time, and not onto an already-heavy frame.
	if _busy_id == "" and not _gen_queue.is_empty() and delta <= SLOW_FRAME_SEC:
		_start_gen(_gen_queue.pop_front())


func _load_cached(id: String) -> void:
	_pending.erase(id)
	var cd := ClipLibrary.get_clip(id)
	if cd == null:
		return
	var img := Image.new()
	if img.load(cd.thumb_cache_path) != OK or img.is_empty():
		# Stale/corrupt cache file — fall back to regenerating it.
		_pending[id] = true
		_gen_queue.append(id)
		return
	thumbnail_ready.emit(id, ImageTexture.create_from_image(img))


func _start_gen(id: String) -> void:
	var cd := ClipLibrary.get_clip(id)
	if cd == null or not Storage.exists(cd.path):
		_pending.erase(id)
		return
	_ensure_extractor()
	_busy_id = id
	_busy_since = Time.get_ticks_msec() / 1000.0
	# enable_auto_play stays false, so the worker decodes frame 0 and holds it;
	# _on_extractor_loaded renders that one frame and reads it back.
	_extractor.set_video_path(Storage.playable(cd.path))   # SAF-aware (core/storage.gd)


## True when the clip never gave a frame (CAN'T PLAY in the grid).
func is_failed(id: String) -> bool:
	return _failed.has(id)


## A rescan or a new import may have replaced the file: try it again.
func forget_failure(id: String) -> void:
	_failed.erase(id)


## A deck could not open the clip either (ClipEngine.clip_failed): CAN'T PLAY.
func mark_failed(id: String) -> void:
	if id == "" or _failed.has(id):
		return
	_pending.erase(id)
	_gen_queue.erase(id)
	_load_queue.erase(id)
	_failed[id] = true
	thumbnail_failed.emit(id)


func _give_up(id: String) -> void:
	_busy_id = ""
	_pending.erase(id)
	_failed[id] = true
	var cd := ClipLibrary.get_clip(id)
	print("[Thumbs] %s gave no frame in %.0f s — CAN'T PLAY" % [cd.display_name if cd != null else id, GEN_TIMEOUT_SEC])
	thumbnail_failed.emit(id)


func _on_extractor_loaded() -> void:
	if _busy_id != "":
		_capture()


func _capture() -> void:
	var id := _busy_id
	var cd := ClipLibrary.get_clip(id)
	# Render exactly one frame into the extractor, then read it back next draw.
	_extractor_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if _busy_id != id:
		return   # a later request superseded us (shouldn't happen — we serialize)
	var img: Image = _extractor_vp.get_texture().get_image()
	_busy_id = ""            # free the extractor for the next request immediately
	_pending.erase(id)
	if cd == null or img == null or img.is_empty():
		return
	# Drop alpha before encoding: the extractor renders on opaque black (no
	# transparency to keep), and RGBA lossy WebP is the flaky Godot path — RGB8
	# lossless is small at 256x144 and reliable on-device. EXTRACT_SIZE is already
	# 256x144 (256 long edge), so no resize is needed.
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	_gen_done += 1
	print("[Thumbs] generated %s (%s) — %d done" % [id, cd.display_name, _gen_done])
	thumbnail_ready.emit(id, ImageTexture.create_from_image(img))
	# The lossless WebP encode + write runs on a worker, off the frame: until
	# beta4 it ran here, on the main thread, once per thumbnail while the deck
	# played (docs/STORAGE_GROWTH_AUDIT.md). The texture above is already on the
	# GPU. While it writes, a request() for this id generates again rather than
	# loading a half-written file.
	_saving[id] = true
	var path := cd.thumb_cache_path
	var label := cd.display_name
	WorkerThreadPool.add_task(func() -> void:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var err := img.save_webp(path, false)   # lossless
		if err != OK:
			print("[Thumbs] save FAILED %s err=%d" % [label, err])
		call_deferred("_saved", id))


func _saved(id: String) -> void:
	_saving.erase(id)


func _ensure_extractor() -> void:
	if _extractor_vp != null:
		return
	var vp := SubViewport.new()
	vp.name = "ThumbExtractor"
	vp.size = EXTRACT_SIZE
	vp.transparent_bg = false   # opaque black — thumbnails need no alpha, keeps RGB8
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var p := VideoPlayback.new()
	p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	p.loop = false
	p.enable_auto_play = false      # hold frame 0
	p.enable_audio = false          # never open the audio track (main-thread cost)
	p.video_loaded.connect(_on_extractor_loaded)
	vp.add_child(p)
	p.video_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_extractor_vp = vp
	_extractor = p
