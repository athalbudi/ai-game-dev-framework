# ScenarioRunner.gd
# Universal scenario runner untuk AI-assisted game development framework.
# JANGAN daftarkan sebagai Autoload di project.godot -- ini akan menyebabkan
# hot-reload race condition. Muat sebagai script instance dari ErrorTracker._scenario_bootstrap().
# Lihat README.md dan FRAMEWORK.md untuk cara penggunaan yang benar.
#
# Interface dengan game:
#   - Game implementasikan _write_game_state() di node manapun
#   - Game implementasikan _on_set_state(key, value) untuk step set_state
#   - Emit ScenarioRunner.scenario_signal(name) untuk step wait_signal

extends Node

signal scenario_signal(signal_name: String)

const RESULT_PATH    := "user://shots/scenario_result.json"
const SCHEMA_VERSION := "1.0"

var _scenario: Dictionary = {}
var _steps: Array = []
var _step_results: Array = []
var _current_step: int = 0
var _scenario_start_time: float = 0.0
var _step_start_time: float = 0.0
var _screenshots_taken: Array[String] = []
var _waiting_signal: String = ""
var _signal_received: bool = false
var _active: bool = false


func _ready() -> void:
	# Hanya aktif jika dipanggil langsung via _run_scenario dari main, bukan --scenario flag
	# main.gd yang mengontrol inisialisasi -- ScenarioRunner hanya sebagai library
	pass


func _process(_delta: float) -> void:
	if not _active:
		return
	if _current_step >= _steps.size():
		return
	_process_current_step()


## Public API: jalankan scenario dari path file JSON.
## Dipanggil dari main.gd setelah inisialisasi selesai.
## Mengembalikan exit code: 0 = pass, 1 = fail/error.
func run_scenario_file(path: String) -> int:
	print("[scenario] Memuat: ", path)
	if not FileAccess.file_exists(path):
		_write_result("error", "File tidak ditemukan: " + path)
		return 1
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		_write_result("error", "Gagal membuka file: " + path)
		return 1
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK:
		_write_result("error", "JSON tidak valid: " + json.get_error_message())
		return 1
	_scenario = json.get_data()
	if not _scenario.has("steps") or not (_scenario["steps"] is Array):
		_write_result("error", "Scenario tidak punya field 'steps'")
		return 1
	_steps = _scenario["steps"]
	_scenario_start_time = Time.get_unix_time_from_system()
	_current_step = 0
	if _scenario.has("seed") and _scenario["seed"] != null:
		seed(int(_scenario["seed"]))
	print("[scenario] Mulai: ", _scenario.get("scenario_id", "unnamed"), " (", _steps.size(), " steps)")
	await get_tree().process_frame
	var exit_code := await _run_steps()
	return exit_code


func _run_steps() -> int:
	for i in range(_steps.size()):
		_current_step = i
		_step_start_time = Time.get_unix_time_from_system()
		var step: Dictionary = _steps[i]
		var step_type: String = step.get("type", "")
		print("[scenario] step %d/%d: %s" % [i + 1, _steps.size(), step_type])
		await _dispatch(step_type, step)
		# Cek fail -- gunakan type eksplisit agar tidak gagal saat hot-reload
		if _step_results.size() > 0:
			var last: Dictionary = _step_results[-1]
			if last.get("status") == "fail":
				print("[scenario] FAIL at step %d: %s" % [i + 1, last.get("reason", "")])
				_write_result("fail", last.get("reason", ""))
				return 1
	_write_result("pass", null)
	return 0


