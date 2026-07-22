# AI-Assisted Game Development Framework

Framework universal untuk AI-assisted game development dan QA.
Dirancang untuk digunakan di semua project game baru, dari prototype hingga produksi.
Tidak terikat pada game tertentu, engine tertentu, atau struktur folder tertentu.

---

## Komponen Framework

### Tools (global, tidak perlu disalin ke project)

| File | Deskripsi |
|---|---|
| `tools/shot-harness.ps1` | Jalankan game dalam mode screenshot, hasilkan manifest telemetry |
| `tools/visual-diff.ps1` | Bandingkan screenshot terbaru vs baseline, deteksi regresi visual |
| `tools/run-and-analyze.ps1` | Loop otomatis QA: Observe, Generate, Run, Analyze, Report |
| `tools/autonomous-qa.ps1` | Loop autonomous QA dengan anomaly detection dan iterasi mandiri |

### Commands (tersedia di semua project via global config)

| Command | Deskripsi |
|---|---|
| `/shot` | Tampilkan screenshot terbaru dari ShotsDir |
| `/analisis-shot` | Analisis visual menyeluruh dari screenshot + telemetry |
| `/baseline` | Kelola baseline untuk visual regression testing |
| `/scenario` | Jalankan, buat, dan kelola scenario automated testing |

### Templates (disalin ke project saat dibutuhkan)

**Scenario templates** — `scenarios-templates/`

| File | Gunakan untuk |
|---|---|
| `smoke.json` | Verifikasi game bisa launch dan mencapai main menu |
| `screenshot_tour.json` | Dokumentasi visual semua layar utama |
| `crash_stress.json` | Deteksi crash dari input sequence tidak terduga |
| `save_load.json` | Verifikasi integritas sistem save/load |

**Game state templates** — `game-state-templates/`

| File | Genre |
|---|---|
| `universal_minimal.gd` | Semua genre — titik awal untuk game baru |
| `rpg_action.gd` | RPG, action RPG, roguelite |
| `strategy_resource.gd` | Strategy, tower defense, idle, resource management |
| `platformer_runner.gd` | Platformer, runner, endless, level-based |
| `puzzle.gd` | Puzzle berbasis level, board state, move counter |

**Godot templates** — `godot-templates/`

| File | Deskripsi |
|---|---|
| `ScenarioRunner.gd` | Scenario engine (16 step types) — di-load oleh ErrorTracker, bukan Autoload |
| `GameStateWriter.gd` | Autoload: scene tracking via `report_scene()` + `_write_game_state()` hook |
| `InputRecorder.gd` | Autoload untuk merekam input gameplay manual ke recording JSON |
| `RecordingConverter.gd` | Konversi file rekaman ke scenario JSON untuk bug reproduction |
| `ErrorTracker.gd` | Autoload: error tracking + bootstrap `--scenario` flag (hot-reload safe) |

---

## Setup di Project Baru

### Langkah 1 — Jalankan harness pertama kali

```powershell
& "$env:USERPROFILE\.config\kilo\tools\shot-harness.ps1" -ProjectPath "<path-project>"
```

Harness akan otomatis mendeteksi fase telemetry:
- `prototype` — game baru, belum ada screenshot
- `developing` — sudah ada screenshot, belum ada game state hook
- `mature` — sudah ada screenshot dan `_write_game_state()` diimplementasi

### Langkah 2 — Install scenario templates

```
/scenario install-templates
```

Menyalin template universal ke `<ProjectPath>/scenarios/`. Skip jika sudah ada.

### Langkah 3 — Setup Godot templates

1. Salin tiga autoload dari `godot-templates/` ke `scripts/` di project:
   - `GameStateWriter.gd` — scene tracking + write_state
   - `ErrorTracker.gd` — error tracking + **scenario bootstrap**
   - `ScenarioRunner.gd` — scenario engine (tidak didaftarkan sebagai autoload)

2. Daftarkan hanya GameStateWriter dan ErrorTracker sebagai Autoload di `project.godot`:
   ```ini
   [autoload]
   GameStateWriter="*res://scripts/GameStateWriter.gd"
   ErrorTracker="*res://scripts/ErrorTracker.gd"
   ```
   > **Penting:** ScenarioRunner **tidak** didaftarkan sebagai Autoload — ia di-load oleh
   > ErrorTracker sebagai script instance saat `--scenario` flag terdeteksi.
   > Ini adalah workaround untuk Godot 4.7 hot-reload race condition yang
   > menghancurkan main scene node sebelum deferred calls ter-dispatch.

