@tool
extends EditorPlugin
## Registers the export plugin that selects the Gradle tier. See export_plugin.gd.

var _export: EditorExportPlugin


func _enter_tree() -> void:
	_export = preload("res://addons/vjmix_edition/export_plugin.gd").new()
	add_export_plugin(_export)


func _exit_tree() -> void:
	remove_export_plugin(_export)
	_export = null
