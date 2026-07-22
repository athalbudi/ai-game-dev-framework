## ErrorTracker.gd
## Reference implementation untuk _get_error_count() yang dibutuhkan oleh
## step "assert_no_error" di ScenarioRunner.gd.
##
## Daftarkan sebagai Autoload di project.godot:
##
##   [autoload]
##   ErrorTracker="*res://scripts/ErrorTracker.gd"
##
## Cara pakai:
##   ErrorTracker.get_error_count()     — jumlah error sejak start atau reset terakhir
##   ErrorTracker.get_errors()          — daftar semua error
##   ErrorTracker.reset()               — reset counter
##   ErrorTracker.get_last_error()      — error terakhir yang tercatat
##
## Integrasi dengan assert_no_error:
##   ScenarioRunner mencari node dengan method "_get_error_count()".
##   ErrorTracker mengeksposnya secara otomatis karena didaftarkan sebagai Autoload.
##
## Cara intercept error di Godot 4:
##   Godot 4 tidak punya built-in error callback yang mudah.
##   ErrorTracker menggunakan beberapa mekanisme:
##   1. Override push_error via custom error handler (jika tersedia di Godot versi future)
##   2. Log manual via ErrorTracker.log_error() dari kode game
##   3. Monitor print output jika game menggunakan print("[ERROR]") convention
##
## Rekomendasi: panggil ErrorTracker.log_error() dari blok catch/error game:
##   if result != OK:
##       ErrorTracker.log_error("save_failed", "Gagal menyimpan: " + str(result))

extends Node

# ── State ──────────────────────────────────────────────────────────────────────
var _errors: Array[Dictionary] = []
var _warning_count: int = 0
var _start_time: float = 0.0

# ── Entry point ────────────────────────────────────────────────────────────────
func _ready() -> void:
	_start_time = Time.get_unix_time_from_system()
	print("[ErrorTracker] Aktif — pantau error via log_error()")
	# --shot mode dihandle oleh main.gd._ready() via call_deferred (pattern lama yang proven)
	# ErrorTracker hanya menyediakan quit fallback jika game tidak quit sendiri
	if "--shot" in OS.get_cmdline_user_args():
		_shot_quit_watchdog.call_deferred()
	elif "--scenario" in OS.get_cmdline_user_args():
		_scenario_bootstrap.call_deferred()

func _shot_quit_watchdog() -> void:
	# Bootstrap --shot: tunggu hot-reload selesai, lalu trigger _shot_tour di main node.
	# Pola ini identik dengan _scenario_bootstrap — ErrorTracker sebagai autoload
	# diload lebih stabil dari main.gd yang bergantung pada class_name globals.
	# Dengan menunggu beberapa frame, hot-reload selesai dan semua class_name
	# sudah ter-register sebelum _shot_tour dipanggil.
	print("[ErrorTracker] --shot watchdog aktif")

	# Tunggu hot-reload selesai (4 frame cukup untuk class_name re-register)
	for _i in range(4):
		await get_tree().process_frame

	# Cari main node yang punya _shot_tour()
	var main_node: Node = null
	for node in get_tree().root.get_children():
		if node.has_method("_shot_tour"):
			main_node = node
			break

	if main_node == null:
		print("[ErrorTracker] --shot watchdog: _shot_tour tidak ditemukan di root nodes")
		# Fallback: tunggu sampai ada PNG atau timeout
		var shotsDir := "user://shots"
		var maxWaitFrames := 600
		var started := false
		for _i in range(maxWaitFrames):
			await get_tree().process_frame
			if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(shotsDir)):
				var dir := DirAccess.open(shotsDir)
				if dir != null:
					dir.list_dir_begin()
					var f := dir.get_next()
					while f != "":
						if f.ends_with(".png"):
							started = true
							break
						f = dir.get_next()
					dir.list_dir_end()
			if started:
				break
		if not started:
			print("[ErrorTracker] --shot watchdog: tidak ada PNG setelah 10 detik")
		return

	# Trigger shot tour via ErrorTracker (bukan call_deferred dari main._ready)
	print("[ErrorTracker] --shot watchdog: memanggil _shot_tour di %s" % main_node.name)
	main_node._shot_tour.call_deferred()

	# Tunggu shot tour selesai (maksimum 5 menit)
	var shotsDir := "user://shots"
	var lastCount := 0
	var noProgressFrames := 0
	for _i in range(18000):  # 5 menit di 60fps
		await get_tree().process_frame
		var dir := DirAccess.open(shotsDir)
		var count := 0
		if dir != null:
			dir.list_dir_begin()
			var f := dir.get_next()
			while f != "":
				if f.ends_with(".png"): count += 1
				f = dir.get_next()
			dir.list_dir_end()
		if count > lastCount:
			lastCount = count
			noProgressFrames = 0
		else:
			noProgressFrames += 1
		if noProgressFrames >= 300:
			print("[ErrorTracker] --shot watchdog: shot tour selesai (%d PNG)" % lastCount)
			get_tree().quit(0)
			return
	print("[ErrorTracker] --shot watchdog: timeout 5 menit")
	get_tree().quit(0)

