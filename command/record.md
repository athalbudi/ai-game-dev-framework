---
description: Kelola replay dan recording sistem untuk bug reproduction. Rekam input gameplay manual, konversi ke scenario JSON, dan putar ulang secara deterministik.
---

Kamu mengelola replay/recording system untuk AI-assisted game development framework.
Framework ini universal — tidak bergantung pada game tertentu atau struktur folder spesifik.

ProjectPath default: direktori kerja saat ini (atau tanya user jika ambigu)
ShotsDir: baca dari `shots-manifest.json` di ProjectPath, atau `user://shots/` default Godot

---

## Subcommands

### /record list
Tampilkan daftar file rekaman yang tersedia.

Langkah:
1. Resolve ShotsDir dari `shots-manifest.json` di ProjectPath
2. Cari semua file `recording_*.json` di ShotsDir
3. Untuk setiap file, tampilkan:
   - Nama file
   - `session_id`, `recorded_at`, `duration_sec`
   - `event_count`, `seed`
   - `start_scene` — scene saat rekaman dimulai
4. Urutkan dari terbaru ke terlama
5. Jika tidak ada rekaman: tampilkan instruksi cara mulai merekam

### /record convert [nama_file_rekaman] [nama_scenario]
Konversi file rekaman ke scenario JSON yang bisa dijalankan ScenarioRunner.

Langkah:
1. Resolve path file rekaman:
   - Jika argumen berupa nama file lengkap → gunakan langsung
   - Jika hanya nama session_id → cari `recording_<session_id>.json` di ShotsDir
   - Jika tidak ada argumen → gunakan rekaman terbaru
2. Baca file rekaman, validasi schema:
   - Harus punya field: `events`, `seed`, `session_id`
3. Konversi events ke steps scenario:
   - Event `action` → step `action`
   - Event `mouse_button` pressed → step `mouse_click`
   - Event `touch` pressed → step `touch`
   - Event `joypad_button` → step `controller`
   - Event `joypad_axis` → step `controller` axis
   - Frame gaps antar event → step `wait_frames`
   - Event `checkpoint_screenshot` → step `screenshot` + `write_state`
4. Tambahkan header: `seed_override` dengan seed dari rekaman
5. Tentukan nama scenario:
   - Jika argumen nama_scenario diberikan → gunakan itu
   - Default: `replay_<session_id>`
6. Simpan scenario ke `<ProjectPath>/scenarios/<nama_scenario>.json`
7. Tampilkan ringkasan: jumlah steps, seed, path output
8. Berikan instruksi cara menjalankan: `/scenario run <nama_scenario>`

### /record replay [nama_scenario]
Jalankan scenario replay yang sudah dikonversi.

Ini adalah alias untuk `/scenario run <nama_scenario>` dengan konteks bahwa
scenario berasal dari rekaman. Sama persis dengan menjalankan scenario biasa.

Langkah:
1. Resolve scenario path dari `<ProjectPath>/scenarios/<nama_scenario>.json`
2. Salin ke ShotsDir sebagai `test_scenario.json`
3. Jalankan harness dengan flag `--scenario`
4. Baca dan tampilkan hasil dari `scenario_result.json`

### /record status
Tampilkan status recording system di project aktif.

Langkah:
1. Cek apakah `InputRecorder.gd` ada di project (`scripts/InputRecorder.gd` atau autoload)
2. Cek apakah `RecordingConverter.gd` ada di project
3. Tampilkan daftar rekaman tersedia (sama seperti `/record list`)
4. Tampilkan daftar scenario yang berasal dari replay (`scenarios/replay_*.json`)
5. Berikan status: apakah system siap digunakan atau perlu setup tambahan

---

## Setup Recording System di Project Baru

Untuk menggunakan recording system, copy file-file berikut dari `<KILO_CONFIG>/godot-templates/`:

1. `InputRecorder.gd` → `scripts/InputRecorder.gd`
2. `RecordingConverter.gd` → `scripts/RecordingConverter.gd`

Daftarkan sebagai Autoload di `project.godot`:
```ini
[autoload]
InputRecorder="*res://scripts/InputRecorder.gd"
```

Cara mulai merekam dari kode game (contoh di debug menu):
```gdscript
# Mulai rekam
InputRecorder.start()

# Berhenti dan simpan
InputRecorder.stop()  # output: user://shots/recording_<timestamp>.json

# Atau dengan seed deterministik
InputRecorder.start(seed_override: 42)
```

Setelah game dimainkan dan bug ditemukan:
1. Panggil `InputRecorder.stop()` untuk simpan rekaman
2. Jalankan `/record convert` untuk konversi ke scenario
3. Jalankan `/scenario run <nama>` untuk reproduksi bug

---

## Prinsip Reproduksi Deterministik

Rekaman menyimpan `seed` yang dipakai saat merekam. Saat replay:
- `seed_override` di awal scenario meng-override seed engine
- Frame-based timing memastikan urutan event sama
- Reproduksi paling akurat untuk bug yang melibatkan sequence input tertentu

Catatan: replay tidak bisa 100% deterministik untuk bug yang bergantung pada:
- Physics simulation dengan floating point drift
- Animasi yang bergantung pada delta time
- Network atau system call
- Random yang tidak menggunakan seed global Godot

Untuk kasus tersebut, rekaman tetap berguna sebagai **dokumentasi langkah reproduksi**
meskipun tidak deterministik penuh.

---

## Argumen

$ARGUMENTS
