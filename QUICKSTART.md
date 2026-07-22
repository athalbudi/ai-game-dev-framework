# AI-Assisted Game Development Framework — Quick Start

Framework universal untuk AI-assisted game development dan QA di Godot.
Berlaku untuk semua project game baru — tidak bergantung pada game, genre, atau struktur folder tertentu.

---

## Apa yang Disediakan Framework Ini

Framework ini memberi AI "mata" untuk melihat hasil runtime game, bukan hanya membaca source code.
Loop kerja yang diaktifkan:

```
Tulis kode → Jalankan harness → AI lihat hasil → AI analisis → AI laporkan → Developer tindak lanjut
```

---

## Setup untuk Project Baru (10 Menit)

### Langkah 1 — Jalankan harness pertama kali

Tidak perlu setup apapun di kode game. Harness langsung berjalan.

```powershell
& "$env:USERPROFILE\.config\kilo\tools\shot-harness.ps1" -ProjectPath "<path-ke-project-godot>"
```

Hasilnya: `shots-manifest.json` di ShotsDir. Fase telemetry: `prototype`.
AI sudah bisa menjalankan `/shot` dan `/analisis-shot` setelah ini.

### Langkah 2 — Implementasikan --shot handler di game (Fase Developing)

Tambahkan ke `main.gd` atau scene utama:

```gdscript
func _ready() -> void:
    # --shot dihandle oleh ErrorTracker._shot_quit_watchdog (anti-hotreload pattern)
    # Jangan panggil _shot_tour di sini — ErrorTracker yang memanggilnya
    # setelah menunggu hot-reload selesai.
    pass

func _shot_tour() -> void:
    _take_screenshot("01_main_menu")
    # Navigasi ke layar lain dan ambil screenshot...
    get_tree().quit()

func _take_screenshot(name: String) -> void:
    var img = get_viewport().get_texture().get_image()
    img.save_png("user://shots/%s.png" % name)
```

> **Penting — Godot 4.7 hot-reload pattern:**
> Jangan panggil `_shot_tour()` atau `_shot_tour.call_deferred()` dari `_ready()`.
> `ErrorTracker` sebagai Autoload yang mendeteksi `--shot` dan memanggil `_shot_tour`
> di main node setelah menunggu 4 frame agar hot-reload selesai.
> Ini adalah **satu-satunya cara** agar harness bisa berjalan autonomous dari command line.

> **Penting — Hindari `:=` dengan class_name globals:**
> Godot 4.7 melakukan hot-reload saat pertama kali project di-launch dari command line.
> Selama hot-reload, `class_name` globals tidak tersedia sementara. Script yang menggunakan
> `:=` (walrus operator) dengan class_name globals akan gagal parse.
>
> **Pola yang aman:**
> ```gdscript
> # BENAR — tidak bergantung pada class_name saat parse time
> var runner = load("res://scripts/smoke_runner.gd").new()
>
> # BENAR — method call dalam function body, class_name tidak dipakai di signature
> func goto_battle() -> void:
>     var sim = BattleSim.new()  # aman jika BattleSim sudah extends RefCounted/Node
>
> # BENAR — tidak ada type annotation pada member var yang bergantung class_name
> var gs   # GameState — type akan resolved saat runtime
>
> # HATI-HATI — :=  dengan method return yang membutuhkan class registry
> var runner := SmokeRunner.new()  # bisa gagal jika SmokeRunner belum ter-register
> ```
>
> **Aturan sederhana:** gunakan `=` (bukan `:=`) untuk variabel yang nilainya dari
> constructor atau static method `class_name`, terutama di `_ready()` dan member var
> declarations di top of file.

> **Godot 4.7 — One-Time Setup per Mesin:**
> Untuk project yang sudah ada (codebase yang punya banyak `class_name` references),
> jalankan Godot editor sekali untuk project tersebut agar dependency graph ter-compile:
> 1. Buka Godot editor untuk project
> 2. Jalankan game sekali dari editor (F5)
> 3. Tutup editor
>
> Setelah ini, harness berjalan autonomous selamanya di mesin tersebut.
> Project **baru** yang mengikuti pattern di atas tidak membutuhkan step ini.

### Langkah 3 — Install scenario templates

```
/scenario install-templates
```

Menyalin 4 template universal ke `scenarios/` project: smoke, screenshot_tour, crash_stress, save_load.

### Langkah 4 — Setup Automated Testing

1. Salin tiga file dari `<KILO_CONFIG>/godot-templates/` ke `scripts/` project:
   - `GameStateWriter.gd`
   - `ErrorTracker.gd`
   - `ScenarioRunner.gd`

2. Daftarkan **hanya GameStateWriter dan ErrorTracker** sebagai Autoload di `project.godot`:
   ```ini
   [autoload]
   GameStateWriter="*res://scripts/GameStateWriter.gd"
   ErrorTracker="*res://scripts/ErrorTracker.gd"
   ```
   > **Penting:** `ScenarioRunner.gd` **tidak** didaftarkan sebagai Autoload.
   > ErrorTracker yang menjalankannya secara otomatis saat flag `--scenario` terdeteksi.
   > Mendaftarkan ScenarioRunner sebagai Autoload akan menyebabkan hot-reload race condition
   > yang membuat scenario tidak pernah berjalan.

