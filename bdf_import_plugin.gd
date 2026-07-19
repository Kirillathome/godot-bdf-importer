@tool
extends EditorPlugin

var bitmap_importer: EditorImportPlugin


func _enter_tree() -> void:
	# Initialization of the plugin goes here.
	# casting to GDScript seems slightly cursed in concept, works great though
	bitmap_importer = (preload("res://addons/bdf_importer/bitmap_bdf_importer.gd") as GDScript).new()
	add_import_plugin(bitmap_importer)


func _exit_tree() -> void:
	# Clean-up of the plugin goes here.
	if bitmap_importer:
		remove_import_plugin(bitmap_importer)
		bitmap_importer = null