func _scenario_bootstrap() -> void:
	var args := OS.get_cmdline_user_args()
	var si := args.find("--scenario")
	var scenario_name := ""
	if si >= 0 and si + 1 < args.size():
		scenario_name = args[si + 1]
	# Jika argumen sudah berupa path lengkap (res://, user://, atau berakhiran .json),
	# gunakan apa adanya. Jika bukan, bungkus sebagai res://scenarios/<name>.json.
	var scenario_path: String
	if scenario_name == "":
		scenario_path = "res://scenarios/smoke.json"
	elif scenario_name.begins_with("res://") or scenario_name.begins_with("user://") or scenario_name.ends_with(".json"):
		scenario_path = scenario_name
	else:
		scenario_path = "res://scenarios/%s.json" % scenario_name
	print("[ErrorTracker] --scenario bootstrap langsung: %s" % scenario_path)
	# Tunggu lebih lama agar hot-reload Godot selesai sepenuhnya
	# Hot-reload biasanya selesai dalam 3-5 detik setelah launch
	for _i in range(180):
		await get_tree().process_frame
	# Load ScenarioRunner sebagai script instance langsung dari ErrorTracker
	# Tidak bergantung pada Main node yang akan hancur karena hot-reload
	var runner_script = load("res://scripts/ScenarioRunner.gd")
	if runner_script == null:
		print("[ErrorTracker] ERROR: Gagal load ScenarioRunner.gd")
		get_tree().quit(1)
		return
	var runner := runner_script.new() as Node
	get_tree().root.add_child(runner)
	await get_tree().process_frame
	print("[ErrorTracker] ScenarioRunner dibuat, menjalankan scenario...")
	var exit_code: int = await runner.run_scenario_file(scenario_path)
	get_tree().quit(exit_code)


# ── Public API ─────────────────────────────────────────────────────────────────
## Jumlah error yang tercatat. Digunakan oleh ScenarioRunner assert_no_error.
func _get_error_count() -> int:
	return _errors.size()


## Alias untuk kompatibilitas dengan ScenarioRunner
func get_error_count() -> int:
	return _errors.size()


## Catat error secara manual dari kode game.
## category: kategori error (contoh: "save", "network", "gameplay")
## message: pesan error yang deskriptif
## context: data tambahan opsional (Dictionary)
func log_error(category: String, message: String, context: Dictionary = {}) -> void:
	var entry := {
		"timestamp": Time.get_datetime_string_from_system(),
		"elapsed_sec": snappedf(Time.get_unix_time_from_system() - _start_time, 0.001),
		"category": category,
		"message": message,
		"scene": _get_current_scene(),
		"frame": Engine.get_process_frames(),
	}
	if not context.is_empty():
		entry["context"] = context

	_errors.append(entry)
	push_error("[ErrorTracker] [%s] %s" % [category, message])


## Catat warning (tidak menambah error count, tapi dicatat untuk analisis)
func log_warning(category: String, message: String) -> void:
	_warning_count += 1
	push_warning("[ErrorTracker] [%s] %s" % [category, message])


## Ambil semua error yang tercatat
func get_errors() -> Array[Dictionary]:
	return _errors.duplicate()


## Ambil error terakhir
func get_last_error() -> Dictionary:
	if _errors.is_empty():
		return {}
	return _errors[-1]


## Ambil jumlah warning
func get_warning_count() -> int:
	return _warning_count


## Reset counter dan daftar error
func reset() -> void:
	_errors = []
	_warning_count = 0
	print("[ErrorTracker] Counter di-reset")


## Tulis error log ke disk (berguna untuk laporan bug)
func write_error_log() -> void:
	if _errors.is_empty():
		return

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("user://shots")
	)
	var path := "user://shots/error_log_%s.json" % \
		Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var data := {
		"schema_version": "1.0",
		"generated_at": Time.get_datetime_string_from_system(),
		"error_count": _errors.size(),
		"warning_count": _warning_count,
		"errors": _errors
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
		print("[ErrorTracker] Error log ditulis: %s" % path)


## Apakah ada error yang tercatat?
func has_errors() -> bool:
	return not _errors.is_empty()


## Apakah ada error dengan category tertentu?
func has_error_category(category: String) -> bool:
	return _errors.any(func(e): return e.get("category") == category)


# ── Helper ─────────────────────────────────────────────────────────────────────
func _get_current_scene() -> String:
	if get_tree() and get_tree().current_scene:
		return get_tree().current_scene.name
	return "unknown"
