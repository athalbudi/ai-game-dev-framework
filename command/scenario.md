---
description: Kelola dan jalankan scenario runner untuk automated gameplay testing. Contoh /scenario run smoke atau /scenario generate atau /scenario list
---

Kamu mengelola scenario runner untuk AI-assisted game development framework.

ProjectPath default: direktori kerja saat ini (atau tanya user jika ambigu)
ScenariosDir default: `<ProjectPath>\scenarios\`
ScenarioResultPath: `<ShotsDir>\scenario_result.json`
ShotsDir: baca dari `shots-manifest.json` di ProjectPath, atau tanya user

## Perintah yang didukung

### /scenario list
Tampilkan semua scenario yang tersedia di ScenariosDir.

Langkah:
1. Cek apakah folder `scenarios\` ada di ProjectPath
2. List semua file `*.json` di folder tersebut
3. Untuk setiap file, baca field `scenario_id` dan `description`
4. Tampilkan tabel: nama file | scenario_id | description
5. Jika folder tidak ada: informasikan cara membuat scenario pertama

### /scenario run <nama>
Jalankan scenario tertentu via shot-harness.ps1.

Langkah:
1. Resolve path scenario: `<ProjectPath>\scenarios\<nama>.json`
   (tambahkan `.json` jika tidak ada ekstensi)
2. Pastikan file scenario ada
3. Resolve ShotsDir dari `shots-manifest.json` atau tanya user
4. Salin scenario file ke ShotsDir sebagai `test_scenario.json`:
   ```powershell
   Copy-Item -LiteralPath "<scenario_path>" -Destination "<ShotsDir>\test_scenario.json"
   ```
5. Jalankan harness dengan flag `--Scenario`:
   ```powershell
   $harness = Join-Path $env:USERPROFILE ".config\kilo\tools\shot-harness.ps1"
   & $harness -ProjectPath "<ProjectPath>" -Scenario "<ShotsDir>\test_scenario.json"
   ```
   Catatan: ErrorTracker.gd (sebagai Autoload) yang menjalankan ScenarioRunner —
   **bukan** ScenarioRunner.gd sebagai Autoload langsung. Flag `-Scenario` meneruskan
   path scenario ke game via `-- --scenario <path>` yang dibaca oleh ErrorTracker.
6. Baca `<ShotsDir>\scenario_result.json` setelah harness selesai
7. Laporkan hasil: scenario_id, status, passed/failed/skipped, durasi
8. Untuk setiap step yang fail: tampilkan id, type, dan note
9. Jika ada screenshot yang diambil: tampilkan daftarnya
10. Delegasikan ke agent `visual-qa` jika ada screenshot baru yang perlu dianalisis

### /scenario status
Tampilkan status hasil scenario terakhir yang dijalankan.

Langkah:
1. Cek apakah `scenario_result.json` ada di ShotsDir
2. Jika ada, baca dan tampilkan:
   - scenario_id dan executed_at
   - status keseluruhan (pass/fail/timeout/error)
   - Ringkasan: X pass / Y fail / Z skip dari N total steps
   - Durasi total
   - Daftar step yang fail dengan note-nya
   - Screenshots yang diambil
3. Jika tidak ada: informasikan bahwa belum ada scenario yang dijalankan

### /scenario new <nama>
Buat file scenario baru dari template.

Langkah:
1. Buat folder `scenarios\` di ProjectPath jika belum ada
2. Tulis file `<ProjectPath>\scenarios\<nama>.json` dengan template:
```json
{
  "schema_version": "1.0",
  "scenario_id": "<nama>",
  "description": "Deskripsi scenario ini",
  "timeout_sec": 60,
  "seed": null,
  "steps": [
    {
      "id": "step_01",
      "type": "wait_scene",
      "scene": "MainMenu",
      "timeout_sec": 10,
      "description": "Tunggu MainMenu aktif"
    },
    {
      "id": "step_02",
      "type": "screenshot",
      "name": "main_menu",
      "description": "Screenshot kondisi awal"
    },
    {
      "id": "step_03",
      "type": "write_state",
      "description": "Tulis game state ke disk"
    },
    {
      "id": "step_04",
      "type": "assert_state",
      "key": "current_screen",
      "op": "not_null",
      "expected": null,
      "description": "Pastikan current_screen tercatat"
    }
  ]
}
```
3. Laporkan path file yang dibuat
4. Berikan petunjuk: edit field `description`, `scene`, dan tambahkan steps sesuai kebutuhan

### /scenario create-suite
Buat set scenario dasar yang direkomendasikan untuk semua game baru.

Langkah:
1. Buat folder `scenarios\` jika belum ada
2. Buat file-file berikut jika belum ada:
   - `scenario_smoke.json` — launch + main menu screenshot
   - `scenario_save_load.json` — save → quit → load → verify state sama
   - `scenario_settings.json` — ubah setting + verifikasi persist
3. Laporkan file yang dibuat
4. Ingatkan: game harus punya ErrorTracker.gd dan GameStateWriter.gd sebagai Autoload;
   ScenarioRunner.gd di-copy ke scripts/ tapi **tidak** didaftarkan sebagai Autoload

### /scenario install-templates
Salin scenario templates universal ke folder `scenarios\` project aktif.

Templates disimpan di folder global kilo config: `<KILO_CONFIG>\scenarios-templates\`
Di mana `<KILO_CONFIG>` adalah `$env:USERPROFILE\.config\kilo` (Windows) atau `~/.config/kilo` (Linux/Mac).

Langkah:
1. Resolve ProjectPath dari working directory atau tanya user
2. Resolve KiloConfigDir: `Join-Path $env:USERPROFILE ".config\kilo"`
3. Resolve TemplatesDir: `Join-Path $KiloConfigDir "scenarios-templates"`
4. Buat folder `<ProjectPath>\scenarios\` jika belum ada
5. List semua file `*.json` di TemplatesDir
6. Untuk setiap file template:
   - Cek apakah file sudah ada di ScenariosDir
   - Jika sudah ada: SKIP (jangan timpa scenario yang sudah dikustomisasi)
   - Jika belum ada: salin ke ScenariosDir
7. Laporkan: berapa file disalin, berapa diskip
8. Tampilkan daftar file yang berhasil disalin beserta `scenario_id` dan `description`-nya
9. Berikan panduan singkat: action names yang perlu disesuaikan di setiap template
   (cari comment `SESUAIKAN:` di dalam file untuk tahu apa yang perlu diubah)

Templates yang tersedia:
- `smoke.json` — launch + main menu, scenario minimum untuk semua game
- `screenshot_tour.json` — navigasi semua layar utama, hasilkan baseline visual
- `crash_stress.json` — input cepat berulang untuk deteksi crash/hang
- `save_load.json` — integritas save/load (butuh sistem save yang sudah ada)

### /scenario generate
Buat scenario baru berdasarkan observasi visual dan game state terkini.

Ini adalah subcommand utama untuk AI-assisted scenario generation: AI menganalisis
screenshots dan manifest untuk mengidentifikasi area yang perlu diuji, lalu menulis
file scenario JSON yang bisa langsung dijalankan.

Langkah:
1. Resolve ProjectPath dan ShotsDir dari manifest
2. Baca `shots-manifest.json` untuk konteks:
   - `telemetry_phase` — menentukan seberapa dalam scenario bisa dibuat
   - `game_state` — data state untuk membuat assertion yang relevan
   - `screenshots` — daftar layar yang sudah diobservasi
   - `scenario_result` — hasil run terakhir (jika ada step yang fail, fokus di sana)
3. Jika ada `diff\diff-report.json`, baca untuk menemukan regresi yang perlu diuji ulang
4. Baca screenshot yang relevan menggunakan `filesystem_read_media_file` (maks 6 per batch)
   — fokus pada layar yang menampilkan fitur aktif atau anomali visual
5. Berdasarkan observasi, identifikasi hipotesis testing:
   - Apa yang terlihat bekerja tapi belum punya scenario?
   - Apa yang terlihat mencurigakan atau berpotensi bug?
   - State transition apa yang bisa diverifikasi dengan assert_state?
   - Layar apa yang belum punya screenshot coverage?
6. Tentukan nama scenario yang akan dibuat (contoh: `combat_flow`, `menu_nav`, `progression`)
7. Tulis file scenario ke `<ProjectPath>\scenarios\<nama>.json`
8. Scenario yang dibuat harus:
   - Memiliki `scenario_id` yang deskriptif
   - Memiliki `description` yang menjelaskan apa yang diuji dan mengapa
   - Menggunakan step types yang didukung ScenarioRunner.gd
   - Menyertakan assert_state jika game_state tersedia (fase mature)
   - Menyertakan screenshot di titik-titik kritis untuk observasi visual
   - Menggunakan `seed_override` jika ada elemen random yang perlu deterministik
   - Menyertakan `log` steps untuk traceability saat debugging
9. Setelah file ditulis, tampilkan isi scenario yang dibuat
10. Berikan penjelasan: mengapa scenario ini dibuat, apa yang diuji, dan cara menjalankannya
11. Hint: jalankan dengan `/scenario run <nama>` untuk validasi langsung

Jika `shots-manifest.json` tidak ada:
- Buat scenario dari template `smoke.json` sebagai titik awal
- Informasikan bahwa scenario yang lebih spesifik bisa dibuat setelah harness dijalankan

Jika game dalam fase `prototype` (belum ada screenshot):
- Buat hanya `smoke.json` dan `screenshot_tour.json`
- Jelaskan bahwa scenario yang lebih kompleks butuh observasi visual terlebih dahulu

---

### /scenario run-and-analyze [nama]
Feedback loop autonomous: generate scenario dari observasi → run → analyze hasil → report.
Ini adalah subcommand utama untuk AI QA yang benar-benar menutup loop tanpa intervensi manual.

Urutan eksekusi:

1. **Observe** — baca `shots-manifest.json` dan screenshot terbaru
   - Baca manifest untuk konteks: phase, game_state, screenshots, assertion_results
   - Baca screenshot yang relevan menggunakan `filesystem_read_media_file` (maks 6 per batch)
   - Identifikasi anomali visual atau area yang perlu diuji lebih dalam

2. **Generate** — buat scenario berdasarkan observasi (sama seperti `/scenario generate`)
   - Jika argumen nama diberikan: buat scenario dengan nama tersebut
   - Jika tidak ada argumen: buat scenario dengan nama `autoqa_<timestamp>`
   - Tulis ke `<ProjectPath>\scenarios\<nama>.json`

3. **Run** — jalankan scenario yang baru dibuat (sama seperti `/scenario run <nama>`)
   - Salin ke ShotsDir sebagai `test_scenario.json`
   - Jalankan harness dengan flag `--scenario`
   - Tunggu hingga selesai

4. **Analyze** — baca hasil dan laporkan
   - Baca `scenario_result.json` dari ShotsDir
   - Baca screenshot baru yang dihasilkan scenario
   - Bandingkan dengan baseline jika ada (`diff\diff-report.json`)
   - Laporkan: step apa yang pass/fail, anomali visual baru, temuan kritis

5. **Report** — buat laporan terstruktur
   - Ringkasan: berapa step pass/fail/skip
   - Temuan kritis (step fail atau regresi visual baru)
   - Rekomendasi: apa yang harus diperbaiki
   - Instruksi reproduksi: scenario file yang dibuat bisa dijalankan ulang dengan `/scenario run <nama>`

Jika `shots-manifest.json` tidak ada:
- Minta user jalankan harness dulu sebelum run-and-analyze bisa berfungsi

Jika scenario yang dibuat gagal dijalankan (harness error):
- Laporkan error dengan jelas
- Pertahankan scenario file yang dibuat agar bisa diinspeksi dan diperbaiki manual

---

## Step Types yang Didukung ScenarioRunner.gd

| Type | Deskripsi |
|---|---|
| `wait_scene` | Tunggu scene tertentu aktif (field: `scene`, `timeout_sec`) |
| `screenshot` | Ambil screenshot (field: `name`) |
| `action` | Simulasi input action (field: `action`, `duration_frames`, `wait_frames`) |
| `mouse_click` | Klik pada koordinat layar (field: `x`, `y`, `button`, `wait_frames`) |
| `mouse_move` | Gerakkan kursor ke koordinat (field: `x`, `y`, `wait_frames`) |
| `touch` | Sentuh layar di koordinat — mobile input (field: `x`, `y`, `index`, `wait_frames`) |
| `swipe` | Swipe gesture dari titik A ke B (field: `from_x`, `from_y`, `to_x`, `to_y`, `steps`) |
| `controller` | Input gamepad/controller — button press atau axis (field: `button`/`axis`, `value`, `device`) |
| `long_press` | Tahan sentuhan N frame (field: `x`, `y`, `frames`, `index`) |
| `double_tap` | Dua tap berurutan di koordinat yang sama (field: `x`, `y`, `gap_frames`) |
| `pinch` | Pinch gesture dua jari zoom in/out (field: `center_x`, `center_y`, `scale`, `steps`) |
| `wait_frames` | Tunggu N frame (field: `frames`) |
| `wait_signal` | Tunggu signal dari game (field: `signal_name`, `timeout_sec`) |
| `wait_condition` | Polling kondisi game_state sampai terpenuhi (field: `key`, `op`, `expected`, `timeout_sec`) |
| `assert_state` | Validasi game_state.json (field: `key`, `op`, `expected`) |
| `assert_fps` | Verifikasi FPS tidak di bawah threshold (field: `min_fps`, `sample_frames`) |
| `assert_no_error` | Verifikasi tidak ada error dalam N frame (field: `window_frames`) |
| `load_scene` | Load scene langsung (field: `scene_path`, `wait_frames`) |
| `set_state` | Set nilai game state (field: `key`, `value`) |
| `write_state` | Minta game tulis game_state.json ke disk |
| `repeat` | Ulangi steps N kali (field: `count`, `steps`) |
| `seed_override` | Override random seed untuk determinisme (field: `seed`) |
| `log` | Tulis pesan ke log scenario (field: `message`) |

## Operator assert_state

`eq` `ne` `gt` `gte` `lt` `lte` `not_null` `is_null` `is_true` `is_false` `contains`

## Setup Scenario Runner di Game Baru

Untuk menggunakan scenario runner, game Godot perlu:
1. Salin tiga file dari `<KILO_CONFIG>\godot-templates\` ke `scripts/`:
   - `ScenarioRunner.gd`
   - `GameStateWriter.gd`
   - `ErrorTracker.gd`
2. Daftarkan **hanya GameStateWriter dan ErrorTracker** sebagai Autoload di `project.godot`:
   ```ini
   [autoload]
   GameStateWriter="*res://scripts/GameStateWriter.gd"
   ErrorTracker="*res://scripts/ErrorTracker.gd"
   ```
   > **ScenarioRunner tidak boleh didaftarkan sebagai Autoload.** ErrorTracker yang
   > menjalankannya via `_scenario_bootstrap()` setelah hot-reload selesai.
   > Mendaftarkan ScenarioRunner sebagai Autoload menyebabkan hot-reload race condition
   > yang membuat `--scenario` flag tidak pernah ter-handle.
3. Tambahkan `report_scene()` di setiap fungsi navigasi layar untuk `wait_scene` step.
4. Implementasikan `_get_game_state()` di node utama untuk step `write_state` dan `assert_state`.
5. Game dijalankan oleh harness dengan flag: `-- --scenario <nama>`

## Templates Universal

Templates siap pakai tersedia di folder global kilo config:
`<KILO_CONFIG>\scenarios-templates\`
(Windows: `$env:USERPROFILE\.config\kilo\scenarios-templates\`)

Gunakan `/scenario install-templates` untuk menyalin ke project aktif.

## Game State Templates

Templates `_write_game_state()` per genre game tersedia di:
`<KILO_CONFIG>\game-state-templates\`
(Windows: `$env:USERPROFILE\.config\kilo\game-state-templates\`)

File tersedia: `universal_minimal.gd`, `rpg_action.gd`, `strategy_resource.gd`,
`platformer_runner.gd`, `puzzle.gd`

## ScenarioRunner

`ScenarioRunner.gd` tersedia di:
`<KILO_CONFIG>\godot-templates\ScenarioRunner.gd`
(Windows: `$env:USERPROFILE\.config\kilo\godot-templates\ScenarioRunner.gd`)

Salin ke `scripts/ScenarioRunner.gd` di project baru.
**Jangan** daftarkan sebagai Autoload — ErrorTracker yang menjalankannya.

## Argumen

$ARGUMENTS