3. Tambahkan `report_scene()` call di setiap fungsi navigasi layar di game:
   ```gdscript
   func goto_title() -> void:
       _clear()
       if has_node("/root/GameStateWriter"):
           get_node("/root/GameStateWriter").report_scene("title")
       # ... sisa kode
   ```
   Ini memungkinkan `wait_scene` step di scenario bekerja untuk game dengan
   navigasi programmatic (bukan Godot scene transition).

4. Implementasikan `_get_game_state()` di node game untuk telemetry lengkap (opsional):
   ```gdscript
   # Di node manapun (main.gd, game_manager.gd, dll)
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
   GameStateWriter akan menemukan method ini otomatis via `_find_nodes_with_method()`.

---

## Known Limitations — Godot 4.7 Hot-Reload

Godot 4.7 selalu melakukan **hot-reload script** saat pertama kali project di-launch dari
command line. Selama hot-reload, class registry di-reset sementara — `class_name` globals
seperti `UI`, `DB`, `GameState` tidak tersedia pada momen itu.

**Dampak pada framework:**
- Script yang menggunakan `:=` (walrus operator) dengan class_name globals akan gagal parse
- Typed member variable declarations (`var gs: GameState`) akan gagal jika class belum ter-register
- Typed function parameters (`func f(sim: BattleSim)`) akan gagal

**Pattern yang aman untuk game baru:**

```gdscript
# BENAR — gunakan = bukan := untuk constructor calls di _ready()
var runner = load("res://scripts/smoke_runner.gd").new()

# BENAR — member var untyped untuk class yang bergantung class_name
var gs        # GameState
var ui: Control  # Control adalah built-in, aman

# BENAR — ScenarioRunner diakses via load() bukan class_name
var exit_code = await load("res://scripts/ScenarioRunner.gd").new().run_scenario_file(path)

# BENAR — jangan aktifkan --shot dari _ready(), biarkan ErrorTracker yang handle
func _ready() -> void:
    pass  # ErrorTracker.gd mendeteksi --shot via Autoload bootstrap
```

**Untuk codebase yang sudah ada (banyak class_name references):**
Framework tetap bisa dijalankan, tapi membutuhkan one-time setup per mesin:
1. Buka Godot editor untuk project tersebut
2. Jalankan game sekali dari editor (F5)
3. Tutup editor — dependency graph sekarang ter-compile

Setelah step ini, harness berjalan autonomous selamanya di mesin tersebut.

**Mengapa ini terjadi:** Ini adalah Godot 4.7 engine behavior yang tidak bisa di-bypass
dari luar engine. Framework telah memaksimalkan mitigasi via ErrorTracker bootstrap pattern
(4-frame delay sebelum `_shot_tour` dipanggil), tapi mitigasi ini hanya efektif jika
script bisa di-parse saat hot-reload — yang berarti script tidak boleh bergantung pada
class_name globals di parse time.

---

## Panduan Timing _write_game_state()

Kapan hook ini dipanggil menentukan apakah data yang ditulis representatif atau tidak.

### Pola yang Benar

`gdscript
# Di main.gd atau scene utama
func _ready() -> void:
    var args := OS.get_cmdline_user_args()
    if "--shot" in args:
        # Tunggu satu frame agar semua sistem selesai inisialisasi
        await get_tree().process_frame
        _write_game_state()   # tulis SETELAH inisialisasi
        _shot_tour()          # lalu navigasi layar

# Di _shot_tour(), tulis ulang setiap kali state berubah signifikan
func _shot_tour() -> void:
    # Ambil screenshot main menu
    _take_screenshot("01_main_menu")
    _write_game_state()          # state di main menu

    # Masuk gameplay
    get_tree().change_scene_to_file("res://scenes/game.tscn")
    await get_tree().process_frame
    await get_tree().process_frame   # tunggu scene selesai load
    _write_game_state()              # state di awal gameplay

    get_tree().quit()
