## Handoff — 2026-07-27

Commit terakhir: jalankan `git log --oneline -1`

Status: tree bersih, repo ↔ deployed sinkron

### Selesai di sesi ini (audit ketiga + fix K/L)

- **Fix K** (`autonomous-qa.ps1`) — Ekstrak logika resolve ShotsDir ke fungsi `Resolve-GodotShotsDir`
  yang diekspor. Blok inline 35 baris diganti dengan satu pemanggilan fungsi.
  Fungsi ini bisa diuji via dot-source tanpa menjalankan loop penuh.

- **TEST 16 behavioral sungguhan** (`test-pipeline.ps1`) — Dot-source `autonomous-qa.ps1`
  dalam scope terisolasi, panggil `Resolve-GodotShotsDir()` dari file deployed, assert hasil
  mengandung "KiloT16Custom" dan tidak mengandung "app_userdata".
  GAGAL jika stub tanpa fungsi tersebut (diverifikasi oleh auditor).

- **Fix L** (`run-and-analyze.ps1`) — Tambah `-RedirectStandardError` ke `Start-Process`
  scenario RUN + baca stderr log setelah selesai. Jika ada `Compile Error` / `Failed to load script`
  (bukan GDScript::reload artifact), `phase3Status = "compile_error"` → exit 1.
  Menutup gap: worktree tanpa `.godot/` → 193 ERROR baris → scenario pass 5/5 (false verify).

**Self-test: 21/21 PASS** terverifikasi commit `c9dd042`.

### Catatan penting dari auditor

Fix L menutup deteksi di sisi PS (stderr Godot) tapi tidak menutup seluruh gap:
`--import` masih tidak mengisi `.godot/imported/` secara lengkap di worktree isolasi karena
assets binary tidak ada di git. Untuk verifikasi worktree yang benar-benar valid, perlu
mengcopy atau re-generate `.godot/` dari project asli setelah provisioning. Ini belum diimplementasi.

### Belum selesai / outstanding

- Worktree isolation: `.godot/imported/` kosong setelah `--import` karena binary assets tidak di-track git.
  Scenario bisa tetap gagal compile meski Fix L mendeteksinya. Solusi jangka panjang: copy `.godot/`
  dari ProjectPath ke worktree setelah provisioning, atau skip worktree untuk project yang tidak punya
  semua assets di git.
- TEST 6 fixture defect: BOM di `main.tscn` (diketahui sejak putaran pertama)
- `AnomalyDetector.gd`: semantik `target_file` tidak konsisten (screenshot vs source path)
- godot-open-rts: coverage masih minimal (2 screenshot)
- JIMAT: QA terakhir 36 PNG, sudah beberapa sesi tidak dijalankan

### File relevan untuk sesi berikutnya

- `docs/handoff.md` (file ini)
- `tools/autonomous-qa.ps1` — fungsi `Resolve-GodotShotsDir` (Fix K)
- `tools/run-and-analyze.ps1` — Fix L (compile error detection), Fix F2/G/H dari sesi sebelumnya
- `tools/test-pipeline.ps1` — TEST 16 behavioral via dot-source

### Catatan efisiensi token

- Rotasi di ~20 exchange, tulis handoff sebelum tutup
- Grep dulu, baca ±40 baris — jangan baca file penuh
- run-and-analyze ~12K, test-pipeline ~11K, autonomous-qa ~8K token kalau dibaca utuh
