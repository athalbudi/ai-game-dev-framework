## Handoff — 2026-07-28

Commit terakhir: `c95f27c` -- fix: sync audit fixes + TEST 12 assertion update + vendored re-sync 4/4

Status: tree bersih, repo ↔ deployed sinkron

### Selesai di sesi ini

Eksekusi rekomendasi auditor secara penuh:

1. **Sync ke deployed** — `sync.ps1` dijalankan, 38 file ter-copy ke `~/.config/kilo`.
   Semua fixes dari sesi koreksi sebelumnya (gate wildcard, crash autonomous-qa.ps1,
   exit 0, resolver joy/mouse button, input_methods.json) kini operasional di deployed.

2. **Re-sync ScenarioRunner.gd ke semua 4 game validasi** — godot-open-rts, jimat,
   bread-adventure, godot-tiny-mmo semuanya sudah di-sync dari `godot-templates/ScenarioRunner.gd`.
   TEST 19 drift menutup.

3. **TEST 12 Fix A assertion diupdate** — assertion `$allHaveWildcard` di `test-pipeline.ps1`
   menggunakan pola lama `*\*scripts/*` yang tidak cocok dengan pola baru `*ScenarioRunner.gd`.
   Difix agar cek `**ScenarioRunner.gd` dan `*\*ScenarioRunner.gd` (demikian juga untuk
   GameStateWriter dan ErrorTracker). `nonStdMatch=1` sudah benar sebelumnya — yang gagal
   hanya format assertion.

**Self-test: 24/24 PASS** terverifikasi commit `c95f27c`.

### Isi commit c95f27c

- `godot-templates/ScenarioRunner.gd` — `_resolve_joy_button` (21 nama) + `_resolve_mouse_button` (9 nama)
- `tools/run-and-analyze.ps1` — gate wildcard `*ScenarioRunner.gd` layout-agnostic + `exit 0` eksplisit
- `tools/autonomous-qa.ps1` — crash fix PropertyNotFoundException
- `tools/test-pipeline.ps1` — TEST 12 assertion update
- `sync.ps1` — komentar pola wildcard diupdate
- `scenarios-templates/input_methods.json` — file baru (template 6 step type baru)
- `FRAMEWORK.md` — seksi mekanisme internal (self-locating path, sRGB fix)
- `QUICKSTART.md` — catatan HANG normal di prototype, DirAccess.make_dir_absolute

### Outstanding (prioritas rendah, tidak berubah dari sesi sebelumnya)

- Enam step type scenario (`assert_fps`, `assert_screenshot_exists`, `controller_press`,
  `mouse_click`, `touch_tap`, `wait_signal`) — `input_methods.json` sudah ada sebagai template,
  implementasi behavioral di ScenarioRunner belum ada (pre-existing gap)
- godot-tiny-mmo scenario file memakai `comment`/`wait`/`value` yang tidak dikenal ScenarioRunner
  (bug pre-existing, bukan regresi)

### Catatan penting: TEST 19 adalah syarat tegas

TEST 19 FAIL di mesin tanpa keempat game validasi kecuali `KILO_GAMES_DIR` di-set.
Lokasi default: `C:\Users\Athallah Budiman\Documents\games\`
Game paths: `godot-open-rts/source/scripts/`, `godot-tiny-mmo/source/common/framework/`,
`bread-adventure/src/global/`, `jimat/scripts/`

### Catatan setelah update template framework

Setiap kali ada fix di `godot-templates/`, jalankan:
1. `sync.ps1` — deploy ke `~/.config/kilo`
2. Copy manual ScenarioRunner.gd ke 4 game validasi (atau jalankan re-sync script)
3. Self-test `24/24 PASS` sebelum commit