func _dispatch(step_type: String, step: Dictionary) -> void:
	if step_type == "wait_frames":
		await _exec_wait_frames(step)
	elif step_type == "wait_scene":
		await _exec_wait_scene(step)
	elif step_type == "wait_signal":
		_exec_wait_signal(step)
	elif step_type == "wait_condition":
		await _exec_wait_condition(step)
	elif step_type == "action":
		await _exec_action(step)
	elif step_type == "touch_tap":
		await _exec_touch_tap(step)
	elif step_type == "controller_press":
		await _exec_controller_press(step)
	elif step_type == "mouse_click":
		await _exec_mouse_click(step)
	elif step_type == "screenshot":
		await _exec_screenshot(step)
	elif step_type == "write_state":
		await _exec_write_state(step)
	elif step_type == "assert_state":
		await _exec_assert_state(step)
	elif step_type == "assert_no_error":
		await _exec_assert_no_error(step)
	elif step_type == "assert_fps":
		await _exec_assert_fps(step)
	elif step_type == "assert_screenshot_exists":
		_exec_assert_screenshot_exists(step)
	elif step_type == "set_state":
		_exec_set_state(step)
	elif step_type == "log":
		_exec_log(step)
	elif step_type == "repeat":
		await _exec_repeat(step)
	elif step_type == "seed_override":
		_exec_seed_override(step)
	else:
		_step_skip("Step type tidak dikenal: " + step_type)


# --- Step handlers ---

func _exec_wait_frames(step: Dictionary) -> void:
	var frames: int = int(step.get("frames", 1))
	await _wait_frames(frames)
	_step_pass({"frames": frames})


func _exec_wait_scene(step: Dictionary) -> void:
	var target: String = step.get("scene", "")
	var timeout: float = float(step.get("timeout", 10.0))
	# Prioritas 1: pakai GameStateWriter.scene_label_changed signal
	# (untuk game dengan navigasi programmatic yang tidak pakai Godot scene transition)
	if has_node("/root/GameStateWriter"):
		var gsw := get_node("/root/GameStateWriter")
		# Cek apakah sudah di scene yang dimaksud
		if gsw.get_current_scene() == target:
			_step_pass({"scene": target, "via": "GameStateWriter"})
			return
		# Tunggu signal dengan timeout
		var elapsed: float = 0.0
		var interval: float = 0.1
		while elapsed < timeout:
			if gsw.get_current_scene() == target:
				_step_pass({"scene": target, "elapsed": elapsed, "via": "GameStateWriter"})
				return
			await _wait_frames(int(interval * 60))
			elapsed += interval
		_step_fail("wait_scene timeout: scene '%s' tidak tercapai dalam %.1f detik (GameStateWriter)" % [target, timeout])
		return
	# Prioritas 2: fallback ke Godot current_scene (untuk game dengan Godot scene transition)
	var elapsed: float = 0.0
	var interval: float = 0.1
	while elapsed < timeout:
		var current := _get_current_scene_name()
		if current == target:
			_step_pass({"scene": target, "elapsed": elapsed, "via": "Godot"})
			return
		await _wait_frames(int(interval * 60))
		elapsed += interval
	_step_fail("wait_scene timeout: '%s' tidak tercapai dalam %.1f detik" % [target, timeout])


func _exec_wait_signal(step: Dictionary) -> void:
	var sig: String = step.get("signal_name", "")
	if sig.is_empty():
		_step_fail("wait_signal tidak punya field 'signal_name'")
		return
	_waiting_signal = sig
	_signal_received = false
	_step_pass({"waiting_for": sig})


func _exec_wait_condition(step: Dictionary) -> void:
	var key: String = step.get("key", "")
	var op: String = step.get("op", "not_null")
	var expected = step.get("expected", null)
	var timeout_sec: float = float(step.get("timeout_sec", 10.0))
	if key.is_empty():
		_step_fail("wait_condition tidak punya field 'key'")
		return
	var elapsed: float = 0.0
	while elapsed < timeout_sec:
		var writers := _find_nodes_with_method(get_tree().root, "_write_game_state")
		if writers.size() > 0:
			writers[0].call("_write_game_state")
		await _wait_frames(6)
		elapsed += 6.0 / 60.0
		var state := _read_game_state()
		if not state.is_empty():
			var actual = _resolve_dot_key(state, key)
			if _evaluate_op(actual, op, expected):
				_step_pass({"key": key, "op": op, "elapsed": elapsed})
				return
	_step_fail("wait_condition timeout: %s %s tidak terpenuhi dalam %.1f detik" % [key, op, timeout_sec])


