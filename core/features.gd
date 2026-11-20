extends Node
## Features — the one place that decides what this build contains.
##
## VJMIX Mobile ships as two builds from one tree:
##   "VJMIX Mobile"      (Play, public)  — no custom feature
##   "VJMIX Mobile Pro"  (sideloaded)    — export custom feature "pro"
##
## The flags gate GDScript: a pro module's node is never built and its UI entry
## never created when its flag is false. They do NOT stop Kotlin compiling —
## that is the Gradle `tier` flavor's job (android/build/build.gradle), and the
## two are kept in step by addons/vjmix_edition (the export plugin that turns
## the "pro" feature into the Gradle flavor).
##
## ⚠️ Most pro GDScript still ships inside the public .pck: pipeline.gd names
## the pro classes statically, so removing their files would break parsing.
## They are inert there — nothing constructs them. The network modules are the
## exception: ClipServer / DriveAuth / DriveClient are not autoloads but are
## created in _ready below (pro only), and the public presets' exclude_filter
## leaves them, their two browser scenes and the OAuth secret out of the .pck.
##
## Desktop / headless runs have no export features, so they are the PUBLIC
## build unless `-- --pro` is passed (user args, after the `--`).

var PRO: bool = is_pro()

## Pro-only (personal tooling).
var LED_DDP: bool = PRO          ## DDP/LED panel output (+ the Life panel source)
var TD_PVJ_LINK: bool = PRO      ## the PVJ/TouchDesigner video link + lane B PEER/TD
var MEDIAPIPE: bool = PRO        ## tracking, crowd, trigger lanes, tracking FX
var OSC: bool = PRO              ## OSC in + out
var DRIVE_OAUTH: bool = PRO      ## the in-app Google Drive browser (drive.readonly OAuth)
var CLIP_SERVER: bool = PRO      ## the laptop FastAPI clip server

## Public.
var SET_RECORD: bool = true      ## set recording (SurfaceRecorder/AudioEncoder/SegmentMuxer)
var GAME_OF_LIFE: bool = true
var DRIVE_IMPORT: bool = true    ## Drive via the system (SAF) picker — no OAuth


## The same answer without the autoload, for scripts that can compile before
## autoloads exist: headless tools/ preload pro modules under --script, where
## the `Features` identifier does not resolve. Those scripts do
## `const FeaturesS := preload("res://core/features.gd")` and ask this.
static func is_pro() -> bool:
	return OS.has_feature("pro") or OS.get_cmdline_user_args().has("--pro")


## The pro network singletons, in creation order (DriveClient asks DriveAuth).
## Loaded by path so nothing in the public build references their files.
const PRO_NETWORK_NODES: Array = [
	["ClipServer", "res://scripts/clip_server.gd"],
	["DriveAuth", "res://scripts/drive_auth.gd"],
	["DriveClient", "res://scripts/drive_client.gd"],
]


func _ready() -> void:
	print("[features] %s build" % ("PRO" if PRO else "PUBLIC"))
	if PRO:
		# Deferred: the root is still adding autoloads. They land before any
		# deferred call the main scene queues in its own _ready.
		for entry: Array in PRO_NETWORK_NODES:
			var node: Node = (load(entry[1]) as GDScript).new()
			node.name = entry[0]
			get_tree().root.add_child.call_deferred(node)
