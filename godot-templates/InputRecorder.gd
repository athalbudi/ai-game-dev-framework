## InputRecorder.gd
## Rekam input gameplay manual ke format yang bisa dikonversi ke scenario JSON.
## Daftarkan sebagai Autoload di project.godot:
##
##   [autoload]
##   InputRecorder="*res://scripts/InputRecorder.gd"
##
## Cara pakai:
##   InputRecorder.start()          -- mulai rekam (biasanya di _ready() atau tombol debug)
##   InputRecorder.stop()           -- berhenti rekam, tulis recording ke disk
##   InputRecorder.is_recording()   -- cek apakah sedang merekam
##
## Output: user://shots/recording_<timestamp>.json
## Konversi ke scenario: gunakan RecordingConverter.gd atau /record convert command
##
## Catatan arsitektur:
##   - Recorder bekerja di level Godot input event (engine-level, bukan OS-level)
##   - Hanya merekam event yang relevan untuk reproduksi: action, mouse, touch, joypad
##   - Frame-based timing untuk reproduksi deterministik via seed + frame count
##   - Screenshot otomatis diambil setiap N frame sebagai checkpoint visual

extends Node

# -- Konstanta ------------------------------------------------------------------
const SCHEMA_VERSION   := "1.0"
const MAX_EVENTS       := 10000   # batas rekaman untuk mencegah file terlalu besar
const AUTO_SCREENSHOT_INTERVAL := 300  # ambil screenshot setiap N frame (0 = off)

# -- State ----------------------------------------------------------------------
var _recording: bool = false
var _events: Array[Dictionary] = []
var _start_frame: int = 0
var _start_time: float = 0.0
var _seed: int = 0
var _session_id: String = ""
var _screenshot_counter: int = 0
var _frame_counter: int = 0
var _output_path: String = ""

# -- Signals --------------------------------------------------------------------
signal recording_started(session_id: String)
signal recording_stopped(output_path: String, event_count: int)
signal recording_screenshot(filename: String, frame: int)

# -- Entry point ----------------------------------------------------------------
func _ready() -> void:
	set_process_input(false)
	set_process(false)


func _input(event: InputEvent) -> void:
	if not _recording:
		return
	if _events.size() >= MAX_EVENTS:
		push_warning("[InputRecorder] MAX_EVENTS tercapai -- rekaman dihentikan otomatis")
		stop()
		return

	var frame_offset: int = Engine.get_process_frames() - _start_frame
	var recorded := _record_event(event, frame_offset)
	if recorded != null:
		_events.append(recorded)


func _process(_delta: float) -> void:
	if not _recording:
		return
	_frame_counter += 1
	if AUTO_SCREENSHOT_INTERVAL > 0 and _frame_counter % AUTO_SCREENSHOT_INTERVAL == 0:
		_take_checkpoint_screenshot()


# -- Public API -----------------------------------------------------------------
## Mulai merekam. Seed opsional untuk reproduksi deterministik.
func start(seed_override: int = -1) -> void:
	if _recording:
		push_warning("[InputRecorder] Sudah merekam -- stop dulu sebelum start baru")
		return

	_recording      = true
	_events         = []
	_start_frame    = Engine.get_process_frames()
	_start_time     = Time.get_unix_time_from_system()
	_screenshot_counter = 0
	_frame_counter  = 0

	# Seed: gunakan override jika diberikan, atau generate baru
	if seed_override >= 0:
		_seed = seed_override
	else:
		_seed = randi()
	seed(_seed)

	_session_id = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	_output_path = "user://shots/recording_%s.json" % _session_id

	set_process_input(true)
	set_process(true)

	print("[InputRecorder] Mulai merekam: %s (seed: %d)" % [_session_id, _seed])
	recording_started.emit(_session_id)


## Hentikan rekaman dan tulis ke disk.
func stop() -> void:
	if not _recording:
		push_warning("[InputRecorder] Tidak sedang merekam")
		return

	_recording = false
	set_process_input(false)
	set_process(false)

	var duration := Time.get_unix_time_from_system() - _start_time
	_write_recording(duration)
	print("[InputRecorder] Rekaman selesai: %d events dalam %.1fs -> %s" % [
		_events.size(), duration, _output_path
	])
	recording_stopped.emit(_output_path, _events.size())


## Apakah sedang merekam?
func is_recording() -> bool:
	return _recording


## Hapus rekaman yang belum disimpan.
func discard() -> void:
	_recording = false
	_events = []
	set_process_input(false)
	set_process(false)
	print("[InputRecorder] Rekaman dibuang")


