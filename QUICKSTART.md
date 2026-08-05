# Saksi — Quick Start

Framework universal untuk AI-assisted game development dan QA di Godot.
Berlaku untuk semua project game baru — tidak bergantung pada game, genre, atau struktur folder tertentu.

---

## Apa yang Disediakan Framework Ini

Framework ini memberi AI "mata" untuk melihat hasil runtime game, bukan hanya membaca source code.
Loop kerja yang diaktifkan:

```
Tulis kode → Jalankan harness → AI lihat hasil → AI analisis → AI laporkan → Developer tindak lanjut
```

Melihat saja tidak cukup, dan sebagian kemampuan di sini ada justru karena itu: screenshot
memberi tahu sebuah layar **tampak** seperti apa, bukan apakah ia **benar**; scenario tertulis
hanya mengunjungi apa yang sudah dipikirkan penulisnya; dan sebagian cacat tidak pernah sampai
ke screenshot karena ia mematikan sesuatu lebih dulu. Lihat
[Setelah Setup Dasar](#setelah-setup-dasar--empat-langkah-yang-mengubah-nilainya).

---

## Setup untuk Project Baru (10 Menit)

> **Git setup:** Tambahkan `.godot/` ke `.gitignore` project Anda sebelum commit pertama.
> Folder ini di-generate Godot saat runtime (cache, shader compiled, script bytecode) dan
> bukan bagian dari source code. Tanpa ini, file runtime bisa masuk ke `git diff` dan
> memicu false-positive di hard-block gate `run-and-analyze.ps1`.
>
> ```
> # .gitignore
> .godot/
> ```

### Langkah 0 — Bootstrap framework (sekali saja per mesin)

Sebelum langkah manapun di bawah, pasang framework ke `~/.config/kilo`:

```powershell
& ".\setup.ps1"
```

Ini mendeteksi Godot/ImageMagick, menyalin `tools/`, `godot-templates/`, dan template lain
ke `~/.config/kilo`, lalu memverifikasi hasilnya. Cukup dijalankan sekali per mesin --
jalankan ulang kapan saja repo ini di-update untuk sync ulang.

> **Opsional — agar framework dikenali dari project game manapun:**
>
> ```powershell
> & ".\setup.ps1" -InstallAgentRules
> ```
>
> Tanpa ini, AI agent hanya mengenali framework saat bekerja di dalam repo framework.
> Dengan ini, agent juga mengenalinya saat Anda membuka project game Anda sendiri.
>
> Flag ini **opt-in** karena menulis ke direktori config pribadi Anda. Yang disentuh
> (hanya yang direktorinya sudah ada):
>
> | File | Cara |
> |---|---|
> | `~/.kilocode/rules/gamedev-framework.md` | file terpisah |
> | `~/.claude/CLAUDE.md` | blok bertanda `BEGIN`/`END` |
>
> Isi di luar penanda tidak pernah disentuh, dan menjalankan ulang bersifat idempoten
> (tidak menumpuk blok). Cabut kapan saja:
>
> ```powershell
> & ".\setup.ps1" -UninstallAgentRules
> ```

### Langkah 0b — Integrasikan project game (opsional, mempercepat Langkah 1-3)

```powershell
& ".\setup.ps1" -InitProject "C:\path\ke\project-game"
```

Menyalin `ErrorTracker.gd` / `GameStateWriter.gd` / `ScenarioRunner.gd` ke project,
menyalin template scenario dan command AI, lalu mendaftarkan autoload di `project.godot`.

> `project.godot` adalah file milik Anda — dan file pertama yang dibaca Godot. Karena itu
> penyuntingannya defensif: dibuat backup `project.godot.bak`, perubahan ditampilkan lebih
> dulu, menjalankan ulang tidak menduplikasi entri, dan kalau ada nama autoload yang sudah
> Anda pakai untuk file lain, prosesnya **berhenti tanpa mengubah apa pun**.
>
> Tambahkan `-DryRun` untuk melihat rencananya saja. Pakai `-ProjectScriptsDir "src/global"`
> kalau ingin file `.gd` diletakkan di sub-direktori tertentu.

Setelah ini, satu langkah tetap manual: handler `_shot_tour()` di Langkah 2 — itu kode game
yang hanya Anda tahu isinya.

### Langkah 1 — Jalankan harness pertama kali

Harness dapat dijalankan pada project yang belum punya kode game sama sekali.

```powershell
& "$env:USERPROFILE\.config\kilo\tools\shot-harness.ps1" -ProjectPath "<path-ke-project-godot>"
```

Hasilnya: `shots-manifest.json` di ShotsDir. Fase telemetry: `prototype`.
AI sudah bisa menjalankan `/shot` dan `/analisis-shot` setelah ini.

> **Catatan:** Pada project yang benar-benar kosong (tanpa handler `--shot` dan tanpa
> `get_tree().quit()`), Godot tidak akan exit sendiri sehingga harness akan timeout dan
> melaporkan `HANG terdeteksi`. Ini normal — fase `prototype` hanya membuktikan harness
> dapat menjangkau project. Lanjutkan ke Langkah 2 untuk mengaktifkan screenshot penuh.

### Langkah 2 — Implementasikan --shot handler di game (Fase Developing)

Tambahkan ke `main.gd` atau scene utama:

```gdscript
func _ready() -> void:
    # --shot dihandle oleh ErrorTracker._shot_quit_watchdog (anti-hotreload pattern)
    # Jangan panggil _shot_tour di sini — ErrorTracker yang memanggilnya
    # setelah menunggu hot-reload selesai.
    pass

func _shot_tour() -> void:
    _take_screenshot("01_main_menu")
    # Navigasi ke layar lain dan ambil screenshot...
    get_tree().quit()

func _take_screenshot(name: String) -> void:
    var img = get_viewport().get_texture().get_image()
    # Pastikan folder shots ada sebelum menyimpan.
    # Gunakan make_dir_absolute (static, tidak butuh DirAccess yang valid) — lebih aman daripada
    # DirAccess.open("user://").make_dir("shots") karena open() bisa kembalikan null di beberapa
    # export target sebelum user:// ter-inisialisasi penuh.
    DirAccess.make_dir_absolute("user://shots")
    img.save_png("user://shots/%s.png" % name)
```

> **Penting — Godot 4.7 hot-reload pattern:**
> Jangan panggil `_shot_tour()` atau `_shot_tour.call_deferred()` dari `_ready()`.
> `ErrorTracker` sebagai Autoload yang mendeteksi `--shot` dan memanggil `_shot_tour`
> di main node setelah menunggu 4 frame agar hot-reload selesai.
> Ini adalah **satu-satunya cara** agar harness bisa berjalan autonomous dari command line.

> **Penting — Hindari `:=` dengan class_name globals:**
> Godot 4.7 melakukan hot-reload saat pertama kali project di-launch dari command line.
> Selama hot-reload, `class_name` globals tidak tersedia sementara. Script yang menggunakan
> `:=` (walrus operator) dengan class_name globals akan gagal parse.
>
> **Pola yang aman:**
> ```gdscript
> # BENAR — tidak bergantung pada class_name saat parse time
> var runner = load("res://scripts/smoke_runner.gd").new()
>
> # BENAR — method call dalam function body, class_name tidak dipakai di signature
> func goto_battle() -> void:
>     var sim = BattleSim.new()  # aman jika BattleSim sudah extends RefCounted/Node
>
> # BENAR — tidak ada type annotation pada member var yang bergantung class_name
> var gs   # GameState — type akan resolved saat runtime
>
> # HATI-HATI — :=  dengan method return yang membutuhkan class registry
> var runner := SmokeRunner.new()  # bisa gagal jika SmokeRunner belum ter-register
> ```
>
> **Aturan sederhana:** gunakan `=` (bukan `:=`) untuk variabel yang nilainya dari
> constructor atau static method `class_name`, terutama di `_ready()` dan member var
> declarations di top of file.

> **Godot 4.7 — One-Time Setup per Mesin:**
> Untuk project yang sudah ada (codebase yang punya banyak `class_name` references),
> jalankan Godot editor sekali untuk project tersebut agar dependency graph ter-compile:
> 1. Buka Godot editor untuk project
> 2. Jalankan game sekali dari editor (F5)
> 3. Tutup editor
>
> Setelah ini, harness berjalan autonomous selamanya di mesin tersebut.
> Project **baru** yang mengikuti pattern di atas tidak membutuhkan step ini.

### Langkah 3 — Install scenario templates

```
/scenario install-templates
```

Menyalin 4 template universal ke `scenarios/` project: smoke, screenshot_tour, crash_stress, save_load.

### Langkah 4 — Setup Automated Testing

1. Salin tiga file dari `<KILO_CONFIG>/godot-templates/` ke `scripts/` project:
   - `GameStateWriter.gd`
   - `ErrorTracker.gd`
   - `ScenarioRunner.gd`

2. Daftarkan **hanya GameStateWriter dan ErrorTracker** sebagai Autoload di `project.godot`:
   ```ini
   [autoload]
   GameStateWriter="*res://scripts/GameStateWriter.gd"
   ErrorTracker="*res://scripts/ErrorTracker.gd"
   ```
   > **Penting:** `ScenarioRunner.gd` **tidak** didaftarkan sebagai Autoload.
   > ErrorTracker yang menjalankannya secara otomatis saat flag `--scenario` terdeteksi.
   > Mendaftarkan ScenarioRunner sebagai Autoload akan menyebabkan hot-reload race condition
   > yang membuat scenario tidak pernah berjalan.

3. Tambahkan `report_scene()` di setiap fungsi navigasi layar game:
   ```gdscript
   func goto_main_menu() -> void:
       if has_node("/root/GameStateWriter"):
           # Gunakan .call() agar kompatibel dengan GDScript strict mode (unsafe_method_access)
           get_node("/root/GameStateWriter").call("report_scene", "main_menu")
       # ... sisa kode
   ```

4. Implementasikan `_get_game_state()` di node utama game (opsional, untuk telemetry lengkap):
   ```gdscript
   func _get_game_state() -> Dictionary:
       return {
           "schema_version": "1.0",
           "build": MY_VERSION,
           # Gunakan .call() agar kompatibel dengan GDScript strict mode (unsafe_method_access)
           "current_scene": get_node("/root/GameStateWriter").call("get_current_scene") if has_node("/root/GameStateWriter") else "",
           "frame_count": Engine.get_process_frames(),
           "timestamp": Time.get_datetime_string_from_system(),
           # field game-specific di sini
       }
   ```

5. Jalankan smoke test: `/scenario run smoke`

### Langkah 5 — Buat Scenarios Folder

Buat folder `scenarios/` di root project dan tambahkan scenario pertama:

```
/scenario install-templates
```

Atau salin manual dari `<KILO_CONFIG>/scenarios-templates/`.

---

## Setelah Setup Dasar — Empat Langkah yang Mengubah Nilainya

Lima langkah di atas membuat framework bisa **melihat** game kamu. Empat berikut membuatnya
bisa **menilai**. Urutannya bukan selera — tiap langkah membuka langkah sesudahnya.

### 1. `/game-doctor` — jalankan ini lebih dulu, selalu

```powershell
& "$env:USERPROFILE\.config\kilo\tools\game-doctor.ps1" -ProjectPath "path/to/project"
```

Pemeriksaan statis, tanpa menjalankan Godot, selesai dalam hitungan detik. Ia menangkap
cacat yang **mematikan pengujian lain lebih dulu** — `class_name` ganda, mojibake di teks UI,
autoload yang belum terpasang, tur screenshot yang terpanggil dua kali.

Menjalankan harness pada project dengan `class_name` ganda hanya menghasilkan tur terpotong
dan waktu terbuang: Godot menolak memuat kedua script, layar tidak pernah terbangun, dan
tidak ada pesan yang menyebut sebabnya.

### 2. `/invariant init` — aturan yang berlaku sepanjang run

```
/invariant init
```

Menyalin template lalu membantu kamu menyesuaikannya ke field `game_state.json` game kamu.

`assert_state` hanya memeriksa di titik tempat kamu menaruhnya. Invariant diperiksa setelah
**setiap** langkah, di **semua** scenario yang sudah ada — tanpa satu pun scenario perlu
diubah. Ini satu-satunya pemeriksaan yang bisa menangkap "pemain melompati sesuatu":

```json
{ "id": "progres_butuh_usaha",
  "expr": "delta.level_selesai <= delta.musuh_dikalahkan",
  "severity": "critical" }
```

Lima sampai sepuluh baris JSON biasanya sudah menutup sebagian besar game. Framework tidak
bisa menebaknya — invariant menyatakan maksud desain, dan itu hanya ada di kepala kamu.

### 3. `/explore` — jalur yang tidak kamu pikirkan

```json
{ "type": "explore", "iterations": 40, "seed": 20260101,
  "avoid_text": ["Quit", "Keluar"] }
```

Mengklik tombol yang benar-benar ada di layar secara acak, dengan invariant hidup. Scenario
tertulis hanya mengunjungi apa yang sudah kamu pikirkan — dan jalur yang bisa dilewati,
menurut definisinya, adalah yang tidak terpikirkan.

Periksa `clicked` lebih dulu sebelum melihat pelanggaran. **`clicked: 0` berarti gagal** —
tidak ada perilaku game yang teruji sama sekali.

Saat invariant jebol, jejaknya diperkecil jadi repro minimal:

```powershell
& "$env:USERPROFILE\.config\kilo\tools\explore-minimize.ps1" `
    -ProjectPath "path/to/project" -InvariantId "progres_butuh_usaha"
```

40 klik jadi 3, dan 3 klik adalah sesuatu yang bisa dibaca manusia dan disimpan sebagai
test regresi.

### 4. `/visual-review` — penilaian yang tidak hilang

```powershell
$t = "$env:USERPROFILE\.config\kilo\tools\visual-review.ps1"
& $t -ProjectPath "path/to/project" -Mode plan     # apa yang perlu dinilai
& $t -ProjectPath "path/to/project" -Mode record -VerdictFile verdicts.json
& $t -ProjectPath "path/to/project" -Mode check    # gerbang CI
```

`visual-diff` tahu sebuah layar **berubah**; ia tidak pernah tahu layar itu **benar**. Teks
terpotong, mojibake, tombol tertutup panel — hanya bisa dinilai dengan melihat, dan
penilaian itu dulu hilang begitu percakapan selesai.

Verdict disimpan dan dipaku ke sha256 gambar yang dinilai. Kalau gambarnya berubah cukup
jauh, verdict batal dan minta dinilai ulang. Verdict `fail` **tidak pernah** dibawa maju —
melaporkan bug yang sudah diperbaiki merusak kepercayaan sama parahnya dengan melewatkannya.

---

## Fase Telemetry

| Fase | Kondisi | Kemampuan AI |
|---|---|---|
| `prototype` | Harness jalan, belum ada PNG | Screenshot harness tersedia |
| `developing` | Ada PNG, belum ada game_state | Visual QA, baseline, regression |
| `mature` | Ada PNG + game_state.json | Semua + assertion, scenario testing |

---

## Commands yang Tersedia

| Command | Deskripsi |
|---|---|
| `/shot` | Preview screenshot terbaru |
| `/analisis-shot` | Analisis visual menyeluruh |
| `/baseline set` | Set baseline untuk regression |
| `/baseline diff` | Bandingkan vs baseline |
| `/baseline diff --ignore visual-diff-ignore.json` | Diff dengan config intentional/threshold |
| `/scenario run <nama>` | Jalankan scenario automated test |
| `/scenario generate` | AI buat scenario dari observasi |
| `/scenario run-and-analyze` | Loop: generate → run → analyze |
| `/scenario install-templates` | Salin template universal ke project |
| `/record convert <file>` | Konversi rekaman input ke scenario |
| `/record list` | Daftar rekaman tersedia |
| `/game-doctor` | Pemeriksaan statis project game — jalankan lebih dulu |
| `/invariant init` | Pasang aturan yang diperiksa tiap langkah |
| `/invariant check` | Jalankan scenario dan baca hasil invariant |
| `/explore` | Eksplorasi jalur tak terskrip, lalu perkecil jejaknya |
| `/visual-review plan` | Daftar layar × klaim yang perlu dinilai |
| `/visual-review record` | Simpan verdict visual |
| `/visual-review check` | Gerbang: gagal bila ada verdict `fail` atau belum dinilai |

---

## Godot Templates yang Tersedia

Semua tersedia di `<KILO_CONFIG>/godot-templates/`:

| File | Fungsi | Perlu di Autoload? |
|---|---|---|
| `ScenarioRunner.gd` | Automated gameplay testing | **Tidak** — dijalankan oleh ErrorTracker |
| `GameStateWriter.gd` | Scene tracking + telemetry Layer 1 | **Ya** |
| `InputRecorder.gd` | Rekam input untuk bug replay | Ya |
| `RecordingConverter.gd` | Konversi rekaman ke scenario | Tidak (static class) |
| `ErrorTracker.gd` | Error tracking + bootstrap `--scenario` | **Ya** |

---

## Game State Templates

Pilih satu sesuai genre game, salin ke project, sesuaikan referensi:

| File | Genre |
|---|---|
| `universal_minimal.gd` | Semua genre — mulai dari sini |
| `rpg_action.gd` | RPG, action, roguelite |
| `strategy_resource.gd` | Strategy, tower defense, idle |
| `platformer_runner.gd` | Platformer, runner, endless |
| `puzzle.gd` | Puzzle berbasis level |

---

## Scenario Templates Universal

Install via `/scenario install-templates`. Semua bisa dipakai langsung setelah
action names disesuaikan dengan InputMap game:

| Template | Tujuan |
|---|---|
| `smoke.json` | Verifikasi game bisa launch |
| `screenshot_tour.json` | Dokumentasi visual semua layar |
| `crash_stress.json` | Deteksi crash dari input cepat |
| `save_load.json` | Verifikasi integritas save/load |

---

## Workflow Bug Reproduction

Saat menemukan bug saat bermain manual:

1. Pastikan `InputRecorder` aktif sebagai Autoload
2. Sebelum bermain: `InputRecorder.start()` dari debug console atau tombol debug
3. Reproduksi bug
4. Setelah bug: `InputRecorder.stop()` — rekaman tersimpan di `user://shots/`
5. Di Kilo: `/record convert` — konversi ke scenario JSON
6. `/scenario run replay_<session>` — reproduksi deterministik
7. Jika bug terreproduksi: `/scenario generate` untuk buat assertion scenario
8. Commit scenario file ke repo sebagai regression test

---

## Prinsip Progressive Capability

Framework berjalan dari hari pertama tanpa setup apapun (fase prototype),
dan kapabilitasnya bertambah seiring game berkembang:

```
Hari 1: harness jalan → AI lihat game exists
Minggu 1: --shot handler → AI lihat layar game
Bulan 1: ScenarioRunner → AI bisa automated testing
Bulan 2: GameStateWriter → AI bisa assertion + diagnosis
Bulan 3+: ErrorTracker + InputRecorder → AI bisa full QA cycle
```

Tidak ada yang wajib dari hari pertama. Setiap komponen opsional dan additive.
