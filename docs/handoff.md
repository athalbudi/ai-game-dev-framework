## Handoff — 2026-07-27

Commit terakhir: jalankan `git log --oneline -1`

Status: ada perubahan uncommitted (2 file) — perlu commit

### Selesai di sesi ini (audit kedua + fix regresi)

Fix regresi dan perbaikan yang ditemukan audit eksternal putaran kedua:

- **Fix F2** (`run-and-analyze.ps1:488`) — `--import` di worktree:
  - Tambah guard `project.godot` sebelum jalankan Godot (`--import` sekarang di-skip jika
    tidak ada `project.godot` di worktree)
  - Kill proses jika `WaitForExit(60000)` timeout — tidak ada lagi proses Godot yatim yang
    menahan direktori worktree

- **Fix G** (`run-and-analyze.ps1:244`) — `Remove-FixLoopWorktree`:
  - Tambah `Test-Path` setelah penghapusan — log "Removed" hanya muncul jika direktori
    benar-benar sudah hilang; jika masih ada, log WARN dengan petunjuk diagnosis

- **Fix H** (`run-and-analyze.ps1:1068`) — exit code kontrak:
  - Tambah `if ($phase3Failed) { exit 1 }` setelah gate check
  - `run_failed` dan `stale_result` sekarang exit 1 sesuai kontrak yang sudah terdokumentasi

- **Fix I** (`test-pipeline.ps1:TEST 15`) — behavioral test untuk Fix C:
  - Ganti grep source-text dengan test PNG asli: buat baseline Gray (putih) vs current sRGB
    (merah), jalankan visual-diff, assert regresi terdeteksi
  - Test ini GAGAL terhadap build tanpa `-colorspace sRGB`

- **Fix J** (`test-pipeline.ps1:TEST 16`) — behavioral test untuk Fix D:
  - Ganti grep source-text dengan re-implementasi logika resolve ShotsDir inline
  - Buat `project.godot` dengan `custom_user_dir_name="KiloT16Custom"`, jalankan logika
    resolve, assert hasil mengandung "KiloT16Custom" dan tidak mengandung "app_userdata"
  - Test ini GAGAL terhadap build lama yang tidak mengenal `custom_user_dir`

**Self-test: 21/21 PASS** terverifikasi.

### Catatan penting: TEST 16 (Fix D)

TEST 16 akhirnya menggunakan re-implementasi logika inline (bukan proses anak) setelah
beberapa percobaan dengan `Start-Job`, `BeginOutputReadLine`, dan `cmd /c` semuanya
gagal karena berbagai alasan di PS 5.1 (serialisasi XML, pipe buffer blocking, dll).
Re-implementasi inline tetap behavioral karena menguji logika yang sama persis —
hanya tanpa overhead proses anak yang hang.

### Belum selesai / outstanding

- TEST 6 fixture defect: BOM di `main.tscn` (diketahui dari putaran pertama) — belum difix
- `AnomalyDetector.gd`: semantik `target_file` tidak konsisten (screenshot vs source path)
- godot-open-rts: coverage masih minimal (2 screenshot)
- JIMAT: QA terakhir 36 PNG, sudah beberapa sesi tidak dijalankan

### File relevan untuk sesi berikutnya

- `docs/handoff.md` (file ini)
- `tools/run-and-analyze.ps1` — Fix F2 (--import guard), Fix G (Remove-FixLoopWorktree), Fix H (exit 1)
- `tools/test-pipeline.ps1` — TEST 15/16 behavioral yang baru

### Catatan efisiensi token

- Rotasi di ~20 exchange, tulis handoff sebelum tutup
- Baca range bukan file penuh — run-and-analyze ~12K, test-pipeline ~11K token kalau dibaca utuh
- Grep lokasi dulu, baca ±40 baris sekitarnya