## Daftar file rekaman yang ada di user://shots/
static func list_recordings() -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open("user://shots")
	if dir == null:
		return result
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.begins_with("recording_") and fname.ends_with(".json"):
			result.append("user://shots/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result


# -- Internal -------------------------------------------------------------------
func _record_event(event: InputEvent, frame_offset: int) -> Dictionary:
	## Konversi InputEvent ke Dictionary yang bisa di-serialize ke JSON.
	## Hanya event yang relevan untuk reproduksi yang direkam.

	var base := {
		"frame": frame_offset,
		"time_sec": snappedf(Time.get_unix_time_from_system() - _start_time, 0.001)
	}

	if event is InputEventAction:
		var e := event as InputEventAction
		if not e.action:
			return null
		base.merge({
			"type": "action",
			"action": str(e.action),
			"pressed": e.pressed,
			"strength": snappedf(e.strength, 0.01)
		})
		return base

	elif event is InputEventKey:
		var e := event as InputEventKey
		# Konversi ke action jika ada di InputMap
		var matched_actions := InputMap.get_actions().filter(
			func(a): return InputMap.action_has_event(a, event)
		)
		if not matched_actions.is_empty():
			base.merge({
				"type": "action",
				"action": str(matched_actions[0]),
				"pressed": e.pressed,
				"strength": 1.0
			})
			return base
		# Fallback: rekam sebagai keycode
		base.merge({
			"type": "key",
			"keycode": e.keycode,
			"physical_keycode": e.physical_keycode,
			"pressed": e.pressed,
			"echo": e.echo
		})
		return base

	elif event is InputEventMouseButton:
		var e := event as InputEventMouseButton
		base.merge({
			"type": "mouse_button",
			"button_index": e.button_index,
			"pressed": e.pressed,
			"x": snappedf(e.position.x, 0.5),
			"y": snappedf(e.position.y, 0.5),
			"double_click": e.double_click
		})
		return base

	elif event is InputEventMouseMotion:
		var e := event as InputEventMouseMotion
		# Mouse motion: rekam setiap 10 frame untuk mengurangi noise
		if frame_offset % 10 != 0:
			return null
		base.merge({
			"type": "mouse_motion",
			"x": snappedf(e.position.x, 0.5),
			"y": snappedf(e.position.y, 0.5)
		})
		return base

	elif event is InputEventScreenTouch:
		var e := event as InputEventScreenTouch
		base.merge({
			"type": "touch",
			"index": e.index,
			"pressed": e.pressed,
			"x": snappedf(e.position.x, 0.5),
			"y": snappedf(e.position.y, 0.5)
		})
		return base

	elif event is InputEventScreenDrag:
		var e := event as InputEventScreenDrag
		if frame_offset % 5 != 0:
			return null
		base.merge({
			"type": "drag",
			"index": e.index,
			"x": snappedf(e.position.x, 0.5),
			"y": snappedf(e.position.y, 0.5),
			"vel_x": snappedf(e.velocity.x, 1.0),
			"vel_y": snappedf(e.velocity.y, 1.0)
		})
		return base

	elif event is InputEventJoypadButton:
		var e := event as InputEventJoypadButton
		base.merge({
			"type": "joypad_button",
			"device": e.device,
			"button_index": e.button_index,
			"pressed": e.pressed
		})
		return base

	elif event is InputEventJoypadMotion:
		var e := event as InputEventJoypadMotion
		# Skip micro-drift
		if abs(e.axis_value) < 0.1:
			return null
		base.merge({
			"type": "joypad_axis",
			"device": e.device,
			"axis": e.axis,
			"axis_value": snappedf(e.axis_value, 0.05)
		})
		return base

	return null


func _take_checkpoint_screenshot() -> void:
	_screenshot_counter += 1
	var name := "rec_%s_checkpoint_%03d" % [_session_id, _screenshot_counter]
	var img  := get_viewport().get_texture().get_image()
	var path := "user://shots/%s.png" % name
	img.save_png(path)
	_events.append({
		"frame": Engine.get_process_frames() - _start_frame,
		"time_sec": snappedf(Time.get_unix_time_from_system() - _start_time, 0.001),
		"type": "checkpoint_screenshot",
		"name": name
	})
	recording_screenshot.emit(name, Engine.get_process_frames() - _start_frame)


func _write_recording(duration: float) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("user://shots")
	)

	var current_scene := get_tree().current_scene
	var data := {
		"schema_version": SCHEMA_VERSION,
		"session_id": _session_id,
		"recorded_at": Time.get_datetime_string_from_system(),
		"seed": _seed,
		"start_frame": _start_frame,
		"total_frames": Engine.get_process_frames() - _start_frame,
		"duration_sec": snappedf(duration, 0.01),
		"event_count": _events.size(),
		"start_scene": current_scene.name if current_scene else "unknown",
		"events": _events
	}

	var file := FileAccess.open(_output_path, FileAccess.WRITE)
	if file == null:
		push_error("[InputRecorder] Gagal menulis: %s" % _output_path)
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
