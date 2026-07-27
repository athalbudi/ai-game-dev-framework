## Handoff — 2026-07-27

Commit terakhir: `1c0a910` -- docs: update handoff -- ErrorTracker self-locating + TEST 19 fix + 24/24 PASS

Status: tree bersih, repo ↔ deployed sinkron, pushed ke origin/main

### Selesai di sesi ini

- **Fix ErrorTracker.gd:174** — self-locating path via `get_script() as Script`
  + `resource_path.get_base_dir()` + `path_join("ScenarioRunner.gd")`.
  Terverifikasi behavioral di dua layout: godot-open-rts (`source/scripts/`) 5/5 pass,
  godot-tiny-mmo (`source/common/framework/`) ScenarioRunner berhasil di-load.

- **Vendored templates re-sync** 12/12 dengan ErrorTracker yang sudah diperbaiki.

- **TEST 19** — SKIP dihitung FAIL; path via `KILO_GAMES_DIR` env var.

**Self-test: 24/24 PASS** terverifikasi commit `1c0a910`.

### Catatan penting: TEST 19 adalah syarat tegas

TEST 19 akan FAIL di mesin tanpa keempat game validasi kecuali `KILO_GAMES_DIR` di-set.
Ini menukar "diam-diam tidak teruji" dengan "selalu merah di tempat lain" — pilihan yang lebih
jujur, tapi perlu disadari bahwa ini syarat tegas, bukan nice-to-have.
Untuk mesin lain atau CI: set env `KILO_GAMES_DIR` ke direktori yang berisi
`godot-open-rts/`, `godot-tiny-mmo/`, `bread-adventure/`, `jimat/`.

### Outstanding (prioritas rendah)

- Enam step type scenario tanpa cakupan template: `assert_fps`, `assert_screenshot_exists`,
  `controller_press`, `mouse_click`, `touch_tap`, `wait_signal`
- godot-tiny-mmo scenario file memakai `comment`/`wait`/`value` yang tidak dikenal ScenarioRunner
  (bug pre-existing, bukan regresi dari sesi ini)

### Catatan setelah update template framework

Setiap kali ada fix di `godot-templates/`, jalankan re-sync ke game validasi:
```powershell
$gamesDir = "C:\Users\Athallah Budiman\Documents\games"
$enc = New-Object System.Text.UTF8Encoding($false)
# ... salin ErrorTracker.gd, GameStateWriter.gd, ScenarioRunner.gd ke masing-masing game
```
TEST 19 mendeteksi drift secara otomatis. Pastikan 24/24 PASS setelah re-sync.

### Catatan efisiensi token

- Rotasi di ~20 exchange, tulis handoff sebelum tutup
- Grep dulu, baca ±40 baris — jangan baca file penuh