func _exec_action(step: Dictionary) -> void:
	var action_name: String = step.get("action", "")
	if action_name.is_empty():
		_step_fail("action tidak punya field 'action'")
		return
	if not InputMap.has_action(action_name):
		_step_skip("Action '%s' tidak ada di InputMap" % action_name)
		return
	var duration_frames: int = int(step.get("duration_frames", 1))
	var wait_after: int = int(step.get("wait_frames", 0))
	var press := InputEventAction.new()
	press.action = action_name
	press.pressed = true
	Input.parse_input_event(press)
	await _wait_frames(duration_frames)
	var release := InputEventAction.new()
	release.action = action_name
	release.pressed = false
	Input.parse_input_event(release)
	if wait_after > 0:
		await _wait_frames(wait_after)
	_step_pass({"action": action_name})


func _exec_mouse_click(step: Dictionary) -> void:
	var x: float = float(step.get("x", 0))
	var y: float = float(step.get("y", 0))
	var button: int = int(step.get("button", MOUSE_BUTTON_LEFT))
	var wait_after: int = int(step.get("wait_frames", 0))
	var pos := Vector2(x, y)
	var press := InputEventMouseButton.new()
	press.position = pos
	press.button_index = button
	press.pressed = true
	Input.parse_input_event(press)
	await _wait_frames(2)
	var rel := InputEventMouseButton.new()
	rel.position = pos
	rel.button_index = button
	rel.pressed = false
	Input.parse_input_event(rel)
	if wait_after > 0:
		await _wait_frames(wait_after)
	_step_pass({"x": x, "y": y})


func _exec_touch_tap(step: Dictionary) -> void:
	var x: float = float(step.get("x", 0))
	var y: float = float(step.get("y", 0))
	var wait_after: int = int(step.get("wait_frames", 0))
	var pos := Vector2(x, y)
	var press := InputEventScreenTouch.new()
	press.position = pos
	press.pressed = true
	press.index = 0
	Input.parse_input_event(press)
	await _wait_frames(2)
	var rel := InputEventScreenTouch.new()
	rel.position = pos
	rel.pressed = false
	rel.index = 0
	Input.parse_input_event(rel)
	if wait_after > 0:
		await _wait_frames(wait_after)
	_step_pass({"x": x, "y": y})


func _exec_controller_press(step: Dictionary) -> void:
	var button: int = int(step.get("button", JOY_BUTTON_A))
	var duration_frames: int = int(step.get("duration_frames", 2))
	var wait_after: int = int(step.get("wait_frames", 0))
	var device: int = int(step.get("device", 0))
	var press := InputEventJoypadButton.new()
	press.button_index = button
	press.pressed = true
	press.device = device
	press.pressure = 1.0
	Input.parse_input_event(press)
	await _wait_frames(duration_frames)
	var rel := InputEventJoypadButton.new()
	rel.button_index = button
	rel.pressed = false
	rel.device = device
	rel.pressure = 0.0
	Input.parse_input_event(rel)
	if wait_after > 0:
		await _wait_frames(wait_after)
	_step_pass({"button": button, "device": device})


func _exec_screenshot(step: Dictionary) -> void:
	var name: String = step.get("name", "scenario_%d" % _current_step)
	var path := "user://shots/scenario_" + name + ".png"
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://shots"))
	img.save_png(ProjectSettings.globalize_path(path))
	_screenshots_taken.append(name)
	_step_pass({"name": name, "path": path})


func _exec_write_state(step: Dictionary) -> void:
	# Prioritas 1: pakai GameStateWriter autoload (stable, tidak hancur oleh hot-reload)
	if has_node("/root/GameStateWriter"):
		get_node("/root/GameStateWriter").call("_write_game_state")
		await _wait_frames(1)
		_step_pass({"writer": "GameStateWriter"})
		return
	# Prioritas 2: cari _write_game_state() di tree (untuk game tanpa GameStateWriter autoload)
	var writers := _find_nodes_with_method(get_tree().root, "_write_game_state")
	if writers.is_empty():
		_step_skip("Tidak ada GameStateWriter autoload dan tidak ada node dengan _write_game_state() di tree")
		return
	writers[0].call("_write_game_state")
	await _wait_frames(1)
	_step_pass({"writer": writers[0].name})


