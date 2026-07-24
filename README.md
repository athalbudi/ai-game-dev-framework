# AI-Assisted Game Development Framework

Framework universal untuk AI-assisted game development dan QA — dari prototype hingga production.

Dirancang untuk membantu developer yang membuat game baru dari nol, tanpa bergantung pada:
- Game atau genre tertentu
- Engine tertentu (Godot, Unity, atau lainnya)
- Struktur folder tertentu
- Lokasi project tertentu

---

## Prinsip Utama

**Progressive capability** — framework tetap usable dari fase prototype hingga production:

| Fase | Yang tersedia |
|---|---|
| Prototype | Screenshot harness, manifest, observasi runtime |
| Developing | Game state telemetry, scenario testing, assertion |
| Production | Automated gameplay testing, visual regression, CI/CD, autonomous QA |

**Feedback-to-code bridge** — menghubungkan feedback playtester ke screenshot, komponen UI, dan lokasi kode secara otomatis.

---

## Komponen Utama

### Tools (PowerShell)

| File | Fungsi |
|---|---|
| `tools/shot-harness.ps1` | Screenshot tour otomatis via `--shot` flag |
| `tools/shot-harness-unity.ps1` | Adapter untuk Unity |
| `tools/visual-diff.ps1` | Visual regression comparison antar build |
| `tools/feedback-bridge.ps1` | Hubungkan feedback playtester ke screenshot + kode |
| `tools/autonomous-qa.ps1` | Loop QA otonom: observe → analyze → report |
| `tools/run-and-analyze.ps1` | Jalankan game dan analisis output |
| `tools/schema-migration.ps1` | Migrasi schema manifest antar versi |

### Godot Templates

| File | Fungsi | Autoload? |
|---|---|---|
| `godot-templates/ScenarioRunner.gd` | Automated gameplay testing (17 step types) | **Tidak** |
| `godot-templates/GameStateWriter.gd` | Scene tracking + write game_state.json | Ya |
| `godot-templates/ErrorTracker.gd` | Error tracking + bootstrap `--scenario` | Ya |
| `godot-templates/InputRecorder.gd` | Rekam input untuk bug replay | Ya |

> **Penting:** `ScenarioRunner.gd` tidak didaftarkan sebagai Autoload. `ErrorTracker` yang menjalankannya secara otomatis saat flag `--scenario` terdeteksi.

### Dokumentasi

- `FRAMEWORK.md` — arsitektur lengkap dan cara kerja
- `QUICKSTART.md` — setup dari nol ke screenshot pertama
- `GAME_STATE_SPEC.md` — kontrak `game_state.json` dari minimal ke full telemetry
- `AGENTS.md` — instruksi global untuk AI yang bekerja dengan framework ini

### Commands (Kilo AI)

Tempatkan di `.kilo/command/` di project game:

| Command | Fungsi |
|---|---|
| `/shot` | Jalankan screenshot harness |
| `/scenario` | Jalankan automated scenario testing |
| `/analisis-feedback` | Analisis feedback playtester dengan bridge |
| `/analisis-shot` | Analisis screenshot untuk visual QA |
| `/baseline` | Set baseline visual regression |
| `/record` | Rekam sesi gameplay untuk bug replay |

---

## Quick Start

### 1. Setup screenshot harness (Godot)

```gdscript
# Di main.gd — tambahkan di _ready()
if "--shot" in OS.get_cmdline_user_args():
    _shot_tour.call_deferred()

func _shot_tour() -> void:
    # Navigasi semua layar game dan ambil screenshot
    goto_title()
    await _snap("01_title")
    # ... dst
    get_tree().quit()

func _snap(name_: String) -> void:
    for i in 4:
        await get_tree().process_frame
    await RenderingServer.frame_post_draw
    var img := get_viewport().get_texture().get_image()
    img.save_png("user://shots/%s.png" % name_)
```

```powershell
# Jalankan harness
& "$env:USERPROFILE\.config\kilo\tools\shot-harness.ps1" -ProjectPath "path/to/project"
```

### 2. Setup automated testing (Godot)

```ini
# project.godot
[autoload]
GameStateWriter="*res://scripts/GameStateWriter.gd"
ErrorTracker="*res://scripts/ErrorTracker.gd"
```

```powershell
# Jalankan scenario
& GodotEngine.exe --path "path/to/project" -- --scenario smoke
```

### 3. Setup feedback bridge

Buat `screen-index.json` di root project (lihat `GAME_STATE_SPEC.md` untuk format), lalu:

```powershell
& "$env:USERPROFILE\.config\kilo\tools\feedback-bridge.ps1" `
    -FeedbackFile "feedback/B04.txt" `
    -ProjectPath "path/to/project" `
    -MinScore 2
```

---

## Validated in Production

Framework ini divalidasi menggunakan sebuah roguelite indie berbasis folklor Indonesia sebagai studi kasus dari prototype hingga batch playtesting ke-4 (40+ pemain).

Hasil validasi:
- `--scenario smoke` → pass=8/8 end-to-end
- `feedback-bridge` → tervalidasi dengan tiga batch playtesting (40 profil)
- Frequency weighting → tervalidasi dengan simulasi batch ke-4 (10 profil, delimiter per profil)
- Visual regression → `intentional_changes` annotation berfungsi

---

## Requirements

- Windows (PowerShell 5.1+)
- Godot 4.x (untuk Godot templates)
- ImageMagick (opsional, untuk pixel-level visual diff)
- Kilo AI (untuk `/command` integration)

---

## Struktur Repo

```
ai-game-dev-framework/
├── AGENTS.md                    # Instruksi AI global
├── FRAMEWORK.md                 # Arsitektur lengkap
├── QUICKSTART.md                # Setup dari nol
├── GAME_STATE_SPEC.md           # Kontrak game_state.json
├── tools/                       # PowerShell tools
├── godot-templates/             # GDScript templates
├── game-state-templates/        # Template telemetry per genre
├── scenarios-templates/         # Universal scenario templates
└── command/                     # Kilo AI slash commands
```

---

## License

MIT
