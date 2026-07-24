## AnomalyDetector.gd
## Deteksi anomali dari shots-manifest.json, game_state.json, dan scenario_result.json
## tanpa membutuhkan pembacaan screenshot langsung.
##
## Menghasilkan daftar anomali terstruktur yang bisa digunakan untuk:
##   - Menyusun hipotesis investigasi
##   - Membuat scenario JSON yang ditargetkan
##   - Menentukan prioritas pengujian
##
## Cara pakai:
##   var detector := AnomalyDetector.new()
##   var anomalies := detector.detect_all(manifest_path, scenario_result_path)
##   for a in anomalies:
##       print(a.severity, " -- ", a.description, " -> ", a.suggested_action)
##
## Output anomaly: Dictionary dengan field:
##   type        -- kategori anomali (visual, state, performance, scenario, coverage)
##   severity    -- "critical" | "warning" | "info"
##   description -- deskripsi teknis anomali
##   evidence    -- data konkret yang mendukung (nilai aktual vs ekspektasi)
##   suggested_action -- langkah investigasi yang disarankan
##   step_hint   -- step type ScenarioRunner yang relevan untuk investigasi
##   target_file -- screenshot atau layar yang terkait (jika ada)

extends RefCounted

# -- Konstanta severity ---------------------------------------------------------
const CRITICAL := "critical"
const WARNING  := "warning"
const INFO     := "info"

# -- Entry point utama ----------------------------------------------------------
## Deteksi semua anomali dari semua sumber data yang tersedia.
## Kembalikan Array[Dictionary] anomali, diurutkan dari severity tertinggi.
func detect_all(manifest_path: String, scenario_result_path: String = "") -> Array[Dictionary]:
	var anomalies: Array[Dictionary] = []

	# Load manifest
	var manifest := _load_json(manifest_path)
	if manifest.is_empty():
		anomalies.append(_make_anomaly(
			"coverage", CRITICAL,
			"shots-manifest.json tidak ditemukan atau tidak valid",
			{"path": manifest_path},
			"Jalankan shot harness terlebih dahulu",
			"wait_scene"
		))
		return anomalies

	# Load game_state jika tersedia (dari manifest layer 1)
	var game_state: Dictionary = {}
	if manifest.has("game_state") and manifest["game_state"] != null:
		var gs = manifest["game_state"]
		if gs is Dictionary:
			game_state = gs

	# Load scenario result jika tersedia
	var scenario_result: Dictionary = {}
	if scenario_result_path != "" and FileAccess.file_exists(scenario_result_path):
		scenario_result = _load_json(scenario_result_path)

	# Load diff report jika tersedia
	var shots_dir: String = manifest.get("shots_dir", "")
	var diff_report: Dictionary = {}
	if shots_dir != "":
		var diff_path := shots_dir.path_join("diff/diff-report.json")
		if FileAccess.file_exists(diff_path):
			diff_report = _load_json(diff_path)

	# Jalankan semua detector
	anomalies.append_array(_detect_telemetry_phase(manifest))
	anomalies.append_array(_detect_stale_screenshots(manifest))
	anomalies.append_array(_detect_coverage_gaps(manifest))
	anomalies.append_array(_detect_visual_regressions(diff_report, manifest))
	anomalies.append_array(_detect_state_anomalies(game_state, manifest))
	anomalies.append_array(_detect_scenario_failures(scenario_result))
	anomalies.append_array(_detect_performance_signals(manifest, scenario_result))
	anomalies.append_array(_detect_missing_seed(manifest, game_state))

	# Sort: critical dulu, lalu warning, lalu info
	anomalies.sort_custom(func(a, b):
		var order := {"critical": 0, "warning": 1, "info": 2}
		return order.get(a.severity, 3) < order.get(b.severity, 3)
	)

	return anomalies


## Deteksi anomali hanya dari manifest (tanpa scenario result)
func detect_from_manifest(manifest_path: String) -> Array[Dictionary]:
	return detect_all(manifest_path, "")


