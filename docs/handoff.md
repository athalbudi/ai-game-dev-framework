## Handoff — 2026-07-27

Commit terakhir: `b4ecab0` -- feat: TEST 19 drift detection vendored templates + sync 12/12 ke game validasi

Status: tree bersih, repo ↔ deployed sinkron, pushed ke origin/main

### Selesai di sesi ini

- **Sync vendored templates** ke 4 game validasi (12/12 OK, tanpa BOM):
  - godot-open-rts: `source/scripts/`
  - godot-tiny-mmo: `source/common/framework/`
  - bread-adventure: `src/global/`
  - jimat: `scripts/`

- **TEST 19** (`test-pipeline.ps1`) — drift detection: cek md5 vendored
  ErrorTracker/GameStateWriter/ScenarioRunner di 4 game validasi vs framework.
  FAIL jika ada yang tertinggal. 24/24 PASS terverifikasi.

**Self-test: 24/24 PASS** terverifikasi commit `b4ecab0`.

### Outstanding (prioritas rendah)

- Enam step type scenario tanpa cakupan template: `assert_fps`, `assert_screenshot_exists`,
  `controller_press`, `mouse_click`, `touch_tap`, `wait_signal`
- TEST 18 Fix Q adalah grep source-text (jujur terdokumentasi); behavioral sudah diverifikasi
  oleh auditor lewat Godot headless

### Catatan penting: setelah update template framework

Setiap kali ada fix di `godot-templates/`, jalankan sync ke game validasi:
```powershell
$gamesDir = "C:\Users\Athallah Budiman\Documents\games"
$enc = New-Object System.Text.UTF8Encoding($false)
# ... atau gunakan sync.ps1 -GameProjectScriptsDir per game
```
TEST 19 akan mendeteksi drift secara otomatis di self-test.

### Catatan efisiensi token

- Rotasi di ~20 exchange, tulis handoff sebelum tutup
- Grep dulu, baca ±40 baris — jangan baca file penuh
