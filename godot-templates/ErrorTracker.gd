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
##   ErrorTracker.get_error_count()     -- jumlah error sejak start atau reset terakhir
##   ErrorTracker.get_errors()          -- daftar semua error
##   ErrorTracker.reset()               -- reset counter
##   ErrorTracker.get_last_error()      -- error terakhir yang tercatat
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

# -- State ----------------------------------------------------------------------
var _errors: Array[Dictionary] = []
var _warning_count: int = 0
var _start_time: float = 0.0

# -- Entry point ----------------------------------------------------------------
func _ready() -> void:
	_start_time = Time.get_unix_time_from_system()
	print("[ErrorTracker] Aktif -- pantau error via log_error()")
	# --shot mode dihandle oleh main.gd._ready() via call_deferred (pattern lama yang proven)
	# ErrorTracker hanya menyediakan quit fallback jika game tidak quit sendiri
	if "--shot" in OS.get_cmdline_user_args():
		_shot_quit_watchdog.call_deferred()
	elif "--scenario" in OS.get_cmdline_user_args():
		_scenario_bootstrap.call_deferred()

func _shot_quit_watchdog() -> void:
	# Bootstrap --shot: tunggu hot-reload selesai, lalu trigger _shot_tour di main node.
	# Pola ini identik dengan _scenario_bootstrap -- ErrorTracker sebagai autoload
	# diload lebih stabil dari main.gd yang bergantung pada class_name globals.
	# Dengan menunggu beberapa frame, hot-reload selesai dan semua class_name
	# sudah ter-register sebelum _shot_tour dipanggil.
	print("[ErrorTracker] --shot watchdog aktif")

	# Jumlah PNG SEBELUM apa pun terjadi. Harus diambil di baris pertama: kalau diukur setelah
	# jeda hot-reload di bawah, tur milik game (kalau ada) sudah sempat menulis file pertamanya
	# dan pertambahannya tidak lagi terlihat. Nilai absolutnya tidak berarti -- folder bisa
	# berisi sisa run sebelumnya -- yang bermakna hanya pertambahannya.
	var pngAtStart := _count_shot_pngs()

	# Tunggu hot-reload selesai (4 frame cukup untuk class_name re-register)
	for _i in range(4):
		await get_tree().process_frame

	# Cari main node yang punya _shot_tour() -- retry sampai 600 frame (10 detik di 60fps)
	# Beberapa game punya loading screen panjang sebelum main node siap (resources, Steam check, dll)
	var main_node: Node = null
	var maxSearchFrames := 600
	for _i in range(maxSearchFrames):
		for node in get_tree().root.get_children():
			if node.has_method("_shot_tour"):
				main_node = node
				break
		if main_node != null:
			break
		await get_tree().process_frame

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

	# ErrorTracker adalah SATU-SATUNYA pemilik pemanggilan _shot_tour. Kalau game juga
	# memanggilnya sendiri dari _ready(), dua tur berjalan bersamaan menelusuri UI dan state
	# yang sama: screenshot saling mendahului dan tersimpan dengan nama layar yang SALAH.
	# Terukur pada jimat -- setiap baris log muncul dua kali dan 01_title.png justru berisi
	# layar Candi. Kerusakan ini diam: jumlah file tetap benar dan coverage tetap 100%,
	# sehingga tidak ada satu pun pemeriksaan lain yang bisa melihatnya. Karena itu di sini
	# harus dibatalkan dan diteriakkan, bukan diperbaiki diam-diam.
	if main_node.has_meta("saksi_shot_tour_invoked"):
		push_error("[ErrorTracker] _shot_tour sudah dipanggil watchdog sebelumnya -- pemanggilan kedua dibatalkan")
		print("[ErrorTracker] --shot watchdog: BATAL -- _shot_tour sudah dipanggil")
		return
	# Beri jeda singkat sebelum memutuskan. Tur milik game dipanggil lewat call_deferred dari
	# _ready(), dan _snap() sendiri menunggu beberapa frame sebelum menulis file -- tanpa jeda
	# ini watchdog bisa sampai di sini lebih dulu dan tidak melihat pertambahan apa pun.
	# Pada game yang TIDAK memanggil sendiri, jeda ini tidak menulis apa-apa dan hanya
	# menambah sekitar setengah detik.
	for _i in range(30):
		await get_tree().process_frame
	var pngNow := _count_shot_pngs()
	if pngNow > pngAtStart:
		push_error("[ErrorTracker] Tur screenshot sudah berjalan sebelum watchdog memanggilnya (%d -> %d PNG). Game tampaknya memanggil _shot_tour() sendiri dari _ready() -- hapus pemanggilan itu, ErrorTracker yang memilikinya. Dua tur bersamaan menyimpan screenshot dengan nama layar yang salah." % [pngAtStart, pngNow])
		print("[ErrorTracker] --shot watchdog: BATAL -- tur sudah berjalan (game memanggil _shot_tour sendiri?)")
		return

	# Trigger shot tour via ErrorTracker (bukan call_deferred dari main._ready)
	# Gunakan .call_deferred("_shot_tour") agar kompatibel dengan GDScript strict mode --
	# memanggil custom method langsung di atas Node return value gagal di unsafe_method_access=2
	main_node.set_meta("saksi_shot_tour_invoked", true)
	print("[ErrorTracker] --shot watchdog: memanggil _shot_tour di %s" % main_node.name)
	main_node.call_deferred("_shot_tour")

	# Tunggu shot tour selesai (maksimum 5 menit)
	#
	# Kemajuan TIDAK boleh diukur dari cacah file saja. Tur menimpa nama file yang sama pada
	# setiap run, jadi cacahnya tidak pernah bertambah dan watchdog menyimpulkan "tidak ada
	# kemajuan" sejak detik pertama. Dulu lastCount juga dimulai dari 0, sehingga iterasi
	# pertama menganggap file-file LAMA sebagai kemajuan, lalu 300 frame berikutnya diam dan
	# game dimatikan ~5 detik kemudian -- sebelum tur sempat menulis apa pun.
	#
	# Efeknya: watchdog hanya andal kalau folder shots kebetulan kosong. Setiap run kedua ke
	# folder yang sama terpotong diam-diam, dan file lama membuat hasilnya tetap terlihat
	# lengkap. Terukur pada jimat: tur dipanggil, langsung dinyatakan "selesai (25 PNG)",
	# dan nol file baru tertulis.
	#
	# Sekarang dipakai DUA sinyal -- cacah file bertambah ATAU ada file yang mtime-nya maju --
	# dan keduanya di-baseline ke keadaan SEBELUM tur mulai, supaya isi folder lama tidak
	# pernah terhitung sebagai kemajuan.
	var lastCount := _count_shot_pngs()
	var lastStamp := _latest_shot_mtime()
	var noProgressFrames := 0
	for _i in range(18000):  # 5 menit di 60fps
		await get_tree().process_frame
		var count := _count_shot_pngs()
		var stamp := _latest_shot_mtime()
		if count > lastCount or stamp > lastStamp:
			lastCount = count
			lastStamp = stamp
			noProgressFrames = 0
		else:
			noProgressFrames += 1
		# 600 frame (~10 detik): mtime hanya berbutir detik, dan sebagian layar butuh
		# beberapa detik disiapkan sebelum screenshot berikutnya tertulis.
		if noProgressFrames >= 600:
			print("[ErrorTracker] --shot watchdog: shot tour selesai (%d PNG)" % lastCount)
			get_tree().quit(0)
			return
	print("[ErrorTracker] --shot watchdog: timeout 5 menit")
	get_tree().quit(0)


