## ClipServer.gd — PRO-only singleton at /root/ClipServer
## core/features.gd creates it; the public .pck leaves this file out.
##
## Talks to the PocketVJ FastAPI server over WiFi.
## Emits signals so your UI reacts without polling manually.

extends Node

# ── Config ────────────────────────────────────────────────────────────────────
## Set this to the clip-server laptop's LAN IP (`ip addr` / `ipconfig`). The
## placeholder fails fast with a request_failed error instead of probing a host.
var server_ip: String = "<laptop-ip>"   # the PocketVJ clip server
var server_port: int = 8765

var base_url: String:
	get: return "http://%s:%d" % [server_ip, server_port]

# ── Signals ───────────────────────────────────────────────────────────────────
signal clips_loaded(clips: Array)
signal clip_deleted(filename: String, freed_mb: float)
signal clip_queued(filename: String)
signal drive_pull_started(filename: String)
signal drive_pull_status(filename: String, status: String, downloaded_mb: float)
signal storage_updated(info: Dictionary)
signal request_failed(endpoint: String, error: String)

# ── Internal ──────────────────────────────────────────────────────────────────
var _http_pool: Array[HTTPRequest] = []
var _pending: Dictionary = {}  # HTTPRequest -> callback

func _ready() -> void:
	# Pre-warm a few HTTPRequest nodes
	for i in 4:
		_http_pool.append(_make_http())


func _make_http() -> HTTPRequest:
	var h := HTTPRequest.new()
	add_child(h)
	h.request_completed.connect(_on_request_completed.bind(h))
	return h


func _get_http() -> HTTPRequest:
	for h in _http_pool:
		if not _pending.has(h):
			return h
	# Spawn extra if all busy
	var h := _make_http()
	_http_pool.append(h)
	return h


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	var cb: Callable = _pending.get(http, Callable())
	_pending.erase(http)
	if not cb.is_valid():
		return
	if result != HTTPRequest.RESULT_SUCCESS or code >= 400:
		cb.call(null, "HTTP %d / result %d" % [code, result])
		return
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) == OK:
		cb.call(json.data, null)
	else:
		cb.call(null, "JSON parse error")


func _request(method: int, endpoint: String, body: Variant, cb: Callable) -> void:
	var h := _get_http()
	_pending[h] = cb
	var url := base_url + endpoint
	var headers := ["Content-Type: application/json"]
	var body_str := JSON.stringify(body) if body != null else ""
	var err := h.request(url, headers, method, body_str)
	if err != OK:
		_pending.erase(h)
		cb.call(null, "Request error: %d" % err)


# ── Public API ────────────────────────────────────────────────────────────────

## Fetch the full clip list from the server.
## Emits clips_loaded(clips: Array) on success.
func fetch_clips() -> void:
	_request(HTTPClient.METHOD_GET, "/clips", null, func(data, err):
		if err:
			request_failed.emit("/clips", err)
			return
		clips_loaded.emit(data.get("clips", []))
	)


## Returns the full stream URL for a clip filename.
## Feed this directly into VideoStreamPlayer or an HTTP stream.
func clip_url(filename: String) -> String:
	return "%s/clips/%s" % [base_url, filename.uri_encode()]


## Delete a clip from local server storage.
## Emits clip_deleted(filename, freed_mb) on success.
func delete_clip(filename: String) -> void:
	_request(HTTPClient.METHOD_DELETE, "/clips/%s" % filename.uri_encode(), null, func(data, err):
		if err:
			request_failed.emit("/clips/DELETE", err)
			return
		clip_deleted.emit(data.get("deleted", filename), data.get("freed_mb", 0.0))
	)


## Pull a clip from Google Drive to the server.
## file_id: Drive file ID string
## filename: what to save it as locally (e.g. "tunnel_loop.mp4")
## Emits drive_pull_started, then poll drive_pull_status manually.
func pull_from_drive(file_id: String, filename: String) -> void:
	var body := {"file_id": file_id, "filename": filename}
	_request(HTTPClient.METHOD_POST, "/drive/pull", body, func(data, err):
		if err:
			request_failed.emit("/drive/pull", err)
			return
		drive_pull_started.emit(filename)
	)


## Poll download progress for a Drive pull.
## Emits drive_pull_status(filename, status, downloaded_mb).
func poll_drive_status(filename: String) -> void:
	_request(HTTPClient.METHOD_GET, "/drive/status/%s" % filename.uri_encode(), null, func(data, err):
		if err:
			return
		drive_pull_status.emit(
			data.get("filename", filename),
			data.get("status", "unknown"),
			data.get("downloaded_mb", 0.0)
		)
	)


## Get storage stats from the server.
## Emits storage_updated(info dict).
func fetch_storage() -> void:
	_request(HTTPClient.METHOD_GET, "/storage", null, func(data, err):
		if err:
			request_failed.emit("/storage", err)
			return
		storage_updated.emit(data)
	)
