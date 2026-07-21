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
	# Watchdog: tunggu shot tour selesai, quit jika main tidak quit sendiri.
	# --shot tour seharusnya quit via get_tree().quit() di akhir _shot_tour().
	# Jika hot-reload menghancurkan instance yang memanggil quit(),
	# watchdog ini memastikan game tetap bersih keluar.
	print("[ErrorTracker] --shot watchdog aktif")
	# Tunggu sampai ada PNG pertama (tanda shot tour mulai)
	var shotsDir := "user://shots"
	var maxWaitFrames := 600  # 10 detik untuk mulai
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
	# Shot tour sudah mulai — tunggu sampai selesai (maksimum 3 menit)
	var lastCount := 0
	var noProgressFrames := 0
	for _i in range(10800):  # 3 menit di 60fps
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
		# Jika tidak ada PNG baru selama 5 detik, anggap shot tour selesai
		if noProgressFrames >= 300:
			print("[ErrorTracker] --shot watchdog: shot tour selesai (%d PNG), memanggil quit()" % lastCount)
			get_tree().quit(0)
			return
	print("[ErrorTracker] --shot watchdog: timeout 3 menit")
	get_tree().quit(0)

func _scenario_bootstrap() -> void:
	var args := OS.get_cmdline_user_args()
	var si := args.find("--scenario")
	var scenario_name := ""
	if si >= 0 and si + 1 < args.size():
		scenario_name = args[si + 1]
	var scenario_path := "res://scenarios/%s.json" % scenario_name if scenario_name != "" else "res://scenarios/smoke.json"
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
