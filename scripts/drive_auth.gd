## DriveAuth.gd — PRO-only singleton at /root/DriveAuth (core/features.gd creates it; the public .pck leaves this file out)
##
## On-device Google OAuth 2.0 using the **Authorization Code + PKCE** flow with a
## **loopback redirect** — pure GDScript, no laptop, no native plugin, no manifest
## changes. (The simpler device-code flow can NOT be used: Google rejects Drive
## scopes there with invalid_scope.)
##
## Flow:
##   1. begin_auth() opens the system browser to Google's consent page and starts a
##      tiny TCPServer on 127.0.0.1:<REDIRECT_PORT>.
##   2. The user approves; Google redirects the browser to http://127.0.0.1:<port>/
##      ?code=... — our local server reads the auth code and shows a "done" page.
##   3. We exchange code (+ PKCE verifier) for access + refresh tokens.
##   4. ensure_token(cb) hands callers a fresh access token, refreshing when stale.
##
## Tokens persist in user://drive_auth.cfg (app-private on Android). Use a Google
## Cloud **"Desktop app"** OAuth client (loopback redirect is implicit for that type;
## Drive scopes are supported).

extends Node

# ── OAuth client (Google Cloud Console → Credentials → "Desktop app"). ─────────
# Not in the repository. Copy secrets/drive_oauth.example.cfg to
# secrets/drive_oauth.cfg (git-ignored) and fill in your own client; the Pro
# export preset packs that file, the public and debug presets leave it out.
# Without it, Drive sign-in reports that it is not configured.
const OAUTH_CFG_PATH: String = "res://secrets/drive_oauth.cfg"
var CLIENT_ID: String = ""
var CLIENT_SECRET: String = ""

const SCOPE: String = "https://www.googleapis.com/auth/drive.readonly"
const AUTH_URL: String = "https://accounts.google.com/o/oauth2/v2/auth"
const TOKEN_URL: String = "https://oauth2.googleapis.com/token"

const REDIRECT_PORT: int = 8910
const REDIRECT_URI: String = "http://127.0.0.1:8910"
const AUTH_TIMEOUT: float = 240.0   # give up waiting for the browser redirect

const STORE_PATH: String = "user://drive_auth.cfg"
const EXPIRY_SKEW: int = 60   # refresh this many seconds before real expiry

# ── Signals ───────────────────────────────────────────────────────────────────
signal auth_started()                      ## browser opened — UI should say "waiting"
signal authorized()                        ## tokens obtained / restored
signal auth_failed(message: String)        ## flow could not complete
signal auth_required()                     ## no/invalid refresh token — UI should re-auth
signal signed_out()

# ── Token state ───────────────────────────────────────────────────────────────
var _access_token: String = ""
var _refresh_token: String = ""
var _expiry_unix: int = 0

# ── PKCE / loopback flow state ────────────────────────────────────────────────
var _verifier: String = ""
var _state: String = ""
var _server: TCPServer
var _peer: StreamPeerTCP
var _peer_buf: String = ""
var _awaiting: bool = false
var _deadline: float = 0.0

# ── Request plumbing (token exchange + refresh) ───────────────────────────────
enum _Kind { NONE, EXCHANGE, REFRESH }
var _http: HTTPRequest
var _kind: int = _Kind.NONE
var _token_waiters: Array[Callable] = []
var _refreshing: bool = false


func _ready() -> void:
	_load_oauth_client()
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_load_store()
	if not _refresh_token.is_empty():
		_log("restored refresh token")


func _process(_delta: float) -> void:
	if not _awaiting:
		return
	if Time.get_unix_time_from_system() > _deadline:
		_cancel_loopback()
		_handle_failure("timed out waiting for browser approval")
		return
	_pump_loopback()


# ── Public API ────────────────────────────────────────────────────────────────

func is_authorized() -> bool:
	return not _refresh_token.is_empty()


## Open the browser consent page + start the loopback listener.
func begin_auth() -> void:
	if CLIENT_ID.is_empty() or CLIENT_SECRET.is_empty():
		auth_failed.emit("Drive sign-in is not configured in this build (secrets/drive_oauth.cfg)")
		return
	if _awaiting or _kind != _Kind.NONE:
		_log("auth already in progress")
		return
	_server = TCPServer.new()
	var err: int = _server.listen(REDIRECT_PORT, "127.0.0.1")
	if err != OK:
		_handle_failure("could not open local port %d (err %d)" % [REDIRECT_PORT, err])
		return

	_verifier = _rand_token(48)
	_state = _rand_token(16)
	var challenge: String = _b64url(_sha256(_verifier))
	var url: String = "%s?%s" % [AUTH_URL, _form({
		"client_id": CLIENT_ID,
		"redirect_uri": REDIRECT_URI,
		"response_type": "code",
		"scope": SCOPE,
		"code_challenge": challenge,
		"code_challenge_method": "S256",
		"state": _state,
		"access_type": "offline",
		"prompt": "consent",
	})]
	_awaiting = true
	_deadline = Time.get_unix_time_from_system() + AUTH_TIMEOUT
	_log("opening consent page; listening on %s" % REDIRECT_URI)
	OS.shell_open(url)
	auth_started.emit()


