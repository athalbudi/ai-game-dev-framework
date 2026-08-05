# ScenarioRunner.gd
# Universal scenario runner untuk AI-assisted game development framework.
# JANGAN daftarkan sebagai Autoload di project.godot -- ini akan menyebabkan
# hot-reload race condition. Muat sebagai script instance dari ErrorTracker._scenario_bootstrap().
# Lihat README.md dan FRAMEWORK.md untuk cara penggunaan yang benar.
#
# Interface dengan game:
#   - Game menyediakan state lewat SALAH SATU dari dua kontrak berikut:
#       a. _get_game_state() -> Dictionary  di node manapun  (DISARANKAN)
#          GameStateWriter yang mengurus penulisan file; game cukup menyediakan datanya.
#       b. _write_game_state() -> void      di node manapun
#          Game menulis filenya sendiri. Kalau GameStateWriter autoload juga terpasang,
#          implementasi milik GAME yang dipakai -- lihat _resolve_state_writer().
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

# --- Invariant: klaim yang berlaku sepanjang run, bukan di satu titik ---
# assert_state bersifat posisional -- ia hanya memeriksa di tempat penulis scenario
# menaruhnya, jadi bug yang terjadi di antara dua assertion tidak terlihat. Invariant
# diperiksa setelah SETIAP langkah, sehingga kelas bug "pemain melompati sesuatu"
# (progres naik tanpa usaha yang mendahuluinya) baru bisa terdeteksi sama sekali.
#
# Pelanggaran TIDAK menghentikan run kecuali invariant itu menyetel fail_fast:true --
# satu run harus bisa memanen semua pelanggaran sekaligus, dan fail-fast di sini akan
# membuat mode eksplorasi tidak berguna karena pelanggaran pertama mengakhiri penjelajahan.
# Hasil di-dedup per id: kejadian pertama disimpan lengkap, berikutnya hanya menambah
# pencacah, supaya satu kondisi yang terus rusak tidak membanjiri laporan.
var _invariants: Array = []
var _invariant_violations: Dictionary = {}
var _invariant_prev: Dictionary = {}
var _invariant_checks: int = 0

# --- Gerbang liveness: scenario yang tidak menyentuh apa pun bukan scenario yang lulus ---
# Kegagalan terburuk yang bisa dilakukan harness bukan melewatkan bug, melainkan melaporkan
# PASS atas ketiadaan pengujian. Terukur pada jimat: smoke, menu_navigation,
# adversarial_input_mash, dan probe_run_start semuanya "PASS" selama berminggu-minggu
# terhadap LAYAR KOSONG, karena game mengambil jalur init minimal saat --scenario. Tidak ada
# satu pun assertion yang bisa menangkapnya -- semuanya memang lolos, terhadap ketiadaan.
#
# Aturannya sengaja dipersempit supaya tidak menghukum scenario yang sah: liveness HANYA
# dituntut bila scenario benar-benar mengirim input. Scenario yang isinya hanya screenshot
# memang wajar tidak mengubah apa pun; scenario yang menekan tombol lalu tidak mengubah
# state maupun layar tidak menguji apa-apa.
const INPUT_STEP_TYPES := ["action", "mouse_click", "click_button", "touch_tap",
	"controller_press", "explore"]

# Daftar lengkap step type yang punya implementasi. Dipakai untuk menyusun pesan kesalahan
# saat scenario memakai type asing -- lihat cabang else di _dispatch(). Urutannya sama
# dengan tabel di command/scenario.md, dan test-pipeline memeriksa keduanya tetap cocok:
# dokumentasi yang menjanjikan step type yang tidak ada adalah cara lain menghasilkan
# scenario yang "lulus" tanpa menjalankan apa pun.
const KNOWN_STEP_TYPES := ["wait_frames", "wait_scene", "wait_signal", "wait_condition",
	"action", "mouse_click", "click_button", "touch_tap", "controller_press", "screenshot",
	"assert_state", "assert_fps", "assert_no_error", "assert_screenshot_exists",
	"set_state", "write_state", "repeat", "seed_override", "log", "comment", "explore"]

# Field yang SELALU berubah tiap penulisan state. Tanpa dikecualikan, setiap scenario akan
# tampak hidup dan gerbang ini jadi hiasan.
const VOLATILE_STATE_FIELDS := ["timestamp", "frame_count", "schema_version", "fps",
	"uptime_sec", "time", "delta", "elapsed"]

var _liveness_required: bool = false
var _liveness_input_steps: int = 0
var _liveness_state_changed: bool = false
var _liveness_shots_vary: bool = false


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
	_load_invariants(path)
	_scenario_start_time = Time.get_unix_time_from_system()
	_current_step = 0
	if _scenario.has("seed") and _scenario["seed"] != null:
		seed(int(_scenario["seed"]))
	print("[scenario] Mulai: ", _scenario.get("scenario_id", "unnamed"), " (", _steps.size(), " steps)")
	await get_tree().process_frame
	var exit_code := await _run_steps()
	return exit_code


