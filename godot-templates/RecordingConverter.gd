## RecordingConverter.gd
## Konversi file rekaman InputRecorder ke format scenario JSON yang bisa
## dijalankan oleh ScenarioRunner.gd untuk bug reproduction deterministik.
##
## Cara pakai dari editor script atau tool:
##   var path = RecordingConverter.convert("user://shots/recording_2026-07-19.json")
##   print("Scenario saved to: ", path)
##
## Atau via command /record convert di Kilo.
##
## Prinsip konversi:
##   - Event action  -> step "action"
##   - Mouse button  -> step "mouse_click"
##   - Touch press   -> step "touch"
##   - Frame gaps    -> step "wait_frames"
##   - Checkpoint    -> step "screenshot"
##   - Seed dari rekaman dipreservasi untuk reproduksi deterministik

extends Node

# -- Konstanta ------------------------------------------------------------------
const MIN_WAIT_FRAMES := 2   # gap minimum sebelum insert wait_frames
const MAX_WAIT_FRAMES := 300 # gap > ini dikonversi ke wait_frames dengan cap

# -- API Publik -----------------------------------------------------------------
## Konversi file rekaman ke scenario JSON.
## Kembalikan path scenario yang dihasilkan, atau "" jika gagal.
static func convert(recording_path: String, scenario_name: String = "") -> String:
	# Baca rekaman
	if not FileAccess.file_exists(recording_path):
		push_error("[RecordingConverter] File tidak ditemukan: %s" % recording_path)
		return ""

	var file := FileAccess.open(recording_path, FileAccess.READ)
	if file == null:
		push_error("[RecordingConverter] Gagal membuka: %s" % recording_path)
		return ""

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("[RecordingConverter] JSON tidak valid: %s" % json.get_error_message())
		file.close()
		return ""
	file.close()

	var recording: Dictionary = json.get_data()
	if not recording.has("events"):
		push_error("[RecordingConverter] Rekaman tidak punya field 'events'")
		return ""

	# Tentukan nama scenario
	var sid: String = recording.get("session_id", "recording")
	if scenario_name.is_empty():
		scenario_name = "replay_%s" % sid

	# Konversi events ke steps
	var steps := _convert_events(recording["events"])

	# Bangun scenario JSON
	var scenario := {
		"scenario_id": scenario_name,
		"description": "Replay otomatis dari rekaman %s. Dikonversi oleh RecordingConverter." % sid,
		"version": "1.0",
		"tags": ["replay", "auto-generated", "bug-reproduction"],
		"notes": [
			"Scenario ini di-generate otomatis dari rekaman input gameplay.",
			"Seed: %d -- jalankan ulang untuk hasil deterministik." % recording.get("seed", 0),
			"Durasi rekaman asli: %.1f detik." % recording.get("duration_sec", 0),
			"Source: %s" % recording_path
		],
		"seed": recording.get("seed", null),
		"steps": steps
	}

	# Tulis ke disk
	var out_path := "user://shots/%s.json" % scenario_name
	var out_file := FileAccess.open(out_path, FileAccess.WRITE)
	if out_file == null:
		push_error("[RecordingConverter] Gagal menulis scenario: %s" % out_path)
		return ""
	out_file.store_string(JSON.stringify(scenario, "\t"))
	out_file.close()

	print("[RecordingConverter] Scenario disimpan: %s (%d steps)" % [out_path, steps.size()])
	return out_path


## Konversi dan langsung simpan ke folder scenarios/ project.
static func convert_to_scenarios_dir(recording_path: String,
                                      project_path: String,
                                      scenario_name: String = "") -> String:
	var tmp_path := convert(recording_path, scenario_name)
	if tmp_path.is_empty():
		return ""

	# Copy ke project scenarios folder
	var scenarios_dir := project_path.path_join("scenarios")
	DirAccess.make_dir_recursive_absolute(scenarios_dir)

	var fname := tmp_path.get_file()
	var dest  := scenarios_dir.path_join(fname)

	var content := FileAccess.open(tmp_path, FileAccess.READ).get_as_text()
	var dest_file := FileAccess.open(dest, FileAccess.WRITE)
	if dest_file == null:
		push_error("[RecordingConverter] Gagal copy ke scenarios/: %s" % dest)
		return tmp_path
	dest_file.store_string(content)
	dest_file.close()

	print("[RecordingConverter] Scenario disalin ke: %s" % dest)
	return dest


