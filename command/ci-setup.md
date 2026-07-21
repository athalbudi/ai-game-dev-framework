---
description: Setup CI/CD GitHub Actions untuk project Godot. Salin workflow templates ke .github/workflows/ dan sesuaikan konfigurasi. Contoh /ci-setup | /ci-setup status | /ci-setup list
---

Kamu membantu developer setup CI/CD GitHub Actions untuk project Godot menggunakan
AI-assisted game development framework.

Framework ini universal -- tidak bergantung pada game tertentu atau struktur folder spesifik.
CI templates tersedia di `<KILO_CONFIG>/ci-templates/.github/workflows/`.

ProjectPath default: direktori kerja saat ini

---

## Subcommands

### /ci-setup
Setup CI/CD di project aktif -- salin semua workflow templates.

Langkah:
1. Resolve ProjectPath dari working directory
2. Verifikasi ini adalah Godot project (cek `project.godot`)
3. Baca `project.godot` untuk mendapatkan `config/name` (GAME_NAME)
4. Baca `project.godot` untuk mendapatkan versi Godot yang digunakan
5. Buat folder `.github/workflows/` jika belum ada
6. Salin semua 3 workflow dari `<KILO_CONFIG>/ci-templates/.github/workflows/`:
   - `godot-screenshot.yml`
   - `godot-scenario-test.yml`
   - `godot-autonomous-qa.yml`
7. Update `GAME_NAME` dan `GODOT_VERSION` di setiap file sesuai project.godot
8. Cek prasyarat:
   - Ada `--shot` handler di kode? (cari `"--shot"` di scripts)
   - Ada `ScenarioRunner` Autoload? (cek project.godot)
   - Ada `scenarios/smoke.json`? (cek folder scenarios/)
9. Tampilkan laporan setup:
   - File yang berhasil disalin
   - Prasyarat yang sudah terpenuhi (checklist)
   - Prasyarat yang belum ada + cara memenuhinya
10. Berikan perintah commit yang siap dijalankan

### /ci-setup --screenshot-only
Salin hanya `godot-screenshot.yml` (tanpa scenario test dan autonomous QA).

Langkah 1-8 sama, hanya salin 1 file.

### /ci-setup status
Cek status CI/CD yang sudah ada di project aktif.

Langkah:
1. Cek apakah `.github/workflows/` ada
2. List semua workflow files yang ada
3. Untuk setiap workflow dari framework:
   - Apakah sudah ada di project?
   - Apakah `GAME_NAME` sudah disesuaikan (bukan "MyGame")?
   - Apakah `GODOT_VERSION` sudah sesuai?
4. Cek prasyarat game:
   - `--shot` handler
   - `ScenarioRunner` Autoload
   - `scenarios/` folder dengan scenario files
5. Tampilkan status per item:
   - SETUP -- sudah setup dengan benar
   - PARTIAL -- ada tapi perlu dikonfigurasi
   - MISSING -- belum ada

### /ci-setup list
Tampilkan daftar workflow templates yang tersedia.

Langkah:
1. List semua file di `<KILO_CONFIG>/ci-templates/.github/workflows/`
2. Untuk setiap file, tampilkan:
   - Nama file
   - Trigger (dari `on:` di YAML)
   - Deskripsi singkat

### /ci-setup update
Update workflow files yang sudah ada dengan versi terbaru dari templates.

Langkah:
1. Bandingkan versi di project vs template (cek komentar `# Version:` jika ada)
2. Untuk setiap file yang perlu update:
   - Backup file lama ke `.github/workflows/<nama>.yml.bak`
   - Salin versi baru
   - Update `GAME_NAME` dan `GODOT_VERSION` dari project.godot
3. Tampilkan apa yang berubah

---

## Prasyarat yang Dicek

### 1. --shot handler
Cari di kode game:
```gdscript
if "--shot" in OS.get_cmdline_user_args():
```
Jika tidak ada: tampilkan template minimal yang perlu ditambahkan.

### 2. ScenarioRunner Autoload
Cek di `project.godot`:
```ini
[autoload]
ScenarioRunner="*res://scripts/ScenarioRunner.gd"
```
Jika tidak ada: berikan instruksi setup.

### 3. scenarios/smoke.json
Cek apakah file ada di `<ProjectPath>/scenarios/smoke.json`.
Jika tidak ada: sarankan jalankan `/scenario install-templates`.

---

## Konfigurasi yang Disesuaikan Otomatis

| Variable | Sumber | Default fallback |
|---|---|---|
| `GAME_NAME` | `project.godot` > `config/name` | `"MyGame"` |
| `GODOT_VERSION` | `project.godot` > `config/features` atau tanya user | `"4.3"` |
| `PROJECT_PATH` | Relatif dari root repo | `"."` |

---

## Argumen

$ARGUMENTS