func _run_steps() -> int:
	# State awal jadi pembanding untuk delta di langkah pertama. Tanpa ini delta pada
	# langkah 1 selalu kosong dan invariant berbasis delta diam-diam tidak pernah menguji apa pun.
	if not _invariants.is_empty():
		var w0 := _resolve_state_writer()
		if w0 != null:
			w0.call("_write_game_state")
			await _wait_frames(1)
		_invariant_prev = _read_game_state()
	# Liveness hanya relevan kalau scenario memang mengirim input -- lihat catatan di
	# INPUT_STEP_TYPES. Snapshot diambil SEBELUM langkah pertama supaya pembandingnya
	# adalah keadaan awal yang sesungguhnya.
	_liveness_input_steps = _count_input_steps(_steps)
	_liveness_required = _liveness_input_steps > 0
	var state_before: Dictionary = {}
	if _liveness_required:
		state_before = await _snapshot_state()

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
		if await _check_invariants(i, step_type):
			_write_result("fail", "Invariant fail_fast dilanggar di step %d" % (i + 1))
			return 1
	# Pelanggaran invariant critical WAJIB mengubah status akhir. Kalau hanya dicatat di
	# laporan, exit code tetap 0 dan orchestrator yang -- sesuai kontraknya -- hanya membaca
	# exit code akan meluluskan run yang sebenarnya melanggar aturan game. Itu pola
	# false-verify yang sudah pernah terjadi di proyek ini (status benar, exit code salah).
	var critical := _critical_violations()
	if critical.size() > 0:
		_write_result("fail", "Invariant critical dilanggar: " + ", ".join(PackedStringArray(critical)))
		return 1

	# Gerbang liveness -- dijalankan hanya di jalur yang SEHARUSNYA lulus. Sebuah scenario
	# yang mengirim input lalu tidak mengubah state maupun layar tidak menguji apa pun, dan
	# melabelinya "pass" adalah false-verify yang paling merugikan: ia bukan cuma gagal
	# menemukan bug, ia memberi lampu hijau atas ketiadaan pengujian.
	if _liveness_required and not bool(_scenario.get("allow_inert", false)):
		var state_after := await _snapshot_state()
		_liveness_state_changed = _state_meaningfully_changed(state_before, state_after)
		_liveness_shots_vary = _screenshots_vary()
		if not _liveness_state_changed and not _liveness_shots_vary:
			_write_result("inert", ("Scenario mengirim %d langkah input tetapi TIDAK ada yang berubah: " +
				"game_state identik dari awal sampai akhir (di luar field volatil) dan semua screenshot " +
				"byte-identik. Tidak ada perilaku game yang teruji. Periksa apakah game benar-benar " +
				"membangun layarnya saat dijalankan dengan --scenario -- beberapa game mengambil jalur " +
				"init minimal dan menampilkan layar kosong. Kalau scenario ini memang dimaksudkan tidak " +
				"mengubah apa-apa, set \"allow_inert\": true.") % _liveness_input_steps)
			return 1

	# Gerbang terakhir: scenario yang TIDAK SATU PUN langkahnya lulus bukan scenario yang
	# lulus. Dua bentuknya sama-sama berakhir "pass" sebelum ini:
	#
	#   - scenario berisi 10 assert_state terhadap game tanpa penyedia state -> 10 skip,
	#     0 pass, status "pass", exit 0. Orchestrator yang membaca exit code menyimpulkan
	#     scenario ini memverifikasi sesuatu. Ia tidak memverifikasi apa pun.
	#   - scenario dengan "steps": [] -> loop tidak pernah berjalan, langsung "pass".
	#
	# Gerbang liveness tidak menangkap keduanya: ia hanya aktif kalau ada langkah INPUT,
	# sementara scenario yang seluruhnya assertion (atau kosong) tidak punya satu pun.
	# Status "inert" dipakai ulang karena artinya memang sama -- berjalan tanpa menguji
	# apa pun -- dan opt-out-nya pun sama: "allow_inert": true.
	var pass_total := 0
	for r: Dictionary in _step_results:
		if r.get("status", "") == "pass":
			pass_total += 1
	if pass_total == 0 and not bool(_scenario.get("allow_inert", false)):
		var skip_total := _steps.size() - _step_results.size()
		for r2: Dictionary in _step_results:
			if r2.get("status", "") == "skip":
				skip_total += 1
		_write_result("inert", ("Tidak satu pun dari %d langkah yang lulus (%d dilewati). " +
			"Scenario ini tidak memverifikasi apa pun, dan melabelinya \"pass\" memberi lampu " +
			"hijau atas ketiadaan pengujian. Penyebab tersering: seluruh assertion dilewati " +
			"karena game belum menulis game_state.json, atau daftar steps kosong. " +
			"Kalau memang disengaja, set \"allow_inert\": true.") % [_steps.size(), skip_total])
		return 1

	_write_result("pass", null)
	return 0


func _dispatch(step_type: String, step: Dictionary) -> void:
	if step_type == "wait_frames":
		await _exec_wait_frames(step)
	elif step_type == "wait_scene":
		await _exec_wait_scene(step)
	elif step_type == "wait_signal":
		# await WAJIB: _exec_wait_signal sekarang benar-benar menunggu (await + timeout).
		# Tanpa await, dispatcher kembali seketika, scenario selesai lebih dulu, dan hasil
		# step-nya tidak pernah tercatat -- terukur sebagai "PASS | pass=0 fail=0 skip=0".
		await _exec_wait_signal(step)
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
	elif step_type == "click_button":
		await _exec_click_button(step)
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
	elif step_type == "explore":
		await _exec_explore(step)
	elif step_type == "repeat":
		await _exec_repeat(step)
	elif step_type == "seed_override":
		_exec_seed_override(step)
	elif step_type == "comment":
		# Anotasi murni. JSON tidak punya komentar, dan scenario panjang jadi tak terbaca
		# tanpa penanda fase. Sengaja dijadikan type yang SAH dan lulus, bukan dilewati:
		# yang dilewati tak bisa dibedakan dari salah ketik.
		_step_pass({"text": str(step.get("text", ""))})
	else:
		# GAGAL, bukan skip. Skip terlihat aman tapi justru false-verify: scenario yang setiap
		# langkahnya salah ketik akan berakhir "pass" tanpa pernah menjalankan apa pun, dan
		# laporannya tidak bisa dibedakan dari scenario yang benar-benar lulus. Gerbang liveness
		# pun tidak menolongnya -- type asing tidak dikenali sebagai langkah input, jadi
		# gerbangnya tidak pernah aktif.
		_step_fail("Step type tidak dikenal: '%s'. Yang sah: %s" % [step_type, ", ".join(KNOWN_STEP_TYPES)])


# --- Invariant ---

## Dimuat dari dua sumber: field "invariants" di scenario itu sendiri, dan file game-wide
## res://scenarios/invariants.json. Yang game-wide berlaku untuk SEMUA scenario -- di situ
## nilai terbesarnya: sekali tulis, seluruh suite yang sudah ada langsung ikut diawasi
## tanpa satu pun scenario perlu diubah.
func _load_invariants(scenario_path: String) -> void:
	_invariants = []
	var shared_path := "res://scenarios/invariants.json"
	if FileAccess.file_exists(shared_path) and scenario_path != shared_path:
		var f := FileAccess.open(shared_path, FileAccess.READ)
		if f:
			var j := JSON.new()
			var perr := j.parse(f.get_as_text())
			f.close()
			if perr == OK:
				var d: Variant = j.get_data()
				if d is Dictionary and (d as Dictionary).has("invariants"):
					var arr: Variant = (d as Dictionary)["invariants"]
					if arr is Array:
						_invariants.append_array(arr as Array)
			else:
				push_warning("[scenario] invariants.json tidak valid: " + j.get_error_message())
	if _scenario.has("invariants") and _scenario["invariants"] is Array:
		_invariants.append_array(_scenario["invariants"] as Array)
	if _invariants.size() > 0:
		print("[scenario] Invariant aktif: %d" % _invariants.size())


## delta HANYA dihitung untuk field numerik yang hadir di kedua state. Field yang baru
## muncul atau hilang sengaja tidak diberi delta -- kalau dipaksakan jadi 0, invariant
## seperti "delta.seals <= delta.wins" akan lolos diam-diam justru saat datanya tidak ada.
func _state_delta(prev: Dictionary, curr: Dictionary) -> Dictionary:
	var d: Dictionary = {}
	for k: Variant in curr.keys():
		if not prev.has(k):
			continue
		var a: Variant = prev[k]
		var b: Variant = curr[k]
		if (a is int or a is float) and (b is int or b is float):
			d[k] = float(b) - float(a)
	return d


