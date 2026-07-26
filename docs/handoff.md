## Handoff — 2026-07-26

Commit terakhir: jalankan `git log --oneline -1`

Status: ada perubahan uncommitted (7 file) — perlu commit

### Selesai di sesi ini (audit + fix dari external reviewer)

Fix kritis dari hasil audit end-to-end oleh external reviewer:

- **Fix A** — `Get-DefaultProtectedPatterns`: tambah prefix `*` pada tiga pola script
  (`*scripts/ScenarioRunner.gd` dll) agar cocok dengan layout folder non-standar
  (`source/scripts/`, `src/global/`). Tanpa ini gate bisa dilewati di 3 dari 4 game nyata.

- **Fix B** — Guard stale `scenario_result.json` di `run-and-analyze.ps1`:
  - Cek mtime file vs `$ts_run` (guard aktif saat `ok` DAN `timeout`)
  - `$phase3Status` masuk formula `$overallStatus` → status baru `run_failed`
  - Sebelumnya: scenario timeout → laporan tetap `clean`, exit 0 (false-verify kritis)

- **Fix C** — `visual-diff.ps1`: tambah `-colorspace sRGB` pada kedua argumen ImageMagick
  (v7 dan v6). Tanpa ini: baseline Gray vs current sRGB → `compare -metric AE` selalu 0
  → visual regression tidak pernah terdeteksi.

- **Fix D** — `autonomous-qa.ps1`: perbaiki resolusi `ShotsDir` agar mendukung
  `custom_user_dir_name` (sama dengan `run-and-analyze.ps1`). Sebelumnya: 0 referensi
  `custom_user_dir` di autonomous-qa, sehingga game seperti godot-tiny-mmo (custom dir
  `slayhorizon`) selalu mencari path yang salah.

- **Fix E** — `shot-harness.ps1` + `shot-harness-unity.ps1`: sentuh `$proc.Handle | Out-Null`
  setelah `Start-Process -PassThru` agar `ExitCode` tidak selalu `$null`.

- **Fix F** — `run-and-analyze.ps1 -FixLoopMode`: jalankan `--import` di worktree setelah
  provisioning. Tanpa ini Godot tidak bisa compile script di worktree (tidak ada `.godot/`)
  dan scenario selalu gagal di step 1. Godot resolve dipindah ke sebelum blok provisioning.

- **Docs** — `FRAMEWORK.md`: tambah section "Fix-Loop Otonom" yang mendokumentasikan
  `-FixLoopMode`, alur 7 tahap, default protected patterns, `-ProtectedPatterns` override,
  dan tabel `overall_status`.

- **Tests** — `test-pipeline.ps1`: tambah TEST 12–16 (regression test untuk Fix A/B/C/D).
  Setiap test didesain gagal terhadap build lama. **21/21 PASS** terverifikasi.

### Belum selesai / outstanding

- TEST 6 fixture defect: `Set-Content -Encoding UTF8` di PS 5.1 menulis BOM → `main.tscn:1`
  parse error saat dijalankan Godot. Test tetap PASS karena cukup `$pngs.Count -ge 1`,
  tapi ini noise yang sebaiknya difix dengan `[System.IO.File]::WriteAllText(...)` tanpa BOM.
- `AnomalyDetector.gd`: `target_file` didokumentasikan sebagai nama screenshot tapi dipakai
  sebagai source-path allowlist di `Test-ScopeViolation` — semantik tidak konsisten.
- godot-open-rts: coverage masih minimal (2 screenshot), perlu shot tour lebih lengkap.
- JIMAT: QA terakhir 36 PNG, 100%, tapi sudah beberapa sesi tidak dijalankan.

### File relevan untuk sesi berikutnya

- `docs/handoff.md` (file ini)
- `tools/run-and-analyze.ps1` — Fix B (guard stale), Fix F (--import worktree), Fix A (gate)
- `tools/visual-diff.ps1` — Fix C (-colorspace sRGB)
- `tools/autonomous-qa.ps1` — Fix D (custom_user_dir)
- `tools/test-pipeline.ps1` — TEST 12–16 regression test baru
- `FRAMEWORK.md` — section Fix-Loop Otonom baru

### Catatan efisiensi token

- Rotasi di ~20 exchange, tulis handoff sebelum tutup
- Baca range bukan file penuh (run-and-analyze ~12K, test-pipeline ~11K token kalau dibaca utuh)
- Grep lokasi dulu, baca ±40 baris sekitarnya