3. Tambahkan `report_scene()` di setiap fungsi navigasi layar game:
   ```gdscript
   func goto_main_menu() -> void:
       if has_node("/root/GameStateWriter"):
           get_node("/root/GameStateWriter").report_scene("main_menu")
       # ... sisa kode
   ```

4. Implementasikan `_get_game_state()` di node utama game (opsional, untuk telemetry lengkap):
   ```gdscript
   func _get_game_state() -> Dictionary:
       return {
           "schema_version": "1.0",
           "build": MY_VERSION,
           "current_scene": GameStateWriter.get_current_scene(),
           "frame_count": Engine.get_process_frames(),
           "timestamp": Time.get_datetime_string_from_system(),
           # field game-specific di sini
       }
   ```

5. Jalankan smoke test: `/scenario run smoke`

### Langkah 5 — Buat Scenarios Folder

Buat folder `scenarios/` di root project dan tambahkan scenario pertama:

```
/scenario install-templates
```

Atau salin manual dari `<KILO_CONFIG>/scenarios-templates/`.

---

## Fase Telemetry

| Fase | Kondisi | Kemampuan AI |
|---|---|---|
| `prototype` | Harness jalan, belum ada PNG | Screenshot harness tersedia |
| `developing` | Ada PNG, belum ada game_state | Visual QA, baseline, regression |
| `mature` | Ada PNG + game_state.json | Semua + assertion, scenario testing |

---

## Commands yang Tersedia

| Command | Deskripsi |
|---|---|
| `/shot` | Preview screenshot terbaru |
| `/analisis-shot` | Analisis visual menyeluruh |
| `/baseline set` | Set baseline untuk regression |
| `/baseline diff` | Bandingkan vs baseline |
| `/scenario run <nama>` | Jalankan scenario automated test |
| `/scenario generate` | AI buat scenario dari observasi |
| `/scenario run-and-analyze` | Loop: generate → run → analyze |
| `/scenario install-templates` | Salin template universal ke project |
| `/record convert <file>` | Konversi rekaman input ke scenario |
| `/record list` | Daftar rekaman tersedia |

---

## Godot Templates yang Tersedia

Semua tersedia di `<KILO_CONFIG>/godot-templates/`:

| File | Fungsi | Perlu di Autoload? |
|---|---|---|
| `ScenarioRunner.gd` | Automated gameplay testing | **Tidak** — dijalankan oleh ErrorTracker |
| `GameStateWriter.gd` | Scene tracking + telemetry Layer 1 | **Ya** |
| `InputRecorder.gd` | Rekam input untuk bug replay | Ya |
| `RecordingConverter.gd` | Konversi rekaman ke scenario | Tidak (static class) |
| `ErrorTracker.gd` | Error tracking + bootstrap `--scenario` | **Ya** |

---

## Game State Templates

Pilih satu sesuai genre game, salin ke project, sesuaikan referensi:

| File | Genre |
|---|---|
| `universal_minimal.gd` | Semua genre — mulai dari sini |
| `rpg_action.gd` | RPG, action, roguelite |
| `strategy_resource.gd` | Strategy, tower defense, idle |
| `platformer_runner.gd` | Platformer, runner, endless |
| `puzzle.gd` | Puzzle berbasis level |

---

## Scenario Templates Universal

Install via `/scenario install-templates`. Semua bisa dipakai langsung setelah
action names disesuaikan dengan InputMap game:

| Template | Tujuan |
|---|---|
| `smoke.json` | Verifikasi game bisa launch |
| `screenshot_tour.json` | Dokumentasi visual semua layar |
| `crash_stress.json` | Deteksi crash dari input cepat |
| `save_load.json` | Verifikasi integritas save/load |

---

## Workflow Bug Reproduction

Saat menemukan bug saat bermain manual:

1. Pastikan `InputRecorder` aktif sebagai Autoload
2. Sebelum bermain: `InputRecorder.start()` dari debug console atau tombol debug
3. Reproduksi bug
4. Setelah bug: `InputRecorder.stop()` — rekaman tersimpan di `user://shots/`
5. Di Kilo: `/record convert` — konversi ke scenario JSON
6. `/scenario run replay_<session>` — reproduksi deterministik
7. Jika bug terreproduksi: `/scenario generate` untuk buat assertion scenario
8. Commit scenario file ke repo sebagai regression test

---

## Prinsip Progressive Capability

Framework berjalan dari hari pertama tanpa setup apapun (fase prototype),
dan kapabilitasnya bertambah seiring game berkembang:

```
Hari 1: harness jalan → AI lihat game exists
Minggu 1: --shot handler → AI lihat layar game
Bulan 1: ScenarioRunner → AI bisa automated testing
Bulan 2: GameStateWriter → AI bisa assertion + diagnosis
Bulan 3+: ErrorTracker + InputRecorder → AI bisa full QA cycle
```

Tidak ada yang wajib dari hari pertama. Setiap komponen opsional dan additive.