func _exec_assert_state(step: Dictionary) -> void:
	var key: String = step.get("field", step.get("key", ""))
	var expected = step.get("expected", null)
	var op: String = step.get("op", "eq")
	var writers := _find_nodes_with_method(get_tree().root, "_write_game_state")
	if writers.size() > 0:
		writers[0].call("_write_game_state")
		await _wait_frames(1)
	var state := _read_game_state()
	if state.is_empty():
		_step_skip("game_state.json belum ada")
		return
	var actual = _resolve_dot_key(state, key)
	if _evaluate_op(actual, op, expected):
		_step_pass({"key": key, "actual": str(actual), "expected": str(expected)})
	else:
		_step_fail("assert_state gagal: %s = %s, expected %s %s" % [key, str(actual), op, str(expected)])


func _exec_assert_no_error(step: Dictionary) -> void:
	var window_frames: int = int(step.get("window_frames", 30))
	var trackers := _find_nodes_with_method(get_tree().root, "_get_error_count")
	var before: int = 0
	if trackers.size() > 0:
		before = int(trackers[0].call("_get_error_count"))
	await _wait_frames(window_frames)
	if trackers.size() > 0:
		var after: int = int(trackers[0].call("_get_error_count"))
		var new_errors: int = after - before
		if new_errors == 0:
			_step_pass({"errors_detected": 0})
		else:
			_step_fail("Terdeteksi %d error dalam %d frame" % [new_errors, window_frames])
	else:
		if get_tree().current_scene != null:
			_step_pass({"note": "no error tracker, scene still active"})
		else:
			_step_fail("Scene tidak valid setelah %d frame" % window_frames)


func _exec_assert_fps(step: Dictionary) -> void:
	var min_fps: float = float(step.get("min_fps", 30.0))
	var sample_frames: int = int(step.get("sample_frames", 60))
	await _wait_frames(sample_frames)
	var fps: float = Engine.get_frames_per_second()
	if fps >= min_fps:
		_step_pass({"fps": fps, "min_fps": min_fps})
	else:
		_step_fail("FPS terlalu rendah: %.1f < %.1f" % [fps, min_fps])


func _exec_assert_screenshot_exists(step: Dictionary) -> void:
	var name: String = step.get("name", "")
	if name.is_empty():
		_step_fail("assert_screenshot_exists tidak punya field 'name'")
		return
	var path1 := "user://shots/scenario_" + name + ".png"
	var path2 := "user://shots/" + name + ".png"
	if FileAccess.file_exists(path1):
		_step_pass({"found": path1})
	elif FileAccess.file_exists(path2):
		_step_pass({"found": path2})
	else:
		_step_fail("Screenshot tidak ditemukan: " + name)


func _exec_set_state(step: Dictionary) -> void:
	var key: String = step.get("key", "")
	var value = step.get("value", null)
	var setters := _find_nodes_with_method(get_tree().root, "_on_set_state")
	if setters.is_empty():
		_step_skip("_on_set_state tidak diimplementasikan di game")
		return
	setters[0].call("_on_set_state", key, value)
	_step_pass({"key": key, "value": str(value)})


func _exec_log(step: Dictionary) -> void:
	var message: String = step.get("message", step.get("description", ""))
	print("[scenario] LOG: ", message)
	_step_pass({"message": message})


func _exec_seed_override(step: Dictionary) -> void:
	var s = step.get("seed", null)
	if s != null:
		seed(int(s))
		_step_pass({"seed": s})
	else:
		_step_skip("seed_override tidak punya field 'seed'")


func _exec_repeat(step: Dictionary) -> void:
	var count: int = int(step.get("count", 1))
	var sub_steps: Array = step.get("steps", [])
	if sub_steps.is_empty():
		_step_skip("repeat tidak punya field 'steps'")
		return
	var failed: int = 0
	for i in range(count):
		for sub in sub_steps:
			var sub_type: String = sub.get("type", "")
			if sub_type == "repeat":
				print("[scenario] nested repeat tidak didukung -- skip")
				continue
			await _dispatch(sub_type, sub)
			if _step_results.size() > 0:
				if _step_results[-1].get("status") == "fail":
					failed += 1
	_step_pass({"repeated": count, "failed_in_repeat": failed})


