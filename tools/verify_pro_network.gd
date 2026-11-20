extends SceneTree
## Headless: the pro network singletons exist only in the pro build, and the
## public presets leave their files (and the OAuth secret) out of the .pck.
##
##   godot --headless --script tools/verify_pro_network.gd              (public)
##   godot --headless --script tools/verify_pro_network.gd -- --pro     (pro)

const FeaturesS := preload("res://core/features.gd")

const PRO_FILES: Array[String] = [
	"scripts/clip_server.gd", "scripts/drive_auth.gd", "scripts/drive_client.gd",
	"scripts/clip_browser_ui.gd", "scripts/drive_browser_ui.gd",
	"scenes/ClipBrowser.tscn", "scenes/DriveBrowser.tscn",
]

var _checks: int = 0
var _failed: int = 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		print("FAIL: %s" % what)


func _initialize() -> void:
	# Features adds the nodes deferred; give it a few frames.
	for i in 5:
		await process_frame
	var pro := FeaturesS.is_pro()
	for entry: Array in FeaturesS.PRO_NETWORK_NODES:
		var node := root.get_node_or_null(str(entry[0]))
		_check((node != null) == pro, "/root/%s %s in the %s build" % [entry[0],
				"missing" if pro else "present", "pro" if pro else "public"])
	var autoloads := ProjectSettings.get_property_list().filter(
			func(p: Dictionary) -> bool: return str(p["name"]).begins_with("autoload/"))
	for p: Dictionary in autoloads:
		var path := str(ProjectSettings.get_setting(p["name"]))
		for f: String in PRO_FILES:
			_check(not path.ends_with(f), "%s is still an autoload" % f)
	_check_presets()
	_check_scripts_compile()
	print("verify_pro_network: %d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)


func _check_presets() -> void:
	var cfg := ConfigFile.new()
	_check(cfg.load("res://export_presets.cfg") == OK, "export_presets.cfg loads")
	for section: String in cfg.get_sections():
		if not cfg.has_section_key(section, "exclude_filter"):
			continue
		var pro := str(cfg.get_value(section, "custom_features", "")).split(",").has("pro")
		var excludes := str(cfg.get_value(section, "exclude_filter", ""))
		var name := str(cfg.get_value(section, "name", section))
		for f: String in PRO_FILES:
			var left_out := excludes.contains(f)
			_check(left_out != pro, "%s: %s %s" % [name, f,
					"left out of a pro build" if pro else "ships in a public build"])


## The pro scripts are left out of the public build, so only a pro export
## compiles them: a parse error there (an untyped `:=` once the singletons
## stopped being autoloads) shipped silently. Compile each one here, in either
## mode, so the headless check fails first.
func _check_scripts_compile() -> void:
	for f: String in PRO_FILES:
		if not f.ends_with(".gd"):
			continue
		# load(), not GDScript.new() + reload(): a fresh copy of a class_name
		# script fails with "hides a global script class".
		var s: Script = load("res://" + f)
		_check(s != null and s.can_instantiate(), "%s compiles" % f)