## Hand the caller a valid access token, refreshing transparently if stale.
## cb is called as cb.call(access_token: String, err: String) — err == "" on success.
func ensure_token(cb: Callable) -> void:
	var now: int = int(Time.get_unix_time_from_system())
	if not _access_token.is_empty() and now < _expiry_unix - EXPIRY_SKEW:
		cb.call(_access_token, "")
		return
	if _refresh_token.is_empty():
		cb.call("", "not authorized")
		auth_required.emit()
		return
	_token_waiters.append(cb)
	_refresh_token_now()


## Force the next ensure_token() to refresh (call after the API returns 401).
func invalidate_access() -> void:
	_expiry_unix = 0


## Forget all tokens (user explicitly signs out).
func sign_out() -> void:
	_access_token = ""
	_refresh_token = ""
	_expiry_unix = 0
	_cancel_loopback()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STORE_PATH))
	signed_out.emit()


# ── Loopback redirect listener ────────────────────────────────────────────────

func _pump_loopback() -> void:
	if _peer == null:
		if not _server.is_connection_available():
			return
		_peer = _server.take_connection()
		_peer_buf = ""
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var avail: int = _peer.get_available_bytes()
	if avail > 0:
		var chunk: Array = _peer.get_partial_data(avail)
		var bytes: PackedByteArray = chunk[1]
		_peer_buf += bytes.get_string_from_utf8()
	if not _peer_buf.contains("\r\n"):
		return   # wait for the full request line

	var first_line: String = _peer_buf.split("\r\n")[0]
	var params: Dictionary = _parse_redirect_query(first_line)
	if not params.has("code") and not params.has("error"):
		# Not the redirect (e.g. a favicon probe) — answer + keep listening.
		_respond(_peer, "ignored")
		_peer = null
		return

	_respond(_peer, "<h2>PocketVJ linked ✓</h2><p>You can close this tab and return to the app.</p>")
	_cancel_loopback()

	if str(params.get("state", "")) != _state:
		_handle_failure("state mismatch (possible CSRF) — try again")
		return
	if params.has("error"):
		_handle_failure("access denied: %s" % str(params["error"]))
		return
	_exchange_code(str(params["code"]))


func _parse_redirect_query(request_line: String) -> Dictionary:
	var out: Dictionary = {}
	var parts: PackedStringArray = request_line.split(" ")
	if parts.size() < 2:
		return out
	var path: String = parts[1]
	var qpos: int = path.find("?")
	if qpos == -1:
		return out
	for kv: String in path.substr(qpos + 1).split("&"):
		var eq: int = kv.find("=")
		if eq != -1:
			out[kv.substr(0, eq)] = kv.substr(eq + 1).uri_decode()
	return out


func _respond(peer: StreamPeerTCP, body_html: String) -> void:
	var html: String = "<!doctype html><html><body style='font-family:sans-serif;background:#0b0d12;color:#dde;text-align:center;padding-top:60px'>%s</body></html>" % body_html
	var payload: PackedByteArray = html.to_utf8_buffer()
	var resp: String = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % payload.size()
	peer.put_data(resp.to_utf8_buffer())
	peer.put_data(payload)
	peer.poll()
	peer.disconnect_from_host()


func _cancel_loopback() -> void:
	_awaiting = false
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _server != null:
		_server.stop()
		_server = null


# ── Token exchange / refresh ──────────────────────────────────────────────────

func _exchange_code(code: String) -> void:
	var body: String = _form({
		"client_id": CLIENT_ID,
		"client_secret": CLIENT_SECRET,
		"code": code,
		"code_verifier": _verifier,
		"grant_type": "authorization_code",
		"redirect_uri": REDIRECT_URI,
	})
	_kind = _Kind.EXCHANGE
	_post(TOKEN_URL, body)


func _refresh_token_now() -> void:
	if _refreshing:
		return
	_refreshing = true
	var body: String = _form({
		"client_id": CLIENT_ID,
		"client_secret": CLIENT_SECRET,
		"refresh_token": _refresh_token,
		"grant_type": "refresh_token",
	})
	_kind = _Kind.REFRESH
	_post(TOKEN_URL, body)