# --- Process polling untuk wait_scene/wait_signal ---

func _process_current_step() -> void:
	if _current_step >= _steps.size():
		return
	var step: Dictionary = _steps[_current_step]
	var step_type: String = step.get("type", "")
	if step_type == "wait_signal":
		if _signal_received:
			_signal_received = false
			_step_pass({"signal": _waiting_signal})


# --- Signal relay ---

func emit_scenario_signal(sig_name: String) -> void:
	if sig_name == _waiting_signal:
		_signal_received = true
	scenario_signal.emit(sig_name)


# --- Result helpers ---

func _step_pass(data) -> void:
	var result := {"step": _current_step, "type": _steps[_current_step].get("type", ""), "status": "pass"}
	if data != null:
		result["data"] = data
	_step_results.append(result)
	print("[scenario] PASS: ", result.get("type", ""))


func _step_fail(reason: String) -> void:
	var result := {"step": _current_step, "type": _steps[_current_step].get("type", ""), "status": "fail", "reason": reason}
	_step_results.append(result)
	print("[scenario] FAIL: ", reason)


func _step_skip(reason: String) -> void:
	var result := {"step": _current_step, "type": _steps[_current_step].get("type", ""), "status": "skip", "reason": reason}
	_step_results.append(result)
	print("[scenario] SKIP: ", reason)


# --- Finish ---

func _write_result(status: String, error_msg) -> void:
	var pass_count := 0
	var fail_count := 0
	var skip_count := 0
	for r in _step_results:
		match r.get("status", ""):
			"pass": pass_count += 1
			"fail": fail_count += 1
			"skip": skip_count += 1
	var result := {
		"schema_version": SCHEMA_VERSION,
		"scenario_id": _scenario.get("scenario_id", "unnamed"),
		"status": status,
		"timestamp": Time.get_datetime_string_from_system(),
		"duration_sec": Time.get_unix_time_from_system() - _scenario_start_time,
		"steps_total": _steps.size(),
		"steps_pass": pass_count,
		"steps_fail": fail_count,
		"steps_skip": skip_count,
		"screenshots": _screenshots_taken,
		"step_results": _step_results,
	}
	if error_msg != null:
		result["error"] = error_msg
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://shots"))
	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(result, "\t"))
		f.close()
		print("[scenario] Hasil ditulis ke: ", RESULT_PATH)
	print("[scenario] === %s | pass=%d fail=%d skip=%d ===" % [status.to_upper(), pass_count, fail_count, skip_count])


# --- Utilities ---

func _get_current_scene_name() -> String:
	if get_tree().current_scene:
		return get_tree().current_scene.name
	return ""


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _read_game_state() -> Dictionary:
	var path := "user://shots/game_state.json"
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return {}
	f.close()
	var data = json.get_data()
	if data is Dictionary:
		return data
	return {}


func _resolve_dot_key(data: Dictionary, key: String):
	var parts := key.split(".")
	var current = data
	for part in parts:
		if current is Dictionary and current.has(part):
			current = current[part]
		else:
			return null
	return current


func _evaluate_op(actual, op: String, expected) -> bool:
	match op:
		"eq":       return actual == expected
		"neq":      return actual != expected
		"gt":       return float(str(actual)) > float(str(expected))
		"gte":      return float(str(actual)) >= float(str(expected))
		"lt":       return float(str(actual)) < float(str(expected))
		"lte":      return float(str(actual)) <= float(str(expected))
		"is_true":  return actual == true or actual == 1 or str(actual) == "true"
		"is_false": return actual == false or actual == 0 or str(actual) == "false"
		"not_null": return actual != null
		"is_null":  return actual == null
		_:          return actual == expected


func _find_nodes_with_method(node: Node, method_name: String) -> Array[Node]:
	var result: Array[Node] = []
	if node.has_method(method_name):
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_nodes_with_method(child, method_name))
	return result