# -- Internal -------------------------------------------------------------------
static func _convert_events(events: Array) -> Array:
	var steps := []
	var last_frame: int = 0

	# Header: seed override dan screenshot awal
	steps.append({
		"type": "log",
		"message": "=== REPLAY DIMULAI ==="
	})

	for i in range(events.size()):
		var ev: Dictionary = events[i]
		var frame: int = ev.get("frame", 0)

		# Insert wait_frames jika ada gap
		var gap := frame - last_frame
		if gap >= MIN_WAIT_FRAMES:
			steps.append({
				"type": "wait_frames",
				"frames": min(gap, MAX_WAIT_FRAMES),
				"comment": "gap %.2f detik" % ev.get("time_sec", 0)
			})
		last_frame = frame

		var ev_type: String = ev.get("type", "")

		match ev_type:
			"action":
				if ev.get("pressed", true):
					steps.append({
						"type": "action",
						"action": ev.get("action", ""),
						"comment": "frame %d" % frame
					})

			"mouse_button":
				if ev.get("pressed", true):
					var btn_str := "left"
					match ev.get("button_index", MOUSE_BUTTON_LEFT):
						MOUSE_BUTTON_RIGHT:  btn_str = "right"
						MOUSE_BUTTON_MIDDLE: btn_str = "middle"
					steps.append({
						"type": "mouse_click",
						"x": ev.get("x", 0),
						"y": ev.get("y", 0),
						"button": btn_str
					})

			"touch":
				if ev.get("pressed", true):
					steps.append({
						"type": "touch",
						"x": ev.get("x", 0),
						"y": ev.get("y", 0),
						"index": ev.get("index", 0)
					})

			"joypad_button":
				if ev.get("pressed", true):
					# Map button_index ke nama yang dikenal controller step
					var btn_name := _joypad_button_name(ev.get("button_index", 0))
					steps.append({
						"type": "controller",
						"button": btn_name,
						"device": ev.get("device", 0)
					})

			"joypad_axis":
				steps.append({
					"type": "controller",
					"axis": _joypad_axis_name(ev.get("axis", 0)),
					"value": ev.get("axis_value", 0.0),
					"device": ev.get("device", 0)
				})

			"checkpoint_screenshot":
				steps.append({
					"type": "screenshot",
					"name": ev.get("name", "checkpoint_%d" % i)
				})
				steps.append({
					"type": "write_state",
					"comment": "state snapshot di checkpoint"
				})

			"mouse_motion", "drag", "key":
				# Skip -- tidak dikonversi ke step (tidak deterministik atau tidak relevan)
				pass

	steps.append({
		"type": "log",
		"message": "=== REPLAY SELESAI ==="
	})
	steps.append({
		"type": "screenshot",
		"name": "replay_final"
	})

	return steps


static func _joypad_button_name(button_index: int) -> String:
	match button_index:
		JOY_BUTTON_A:             return "cross"
		JOY_BUTTON_B:             return "circle"
		JOY_BUTTON_X:             return "square"
		JOY_BUTTON_Y:             return "triangle"
		JOY_BUTTON_LEFT_SHOULDER: return "l1"
		JOY_BUTTON_RIGHT_SHOULDER: return "r1"
		JOY_BUTTON_LEFT_TRIGGER:  return "l2"
		JOY_BUTTON_RIGHT_TRIGGER: return "r2"
		JOY_BUTTON_LEFT_STICK:    return "l3"
		JOY_BUTTON_RIGHT_STICK:   return "r3"
		JOY_BUTTON_DPAD_UP:       return "dpad_up"
		JOY_BUTTON_DPAD_DOWN:     return "dpad_down"
		JOY_BUTTON_DPAD_LEFT:     return "dpad_left"
		JOY_BUTTON_DPAD_RIGHT:    return "dpad_right"
		JOY_BUTTON_START:         return "start"
		JOY_BUTTON_BACK:          return "select"
		_:                        return "cross"


static func _joypad_axis_name(axis: int) -> String:
	match axis:
		JOY_AXIS_LEFT_X:       return "left_x"
		JOY_AXIS_LEFT_Y:       return "left_y"
		JOY_AXIS_RIGHT_X:      return "right_x"
		JOY_AXIS_RIGHT_Y:      return "right_y"
		JOY_AXIS_TRIGGER_LEFT:  return "left_trigger"
		JOY_AXIS_TRIGGER_RIGHT: return "right_trigger"
		_:                     return "left_x"