## mtime terbaru di antara seluruh PNG di user://shots, dalam detik unix; 0 kalau tidak ada.
## Diperlukan karena tur MENIMPA nama file yang sama -- tanpa sinyal waktu, penulisan ulang
## tidak terlihat sebagai kemajuan sama sekali.
func _latest_shot_mtime() -> int:
	var dir := DirAccess.open("user://shots")
	if dir == null:
		return 0
	var newest := 0
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".png"):
			var t := int(FileAccess.get_modified_time("user://shots/" + f))
			if t > newest:
				newest = t
		f = dir.get_next()
	dir.list_dir_end()
	return newest

## Menghitung PNG di user://shots. Satu-satunya kegunaannya: mendeteksi tur screenshot yang
## sudah terlanjur berjalan sebelum watchdog memanggilnya.
func _count_shot_pngs() -> int:
	var dir := DirAccess.open("user://shots")
	if dir == null:
		return 0
	var n := 0
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".png"):
			n += 1
		f = dir.get_next()
	dir.list_dir_end()
	return n


## Dipanggil dari _shot_tour() saat game perlu ganti scene sebelum screenshot berikutnya.
## ErrorTracker tetap hidup sebagai Autoload saat scene change, sehingga coroutine ini
## tidak ter-cancel. Ini adalah solusi untuk masalah: coroutine di Main node ter-cancel
## saat change_scene_to_file() karena Main node di-free.
func _continue_shot_tour_after_scene_change(scene_path: String, shot_name: String) -> void:
	get_tree().change_scene_to_file(scene_path)
	# Tunggu beberapa frame agar scene baru selesai di-instantiate
	for _i in range(10):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	# Ambil screenshot dari ErrorTracker (tidak bergantung pada node game)
	var img: Image = get_viewport().get_texture().get_image()
	var shots_dir := ProjectSettings.globalize_path("user://shots")
	if not DirAccess.dir_exists_absolute(shots_dir):
		DirAccess.make_dir_absolute(shots_dir)
	img.save_png(shots_dir + "/%s.png" % shot_name)
	print("[ErrorTracker] _continue_shot_tour: saved %s.png" % shot_name)
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
	# Gunakan GDScript type agar kompatibel dengan unsafe_method_access strict mode
	# Self-locating: derive path dari lokasi ErrorTracker.gd itu sendiri sehingga
	# salinan vendored di semua layout folder (scripts/, source/scripts/, src/global/, dll)
	# bisa menemukan ScenarioRunner.gd tanpa adaptasi manual per-game.
	# Cast ke Script eksplisit agar get_resource_path() tersedia di strict mode.
	var self_script := get_script() as Script
	var self_dir: String = self_script.resource_path.get_base_dir()
	var runner_path: String = self_dir.path_join("ScenarioRunner.gd")
	var runner_script: GDScript = load(runner_path)
	if runner_script == null:
		print("[ErrorTracker] ERROR: Gagal load ScenarioRunner.gd dari: %s" % runner_path)
		get_tree().quit(1)
		return
	# Buat instance tanpa cast 'as Node' -- cast ke type konkret gagal di strict mode
	# karena load() mengembalikan GDScript resource, bukan class yang diketahui compiler.
	# Gunakan .call() untuk semua method custom agar strict mode tidak complain.
	var runner: Node = runner_script.new()
	get_tree().root.add_child(runner)
	await get_tree().process_frame
	print("[ErrorTracker] ScenarioRunner dibuat, menjalankan scenario...")
	var exit_code: int = await runner.call("run_scenario_file", scenario_path)
	get_tree().quit(exit_code)


# -- Public API -----------------------------------------------------------------
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
	return _errors.any(func(e: Dictionary) -> bool: return e.get("category") == category)


# -- Helper ---------------------------------------------------------------------
func _get_current_scene() -> String:
	if get_tree() and get_tree().current_scene:
		return get_tree().current_scene.name
	return "unknown"