`

### Kesalahan Umum

| Kesalahan | Akibat | Solusi |
|---|---|---|
| Dipanggil sebelum wait get_tree().process_frame | Sistem belum inisialisasi — nilai default/null | Tambahkan minimal 1 frame await |
| Dipanggil setelah get_tree().quit() | File tidak ditulis | Panggil sebelum quit |
| Hanya dipanggil sekali di awal | State tidak mencerminkan layar saat ini | Panggil ulang setelah setiap scene change |
| Tidak dipanggil di --shot mode | game_state.json tidak ada | Tambahkan conditional check if "--shot" in args |

### Prinsip

- Tulis state **setelah** scene dan sistem selesai inisialisasi
- Tulis ulang state **sebelum** setiap screenshot penting
- Jangan tulis state setelah sistem mulai cleanup/free
- game_state.json mencerminkan state pada momen terakhir _write_game_state() dipanggil
## Arsitektur Telemetry

Framework menggunakan pendekatan **progressive capability** — berjalan dari fase prototype
tanpa membutuhkan implementasi apapun di game, dan secara otomatis memanfaatkan data
tambahan seiring game berkembang.

```
Layer 0 — state.json (selalu ada)
  Ditulis oleh harness. Berisi: project_name, timestamp, png_count,
  telemetry_phase, daftar screenshots.

Layer 1 — game_state.json (opsional, ditulis game)
  Ditulis oleh game saat --shot mode via _write_game_state().
  Format bebas. Jika ada: telemetry_phase = mature.
  Di-embed ke shots-manifest.json untuk konteks AI.

shots-manifest.json (output harness)
  Gabungan Layer 0 + Layer 1. Dibaca oleh semua AI commands.
