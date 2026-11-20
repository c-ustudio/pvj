@tool
extends EditorExportPlugin
## How an export preset picks the Android Gradle flavor (public / pro).
##
## Godot runs Gradle itself (`assemble<Edition><BuildType>` / `bundle…`) and
## forwards only a fixed set of -P properties — package name, version, SDKs,
## ABIs, signing, plugin binaries. A preset's CUSTOM FEATURES are not among
## them, so Gradle cannot see "pro" on its own. This plugin bridges it:
##
##   _export_begin() sees the preset's features  →  writes
##   android/build/vjmix_tier.properties (tier=pro | tier=public)  →
##   build.gradle reads it, keeps only that tier's variants, and aliases
##   Godot's task names onto them.
##
## The file is rewritten at the start of EVERY Android export, so it can never
## carry the previous preset's tier into this one. build.gradle refuses to
## build without it (or an explicit -Pvjmix_tier=…), so an export with this
## plugin disabled fails loudly instead of silently shipping the wrong tier.

const TIER_FILE := "res://android/build/vjmix_tier.properties"


func _get_name() -> String:
	return "vjmix_edition"


func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	if not features.has("android"):
		return
	var tier := "pro" if features.has("pro") else "public"
	var f := FileAccess.open(TIER_FILE, FileAccess.WRITE)
	if f == null:
		push_error("[vjmix_edition] cannot write %s (%s) — Gradle will refuse to build"
			% [TIER_FILE, error_string(FileAccess.get_open_error())])
		return
	f.store_string("# Written by addons/vjmix_edition at export time. Do not edit or commit.\ntier=%s\n" % tier)
	f.close()
	print("[vjmix_edition] Gradle tier = %s" % tier)