# -- Detectors ------------------------------------------------------------------
func _detect_telemetry_phase(manifest: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var phase: String = manifest.get("telemetry_phase", "unknown")

	if phase == "prototype":
		results.append(_make_anomaly(
			"coverage", WARNING,
			"Fase telemetry: prototype -- belum ada screenshot",
			{"telemetry_phase": phase},
			"Implementasikan --shot handler di kode game untuk mulai mengambil screenshot",
			"screenshot"
		))
	elif phase == "developing":
		results.append(_make_anomaly(
			"coverage", INFO,
			"Fase telemetry: developing -- screenshot ada tapi game_state belum tersedia",
			{"telemetry_phase": phase, "png_count": manifest.get("png_count", 0)},
			"Implementasikan _write_game_state() untuk analisis lebih dalam",
			"write_state"
		))
	# mature = tidak perlu anomali

	return results


func _detect_stale_screenshots(manifest: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var screenshots: Array = manifest.get("screenshots", [])
	var generated_at_str: String = manifest.get("generated_at", "")

	if generated_at_str.is_empty() or screenshots.is_empty():
		return results

	var now_unix := Time.get_unix_time_from_system()

	for ss in screenshots:
		if not (ss is Dictionary):
			continue
		var last_write: String = ss.get("last_write", "")
		if last_write.is_empty():
			continue

		# Parse last_write ke unix time
		var dt = Time.get_unix_time_from_datetime_string(last_write)
		if dt <= 0:
			continue

		# Cek umur relatif terhadap run terbaru
		var run_time := Time.get_unix_time_from_datetime_string(generated_at_str)
		if run_time <= 0:
			continue

		var age_hours := (run_time - dt) / 3600.0
		if age_hours > 24:
			var fname: String = ss.get("file", "unknown")
			var severity := CRITICAL if age_hours > 168 else WARNING  # >7 hari = critical
			results.append(_make_anomaly(
				"visual", severity,
				"Screenshot stale: %s (%.0f jam lebih lama dari run terbaru)" % [fname, age_hours],
				{"file": fname, "age_hours": snappedf(age_hours, 0.1), "last_write": last_write},
				"Cek apakah --shot handler masih mencapai kondisi yang menghasilkan screenshot ini",
				"screenshot",
				fname
			))

	return results


func _detect_coverage_gaps(manifest: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var coverage = manifest.get("coverage", null)
	if coverage == null or not (coverage is Dictionary):
		return results

	var pct: float = float(coverage.get("coverage_pct", 100))
	var uncovered: Array = coverage.get("uncovered", [])
	var known: int = int(coverage.get("known_screens", 0) if coverage.get("known_screens") is int else 0)

	if pct < 100 and uncovered.size() > 0:
		results.append(_make_anomaly(
			"coverage", WARNING,
			"Coverage tidak lengkap: %.0f%% (%d layar belum di-screenshot)" % [pct, uncovered.size()],
			{"coverage_pct": pct, "uncovered": uncovered},
			"Tambahkan screenshot untuk layar: %s" % str(uncovered.slice(0, 3)),
			"screenshot"
		))

	return results


func _detect_visual_regressions(diff_report: Dictionary, manifest: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if diff_report.is_empty():
		return results

	var files: Array = diff_report.get("files", [])
	for f in files:
		if not (f is Dictionary):
			continue
		var status: String = f.get("status", "")
		var fname: String = f.get("file", "unknown")
		var pct: float = float(f.get("change_pct", 0))

		if status == "REGRESI":
			results.append(_make_anomaly(
				"visual", CRITICAL,
				"Visual regression: %s berubah %.2f%%" % [fname, pct],
				{"file": fname, "change_pct": pct, "status": status},
				"Buka diff image dan bandingkan dengan baseline untuk identifikasi perubahan",
				"screenshot",
				fname
			))
		elif status == "HILANG":
			results.append(_make_anomaly(
				"visual", CRITICAL,
				"Screenshot hilang dari run terbaru: %s" % fname,
				{"file": fname, "status": status},
				"Cek apakah --shot handler masih menghasilkan screenshot ini",
				"screenshot",
				fname
			))
		elif status == "FILE_BARU":
			results.append(_make_anomaly(
				"visual", INFO,
				"Screenshot baru yang belum ada di baseline: %s" % fname,
				{"file": fname, "status": status},
				"Jalankan /baseline set jika screenshot ini intentional",
				"screenshot",
				fname
			))

	return results


func _detect_state_anomalies(game_state: Dictionary, manifest: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if game_state.is_empty():
		return results

	# Deteksi hp = 0 tapi is_alive = true (pattern umum health bar bug)
	var player = game_state.get("player", null)
	if player is Dictionary:
		var hp = player.get("hp", null)
		var hp_max = player.get("hp_max", null)
		var is_alive = player.get("is_alive", null)

		if hp != null and hp_max != null and float(str(hp_max)) > 0:
			var hp_pct := float(str(hp)) / float(str(hp_max))
			if hp_pct == 0.0 and is_alive == true:
				results.append(_make_anomaly(
					"state", CRITICAL,
					"Health bar mismatch: hp=0 tapi is_alive=true",
					{"player.hp": hp, "player.hp_max": hp_max, "player.is_alive": is_alive},
					"Cek UI binding health bar -- kemungkinan terputus dari nilai aktual",
					"assert_state"
				))
			elif hp_pct < 0.0 or float(str(hp)) > float(str(hp_max)):
				results.append(_make_anomaly(
					"state", WARNING,
					"Nilai hp di luar range: hp=%s, hp_max=%s" % [str(hp), str(hp_max)],
					{"player.hp": hp, "player.hp_max": hp_max},
					"Cek formula damage atau heal yang mungkin tidak di-clamp",
					"assert_state"
				))

	# Deteksi shots_taken mismatch vs png_count di manifest
	var shots_taken = game_state.get("shots_taken", null)
	var png_count: int = manifest.get("png_count", 0)
	if shots_taken != null and int(str(shots_taken)) != png_count:
		var diff := abs(int(str(shots_taken)) - png_count)
		if diff > 2:  # toleransi 2 (zoom crops, dll)
			results.append(_make_anomaly(
				"state", WARNING,
				"Mismatch shots_taken(%d) vs png_count(%d) -- selisih %d" % [
					int(str(shots_taken)), png_count, diff
				],
				{"game_state.shots_taken": shots_taken, "manifest.png_count": png_count},
				"Cek apakah counter shots_taken diupdate setiap screenshot di --shot handler",
				"write_state"
			))

	# Deteksi resource negatif (coins, dll)
	for key in ["coins", "gold", "resource", "score"]:
		var val = _resolve_dot_key(game_state, key)
		if val != null and float(str(val)) < 0:
			results.append(_make_anomaly(
				"state", WARNING,
				"Resource negatif: %s = %s" % [key, str(val)],
				{key: val},
				"Cek apakah ada underflow pada sistem ekonomi",
				"assert_state"
			))

	return results


func _detect_scenario_failures(scenario_result: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if scenario_result.is_empty():
		return results

	var failed_steps: Array = scenario_result.get("steps", []).filter(
		func(s): return s.get("status") == "fail"
	)
	var skipped_steps: Array = scenario_result.get("steps", []).filter(
		func(s): return s.get("status") == "skip"
	)

	for step in failed_steps:
		results.append(_make_anomaly(
			"scenario", CRITICAL,
			"Scenario step fail: [%s] %s" % [step.get("type", "?"), step.get("note", "")],
			{
				"step_id": step.get("id", ""),
				"step_type": step.get("type", ""),
				"note": step.get("note", ""),
				"duration_sec": step.get("duration_sec", 0)
			},
			"Investigasi kondisi yang menyebabkan step ini gagal",
			step.get("type", "screenshot")
		))

	# Warning untuk banyak skip
	if skipped_steps.size() > 3:
		var skip_types := skipped_steps.map(func(s): return s.get("type", "?"))
		results.append(_make_anomaly(
			"scenario", WARNING,
			"%d step di-skip -- mungkin butuh setup tambahan" % skipped_steps.size(),
			{"skipped_types": skip_types},
			"Cek apakah InputMap, game_state hook, atau ScenarioRunner sudah di-setup",
			"log"
		))

	return results


func _detect_performance_signals(manifest: Dictionary, scenario_result: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []

	# Cek elapsed time harness -- sangat lambat bisa indikasi masalah
	var elapsed: float = float(manifest.get("elapsed_sec", 0))
	if elapsed > 60:
		results.append(_make_anomaly(
			"performance", WARNING,
			"Shot tour sangat lambat: %.1f detik" % elapsed,
			{"elapsed_sec": elapsed},
			"Pertimbangkan optimasi --shot handler atau kurangi jumlah layar",
			"assert_fps"
		))

	# Cek dari scenario result jika ada step assert_fps
	if not scenario_result.is_empty():
		var fps_steps: Array = scenario_result.get("steps", []).filter(
			func(s): return s.get("type") == "assert_fps" and s.get("status") == "fail"
		)
		for s in fps_steps:
			results.append(_make_anomaly(
				"performance", CRITICAL,
				"FPS di bawah threshold: %s" % s.get("note", ""),
				{"step_id": s.get("id", ""), "note": s.get("note", "")},
				"Profil performa di layar yang menyebabkan FPS drop",
				"assert_fps"
			))

	return results


func _detect_missing_seed(manifest: Dictionary, game_state: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var phase: String = manifest.get("telemetry_phase", "")
	if phase != "mature":
		return results

	var has_seed := false
	if game_state.has("seed") and game_state["seed"] != null:
		has_seed = true
	elif _resolve_dot_key(game_state, "world.seed") != null:
		has_seed = true
	elif _resolve_dot_key(game_state, "session.seed") != null:
		has_seed = true

	if not has_seed:
		results.append(_make_anomaly(
			"coverage", INFO,
			"Seed tidak ditemukan di game_state -- reproduksi deterministik terbatas",
			{"telemetry_phase": phase},
			"Tambahkan field seed (game_state.seed, world.seed, atau session.seed)",
			"seed_override"
		))

	return results


# -- Utilitas --------------------------------------------------------------------
func _make_anomaly(type: String, severity: String, description: String,
                   evidence: Dictionary, suggested_action: String,
                   step_hint: String, target_file: String = "") -> Dictionary:
	return {
		"type": type,
		"severity": severity,
		"description": description,
		"evidence": evidence,
		"suggested_action": suggested_action,
		"step_hint": step_hint,
		"target_file": target_file,
		"timestamp": Time.get_datetime_string_from_system()
	}


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		return {}
	file.close()
	var data = json.get_data()
	return data if data is Dictionary else {}


func _resolve_dot_key(data: Dictionary, key: String):
	var parts := key.split(".")
	var current = data
	for part in parts:
		if current is Dictionary and current.has(part):
			current = current[part]
		else:
			return null
	return current