```

### Fase telemetry

| Fase | Kondisi | Kemampuan AI |
|---|---|---|
| `prototype` | Belum ada PNG, belum ada game_state | Screenshot tour, harness run |
| `developing` | Ada PNG, belum ada game_state | Visual QA, baseline, regression |
| `mature` | Ada PNG dan game_state | Semua di atas + assertion, scenario testing |

---

## Komponen Engine-Specific vs Universal

Framework ini memisahkan komponen yang bergantung pada engine tertentu dari komponen yang
benar-benar universal. Penting dipahami sebelum menggunakan framework di engine non-Godot.

### Komponen Universal (tidak perlu modifikasi untuk engine apapun)

| Komponen | Lokasi | Keterangan |
|---|---|---|
| isual-diff.ps1 | 	ools/ | Bekerja pada PNG dari engine apapun |
| shots-manifest.json schema | output harness | JSON universal, schema_version tracked |
| ignore_regions + egion_thresholds | shots.zoom.json | Konfigurasi per-project, engine-agnostic |
| Baseline management | aseline/ di ShotsDir | Tidak tahu engine apa yang menghasilkan PNG |
| Command /shot | command/shot.md | Membaca PNG dari folder, tidak peduli engine |
| Command /analisis-shot | command/analisis-shot.md | Membaca manifest + PNG |
| Command /baseline | command/baseline.md | Memanggil isual-diff.ps1 |
| Scenario templates JSON | scenarios-templates/ | Format JSON universal |
| Game-state template schema | konsep Layer 1 | JSON bebas format |
| AGENTS.md global rules | AGENTS.md | Berlaku di semua project |

### Komponen Godot-Specific (butuh adapter untuk engine lain)

| Komponen | Alasan Godot-specific | Adapter yang dibutuhkan |
|---|---|---|
| shot-harness.ps1 | Parse project.godot, invoke godot --path | shot-harness-unity.ps1, shot-harness-unreal.ps1 |
| ScenarioRunner.gd | GDScript 4 API, Godot InputMap, InputEvent* | ScenarioRunner.cs (Unity), custom per engine |
| Game-state templates .gd | GDScript 4 syntax | Template .cs untuk Unity |
| --shot flag convention | Diimplementasikan di kode Godot | Equivalent per engine |

### Cara Menambahkan Engine Baru

Untuk menggunakan framework di engine lain, yang perlu dibuat adalah:

1. **Harness adapter** — script yang:
   - Menjalankan game dalam mode screenshot
   - Menghasilkan PNG ke folder output yang dapat dikonfigurasi
   - Menulis game_state.json ke folder yang sama (opsional — Layer 1)
   - Menulis shots-manifest.json dengan schema yang sama (schema_version: 1.1)

2. **ScenarioRunner equivalent** — komponen yang:
   - Membaca file scenario JSON dengan format yang sama
   - Mengeksekusi step types yang didukung
   - Menulis scenario_result.json ke output folder

Semua komponen analisis (visual-diff, baseline, AI commands) langsung bekerja tanpa modifikasi.

### Adapter yang Tersedia

| Engine | Harness | ScenarioRunner | Status |
|---|---|---|---|
| Godot 4 | shot-harness.ps1 | ScenarioRunner.gd | ✅ Production-ready |
| Unity | shot-harness-unity.ps1 | belum ada | ✅ Harness tersedia di tools/ |
| Unreal Engine | belum ada | belum ada | 📋 Planned |
| Custom engine | buat sendiri sesuai spec | buat sendiri | 📋 Spec tersedia di atas |
## CI/CD Integration (GitHub Actions)

Template workflow tersedia di `<KILO_CONFIG>/ci-templates/.github/workflows/`.
Salin ke `.github/workflows/` project kamu menggunakan `/ci-setup`.

| Template | Trigger | Deskripsi |
|---|---|---|
| `godot-screenshot.yml` | push, PR | Screenshot tour + visual regression vs baseline |
| `godot-scenario-test.yml` | push, PR | Automated scenario testing (smoke, save_load, dll) |
| `godot-autonomous-qa.yml` | schedule, manual | Autonomous QA loop harian |

### Setup CI di project baru

```powershell
# Salin semua workflow templates (dan sesuaikan GAME_NAME + GODOT_VERSION)
/ci-setup
```

Atau manual:
```bash
mkdir -p .github/workflows
cp "<KILO_CONFIG>/ci-templates/.github/workflows/*.yml" .github/workflows/
```

Lihat `ci-templates/README.md` untuk panduan lengkap termasuk baseline management dan artifact retention.
## Kompatibilitas

| Aspek | Status |
|---|---|
| Engine | Godot 4 (harness + ScenarioRunner). Unity: shot-harness-unity.ps1 tersedia. Unreal: planned. |
| OS | Windows (PowerShell). Linux/Mac: port tools ke bash/sh |
| Genre | Semua genre — templates tersedia untuk RPG, strategy, platformer, puzzle |
| Kilo version | `@kilocode/plugin >= 7.4.x` |

---

## Manifest Schema Versioning

`shots-manifest.json` menggunakan field `schema_version` untuk tracking format:

| Versi | Deskripsi |
|---|---|
| `1.1` | Format saat ini. Fields: `schema_version`, `generated_at`, `telemetry_phase`, `shots_dir`, `project_name`, `png_count`, `screenshots`, `game_state`, `baseline_age_days` |

Bump `schema_version` di `shot-harness.ps1` setiap kali format manifest berubah secara breaking.
## intentional_changes — Tandai Perubahan Visual yang Disengaja

Tambahkan ke `shots.zoom.json` di root project:

```json
{
  "intentional_changes": [
    { "src": "01_title.png", "reason": "Redesign title screen v0.21", "version": "0.21" },
    { "src": "battle_*.png", "reason": "Updated battle UI layout" }
  ]
}
```

File yang match akan mendapat status `INTENTIONAL` di diff-report.json alih-alih `REGRESI`.
Tidak masuk ke counter `regressions` — tidak memblokir CI.
Field `src` mendukung wildcard. Field `version` opsional.

---

## ignore_regions — Kurangi False Positive Regression

Tambahkan ke `shots.zoom.json` di root project:

```json
{
  "ignore_regions": [
    { "src": "01_main_menu.png", "x": 650, "y": 10, "w": 70, "h": 20, "reason": "timestamp" },
    { "src": "*", "x": 0, "y": 0, "w": 50, "h": 20, "reason": "fps counter" }
  ]
}
```

Field `src` mendukung wildcard `"*"` untuk semua screenshot.
Butuh ImageMagick untuk fitur ini — fallback ke MD5 hash jika tidak tersedia.

---

## Deteksi Hang vs Slow

`shot-harness.ps1` membedakan tiga kondisi saat game berjalan:

| Kondisi | Indikator | Exit |
|---|---|---|
| Normal | Game selesai dalam timeout | `ok` |
| Slow | Ada PNG dihasilkan tapi tidak selesai | `timeout_slow` |
| Hang | Tidak ada PNG + CPU ~0% | `timeout_hang` |

Tambahkan `-Timeout <detik>` jika game memang lambat secara normal.