## Mengembalikan hasil boolean ekspresi, atau null kalau ekspresi tidak bisa
## di-parse/dievaluasi. null sengaja dibedakan dari false: ekspresi rusak adalah masalah
## penulisan invariant, bukan bukti game melanggar sesuatu.
func _eval_invariant(src: String, prev: Dictionary, curr: Dictionary, delta: Dictionary) -> Variant:
	var e := Expression.new()
	var err := e.parse(src, PackedStringArray(["prev", "curr", "delta"]))
	if err != OK:
		push_warning("[scenario] invariant tidak bisa di-parse: '%s' -- %s" % [src, e.get_error_text()])
		return null
	var res: Variant = e.execute([prev, curr, delta], null, false)
	if e.has_execute_failed():
		push_warning("[scenario] invariant gagal dievaluasi: '%s' -- %s" % [src, e.get_error_text()])
		return null
	return res


## Dipanggil setelah setiap langkah. Mengembalikan true bila ada pelanggaran ber-fail_fast
## yang harus menghentikan run.
func _check_invariants(step_index: int, step_type: String) -> bool:
	if _invariants.is_empty():
		return false
	var writer := _resolve_state_writer()
	if writer != null:
		writer.call("_write_game_state")
		await _wait_frames(1)
	var curr := _read_game_state()
	if curr.is_empty():
		return false
	var delta := _state_delta(_invariant_prev, curr)
	var stop := false
	for inv_v: Variant in _invariants:
		if not (inv_v is Dictionary):
			continue
		var inv: Dictionary = inv_v
		var expr_src: String = str(inv.get("expr", ""))
		if expr_src == "":
			continue
		_invariant_checks += 1
		var ok: Variant = _eval_invariant(expr_src, _invariant_prev, curr, delta)
		if ok == null or bool(ok):
			continue
		var inv_id: String = str(inv.get("id", expr_src))
		if _invariant_violations.has(inv_id):
			var rec: Dictionary = _invariant_violations[inv_id]
			rec["count"] = int(rec.get("count", 1)) + 1
			_invariant_violations[inv_id] = rec
		else:
			_invariant_violations[inv_id] = {
				"id": inv_id,
				"expr": expr_src,
				"description": str(inv.get("description", "")),
				"severity": str(inv.get("severity", "critical")),
				"first_step": step_index + 1,
				"first_step_type": step_type,
				"count": 1,
				"prev": _invariant_prev.duplicate(true),
				"curr": curr.duplicate(true),
				"delta": delta.duplicate(true),
			}
			print("[scenario] INVARIANT dilanggar: %s -- %s (step %d: %s)" % [inv_id, expr_src, step_index + 1, step_type])
			push_warning("[scenario] invariant '%s' dilanggar di step %d" % [inv_id, step_index + 1])
		if bool(inv.get("fail_fast", false)):
			stop = true
	_invariant_prev = curr
	return stop


# --- Eksplorasi ---

## Scenario tertulis hanya mengunjungi apa yang sudah dipikirkan penulisnya. Bug "konten
## bisa dilewati" justru hidup di jalur yang TIDAK terpikirkan -- karena itu ia tidak akan
## pernah muncul dari suite scenario, seberapa pun banyaknya. Step ini menekan tombol yang
## benar-benar ada di layar secara acak, dan invariant diperiksa setelah SETIAP klik.
## Eksplorasi tanpa invariant cuma menghasilkan screenshot; invariant tanpa eksplorasi cuma
## menjaga jalur yang sudah aman. Nilainya muncul dari gabungan keduanya.
##
## Sengaja mengklik Control, BUKAN mengirim action ui_*: tanpa Control yang fokus, ui_*
## tidak mengenai apa pun -- persis kondisi yang membuat seluruh scenario jimat tidak
## pernah masuk ke gameplay sama sekali.
func _exec_explore(step: Dictionary) -> void:
	var iterations: int = int(step.get("iterations", 40))
	var settle: int = int(step.get("settle_frames", 10))
	var stop_on_violation: bool = bool(step.get("stop_on_violation", false))
	var avoid: Array = step.get("avoid_text", ["Quit", "Keluar", "Exit"])
	var warmup: int = int(step.get("warmup_frames", 90))
	var seed_val: Variant = step.get("seed", null)
	if seed_val != null:
		seed(int(seed_val))

	if _invariants.is_empty():
		push_warning("[scenario] explore berjalan TANPA invariant -- ia hanya akan mengklik tombol dan tidak memeriksa apa pun. Sediakan scenarios/invariants.json.")

	var trail: Array = []
	var visited: Dictionary = {}
	var seen_violations := _invariant_violations.size()
	var clicked := 0
	var dead_ends := 0
	var replay_written := false

	for i in range(iterations):
		var buttons := _find_clickable_buttons(avoid)
		if buttons.is_empty():
			# Layar buntu (tidak ada tombol aktif). Coba mundur dengan ui_cancel supaya
			# eksplorasi tidak macet selamanya di satu layar.
			dead_ends += 1
			var ev := InputEventAction.new()
			ev.action = "ui_cancel"
			ev.pressed = true
			Input.parse_input_event(ev)
			await _wait_frames(settle)
			continue

		var pick: Control = buttons[randi() % buttons.size()]
		var label := _button_label(pick)
		var center := pick.get_global_rect().get_center()
		trail.append({"iteration": i, "x": center.x, "y": center.y, "label": label})
		visited[label] = int(visited.get(label, 0)) + 1

		await _click_at(center, MOUSE_BUTTON_LEFT)
		await _wait_frames(settle)
		clicked += 1

		var must_stop := await _check_invariants(_current_step, "explore#%d" % i)
		if _invariant_violations.size() > seen_violations:
			seen_violations = _invariant_violations.size()
			_write_explore_replay(trail, seed_val, settle, warmup)
			replay_written = true
			if stop_on_violation:
				break
		if must_stop:
			break

	var data := {
		"iterations": iterations, "clicked": clicked, "dead_ends": dead_ends,
		"unique_buttons": visited.size(),
		"buttons": visited.keys(),
		"violations": _invariant_violations.size(),
		"replay": (("user://shots/explore_replay.json") if replay_written else "")
	}

	# Eksplorasi yang tidak pernah mengklik apa pun TIDAK mengeksplorasi apa pun. Melaporkan
	# PASS di sini adalah false-verify paling murni: suite terlihat hijau padahal tak satu
	# pun perilaku game tersentuh. Terukur pada jimat -- 40 iterasi, 40 layar buntu, 0 klik,
	# karena game mengambil jalur init minimal saat --scenario dan tidak pernah membangun
	# layar apa pun. Empat scenario lain di game itu "PASS" bertahun-tahun terhadap layar
	# kosong yang sama tanpa ada yang menyadarinya.
	if clicked == 0 and iterations > 0 and bool(step.get("require_clicks", true)):
		_step_fail(("explore: 0 tombol bisa diklik dalam %d iterasi (%d layar buntu). " +
			"Tidak ada satu pun perilaku game yang teruji. Periksa: (a) apakah game benar-benar " +
			"membangun layarnya saat dijalankan dengan --scenario -- beberapa game mengambil " +
			"jalur init minimal dan menampilkan layar kosong; (b) apakah UI-nya memakai Control " +
			"selain BaseButton. Kalau game memang tidak digerakkan tombol, set require_clicks:false " +
			"dan gerakkan lewat step action/mouse_click.") % [iterations, dead_ends])
		return

	_step_pass(data)


