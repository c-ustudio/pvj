## DriveClient.gd — PRO-only singleton at /root/DriveClient (core/features.gd creates it, after DriveAuth)
##
## Thin Google Drive REST v3 layer over DriveAuth. Two jobs:
##   • list_folder(folder_id)  — list a folder's sub-folders + video files (paginated)
##   • download_file(id, name) — stream a file to the local clip cache with progress
##
## Every call grabs a fresh access token from DriveAuth.ensure_token(). A single 401
## (token revoked server-side) triggers one forced refresh + retry.
##
## Downloads land in `cache_dir` (set by pipeline.gd to clip_engine.clips_dir so the
## existing GoZen scan/play path picks them up). A sidecar user://drive_cache.cfg maps
## fileId -> filename so an already-downloaded clip is skipped.

extends Node

const FILES_URL: String = "https://www.googleapis.com/drive/v3/files"
const ROOT_ID: String = "root"
const FOLDER_MIME: String = "application/vnd.google-apps.folder"
const PAGE_SIZE: int = 200
const CACHE_MAP_PATH: String = "user://drive_cache.cfg"
const THUMB_DIR: String = "user://thumb_cache"
const THUMB_H: int = 72   # rendered thumbnail height (px)

## Where downloaded clips are written. pipeline.gd overrides this with
## clip_engine.clips_dir (the public PocketVJ/clips folder on Android).
var cache_dir: String = "user://clips"

# ── Signals ───────────────────────────────────────────────────────────────────
## items: Array[Dictionary] each {id, name, mimeType, size, is_folder}
signal folder_listed(folder_id: String, items: Array)
signal list_failed(folder_id: String, message: String)
signal download_progress(file_id: String, pct: float)
signal download_done(file_id: String, local_path: String)
signal download_failed(file_id: String, message: String)

# ── List state (one listing at a time) ────────────────────────────────────────
var _list_http: HTTPRequest
var _list_folder_id: String = ""
var _list_items: Array = []
var _list_retried: bool = false

# ── Downloads (concurrent; one HTTPRequest each) ──────────────────────────────
# HTTPRequest -> { "file_id": String, "name": String, "path": String, "retried": bool }
var _downloads: Dictionary = {}
# Pro only: created by core/features.gd right before this node, not an autoload.
@onready var DriveAuth: Node = get_node("/root/DriveAuth")


func _ready() -> void:
	_list_http = HTTPRequest.new()
	add_child(_list_http)
	_list_http.request_completed.connect(_on_list_completed)
	DirAccess.make_dir_recursive_absolute(cache_dir)
	DirAccess.make_dir_recursive_absolute(THUMB_DIR)


func _process(_delta: float) -> void:
	# Emit live progress for any in-flight downloads.
	for http: HTTPRequest in _downloads:
		var total: int = http.get_body_size()
		if total > 0:
			var got: int = http.get_downloaded_bytes()
			var ctx: Dictionary = _downloads[http]
			download_progress.emit(str(ctx["file_id"]), float(got) / float(total))


# ── Listing ───────────────────────────────────────────────────────────────────

## List sub-folders + video files inside `folder_id` ("root" for My Drive top).
func list_folder(folder_id: String) -> void:
	_list_folder_id = folder_id
	_list_items = []
	_list_retried = false
	_request_list_page("")


func _request_list_page(page_token: String) -> void:
	DriveAuth.ensure_token(func(token: String, err: String) -> void:
		if err != "":
			list_failed.emit(_list_folder_id, "auth: %s" % err)
			return
		var url: String = _build_list_url(_list_folder_id, page_token)
		var headers: PackedStringArray = ["Authorization: Bearer %s" % token]
		var rc: int = _list_http.request(url, headers, HTTPClient.METHOD_GET)
		if rc != OK:
			list_failed.emit(_list_folder_id, "request error %d" % rc)
	)


func _build_list_url(folder_id: String, page_token: String) -> String:
	var q: String = "'%s' in parents and trashed=false" % folder_id
	var fields: String = "nextPageToken,files(id,name,mimeType,size,modifiedTime,thumbnailLink)"
	var url: String = "%s?q=%s&fields=%s&pageSize=%d&orderBy=%s&supportsAllDrives=true&includeItemsFromAllDrives=true" % [
		FILES_URL, q.uri_encode(), fields.uri_encode(), PAGE_SIZE, "folder,name".uri_encode(),
	]
	if not page_token.is_empty():
		url += "&pageToken=" + page_token.uri_encode()
	return url


