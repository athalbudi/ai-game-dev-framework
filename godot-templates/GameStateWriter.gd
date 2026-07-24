## GameStateWriter.gd
## Utility standalone untuk menulis game_state.json ke user://shots/
## Daftarkan sebagai Autoload di project.godot:
##
##   [autoload]
##   GameStateWriter="*res://scripts/GameStateWriter.gd"
##
## Cara pakai dari kode game:
##   GameStateWriter.write({"player": {"hp": 100}, "scene": "Battle"})
##
## Atau via method helper:
##   GameStateWriter.write_from_node(self)  # jika node punya _get_game_state()

extends Node

const OUTPUT_PATH := "user://shots/game_state.json"

# Scene tracking -- diupdate oleh game via report_scene()
# ScenarioRunner pakai ini untuk wait_scene yang tidak bergantung pada Godot scene transition
var _current_scene_label: String = ""

signal scene_label_changed(label: String)

## Report scene aktif ke framework.
## Dipanggil dari game saat layar berubah -- menggantikan Godot scene transition
## yang tidak dipakai oleh game dengan navigasi programmatic.
##
## Contoh pemakaian:
##   GameStateWriter.report_scene("title")
##   GameStateWriter.report_scene("battle")
##   GameStateWriter.report_scene("map")
##
## ScenarioRunner mendengarkan scene_label_changed signal untuk wait_scene step.
func report_scene(label: String) -> void:
	if _current_scene_label == label:
		return
	_current_scene_label = label
	print("[GameStateWriter] scene: %s" % label)
	scene_label_changed.emit(label)

## Ambil label scene aktif.
func get_current_scene() -> String:
	return _current_scene_label

## Implementasi _write_game_state() yang dicari oleh ScenarioRunner.
## Dipanggil otomatis saat step write_state dieksekusi.
## Game bisa override ini dengan mengimplementasikan _get_game_state() di node manapun.
func _write_game_state() -> void:
	# Cari node yang punya _get_game_state() -- game-specific state provider
	var providers := _find_nodes_with_method(get_tree().root, "_get_game_state")
	var state: Dictionary
	if providers.is_empty():
		# Fallback: tulis minimal universal state
		# Field 'build' sengaja dikosongkan karena GameStateWriter tidak tahu versi game.
		# Game yang implement _get_game_state() harus menyertakan field 'build' sendiri.
		state = {
			"schema_version": "1.0",
			"build": "unknown",
			"timestamp": Time.get_datetime_string_from_system(),
			"current_scene": _current_scene_label,
			"frame_count": Engine.get_process_frames(),
			"error_log": [],
		}
		if has_node("/root/ErrorTracker"):
			var et := get_node("/root/ErrorTracker")
			# Gunakan .call() agar kompatibel dengan GDScript strict mode (unsafe_method_access)
			if et.has_method("get_errors"):
				state["error_log"] = et.call("get_errors")
	else:
		state = providers[0].call("_get_game_state")
		# Pastikan field universal selalu ada
		if not state.has("schema_version"): state["schema_version"] = "1.0"
		if not state.has("build"): state["build"] = "unknown"
		if not state.has("current_scene"): state["current_scene"] = _current_scene_label
		if not state.has("frame_count"): state["frame_count"] = Engine.get_process_frames()
		if not state.has("timestamp"): state["timestamp"] = Time.get_datetime_string_from_system()
	write(state)

## Tulis Dictionary ke game_state.json.
## Dipanggil dari _write_game_state() di node game, atau langsung dari manapun.
static func write(state: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("user://shots")
	)
	var file := FileAccess.open(OUTPUT_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[GameStateWriter] Gagal menulis %s: %s" % [
			OUTPUT_PATH, error_string(FileAccess.get_open_error())
		])
		return
	file.store_string(JSON.stringify(state, "\t"))
	file.close()

## Cari node di tree yang punya _get_game_state() dan tulis hasilnya.
## Berguna jika game punya satu node central yang mengelola state.
static func write_from_node(root: Node) -> void:
	var writers := _find_nodes_with_method(root, "_get_game_state")
	if writers.is_empty():
		push_warning("[GameStateWriter] Tidak ada node dengan _get_game_state() di tree.")
		return
	var state: Dictionary = writers[0].call("_get_game_state")
	write(state)

static func _find_nodes_with_method(node: Node, method_name: String) -> Array[Node]:
	var result: Array[Node] = []
	if node.has_method(method_name):
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_nodes_with_method(child, method_name))
	return result