func _post(url: String, body: String) -> void:
	var headers: PackedStringArray = ["Content-Type: application/x-www-form-urlencoded"]
	var err: int = _http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_log("request error %d for %s" % [err, url])
		_handle_failure("network error (%d)" % err)


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
	var kind: int = _kind
	_kind = _Kind.NONE
	var data: Dictionary = {}
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) == OK and typeof(json.data) == TYPE_DICTIONARY:
		data = json.data

	if result != HTTPRequest.RESULT_SUCCESS:
		_log("transport failure result=%d code=%d kind=%d" % [result, code, kind])
		_handle_failure("network error (result %d)" % result)
		return

	match kind:
		_Kind.EXCHANGE:
			if code == 200:
				_store_tokens(data)
				_log("authorized via loopback flow")
				authorized.emit()
			else:
				_log("token exchange HTTP %d body=%s" % [code, JSON.stringify(data)])
				_handle_failure("token exchange failed (HTTP %d)" % code)
		_Kind.REFRESH:
			_on_refresh_response(code, data)


func _on_refresh_response(code: int, data: Dictionary) -> void:
	_refreshing = false
	if code == 200:
		_store_tokens(data)            # refresh responses omit refresh_token; we keep ours
		_log("access token refreshed")
		_drain_waiters(_access_token, "")
		return
	var oauth_err: String = str(data.get("error", "HTTP %d" % code))
	_log("refresh failed: %s" % oauth_err)
	if oauth_err == "invalid_grant":
		# Refresh token revoked or expired (e.g. 7-day limit on a Testing consent
		# screen). Clear it and ask the UI to re-link the account.
		_access_token = ""
		_refresh_token = ""
		_expiry_unix = 0
		_save_store()
		_drain_waiters("", "auth_required")
		auth_required.emit()
	else:
		_drain_waiters("", "refresh failed: %s" % oauth_err)


# ── Token storage ─────────────────────────────────────────────────────────────

func _store_tokens(data: Dictionary) -> void:
	var at: String = str(data.get("access_token", ""))
	if not at.is_empty():
		_access_token = at
	var expires_in: int = int(data.get("expires_in", 3600))
	_expiry_unix = int(Time.get_unix_time_from_system()) + expires_in
	var rt: String = str(data.get("refresh_token", ""))
	if not rt.is_empty():
		_refresh_token = rt            # only present on the initial authorization grant
	_save_store()


func _save_store() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("drive", "refresh_token", _refresh_token)
	cfg.set_value("drive", "access_token", _access_token)
	cfg.set_value("drive", "expiry_unix", _expiry_unix)
	cfg.save(STORE_PATH)


func _load_store() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(STORE_PATH) != OK:
		return
	_refresh_token = str(cfg.get_value("drive", "refresh_token", ""))
	_access_token = str(cfg.get_value("drive", "access_token", ""))
	_expiry_unix = int(cfg.get_value("drive", "expiry_unix", 0))


# ── Helpers ───────────────────────────────────────────────────────────────────

func _drain_waiters(token: String, err: String) -> void:
	var waiters: Array[Callable] = _token_waiters.duplicate()
	_token_waiters.clear()
	for cb: Callable in waiters:
		if cb.is_valid():
			cb.call(token, err)


func _handle_failure(message: String) -> void:
	_kind = _Kind.NONE
	_cancel_loopback()
	auth_failed.emit(message)
	if _refreshing:
		_refreshing = false
		_drain_waiters("", message)


func _form(fields: Dictionary) -> String:
	var parts: PackedStringArray = []
	for key: String in fields:
		parts.append("%s=%s" % [key.uri_encode(), str(fields[key]).uri_encode()])
	return "&".join(parts)


func _rand_token(n_bytes: int) -> String:
	var crypto := Crypto.new()
	return _b64url(crypto.generate_random_bytes(n_bytes))


func _sha256(text: String) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish()


func _b64url(bytes: PackedByteArray) -> String:
	var s: String = Marshalls.raw_to_base64(bytes)
	return s.replace("+", "-").replace("/", "_").replace("=", "")


func _log(msg: String) -> void:
	print("[DriveAuth] %s" % msg)


func _load_oauth_client() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(OAUTH_CFG_PATH) != OK:
		push_warning("[drive] no %s — Drive sign-in disabled" % OAUTH_CFG_PATH)
		return
	CLIENT_ID = str(cfg.get_value("oauth", "client_id", ""))
	CLIENT_SECRET = str(cfg.get_value("oauth", "client_secret", ""))