func _on_list_completed(result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		list_failed.emit(_list_folder_id, "network error (result %d)" % result)
		return
	if code == 401 and not _list_retried:
		_list_retried = true
		DriveAuth.invalidate_access()
		_request_list_page("")            # restart this listing with a fresh token
		return
	if code != 200:
		list_failed.emit(_list_folder_id, "HTTP %d" % code)
		return

	var data: Dictionary = _parse(raw)
	var files: Array = data.get("files", [])
	for f: Dictionary in files:
		var mime: String = str(f.get("mimeType", ""))
		var is_folder: bool = mime == FOLDER_MIME
		# mimeType filter: keep folders + any video/* clip.
		if not is_folder and not mime.begins_with("video/"):
			continue
		_list_items.append({
			"id": str(f.get("id", "")),
			"name": str(f.get("name", "?")),
			"mimeType": mime,
			"size": int(str(f.get("size", "0"))),   # Drive sends size as a string
			"is_folder": is_folder,
			"thumbnailLink": str(f.get("thumbnailLink", "")),
		})

	var next_token: String = str(data.get("nextPageToken", ""))
	if not next_token.is_empty():
		_request_list_page(next_token)        # more pages to fetch
		return

	folder_listed.emit(_list_folder_id, _list_items)


# ── Download ──────────────────────────────────────────────────────────────────

## Download a Drive file into the local clip cache. No-ops (emits download_done)
## if it was already fetched and still exists on disk.
func download_file(file_id: String, filename: String) -> void:
	var local: String = cache_dir.path_join(filename)
	if _is_cached(file_id, local):
		download_done.emit(file_id, local)
		return
	_start_download(file_id, filename, local, false)


func _start_download(file_id: String, filename: String, local: String, retried: bool) -> void:
	DriveAuth.ensure_token(func(token: String, err: String) -> void:
		if err != "":
			download_failed.emit(file_id, "auth: %s" % err)
			return
		var http := HTTPRequest.new()
		add_child(http)
		http.download_file = local
		http.request_completed.connect(_on_download_completed.bind(http))
		_downloads[http] = {"file_id": file_id, "name": filename, "path": local, "retried": retried}
		var url: String = "%s/%s?alt=media&supportsAllDrives=true" % [FILES_URL, file_id.uri_encode()]
		var headers: PackedStringArray = ["Authorization: Bearer %s" % token]
		var rc: int = http.request(url, headers, HTTPClient.METHOD_GET)
		if rc != OK:
			_downloads.erase(http)
			http.queue_free()
			download_failed.emit(file_id, "request error %d" % rc)
	)


func _on_download_completed(result: int, code: int, _headers: PackedStringArray, _raw: PackedByteArray, http: HTTPRequest) -> void:
	var ctx: Dictionary = _downloads.get(http, {})
	_downloads.erase(http)
	http.queue_free()
	if ctx.is_empty():
		return
	var file_id: String = str(ctx["file_id"])
	var filename: String = str(ctx["name"])
	var local: String = str(ctx["path"])
	var retried: bool = bool(ctx["retried"])

	if code == 401 and not retried:
		DriveAuth.invalidate_access()
		_remove_partial(local)
		_start_download(file_id, filename, local, true)
		return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_remove_partial(local)
		download_failed.emit(file_id, "download failed (HTTP %d / result %d)" % [code, result])
		return

	_remember_cached(file_id, filename)
	download_progress.emit(file_id, 1.0)
	download_done.emit(file_id, local)


# ── Thumbnails (lazy, disk-cached) ────────────────────────────────────────────

## Fetch a video's Drive thumbnail as a ready-to-use Texture2D (resized to THUMB_H).
## Served from user://thumb_cache/<id>.jpg when already fetched. cb.call(tex_or_null).
func fetch_thumbnail(file_id: String, thumb_url: String, cb: Callable) -> void:
	var local: String = THUMB_DIR.path_join(file_id + ".jpg")
	if FileAccess.file_exists(local):
		cb.call(_load_thumb(local))
		return
	if thumb_url.is_empty():
		cb.call(null)
		return
	DriveAuth.ensure_token(func(token: String, err: String) -> void:
		if err != "":
			cb.call(null)
			return
		var http := HTTPRequest.new()
		add_child(http)
		http.request_completed.connect(func(result, rcode, _h, body):
			http.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or rcode != 200 or body.is_empty():
				cb.call(null)
				return
			var f := FileAccess.open(local, FileAccess.WRITE)
			if f != null:
				f.store_buffer(body)
				f.close()
			cb.call(_decode_thumb(body))
		)
		var headers: PackedStringArray = ["Authorization: Bearer %s" % token]
		if http.request(thumb_url, headers, HTTPClient.METHOD_GET) != OK:
			http.queue_free()
			cb.call(null)
	)


func _load_thumb(path: String) -> Texture2D:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	return _decode_thumb(bytes)


func _decode_thumb(bytes: PackedByteArray) -> Texture2D:
	var img := Image.new()
	if img.load_jpg_from_buffer(bytes) != OK and img.load_png_from_buffer(bytes) != OK:
		return null
	var h: int = img.get_height()
	if h > 0:
		var tw: int = int(float(img.get_width()) / float(h) * float(THUMB_H))
		img.resize(maxi(1, tw), THUMB_H)
	return ImageTexture.create_from_image(img)


# ── Cache map (fileId -> filename) ────────────────────────────────────────────

func _is_cached(file_id: String, local_path: String) -> bool:
	if not FileAccess.file_exists(local_path):
		return false
	var cfg := ConfigFile.new()
	if cfg.load(CACHE_MAP_PATH) != OK:
		return false
	return str(cfg.get_value("files", file_id, "")) != ""


func _remember_cached(file_id: String, filename: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CACHE_MAP_PATH)               # ok if missing
	cfg.set_value("files", file_id, filename)
	cfg.save(CACHE_MAP_PATH)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _remove_partial(local_path: String) -> void:
	if FileAccess.file_exists(local_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(local_path))


func _parse(raw: PackedByteArray) -> Dictionary:
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) == OK and typeof(json.data) == TYPE_DICTIONARY:
		return json.data
	return {}