func _button_label(b: Node) -> String:
	if b is Button:
		var t: String = (b as Button).text
		if t.strip_edges() != "":
			return t
	return b.name


func _find_clickable_buttons(avoid: Array) -> Array:
	var out: Array = []
	var vp := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	_collect_buttons(get_tree().root, out, avoid, vp)
	return out


## Hanya tombol yang benar-benar bisa ditekan pemain: terlihat di tree, tidak disabled,
## punya luas, dan berpotongan dengan viewport. Tombol di luar layar tetap "ada" di tree
## tapi mengkliknya tidak mewakili apa pun yang bisa dilakukan pemain.
func _collect_buttons(node: Node, out: Array, avoid: Array, vp: Rect2) -> void:
	if node is BaseButton:
		var b: BaseButton = node
		if b.is_visible_in_tree() and not b.disabled:
			var r := b.get_global_rect()
			if r.size.x > 1.0 and r.size.y > 1.0 and vp.intersects(r):
				var lbl := _button_label(b)
				var skip := false
				for a: Variant in avoid:
					if lbl.findn(str(a)) >= 0:
						skip = true
						break
				if not skip:
					out.append(b)
	for c in node.get_children():
		_collect_buttons(c, out, avoid, vp)


## Eksplorasi yang menemukan bug tapi tidak bisa diulang tidak ada gunanya bagi siapa pun.
## Setiap kali invariant BARU dilanggar, seluruh jejak klik sampai titik itu ditulis sebagai
## scenario utuh yang bisa langsung dijalankan untuk mereproduksi.
func _write_explore_replay(trail: Array, seed_val: Variant, settle: int, warmup: int) -> void:
	var steps: Array = []
	# Seed dan pemanasan ikut ditulis supaya replay benar-benar bisa dijalankan SENDIRI.
	# Tanpa keduanya, klik pertama mendarat sebelum layar selesai dibangun dan replay
	# gagal mereproduksi apa pun -- file yang terlihat berguna tapi tidak pernah bekerja.
	if seed_val != null:
		steps.append({"type": "seed_override", "seed": int(seed_val)})
	steps.append({"type": "wait_frames", "frames": warmup,
		"comment": "tunggu layar awal selesai dibangun sebelum klik pertama"})
	# Ditulis sebagai click_button, BUKAN mouse_click. Jejak yang menyebut APA yang ditekan
	# tahan terhadap pergeseran tata letak, dan -- lebih penting -- membuat minimisasi bisa
	# membuang klik yang tidak relevan tanpa mengubah sasaran klik sesudahnya. Koordinat asli
	# tetap disimpan sebagai catatan, bukan sebagai cara menekan.
	for t: Variant in trail:
		var d: Dictionary = t
		steps.append({
			"type": "click_button", "label": str(d["label"]), "wait_frames": settle,
			"recorded_x": d["x"], "recorded_y": d["y"]
		})
	var doc := {
		"scenario_id": "explore_replay",
		"description": "Dihasilkan otomatis oleh step explore saat invariant dilanggar. Jalankan scenario ini untuk mereproduksi pelanggaran tersebut, atau perkecil dulu dengan tools/explore-minimize.ps1.",
		"steps": steps
	}
	# Invariant inline milik scenario asal WAJIB ikut. Yang game-wide dimuat sendiri dari
	# scenarios/invariants.json, tapi yang dideklarasikan di dalam scenario tidak ada di
	# mana pun selain scenario itu -- tanpa disalin ke sini, replay berjalan tanpa aturan
	# yang tadi dilanggarnya dan tidak akan pernah mereproduksi apa pun. Terukur: kandidat
	# minimisasi memuat 8 invariant game-wide dan bukan yang inline, lalu baseline gagal.
	if _scenario.has("invariants") and _scenario["invariants"] is Array:
		var inline: Array = _scenario["invariants"]
		if inline.size() > 0:
			doc["invariants"] = inline
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://shots"))
	var f := FileAccess.open("user://shots/explore_replay.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(doc, "\t"))
		f.close()
		print("[scenario] explore: replay ditulis (%d klik) -> user://shots/explore_replay.json" % steps.size())


# --- Liveness ---

## Menghitung langkah input TERMASUK yang bersarang, mis. di dalam repeat.
## Pemindaian yang hanya melihat tingkat teratas melewatkan justru scenario yang paling
## banyak mengirim input: adversarial_input_mash milik jimat menaruh kelima langkah action-nya
## di dalam satu repeat, sehingga gerbang liveness sama sekali tidak berlaku untuknya --
## padahal ia salah satu dari empat scenario yang dulu "PASS" terhadap layar kosong.
func _count_input_steps(steps: Array) -> int:
	var n := 0
	for s: Variant in steps:
		if not (s is Dictionary):
			continue
		var d: Dictionary = s
		if str(d.get("type", "")) in INPUT_STEP_TYPES:
			n += 1
		if d.has("steps") and d["steps"] is Array:
			n += _count_input_steps(d["steps"] as Array)
	return n


## Paksa game menulis state terbaru lalu baca. Dipakai sebagai pembanding awal/akhir.
func _snapshot_state() -> Dictionary:
	var w := _resolve_state_writer()
	if w != null:
		w.call("_write_game_state")
		await _wait_frames(1)
	return _read_game_state()


## Perbandingan dilakukan lewat str() supaya nilai bersarang (Dictionary/Array) ikut
## terbandingkan tanpa perlu deep-compare manual. Field volatil dikecualikan -- tanpa itu
## frame_count saja sudah membuat setiap scenario tampak hidup.
func _state_meaningfully_changed(before: Dictionary, after: Dictionary) -> bool:
	if before.is_empty() and after.is_empty():
		return false
	var volatile: Array = VOLATILE_STATE_FIELDS.duplicate()
	if _scenario.has("volatile_fields") and _scenario["volatile_fields"] is Array:
		volatile.append_array(_scenario["volatile_fields"] as Array)
	var all_keys: Dictionary = {}
	for k: Variant in before.keys():
		all_keys[k] = true
	for k: Variant in after.keys():
		all_keys[k] = true
	for k: Variant in all_keys.keys():
		if str(k) in volatile:
			continue
		if str(before.get(k, null)) != str(after.get(k, null)):
			return true
	return false


## true bila ADA dua screenshot yang berbeda isinya. Layar yang tidak pernah berubah
## sepanjang scenario adalah tanda kuat bahwa input tidak mengenai apa pun.
func _screenshots_vary() -> bool:
	if _screenshots_taken.size() < 2:
		return false
	var first := ""
	for nm: String in _screenshots_taken:
		var p := "user://shots/scenario_" + nm + ".png"
		if not FileAccess.file_exists(p):
			continue
		var h := FileAccess.get_md5(p)
		if first == "":
			first = h
		elif h != first:
			return true
	return false


func _critical_violations() -> Array:
	var out: Array = []
	for inv_id: Variant in _invariant_violations.keys():
		var rec: Dictionary = _invariant_violations[inv_id]
		if str(rec.get("severity", "critical")) == "critical":
			out.append(str(inv_id))
	return out


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
		# Gunakan .call() agar kompatibel dengan GDScript strict mode (unsafe_method_access=2)
		if gsw.call("get_current_scene") == target:
			_step_pass({"scene": target, "via": "GameStateWriter"})
			return
		# Tunggu signal dengan timeout
		var elapsed: float = 0.0
		var interval: float = 0.1
		while elapsed < timeout:
			if gsw.call("get_current_scene") == target:
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
	# Terima "timeout" (dipakai scenarios-templates/input_methods.json) maupun
	# "timeout_sec" (dipakai wait_condition), supaya scenario yang sudah ada tetap jalan.
	var timeout_sec: float = float(step.get("timeout_sec", step.get("timeout", 10.0)))
	_waiting_signal = sig
	_signal_received = false

	# Versi sebelumnya memanggil _step_pass() di sini juga -- langsung, tanpa menunggu.
	# Akibatnya step ini SELALU pass meski signal tidak pernah dikirim, dan field
	# "timeout" yang dijanjikan template diabaikan total. Terukur: scenario yang menunggu
	# signal tak-pernah-dikirim dengan timeout 3s selesai dalam 0,229 detik dan lapor PASS.
	# Itu false-verify: scenario yang memakai wait_signal untuk sinkronisasi akan berlari
	# mendahului game, lalu melaporkan bahwa sinkronisasinya berhasil.
	var elapsed: float = 0.0
	while elapsed < timeout_sec:
		if _signal_received:
			_signal_received = false
			_step_pass({"signal": sig, "waited_sec": snappedf(elapsed, 0.001)})
			return
		await _wait_frames(1)
		elapsed += get_process_delta_time()

	_signal_received = false
	_step_fail("Signal '%s' tidak diterima dalam %.1f detik" % [sig, timeout_sec])


func _exec_wait_condition(step: Dictionary) -> void:
	var key: String = step.get("key", "")
	var op: String = step.get("op", "not_null")
	var expected: Variant = step.get("expected", null)
	var timeout_sec: float = float(step.get("timeout_sec", 10.0))
	if key.is_empty():
		_step_fail("wait_condition tidak punya field 'key'")
		return
	var elapsed: float = 0.0
	while elapsed < timeout_sec:
		var condWriter := _resolve_state_writer()
		if condWriter != null:
			condWriter.call("_write_game_state")
		await _wait_frames(6)
		elapsed += 6.0 / 60.0
		var state := _read_game_state()
		if not state.is_empty():
			var actual: Variant = _resolve_dot_key(state, key)
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

	# PASS di sini berarti "input dikirim", BUKAN "input berpengaruh" -- framework tidak
	# bisa tahu apakah game merespons. Tapi satu kasus bisa dipastikan: action ui_* di
	# Godot hanya sampai ke Button/Control yang sedang FOKUS. Kalau tidak ada yang fokus,
	# input itu dijamin tidak mengenai apa pun.
	#
	# Ini penyebab senyap yang mahal: scenario menekan ui_accept berkali-kali, setiap step
	# melapor PASS, dan game tidak bergerak sedikit pun. Terukur di jimat -- goto_title()
	# tidak pernah memanggil grab_focus(), sehingga seluruh navigasi berbasis ui_accept
	# tidak berfungsi sementara scenario melaporkan sukses.
	#
	# Peringatan, bukan kegagalan: sebagian game menangani ui_* lewat _input()/_unhandled_input
	# tanpa bergantung fokus, dan di situ input tetap sampai.
	var data := {"action": action_name}
	if action_name.begins_with("ui_") and get_viewport().gui_get_focus_owner() == null:
		var warn := "tidak ada Control yang fokus -- action ui_* kemungkinan besar tidak mengenai apa pun. Panggil grab_focus() di game, atau pakai mouse_click."
		data["warning"] = warn
		push_warning("[scenario] action '%s': %s" % [action_name, warn])
	_step_pass(data)


func _resolve_mouse_button(value: Variant) -> int:
	# Terima integer langsung atau nama string MouseButton.
	# Masalah yang sama dengan _resolve_joy_button: int("left") = 0, tapi MOUSE_BUTTON_LEFT = 1
	# sehingga string "left" akan resolve ke tombol yang salah. int("right") = 0 juga — salah.
	if value is int:
		return value
	var s: String = str(value).to_lower().strip_edges()
	if s.is_valid_int():
		return s.to_int()
	var _mouse_names: Dictionary = {
		"left":    MOUSE_BUTTON_LEFT,    # 1
		"right":   MOUSE_BUTTON_RIGHT,   # 2
		"middle":  MOUSE_BUTTON_MIDDLE,  # 3
		"wheel_up":   MOUSE_BUTTON_WHEEL_UP,    # 4
		"wheel_down": MOUSE_BUTTON_WHEEL_DOWN,  # 5
		"wheel_left": MOUSE_BUTTON_WHEEL_LEFT,  # 6
		"wheel_right":MOUSE_BUTTON_WHEEL_RIGHT, # 7
		"xbutton1": MOUSE_BUTTON_XBUTTON1,      # 8
		"xbutton2": MOUSE_BUTTON_XBUTTON2,      # 9
	}
	if _mouse_names.has(s):
		return _mouse_names[s]
	push_warning("ScenarioRunner: mouse_click button '%s' tidak dikenal, pakai MOUSE_BUTTON_LEFT (1)" % s)
	return MOUSE_BUTTON_LEFT


## Sintesis satu klik penuh (tekan + lepas) di posisi global. Dipakai step mouse_click
## DAN step explore -- keduanya harus memakai jalur yang sama supaya jejak hasil eksplorasi
## benar-benar bisa diputar ulang sebagai mouse_click biasa.
func _click_at(pos: Vector2, button: int) -> void:
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


func _exec_mouse_click(step: Dictionary) -> void:
	var x: float = float(step.get("x", 0))
	var y: float = float(step.get("y", 0))
	var button: int = _resolve_mouse_button(step.get("button", MOUSE_BUTTON_LEFT))
	var wait_after: int = int(step.get("wait_frames", 0))
	await _click_at(Vector2(x, y), button)
	if wait_after > 0:
		await _wait_frames(wait_after)
	_step_pass({"x": x, "y": y})


## Klik tombol berdasarkan LABEL, bukan koordinat.
##
## Replay berbasis koordinat rapuh dalam dua arah. Ia pecah begitu tata letak bergeser --
## satu tombol tambahan di menu dan seluruh jejak mengenai sasaran yang salah. Dan ia membuat
## minimisasi jejak mentok di 1-minimal: membuang satu klik di tengah menggeser layar yang
## dikenai klik berikutnya, sehingga klik yang sebenarnya TIDAK relevan pun tidak bisa dibuang
## tanpa merusak sisanya.
##
## Dengan label, tiap langkah menyebut APA yang ditekan. Membuang klik yang tidak relevan
## tidak lagi mengubah arti klik sesudahnya, karena sasarannya dicari ulang tiap kali.
##
## Langkah ini GAGAL kalau tombolnya tidak ada — dan itu justru yang diinginkan: subset jejak
## yang tidak bisa mencapai tombolnya memang bukan reproducer yang sah, dan minimizer harus
## tahu itu alih-alih mengklik apa pun yang kebetulan ada di koordinat lama.
func _exec_click_button(step: Dictionary) -> void:
	var label: String = str(step.get("label", ""))
	if label == "":
		_step_fail("click_button: field 'label' wajib diisi")
		return
	var wait_after: int = int(step.get("wait_frames", 10))
	var target := _find_button_by_label(label)
	if target == null:
		var avail := ", ".join(PackedStringArray(_visible_button_labels()))
		_step_fail("click_button: tidak ada tombol berlabel '%s' yang bisa ditekan. Tombol tersedia: [%s]" % [label, avail])
		return
	var center := target.get_global_rect().get_center()
	await _click_at(center, MOUSE_BUTTON_LEFT)
	if wait_after > 0:
		await _wait_frames(wait_after)
	_step_pass({"label": label, "x": center.x, "y": center.y})


func _visible_button_labels() -> Array:
	var out: Array = []
	for b: Variant in _find_clickable_buttons([]):
		out.append(_button_label(b))
	return out


## Kunci pencocokan longgar: angka dibuang, spasi dirapikan, huruf disamakan.
## Label game sering memuat angka yang berubah tanpa mengubah arti tombolnya
## ("Continue the Night — step 2/9"). Pencocokan persis saja akan membuat replay pecah
## pada perubahan yang tidak berarti apa-apa.
func _label_key(s: String) -> String:
	var t := ""
	for i in s.length():
		var ch := s[i]
		if ch >= "0" and ch <= "9":
			continue
		t += ch
	return t.strip_edges().to_lower()


## Pencocokan bertingkat: persis, lalu abaikan besar-kecil huruf, lalu abaikan angka.
func _find_button_by_label(label: String) -> Control:
	var buttons := _find_clickable_buttons([])
	for b: Variant in buttons:
		if _button_label(b) == label:
			return b
	for b: Variant in buttons:
		if _button_label(b).to_lower() == label.to_lower():
			return b
	var key := _label_key(label)
	if key != "":
		for b: Variant in buttons:
			if _label_key(_button_label(b)) == key:
				return b
	return null


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


func _resolve_joy_button(value: Variant) -> int:
	# Terima integer langsung atau nama string JoyButton.
	# GDScript int("button_a") = 0 — semua string non-numerik collapse ke 0 tanpa error,
	# sehingga nama string harus di-resolve sebelum cast ke int.
	if value is int:
		return value
	var s: String = str(value).to_lower().strip_edges()
	# Coba parse sebagai integer literal ("0", "1", ...) dulu
	if s.is_valid_int():
		return s.to_int()
	# Lookup nama ke JoyButton enum (Godot 4 global constants)
	var _joy_names: Dictionary = {
		"button_a": JOY_BUTTON_A,           # 0
		"button_b": JOY_BUTTON_B,           # 1
		"button_x": JOY_BUTTON_X,           # 2
		"button_y": JOY_BUTTON_Y,           # 3
		"back":     JOY_BUTTON_BACK,        # 4
		"guide":    JOY_BUTTON_GUIDE,       # 5
		"start":    JOY_BUTTON_START,       # 6
		"left_stick":  JOY_BUTTON_LEFT_STICK,   # 7
		"right_stick": JOY_BUTTON_RIGHT_STICK,  # 8
		"left_shoulder":  JOY_BUTTON_LEFT_SHOULDER,  # 9
		"right_shoulder": JOY_BUTTON_RIGHT_SHOULDER, # 10
		"dpad_up":    JOY_BUTTON_DPAD_UP,    # 11
		"dpad_down":  JOY_BUTTON_DPAD_DOWN,  # 12
		"dpad_left":  JOY_BUTTON_DPAD_LEFT,  # 13
		"dpad_right": JOY_BUTTON_DPAD_RIGHT, # 14
		"misc1":  JOY_BUTTON_MISC1,          # 15
		"paddle1": JOY_BUTTON_PADDLE1,       # 16
		"paddle2": JOY_BUTTON_PADDLE2,       # 17
		"paddle3": JOY_BUTTON_PADDLE3,       # 18
		"paddle4": JOY_BUTTON_PADDLE4,       # 19
		"touchpad": JOY_BUTTON_TOUCHPAD,     # 20
	}
	if _joy_names.has(s):
		return _joy_names[s]
	push_warning("ScenarioRunner: controller_press button '%s' tidak dikenal, pakai JOY_BUTTON_A (0)" % s)
	return JOY_BUTTON_A


func _exec_controller_press(step: Dictionary) -> void:
	var button: int = _resolve_joy_button(step.get("button", JOY_BUTTON_A))
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
	# save_png mengembalikan Error, dan nilai itu dulu dibuang. Langkahnya melapor PASS
	# entah berkasnya tertulis atau tidak, lalu tetap mendaftarkan namanya ke
	# _screenshots_taken -- sehingga laporan mengklaim screenshot yang tidak pernah ada.
	# Direktori read-only atau disk penuh menghasilkan scenario "lulus" tanpa satu pun bukti.
	var err := img.save_png(ProjectSettings.globalize_path(path))
	if err != OK:
		_step_fail("screenshot '%s' gagal disimpan ke %s (Error %d)" % [name, path, err])
		return
	# Kode sukses saja belum cukup: yang dipakai pembaca laporan adalah BERKASNYA.
	if not FileAccess.file_exists(path):
		_step_fail("screenshot '%s' melapor sukses tetapi berkasnya tidak ada di %s" % [name, path])
		return
	_screenshots_taken.append(name)
	_step_pass({"name": name, "path": path})


# Pilih node yang akan menulis game_state, dengan aturan: implementasi milik GAME
# menang atas autoload GameStateWriter yang generik.
#
# Ini memperbaiki bug yang membuat state game-specific tidak pernah tertulis saat scenario:
# ScenarioRunner mendokumentasikan hook bernama _write_game_state(), dan GameStateWriter.gd
# JUGA mengimplementasikan nama itu. Autoload adalah anak root yang ditambahkan sebelum
# main scene, jadi ia selalu ditemukan lebih dulu -- implementasi kaya milik game selalu
# terbayangi. Terukur di jimat: main.gd menulis coins/run_active/dukun, tapi yang sampai
# ke game_state.json hanya field generik, sehingga SEMUA assertion game-specific gagal.
#
# GameStateWriter tetap dipakai sebagai fallback: ia stabil terhadap hot-reload dan
# mendelegasikan ke _get_game_state() kalau game memakai kontrak yang itu.
func _resolve_state_writer() -> Node:
	var writers := _find_nodes_with_method(get_tree().root, "_write_game_state")
	for w in writers:
		if w.name != "GameStateWriter":
			return w
	if writers.size() > 0:
		return writers[0]
	return null


func _exec_write_state(step: Dictionary) -> void:
	var writer := _resolve_state_writer()
	if writer == null:
		_step_skip("Tidak ada node dengan _write_game_state() -- pasang GameStateWriter autoload atau implementasikan hook itu di game")
		return
	writer.call("_write_game_state")
	await _wait_frames(1)
	# Memanggil penulisnya bukan bukti berkasnya tertulis. Kalau _get_game_state() milik game
	# melempar di tengah jalan, panggilan ini tetap "berhasil" dan berkas lama dari run
	# sebelumnya tetap di tempatnya -- lalu seluruh assert_state sesudahnya meng-assert
	# terhadap data run lain. Langkah ini yang paling murah untuk menangkapnya.
	var path := "user://shots/game_state.json"
	if not FileAccess.file_exists(path):
		_step_fail("write_state: %s memang dipanggil tetapi game_state.json tidak ada" % writer.name)
		return
	var mtime := float(FileAccess.get_modified_time(path))
	if mtime > 0.0 and mtime + 2.0 < _scenario_start_time:
		_step_fail(("write_state: %s dipanggil tetapi game_state.json tidak berubah -- " +
			"isinya masih dari run sebelumnya (berkas: %d, mulai: %d). " +
			"Periksa apakah _get_game_state() melempar sebelum sempat menulis.")
			% [writer.name, int(mtime), int(_scenario_start_time)])
		return
	_step_pass({"writer": writer.name})


func _exec_assert_state(step: Dictionary) -> void:
	var key: String = step.get("field", step.get("key", ""))
	var expected: Variant = step.get("expected", null)
	var op: String = step.get("op", "eq")
	var stateWriter := _resolve_state_writer()
	if stateWriter != null:
		stateWriter.call("_write_game_state")
		await _wait_frames(1)
	var state := _read_game_state()
	if state.is_empty():
		# Dua sebab, gejalanya sama-sama "tidak ada state", perbaikannya berlawanan.
		# Yang basi HARUS gagal: berkasnya ada, terlihat seperti bukti, dan bukan bukti.
		# Yang belum pernah ada tetap skip -- itu fase prototype yang memang didukung.
		if _state_stale_path != "":
			_step_fail(("game_state.json ADA tetapi tidak ditulis run ini -- isinya dari run " +
				"sebelumnya, jadi bukan bukti apa pun tentang run ini. " +
				"Penyebab tersering: GameStateWriter tidak terdaftar sebagai autoload, atau " +
				"_get_game_state() milik game melempar sebelum sempat menulis."))
			return
		_step_skip("game_state.json belum ada")
		return
	var actual: Variant = _resolve_dot_key(state, key)
	# Field tidak ada di game_state = kegagalan yang HARUS terlihat, bukan lolos diam-diam.
	# Penyebab tersering: salah ketik nama field, atau assertion dijalankan di saat game
	# belum menulis field itu (mis. memeriksa state run padahal run belum dimulai).
	# Pesan menyebut key yang tersedia supaya penulis scenario bisa langsung membetulkan.
	if actual == null and not (op in ["is_null", "not_null"]):
		var available := ", ".join(PackedStringArray(state.keys()))
		var msg := "assert_state: field '%s' tidak ada di game_state (op=%s). Field tersedia: %s" % [key, op, available]
		# Membedakan dua sebab yang pesannya selama ini sama persis: nama field salah ketik,
		# versus penyedia state milik GAME tidak tercapai sehingga yang tertulis hanya
		# fallback generik GameStateWriter. Keduanya menghasilkan "field tidak ada", tetapi
		# perbaikannya berlawanan -- yang satu betulkan nama, yang satu perbaiki jangkauan hook.
		# Terukur pada bread-adventure: _get_game_state() ada tetapi melekat pada satu layar,
		# jadi begitu scenario berpindah layar seluruh field game lenyap dan yang tersisa
		# persis keenam field fallback.
		if _is_fallback_only_state(state):
			msg += ("\n  -> game_state HANYA berisi field fallback GameStateWriter; tidak satu pun " +
				"field game tertulis. Penyedia state milik game tidak tercapai saat langkah ini. " +
				"Periksa apakah node yang mengimplementasikan _get_game_state() ada di tree pada " +
				"titik ini -- hook yang melekat pada satu layar akan hilang begitu scenario berpindah.")
		_step_fail(msg)
		return
	if _evaluate_op(actual, op, expected):
		_step_pass({"key": key, "actual": str(actual), "expected": str(expected)})
	else:
		_step_fail("assert_state gagal: %s = %s, expected %s %s" % [key, str(actual), op, str(expected)])


## Enam field yang ditulis GameStateWriter tanpa bantuan game sama sekali. Kalau state HANYA
## berisi ini, penyedia milik game tidak menyumbang apa pun -- dan itu sebab yang sangat
## berbeda dari sekadar salah ketik nama field, meski gejalanya identik.
const FALLBACK_STATE_FIELDS := ["schema_version", "build", "timestamp",
	"current_scene", "frame_count", "error_log"]

func _is_fallback_only_state(state: Dictionary) -> bool:
	if state.is_empty():
		return false
	for k: Variant in state.keys():
		if not (str(k) in FALLBACK_STATE_FIELDS):
			return false
	return true


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


## Yang diverifikasi bukan "ada berkas bernama itu", melainkan "run INI menghasilkannya".
## Keduanya terlihat sama di disk, dan hanya yang kedua yang jadi bukti. Sebelumnya cukup
## keberadaan berkas, sehingga PNG sisa run sebelumnya membuat langkah ini lulus -- persis
## kelas kesalahan yang sudah diperbaiki di shot-harness ("hitung yang dihasilkan run ini,
## bukan yang tergeletak di folder") tapi belum diterapkan di sini. Template
## input_methods.json bahkan sudah menjanjikan perilaku yang benar: "memverifikasi step
## screenshot sebelumnya BERHASIL DISIMPAN ke disk".
func _exec_assert_screenshot_exists(step: Dictionary) -> void:
	var name: String = step.get("name", "")
	if name.is_empty():
		_step_fail("assert_screenshot_exists tidak punya field 'name'")
		return
	var found := ""
	for p: String in ["user://shots/scenario_" + name + ".png", "user://shots/" + name + ".png"]:
		if FileAccess.file_exists(p):
			found = p
			break
	if found == "":
		_step_fail("Screenshot tidak ditemukan: " + name)
		return
	# Opt-out untuk kasus sah "berkas ini memang dibuat di luar scenario" (mis. tur
	# screenshot game). Harus diminta eksplisit -- diam-diam menerima yang basi adalah
	# bentuk lain dari melaporkan sukses atas ketiadaan bukti.
	if bool(step.get("allow_stale", false)):
		_step_pass({"found": found, "stale_diizinkan": true})
		return
	var mtime := float(FileAccess.get_modified_time(found))
	if mtime > 0.0 and mtime + 2.0 < _scenario_start_time:
		# Dua sebab yang gejalanya sama sekali berbeda tapi mudah tertukar: "screenshot
		# tidak pernah dibuat" vs "ada, tapi milik run lain". Pesan menyebut yang mana.
		_step_fail(("Screenshot '%s' ADA tetapi berasal dari sebelum scenario ini mulai " +
			"(berkas: %d, mulai: %d) -- run ini tidak menghasilkannya. " +
			"Kalau memang dibuat di luar scenario, pakai \"allow_stale\": true.")
			% [name, int(mtime), int(_scenario_start_time)])
		return
	_step_pass({"found": found, "modified": int(mtime)})


func _exec_set_state(step: Dictionary) -> void:
	var key: String = step.get("key", "")
	var value: Variant = step.get("value", null)
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
	var s: Variant = step.get("seed", null)
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
		for sub: Dictionary in sub_steps:
			var sub_type: String = sub.get("type", "")
			if sub_type == "repeat":
				print("[scenario] nested repeat tidak didukung -- skip")
				continue
			await _dispatch(sub_type, sub)
			if _step_results.size() > 0:
				var last_result: Dictionary = _step_results[-1]
				if last_result.get("status") == "fail":
					failed += 1
	_step_pass({"repeated": count, "failed_in_repeat": failed})


# --- Process polling ---

func _process_current_step() -> void:
	# Dulu berisi polling untuk wait_signal, tapi tidak pernah bisa bekerja: _exec_wait_signal
	# memanggil _step_pass() sebelum polling ini sempat berjalan, jadi _current_step sudah
	# maju dan cabang ini selalu melihat step BERIKUTNYA, bukan wait_signal-nya.
	# Penantian kini dilakukan langsung di _exec_wait_signal dengan await + timeout.
	# Fungsi ini dipertahankan sebagai titik sisip kalau nanti ada step yang benar-benar
	# butuh polling per-frame di luar coroutine step-nya sendiri.
	pass


# --- Signal relay ---

func emit_scenario_signal(sig_name: String) -> void:
	if sig_name == _waiting_signal:
		_signal_received = true
	scenario_signal.emit(sig_name)


# --- Result helpers ---

func _step_pass(data: Variant) -> void:
	var cur_step: Dictionary = _steps[_current_step]
	var result := {"step": _current_step, "type": cur_step.get("type", ""), "status": "pass"}
	if data != null:
		result["data"] = data
	_step_results.append(result)
	print("[scenario] PASS: ", result.get("type", ""))


func _step_fail(reason: String) -> void:
	var cur_step: Dictionary = _steps[_current_step]
	var result := {"step": _current_step, "type": cur_step.get("type", ""), "status": "fail", "reason": reason}
	_step_results.append(result)
	print("[scenario] FAIL: ", reason)


func _step_skip(reason: String) -> void:
	var cur_step: Dictionary = _steps[_current_step]
	var result := {"step": _current_step, "type": cur_step.get("type", ""), "status": "skip", "reason": reason}
	_step_results.append(result)
	print("[scenario] SKIP: ", reason)


# --- Finish ---

func _write_result(status: String, error_msg: Variant) -> void:
	var pass_count := 0
	var fail_count := 0
	var skip_count := 0
	for r: Dictionary in _step_results:
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
		# Runner ini fail-fast: begitu satu step gagal, sisanya tidak dijalankan sama sekali.
		# Tanpa field ini pass+fail+skip TIDAK menjumlah ke steps_total (mis. 8+1+0 vs 12 pada
		# scenario new_run jimat) sementara steps_skip=0 justru menyiratkan tidak ada yang
		# terlewat. Agent yang menghitung cakupan dari angka-angka itu menyimpulkan hal keliru.
		"steps_not_run": maxi(0, _steps.size() - _step_results.size()),
		"invariants_total": _invariants.size(),
		"invariant_checks": _invariant_checks,
		"invariant_violations": _invariant_violations.values(),
		"liveness": {
			"required": _liveness_required,
			"input_steps": _liveness_input_steps,
			"state_changed": _liveness_state_changed,
			"screenshots_vary": _liveness_shots_vary,
		},
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


## Dibaca oleh assert_state, wait_condition, invariant, dan gerbang liveness -- karena itu
## penjagaannya ditaruh di SINI, bukan di masing-masing pemanggil.
##
## game_state.json bertahan antar-run. Kalau penulis state run ini tidak berjalan (autoload
## tidak terdaftar, atau _get_game_state() milik game melempar di tengah jalan), berkas dari
## run SEBELUMNYA masih tergeletak di sana dan terbaca seolah keadaan sekarang. Terukur:
## project tanpa penyedia state sama sekali, game_state.json berumur 2 jam berisi
## {"score": 999} -> `assert_state score == 999` PASS, scenario PASS. Mekanisme kebenaran
## utama framework meng-assert terhadap data run lain lalu melapor sukses.
##
## Pelajaran yang sama sudah dipetik dua kali (harness menghitung screenshot yang dihasilkan
## run ini; assert_screenshot_exists menolak PNG basi) tapi belum pernah diterapkan ke state.
var _state_stale_path: String = ""

func _read_game_state() -> Dictionary:
	var path := "user://shots/game_state.json"
	_state_stale_path = ""
	if not FileAccess.file_exists(path):
		return {}
	# Toleransi 2 detik: get_modified_time bergranularitas detik, dan langkah pertama bisa
	# berjalan pada detik yang sama dengan waktu mulai scenario.
	var mtime := float(FileAccess.get_modified_time(path))
	if mtime > 0.0 and mtime + 2.0 < _scenario_start_time:
		_state_stale_path = path
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return {}
	f.close()
	var data: Variant = json.get_data()
	if data is Dictionary:
		return data
	return {}


func _resolve_dot_key(data: Dictionary, key: String) -> Variant:
	var parts := key.split(".")
	var current: Variant = data
	for part: String in parts:
		if current is Dictionary and (current as Dictionary).has(part):
			current = (current as Dictionary)[part]
		else:
			return null
	return current


func _evaluate_op(actual: Variant, op: String, expected: Variant) -> bool:
	# Perbandingan numerik terhadap nilai yang TIDAK ADA harus selalu gagal, tidak pernah lolos.
	#
	# GDScript mengubah float(str(null)) menjadi 0.0. Tanpa penjagaan ini, field yang tidak
	# ada di game_state diam-diam dibaca sebagai 0, sehingga bentuk assertion yang paling
	# umum untuk menyatakan invarian justru SELALU lolos:
	#     "coins gte 0"        -> 0.0 >= 0.0  -> true
	#     "dukun.hp_pct lte 1" -> 0.0 <= 1.0  -> true
	# Terukur di jimat: tujuh invarian dilaporkan utuh padahal tidak satu pun diperiksa.
	# Nilai yang tidak diketahui tidak bisa memenuhi batasan apa pun -- itu bukan "0".
	if actual == null and op in ["gt", "gte", "lt", "lte"]:
		return false
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
		_:
			push_warning("[scenario] _evaluate_op: operator tidak dikenal '%s' -- dianggap 'eq'. Operator valid: eq neq gt gte lt lte is_true is_false not_null is_null" % op)
			return actual == expected


func _find_nodes_with_method(node: Node, method_name: String) -> Array[Node]:
	var result: Array[Node] = []
	if node.has_method(method_name):
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_nodes_with_method(child, method_name))
	return result