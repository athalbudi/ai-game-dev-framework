# Saksi — Arsitektur Framework

*Saksi* — yang menyaksikan apa yang benar-benar terjadi, lalu memberi kesaksian yang bisa
diperiksa. Nama ini menggambarkan prinsip yang mengikat seluruh kode di sini: bukti di atas
klaim.

Framework QA untuk game Godot yang dikerjakan bersama AI. Dirancang untuk dipakai dari
prototype hingga produksi, tidak terikat pada game tertentu atau struktur folder tertentu.

---

## Catatan penamaan — JANGAN dirapikan

Framework ini bernama **Saksi**, tapi sejumlah identifier masih memakai nama lama.
Itu **disengaja**, bukan sisa refactor yang terlewat:

| Identifier | Tetap | Alasan |
|---|---|---|
| `~/.config/kilo` | ya | Mengubahnya merusak setiap instalasi yang sudah ada di mesin pengguna |
| `<!-- BEGIN ai-game-dev-framework -->` | ya | Penanda blok di `CLAUDE.md` pengguna. Mengubahnya membuat `-InstallAgentRules` menambah blok KEDUA dan `-UninstallAgentRules` tidak menemukan blok lama |
| `agent-rules/gamedev-framework.md` | ya | Nama file yang di-deploy ke `~/.kilocode/rules/`. Berubah = file lama tertinggal saat uninstall |
| `.kilo/command/` | ya | Lokasi yang sudah dipakai project game yang ada |
| `KILO_GAMES_DIR` | ya | Env var yang mungkin sudah di-set di mesin/CI |

Aturannya sederhana: **nama tampilan boleh berubah, identifier fungsional tidak.**
Identifier fungsional adalah apa pun yang dibaca kembali dari disk atau environment untuk
mencocokkan sesuatu yang ditulis oleh versi sebelumnya.

Kalau suatu saat identifier ini benar-benar perlu diganti, itu butuh jalur migrasi yang
membaca nama lama, memindahkannya, lalu menuliskan nama baru — bukan sekadar find-and-replace.

---

## Komponen Framework

### Tools (global, tidak perlu disalin ke project)

| File | Deskripsi |
|---|---|
| `tools/shot-harness.ps1` | Jalankan game dalam mode screenshot, hasilkan manifest telemetry |
| `tools/visual-diff.ps1` | Bandingkan vs baseline, deteksi regresi, dan lokalisasi jenis perubahannya |
| `tools/visual-review.ps1` | Verdict visual yang awet, dipatok ke gambar yang dinilai |
| `tools/explore-minimize.ps1` | Perkecil jejak eksplorasi jadi repro minimal |
| `tools/game-doctor.ps1` | Pemeriksaan statis terhadap **project game** (bukan instalasi) |
| `tools/doctor.ps1` | Pemeriksaan kesehatan **instalasi framework** |
| `tools/run-and-analyze.ps1` | Loop otomatis QA: Observe, Generate, Run, Analyze, Report |
| `tools/autonomous-qa.ps1` | Loop autonomous QA dengan anomaly detection dan iterasi mandiri |
| `tools/feedback-bridge.ps1` | Petakan keluhan playtester ke screenshot dan lokasi kode |
| `tools/test-pipeline.ps1` | Self-test framework (57 regression test) |
| `tools/_common.ps1` | Bersama: deteksi Godot/ImageMagick, pemetaan `user://`, metrik gambar |

### Commands (tersedia di semua project via global config)

| Command | Deskripsi |
|---|---|
| `/shot` | Tampilkan screenshot terbaru dari ShotsDir |
| `/analisis-shot` | Analisis visual menyeluruh dari screenshot + telemetry |
| `/baseline` | Kelola baseline untuk visual regression testing |
| `/scenario` | Jalankan, buat, dan kelola scenario automated testing |

### Templates (disalin ke project saat dibutuhkan)

**Scenario templates** — `scenarios-templates/`

| File | Gunakan untuk |
|---|---|
| `smoke.json` | Verifikasi game bisa launch dan mencapai main menu |
| `screenshot_tour.json` | Dokumentasi visual semua layar utama |
| `crash_stress.json` | Deteksi crash dari input sequence tidak terduga |
| `save_load.json` | Verifikasi integritas sistem save/load |

**Game state templates** — `game-state-templates/`

| File | Genre |
|---|---|
| `universal_minimal.gd` | Semua genre — titik awal untuk game baru |
| `rpg_action.gd` | RPG, action RPG, roguelite |
| `strategy_resource.gd` | Strategy, tower defense, idle, resource management |
| `platformer_runner.gd` | Platformer, runner, endless, level-based |
| `puzzle.gd` | Puzzle berbasis level, board state, move counter |

**Godot templates** — `godot-templates/`

| File | Deskripsi |
|---|---|
| `ScenarioRunner.gd` | Scenario engine (21 step type, invariant, eksplorasi, gerbang liveness) -- di-load oleh ErrorTracker, bukan Autoload |
| `GameStateWriter.gd` | Autoload: scene tracking via `report_scene()` + `_write_game_state()` hook |
| `InputRecorder.gd` | Autoload untuk merekam input gameplay manual ke recording JSON |
| `RecordingConverter.gd` | Konversi file rekaman ke scenario JSON untuk bug reproduction |
| `ErrorTracker.gd` | Autoload: error tracking + bootstrap `--scenario` flag (hot-reload safe) |
| `AnomalyDetector.gd` | **[In-development, belum disambungkan]** Deteksi anomali in-engine dari manifest/game_state/scenario_result. API: `AnomalyDetector.new().detect_all(manifest_path, scenario_result_path)`. Fungsionalitas serupa dengan `autonomous-qa.ps1` tapi dari sisi GDScript -- ditujukan untuk integrasi langsung ke game engine di masa depan. Belum perlu di-add ke Autoload. |

---

## Setup di Project Baru

### Langkah 1 — Jalankan harness pertama kali

```powershell
& "$env:USERPROFILE\.config\kilo\tools\shot-harness.ps1" -ProjectPath "<path-project>"
```

Harness akan otomatis mendeteksi fase telemetry:
- `prototype` — game baru, belum ada screenshot
- `developing` — sudah ada screenshot, belum ada game state hook
- `mature` — sudah ada screenshot dan `_write_game_state()` diimplementasi

### Langkah 2 — Install scenario templates

```
/scenario install-templates
```

Menyalin template universal ke `<ProjectPath>/scenarios/`. Skip jika sudah ada.

### Langkah 3 — Setup Godot templates

1. Salin tiga autoload dari `godot-templates/` ke `scripts/` di project:
   - `GameStateWriter.gd` — scene tracking + write_state
   - `ErrorTracker.gd` — error tracking + **scenario bootstrap**
   - `ScenarioRunner.gd` — scenario engine (tidak didaftarkan sebagai autoload)

2. Daftarkan hanya GameStateWriter dan ErrorTracker sebagai Autoload di `project.godot`:
   ```ini
   [autoload]
   GameStateWriter="*res://scripts/GameStateWriter.gd"
   ErrorTracker="*res://scripts/ErrorTracker.gd"
   ```
   > **Penting:** ScenarioRunner **tidak** didaftarkan sebagai Autoload — ia di-load oleh
   > ErrorTracker sebagai script instance saat `--scenario` flag terdeteksi.
   > Ini adalah workaround untuk Godot 4.7 hot-reload race condition yang
   > menghancurkan main scene node sebelum deferred calls ter-dispatch.

3. Tambahkan `report_scene()` call di setiap fungsi navigasi layar di game:
   ```gdscript
   func goto_title() -> void:
       _clear()
       if has_node("/root/GameStateWriter"):
           # Gunakan .call() agar kompatibel dengan GDScript strict mode (unsafe_method_access)
           get_node("/root/GameStateWriter").call("report_scene", "title")
       # ... sisa kode
   ```
   Ini memungkinkan `wait_scene` step di scenario bekerja untuk game dengan
   navigasi programmatic (bukan Godot scene transition).

4. Implementasikan `_get_game_state()` di node game untuk telemetry lengkap (opsional):
   ```gdscript
   # Di node manapun (main.gd, game_manager.gd, dll)
   func _get_game_state() -> Dictionary:
       return {
           "schema_version": "1.0",
           "build": MY_VERSION,
           "current_scene": GameStateWriter.get_current_scene(),
           "frame_count": Engine.get_process_frames(),
           "timestamp": Time.get_datetime_string_from_system(),
           # field game-specific di sini
       }
   ```
   GameStateWriter akan menemukan method ini otomatis via `_find_nodes_with_method()`.

---

## Mekanisme Internal Penting

### Self-locating path di ErrorTracker.gd

`ErrorTracker.gd` menemukan `ScenarioRunner.gd` secara otomatis tanpa path yang di-hardcode.
Mekanismenya: `get_script() as Script` mengembalikan script object ErrorTracker itu sendiri,
lalu `resource_path.get_base_dir()` menghasilkan direktori tempat ErrorTracker berada di disk,
dan `path_join("ScenarioRunner.gd")` menyusun path final.

```gdscript
# ErrorTracker.gd — di-load dari direktori apa pun di project
var _self_dir = (get_script() as Script).resource_path.get_base_dir()
var runner_path = _self_dir.path_join("ScenarioRunner.gd")
```

Ini berarti **ErrorTracker dan ScenarioRunner harus berada di direktori yang sama**, tapi
direktori itu bisa bernama apa saja (`scripts/`, `src/global/`, `source/common/framework/`, dll).
Tidak perlu konfigurasi path tambahan saat memindahkan file ke layout folder non-standar.

### Metrik visual-diff — dan kenapa BUKAN `compare -metric AE`

Screenshot yang disimpan via `get_viewport().get_texture().get_image()` di Godot memakai
format warna linear (non-sRGB). Dibandingkan tanpa konversi colorspace, hasilnya
false-positive karena perbedaan interpretasi warna. Karena itu setiap pembandingan diawali
`-colorspace sRGB`, dan flag itu harus berada **di depan**: baseline Gray vs current sRGB
terbaca identik kalau konversinya menyusul belakangan.

**`compare -metric AE` TIDAK dipakai, dan jangan dikembalikan.** Pada build ImageMagick
Q16-HDRI — build yang paling umum di Windows — AE bukan cacah pixel melainkan jumlah
magnitudo ter-skala quantum:

```
500 pixel berbeda  ->  AE = 32.767.500   (= 500 x 65535)
```

Dibagi `totalPixels` lalu di-clamp ke 100, angkanya membengkak hingga 65.535× sehingga
**setiap screenshot yang tidak identik melaporkan "100% pixel berubah"**. Efeknya bukan
sekadar kehilangan gradasi: `Threshold`, `region_thresholds`, dan penandaan
*intentional change* semuanya jadi mati karena tidak ada nilai yang pernah turun di bawah
ambang. Terukur pada jimat: dari 9 file yang dilaporkan regresi, **6 sebenarnya < 1%** —
di bawah threshold default, artinya false positive murni.

Yang dipakai sekarang menghitung fraksi pixel berbeda secara eksplisit, dan hasilnya
identik di build Q8/Q16/HDRI:

```
-colorspace sRGB -alpha off -compose difference -composite
-threshold 0 -separate -evaluate-sequence max   ->   %[fx:mean]
```

Tiap operator punya peran yang tidak bisa dihilangkan:

| Operator | Kenapa ada |
|---|---|
| `-colorspace sRGB` di depan | menyamakan colorspace kedua input sebelum dibandingkan |
| `-threshold 0` | bekerja per channel; menandai selisih sekecil apa pun |
| `-separate -evaluate-sequence max` | pixel dihitung berbeda bila ADA channel yang berbeda, sehingga perbedaan murni warna tidak hilang saat diratakan jadi Gray |

Implementasinya di `Get-ImageChangePercent` (`tools/_common.ps1`), dipakai bersama oleh
`visual-diff.ps1` dan `visual-review.ps1` supaya keduanya tidak bisa menyimpang pada satu
perhitungan yang sudah pernah salah.

### Lokalisasi diff — JENIS perubahan, bukan besarnya

Persentase saja tidak bisa membedakan dua hal yang artinya jauh berbeda: seluruh frame
bergeser beberapa pixel (screen-shake, konten identik) versus satu panel benar-benar
berubah. Keduanya bisa melaporkan angka yang mirip.

Untuk file yang melewati threshold, `visual-diff` menambahkan diagnosis:

```
REGRESI 04_battle.png - 24.75% pixel berubah (threshold: 1%)
   -> GESER (5,-2): konten identik, sisa selisih 0%
```

Dua sinyal, dan yang kedua hanya dijalankan bila perlu:

1. **Kotak batas perubahan** (satu panggilan). Terpusat → `konten`.
2. **Pencarian pergeseran** (hanya bila perubahannya menyebar). Kalau menggeser baseline
   menurunkan sisa selisih ke bawah threshold → `geser` beserta offsetnya; kalau tidak →
   `global` (periksa tema/palet/skala).

Pencariannya memakai *coordinate descent*, bukan satu lintasan separabel: saat kedua sumbu
bergeser, scan `dx` pada `dy=0` tidak punya minimum yang benar dan hasilnya meleset.
Kedua gambar juga di-crop ke bagian dalam sebelum dibandingkan, karena `-roll` membungkus
pixel dari sisi seberang dan pita bungkusan itu sendiri terhitung sebagai perbedaan.

Field yang ditambahkan ke `diff-report.json`: `change_kind`, `change_bbox`,
`bbox_coverage_pct`, dan — bila pergeseran dicari — `shift_dx`, `shift_dy`, `residual_pct`.
Matikan dengan `-NoLocalize`; ubah radius pencarian dengan `-ShiftSearch`.

---

### Invariant — pemeriksaan yang berlaku sepanjang run

`assert_state` bersifat posisional: ia hanya memeriksa di titik tempat penulis scenario
menaruhnya, jadi bug yang terjadi di antara dua assertion tidak terlihat. Invariant
diperiksa setelah **setiap** langkah.

Dimuat dari `res://scenarios/invariants.json` (berlaku ke SEMUA scenario, tanpa satu pun
scenario perlu diubah) dan/atau kunci `"invariants"` di dalam satu scenario. Ekspresi
dievaluasi lewat `Expression` bawaan Godot dengan tiga variabel: `prev`, `curr`, `delta`.

`delta` HANYA memuat field numerik yang hadir di `prev` DAN `curr`. Field yang baru muncul
sengaja tidak diberi delta — kalau dipaksakan jadi 0, invariant seperti
`delta.seals <= delta.wins` akan lolos diam-diam justru saat datanya belum ada.

Perilaku saat dilanggar, dan alasannya:

| Perilaku | Kenapa begitu |
|---|---|
| dicatat, run LANJUT | satu run harus bisa memanen semua pelanggaran; fail-fast juga akan membuat step `explore` tidak berguna karena pelanggaran pertama mengakhiri penjelajahan |
| di-dedup per `id` | satu kondisi yang terus rusak tidak membanjiri laporan; kejadian pertama disimpan lengkap, sisanya menambah `count` |
| `critical` → status `fail` + exit 1 | kalau hanya dicatat, exit code tetap 0 dan orchestrator yang mempercayai exit code meluluskan run yang cacat |
| `fail_fast: true` per-invariant | opt-out untuk kasus yang memang tak bermakna dilanjutkan |

Hasil di `scenario_result.json`: `invariants_total`, `invariant_checks`,
`invariant_violations`. **`invariant_checks` = 0 berarti tidak ada yang diuji** — biasanya
file invariant tidak ditemukan atau game tidak menyediakan penyedia state.

### Gerbang liveness — status `inert`

Kegagalan terburuk sebuah harness bukan melewatkan bug, melainkan melaporkan PASS atas
**ketiadaan pengujian**. Terukur pada jimat: empat scenario hijau berminggu-minggu terhadap
layar kosong, karena game mengambil jalur init minimal saat `--scenario`. Semua assertion di
dalamnya memang lolos — terhadap ketiadaan.

Scenario yang mengirim input lalu tidak mengubah state maupun satu pixel pun berstatus
**`inert`** (exit 1), bukan `pass`.

Dua batasan supaya gerbang ini tidak dimatikan orang:

- Hanya berlaku bila scenario punya langkah input (`action`, `mouse_click`, `touch_tap`,
  `controller_press`, `explore`) — **termasuk yang bersarang di dalam `repeat`**. Pemindaian
  satu tingkat melewatkan justru scenario yang paling gencar mengirim input.
- Field volatil (`timestamp`, `frame_count`, dst) dikecualikan dari pembandingan state.
  Tanpa itu `frame_count` saja sudah membuat setiap scenario tampak hidup.

Opt-out per scenario: `"allow_inert": true`. Field volatil tambahan: `"volatile_fields"`.

Terkait: `steps_pass + steps_fail + steps_skip` TIDAK menjumlah ke `steps_total` saat runner
berhenti fail-fast. Selisihnya ada di **`steps_not_run`**; `steps_skip: 0` tidak berarti
semua langkah sempat berjalan.

Terkait juga: step type yang tidak diimplementasikan **gagal**, bukan dilewati. Sebelumnya
di-skip, dan itu kelas false-verify tersendiri — scenario yang setiap langkahnya salah ketik
berakhir `pass` tanpa mengirim satu pun input, dan gerbang liveness tidak menolong karena
type asing tidak dikenali sebagai langkah input sehingga gerbangnya tidak pernah aktif.
Daftar sahnya ada di `KNOWN_STEP_TYPES`, dan test-pipeline memeriksa daftar itu, cabang
`_dispatch`, serta tabel di `command/scenario.md` tetap bertiga sepadan. Dokumentasi yang
menjanjikan step type yang tidak ada adalah cara lain menghasilkan scenario yang "lulus"
tanpa menguji apa pun — dan itu betul-betul terjadi: delapan type fiktif terdokumentasi
selama berbulan-bulan.

### Diagnostik engine ditempelkan ke langkah

`scenario_result.json` ditulis dari DALAM Godot, dan GDScript tidak punya kait untuk error
engine. Konsekuensinya laporan hanya memuat gejala. Terukur pada fixture:

```
step 2  click_button   pass     <- handler crash: akses properti pada Nil
step 3  assert_state   fail     <- "score = 0.0, expected gt 100.0"
```

Sebabnya ada di langkah 2 yang LULUS; yang tercatat cuma kegagalan langkah 3. Pembaca laporan
hanya punya "score tidak naik" dan tidak ada jalan menuju penyebabnya.

`--log-file` menyatukan stdout dan stderr dalam satu berkas berurutan, dan urutan itulah yang
mengembalikan korelasinya: tiap diagnostik dimiliki langkah yang penanda
`[scenario] step N/M:`-nya terakhir muncul sebelum baris itu. `-RedirectStandardError` saja
tidak cukup — begitu kedua aliran terpisah, tidak ada lagi cara mengetahui error terjadi saat
langkah keberapa.

Ditempelkan ke SEMUA langkah yang jendelanya memuat diagnostik, bukan hanya yang gagal; kasus
di atas justru pada langkah yang lulus. Diagnostik sebelum langkah pertama masuk ke
`godot_log_bootstrap` — error autoload membuat seluruh sisa run tak berarti.

Diagnostik yang dipancarkan runner sendiri (pelanggaran invariant) sengaja tidak disalin ke
sini; ia sudah punya representasinya, dan menyalinnya lagi membuat pembaca mengira ada dua
masalah.

**`godot_log_captured` bukan pelengkap.** Tanpa penanda itu, laporan tanpa error dan laporan
yang tidak pernah melihat error terbaca sama persis — dan yang kedua lebih berbahaya karena
memberi rasa aman yang tidak pernah diperiksa. Versi pertama fungsi ini melanggarnya sendiri:
ia mencari field bernama `steps` padahal ScenarioRunner menulis `step_results`, lalu melapor
`captured: true, count: 0`. Sekarang daftar langkah yang tidak ketemu menghasilkan
`captured: false` beserta catatan sebabnya.

### Eksplorasi dan minimisasi jejak

Step `explore` menelusuri scene tree mencari `BaseButton` yang benar-benar bisa ditekan
pemain (terlihat di tree, tidak disabled, punya luas, berpotongan viewport), lalu mengklik
titik tengahnya dengan invariant diperiksa setelah **setiap** klik.

Sengaja mengklik Control, bukan mengirim `action ui_*`: tanpa Control yang fokus, `ui_*`
tidak mengenai apa pun.

**`clicked: 0` selalu FAIL.** Eksplorasi yang tidak mengklik apa pun tidak mengeksplorasi
apa pun. Opt-out `require_clicks: false` hanya untuk game yang memang tidak digerakkan
tombol.

Saat invariant jebol, jejak klik ditulis ke `user://shots/explore_replay.json` — lengkap
dengan `seed_override` dan warmup, supaya benar-benar bisa dijalankan sendiri. Invariant
inline ikut disalin ke file jejak; tanpa itu replay berjalan tanpa aturan yang tadi
dilanggarnya.

Jejak ditulis sebagai `click_button` — **label**, bukan koordinat. Koordinat mati begitu
layout bergeser sedikit, dan matinya diam-diam: klik mendarat di tempat kosong, langkah
tetap PASS, repro-nya bohong. Label tidak bisa gagal diam-diam; kalau tombolnya tidak ada,
langkahnya gagal sambil menyebut tombol apa saja yang sebenarnya ada di layar itu.

`explore-minimize.ps1` memperkecilnya: bisection prefix lalu pembuangan jendela berurutan,
tiap kandidat di proses Godot **baru** dengan state `user://` dipulihkan dari snapshot.
Tanpa pemulihan itu run kedua berangkat dari layar yang berbeda dan hasil minimisasinya
jadi dusta.

Jendelanya sampai 4 klik, dan panjangnya bukan hiasan. Membuang satu klik saja tidak cukup
di menu berlapis: navigasi datang berpasangan, "masuk Candi" lalu "Back", dan membuang
salah satunya membuat pasangannya tidak punya tombol untuk ditekan — subset ditolak, tidak
ada satu pun klik yang bisa pergi sendirian. Terukur pada jimat: pembuangan satu-satu
berhenti di 5 dari 5 klik; berjendela menyusut ke 1, yaitu klik yang memang penyebabnya.

Baseline diverifikasi lebih dulu dan **gagal tertutup**: kalau jejak penuh saja tidak
mereproduksi, tool berhenti. Batas yang tersisa: jendela lebih panjang dari 4 tidak dicoba,
dan pembuangan hanya berurutan — dua klik tak bersebelahan yang cuma bisa pergi bersama
tidak akan ditemukan.

### Verdict visual — aturan bawa-maju

`visual-diff` tahu sebuah layar berubah; ia tidak pernah tahu layar itu benar.
`visual-review.ps1` menyimpan penilaian dan memaku­nya ke sha256 gambar yang dinilai.

| Kondisi | Perlakuan |
|---|---|
| gambar identik dengan yang dinilai | verdict berlaku apa adanya |
| berubah di bawah `threshold_pct` (default 2%) dan verdict `pass` | dibawa maju, ditandai `carried_from` + `drift_pct` |
| verdict `fail` | **tidak pernah dibawa maju** |
| di atas ambang | basi, wajib dinilai ulang |

Dua aturan yang menentukan sistem ini berguna atau tidak:

**`fail` tidak pernah dibawa maju.** Toleransi ada untuk menahan derau screen-shake, bukan
untuk mengawetkan vonis. Sebuah perbaikan bisa menentukan secara visual namun kecil dalam
hitungan pixel — terukur: menghapus banner yang menimpa judul modal dan mencerahkan satu
label alasan sama-sama mengubah < 2% pixel. Melaporkan bug yang sudah diperbaiki merusak
kepercayaan sama parahnya dengan melewatkan bug.

**Penyimpangan diukur terhadap gambar yang DINILAI, bukan run sebelumnya.** Versi awal
menyematkan ulang sha dan menimpa salinan yang dinilai setiap kali membawa maju, sehingga
acuannya ikut bergeser dan penyimpangan menumpuk tanpa batas: 1,9% + 1,9% + 1,9% ...
masing-masing lolos ambang, tetapi setelah puluhan run gambarnya bisa sudah sama sekali lain
sementara verdict-nya ikut terbawa.

`check` **gagal tertutup**: proyek yang belum pernah dinilai HARUS gagal. Diam bukan bukti
bahwa tampilannya benar. Verdict `fail` tanpa `note` ditolak saat `record`.

### game-doctor — dua daftar pengecualian yang JANGAN disatukan

`doctor.ps1` memeriksa instalasi framework; `game-doctor.ps1` memeriksa project game.
Delapan pemeriksaan statis, tanpa menjalankan Godot.

Sebagian besar melewati direktori arsip (`.`-prefix, `_backup*`, `build`, `export`,
`addons`) untuk menekan kebisingan — pemeriksa yang menuduh arsip cepat kehilangan
kepercayaan, dan pemeriksa yang tidak dipercaya akan dimatikan.

**Pemeriksaan `class_name_ganda` sengaja TIDAK memakai daftar itu.** Godot tidak mengenal
daftar tersebut; ia memindai semuanya kecuali direktori berawalan titik dan direktori
ber-`.gdignore`. Justru di folder yang doctor lewati duplikat biasanya bersembunyi — kasus
nyata: folder cadangan bertanggal di dalam project membuat `class_name` terdaftar ganda,
Godot menolak memuat **keduanya** (yang asli ikut mati), layar tidak pernah terbangun, dan
tur berhenti di tengah tanpa pesan yang menyebut sebabnya.

Menyatukan kedua daftar itu akan membuat pemeriksaannya melewatkan persis kasus yang
menyebabkannya dibuat.

---

## Known Limitations — Multiplayer Game

Framework di-desain untuk single-player atau single-client game. Untuk game multiplayer
(client-server architecture seperti godot-tiny-mmo), harness hanya bisa mencapai layar
yang tersedia tanpa koneksi server aktif:

- Login screen, title screen, pre-connection screen -- BISA di-screenshot
- In-game world, gameplay, chat -- TIDAK bisa tanpa server aktif

## Known Limitations -- Godot pra-4.7 (terverifikasi Godot 4.3)

Hasil validasi empiris framework terhadap Godot 4.3 (godot-open-rts, 2026-07-25):

**`filesystem_cache*` ada di Godot 4.3 dengan nama berbeda:**
File cache class_name di `.godot/editor/` menggunakan nama yang berbeda per versi Godot:
- Godot 4.3: `filesystem_cache8`
- Godot 4.7: `filesystem_cache10`

Angka di belakang nama mengikuti versi format internal Godot. Formatnya kompatibel --
field `$parts[7]` adalah field class di kedua versi. Framework menggunakan glob
`filesystem_cache*` untuk menemukan file yang benar di semua versi secara otomatis.
Fallback ke Strategi 2 (manual scan) tetap aktif jika glob tidak menemukan file apapun.

**Provenance check untuk verifikasi binary Godot:**
Untuk memastikan cache dibuat oleh versi Godot yang benar, jalankan `--import` lalu cek
`git status`. Jika ada file `.import` yang termodifikasi, itu bukan Godot versi lama yang
membuat cache (Godot 4.3 tidak memodifikasi `.import` files, Godot 4.7 memodifikasi ratusan).

**Import headless mungkin gagal jika ada preload() pada resource yang belum ter-import:**
Godot 4.3 `--import` headless bisa gagal jika GDScript menggunakan `preload()` pada file
audio/texture yang belum ter-import sebelumnya. Solusi: buka project di editor GUI sekali
sebelum headless run. Ini adalah keterbatasan Godot, bukan framework.

**Rekomendasi untuk project Godot pra-4.7:**
Framework bisa digunakan di Godot 4.3+ dengan fallback manual-scan yang aktif otomatis.
Jika project menggunakan `preload()` extensif pada audio/resource, import awal via editor
GUI perlu dilakukan sekali agar `--shot` bisa berjalan headless.
**Workaround yang direkomendasikan:**
1. Tambahkan offline/demo mode ke game untuk testing headless
2. Buat mock server sederhana yang bisa di-spawn bersama game untuk CI
3. Screenshot hanya layar pre-connection dan gunakan scenario untuk validasi offline state

**Contoh implementasi:**
`_shot_tour()` hanya mengambil layar pre-connection karena game tidak bisa
connect ke server saat `--shot` headless.

---

## Known Limitations -- GDScript Strict Mode

Pada project yang mengaktifkan `gdscript/warnings/unsafe_method_access=2` di `project.godot`,
dua framework autoload inti akan gagal di-load:

- `GameStateWriter.gd:66` -- memanggil `et.get_errors()` langsung di atas `Node` return value
- `ErrorTracker.gd` -- memanggil `main_node._shot_tour.call_deferred()` di atas `Node` return value

**Status:** Fix sudah diterapkan di versi terkini -- semua direct method call pada `Node` return value
kini menggunakan `.call("method_name")` dan `call_deferred("method_name")`, termasuk di
`_scenario_bootstrap()` dan `has_error_category()`. Lambda di `has_error_category` kini punya
typed parameter `func(e: Dictionary) -> bool`.

**Cara cek:** Jalankan game dengan `--headless --quit` dan cek apakah ada error
`Parse Error: The method "..." is not present on the inferred type "Node"`.

---

## Known Limitations -- Godot 4.7 Hot-Reload

Godot 4.7 me-compile script di **background thread** bersamaan dengan shader cache loading,
sebelum `_ready()` Autoload atau GDScript apapun bisa berjalan. Saat compile pertama ini,
`class_name` globals dari script lain belum tersedia di GDScript runtime, sehingga script
yang bergantung pada class tersebut gagal parse.

**Yang sudah dikonfirmasi melalui tes terkontrol:**

| Pendekatan | Hasil | Keterangan |
|---|---|---|
| `--import --quit-after 2` lalu langsung game | **23 PNG, 0 parse errors** | Solusi autonomous — diimplementasikan di harness |
| `--import --quit-after 2` tanpa langsung game | Cache terisi tapi game berikutnya tetap gagal | Cache expire atau tidak persistent antar process |
| `--headless --editor --quit` | Cache kosong | Editor quit sebelum `update_scripts_classes` selesai |
| Buka Godot editor + Play (F5) | Works permanen | Efek sama dengan --import + langsung run |

**Solusi autonomous yang diimplementasikan di `shot-harness.ps1`:**
Harness sekarang otomatis menjalankan `--import --quit-after 2` sebelum `--shot` untuk setiap
project yang sudah punya `.godot/` folder. Ini menyelesaikan masalah class_name resolution
untuk semua project — termasuk legacy codebase dengan banyak `class_name` dependency —
tanpa intervensi manual apapun.

**Catatan penting tentang `global_script_class_cache.cfg`:**
Cache ini diisi dengan benar oleh `--import` dan berisi semua class yang dibutuhkan. Namun
cache harus diikuti dengan run game **dalam proses yang sama atau berurutan langsung** —
tidak persistent across independent launches. Framework menangani ini secara otomatis di harness.

**Dampak pada framework:**
Script yang menggunakan typed member variable declarations (`var gs: GameState`) atau
walrus operator dengan class_name constructor (`var x := ClassName.new()`) di level
top-of-file akan gagal parse saat pertama kali di-load dari command line.

**Pattern yang aman untuk game baru (tidak butuh editor setup):**

```gdscript
# BENAR — member var untyped
var gs  # GameState

# BENAR — walrus hanya untuk built-in types atau literal
var count := 0
var name := ""

# BENAR — ScenarioRunner via load() bukan class_name
# Ganti "scripts" dengan direktori aktual di project Anda (src/global/, source/common/framework/, dll)
var exit_code = await load("res://scripts/ScenarioRunner.gd").new().run_scenario_file(path)

# BENAR — jangan trigger --shot dari _ready()
func _ready() -> void:
    pass  # ErrorTracker mendeteksi --shot via Autoload bootstrap
```

**Untuk codebase yang sudah ada dengan banyak class_name references:**
Membutuhkan one-time setup per mesin — buka Godot editor untuk project tersebut,
jalankan game sekali dari editor (F5), tutup editor. Setelah itu harness berjalan
autonomous selamanya di mesin tersebut karena dependency graph internal ter-compile
dalam format yang dibaca oleh GDScript runtime (berbeda dari `global_script_class_cache.cfg`).

Ini bukan "buka editor manual sebagai workaround" — ini adalah Godot engine requirement
untuk membangun dependency graph yang hanya bisa dibangun saat game runtime dengan display.
Tidak ada CLI flag yang menghasilkan efek yang sama karena proses ini membutuhkan renderer
aktif untuk menjalankan scene tree dan men-trigger full script compilation chain.

---

## Panduan Timing _write_game_state()

Kapan hook ini dipanggil menentukan apakah data yang ditulis representatif atau tidak.

### Pola yang Benar

`gdscript
# Di main.gd atau scene utama
func _ready() -> void:
    var args := OS.get_cmdline_user_args()
    if "--shot" in args:
        # Tunggu satu frame agar semua sistem selesai inisialisasi
        await get_tree().process_frame
        _write_game_state()   # tulis SETELAH inisialisasi
        _shot_tour()          # lalu navigasi layar

# Di _shot_tour(), tulis ulang setiap kali state berubah signifikan
func _shot_tour() -> void:
    # Ambil screenshot main menu
    _take_screenshot("01_main_menu")
    _write_game_state()          # state di main menu

    # Masuk gameplay
    get_tree().change_scene_to_file("res://scenes/game.tscn")
    await get_tree().process_frame
    await get_tree().process_frame   # tunggu scene selesai load
    _write_game_state()              # state di awal gameplay

    get_tree().quit()
`

### Kesalahan Umum

| Kesalahan | Akibat | Solusi |
|---|---|---|
| Dipanggil sebelum wait get_tree().process_frame | Sistem belum inisialisasi — nilai default/null | Tambahkan minimal 1 frame await |
| Dipanggil setelah get_tree().quit() | File tidak ditulis | Panggil sebelum quit |
| Hanya dipanggil sekali di awal | State tidak mencerminkan layar saat ini | Panggil ulang setelah setiap scene change |
| Tidak dipanggil di --shot mode | game_state.json tidak ada | Tambahkan conditional check if "--shot" in args |

### Prinsip

- Tulis state **setelah** scene dan sistem selesai inisialisasi
- Tulis ulang state **sebelum** setiap screenshot penting
- Jangan tulis state setelah sistem mulai cleanup/free
- game_state.json mencerminkan state pada momen terakhir _write_game_state() dipanggil
## Arsitektur Telemetry

Framework menggunakan pendekatan **progressive capability** — berjalan dari fase prototype
tanpa membutuhkan implementasi apapun di game, dan secara otomatis memanfaatkan data
tambahan seiring game berkembang.

```
Layer 0 — state.json (selalu ada)
  Ditulis oleh harness. Berisi: project_name, timestamp, png_count,
  telemetry_phase, daftar screenshots.

Layer 1 — game_state.json (opsional, ditulis game)
  Ditulis oleh game saat --shot mode via _write_game_state().
  Format bebas. Jika ada: telemetry_phase = mature.
  Di-embed ke shots-manifest.json untuk konteks AI.

shots-manifest.json (output harness)
  Gabungan Layer 0 + Layer 1. Dibaca oleh semua AI commands.
```

### Fase telemetry

| Fase | Kondisi | Kemampuan AI |
|---|---|---|
| `prototype` | Belum ada PNG, belum ada game_state | Screenshot tour, harness run |
| `developing` | Ada PNG, belum ada game_state | Visual QA, baseline, regression |
| `mature` | Ada PNG dan game_state | Semua di atas + assertion, scenario testing |

---

## Komponen Engine-Specific vs Universal

Framework ini memisahkan komponen yang bergantung pada engine tertentu dari komponen yang
benar-benar universal. Penting dipahami sebelum menggunakan framework di engine non-Godot.

### Komponen Universal (tidak perlu modifikasi untuk engine apapun)

| Komponen | Lokasi | Keterangan |
|---|---|---|
| isual-diff.ps1 | 	ools/ | Bekerja pada PNG dari engine apapun |
| shots-manifest.json schema | output harness | JSON universal, schema_version tracked |
| ignore_regions + egion_thresholds | shots.zoom.json | Konfigurasi per-project, engine-agnostic |
| Baseline management | aseline/ di ShotsDir | Tidak tahu engine apa yang menghasilkan PNG |
| Command /shot | command/shot.md | Membaca PNG dari folder, tidak peduli engine |
| Command /analisis-shot | command/analisis-shot.md | Membaca manifest + PNG |
| Command /baseline | command/baseline.md | Memanggil isual-diff.ps1 |
| Scenario templates JSON | scenarios-templates/ | Format JSON universal |
| Game-state template schema | konsep Layer 1 | JSON bebas format |
| AGENTS.md global rules | AGENTS.md | Berlaku di semua project |

### Komponen Godot-Specific (butuh adapter untuk engine lain)

| Komponen | Alasan Godot-specific | Adapter yang dibutuhkan |
|---|---|---|
| shot-harness.ps1 | Parse project.godot, invoke godot --path | shot-harness-unity.ps1, shot-harness-unreal.ps1 |
| ScenarioRunner.gd | GDScript 4 API, Godot InputMap, InputEvent* | ScenarioRunner.cs (Unity), custom per engine |
| Game-state templates .gd | GDScript 4 syntax | Template .cs untuk Unity |
| --shot flag convention | Diimplementasikan di kode Godot | Equivalent per engine |

### Cara Menambahkan Engine Baru

Untuk menggunakan framework di engine lain, yang perlu dibuat adalah:

1. **Harness adapter** — script yang:
   - Menjalankan game dalam mode screenshot
   - Menghasilkan PNG ke folder output yang dapat dikonfigurasi
   - Menulis game_state.json ke folder yang sama (opsional — Layer 1)
   - Menulis shots-manifest.json dengan schema yang sama (schema_version: 1.1)

2. **ScenarioRunner equivalent** — komponen yang:
   - Membaca file scenario JSON dengan format yang sama
   - Mengeksekusi step types yang didukung
   - Menulis scenario_result.json ke output folder

Semua komponen analisis (visual-diff, baseline, AI commands) langsung bekerja tanpa modifikasi.

### Adapter yang Tersedia

| Engine | Harness | ScenarioRunner | Status |
|---|---|---|---|
| Godot 4 | shot-harness.ps1 | ScenarioRunner.gd | ✅ Production-ready |
| Unity | shot-harness-unity.ps1 | belum ada | ✅ Harness tersedia di tools/ |
| Unreal Engine | belum ada | belum ada | 📋 Planned |
| Custom engine | buat sendiri sesuai spec | buat sendiri | 📋 Spec tersedia di atas |
## CI/CD Integration (GitHub Actions)

Template workflow tersedia di `<KILO_CONFIG>/ci-templates/.github/workflows/`.
Salin ke `.github/workflows/` project kamu menggunakan `/ci-setup`.

| Template | Trigger | Deskripsi |
|---|---|---|
| `godot-screenshot.yml` | push, PR | Screenshot tour + visual regression vs baseline |
| `godot-scenario-test.yml` | push, PR | Automated scenario testing (smoke, save_load, dll) |
| `godot-autonomous-qa.yml` | schedule, manual | Autonomous QA loop harian |

### Setup CI di project baru

```powershell
# Salin semua workflow templates (dan sesuaikan GAME_NAME + GODOT_VERSION)
/ci-setup
```

Atau manual:
```bash
mkdir -p .github/workflows
cp "<KILO_CONFIG>/ci-templates/.github/workflows/*.yml" .github/workflows/
```

Lihat `ci-templates/README.md` untuk panduan lengkap termasuk baseline management dan artifact retention.
## Kompatibilitas

| Aspek | Status |
|---|---|
| Engine | Godot 4 (harness + ScenarioRunner). Unity: shot-harness-unity.ps1 tersedia. Unreal: planned. |
| OS | Windows (PowerShell). Linux/Mac: port tools ke bash/sh |
| Genre | Semua genre — templates tersedia untuk RPG, strategy, platformer, puzzle |
| Kilo version | `@kilocode/plugin >= 7.4.x` |

---

## Manifest Schema Versioning

`shots-manifest.json` menggunakan field `schema_version` untuk tracking format:

| Versi | Deskripsi |
|---|---|
| `1.1` | Format saat ini. Fields: `schema_version`, `generated_at`, `telemetry_phase`, `shots_dir`, `project_name`, `png_count`, `screenshots`, `game_state`, `baseline_age_days` |

Bump `schema_version` di `shot-harness.ps1` setiap kali format manifest berubah secara breaking.
## intentional_changes — Tandai Perubahan Visual yang Disengaja

Buat file `visual-diff-ignore.json` di root project, lalu pass ke harness atau visual-diff
dengan flag `-IgnoreConfig`:

```powershell
& "$env:USERPROFILE\.config\kilo\tools\visual-diff.ps1" `
    -ShotsDir $shotsDir -BaselineDir $baselineDir `
    -IgnoreConfig "C:\path\to\visual-diff-ignore.json"
```

Format config mendukung **dua gaya** untuk `intentional_changes`:

**Gaya 1 — String sederhana (direkomendasikan untuk menandai layar battle/animasi):**
```json
{
  "intentional_changes": [
    "04_battle.png",
    "battle_*.png"
  ]
}
```

**Gaya 2 — Object dengan reason dan version (untuk audit trail):**
```json
{
  "intentional_changes": [
    { "src": "01_title.png", "reason": "Redesign title screen v0.21", "version": "0.21" },
    { "src": "battle_*.png", "reason": "Updated battle UI layout" }
  ]
}
```

File yang match akan mendapat status `INTENTIONAL` di diff-report.json alih-alih `REGRESI`.
Tidak masuk ke counter `regressions` — tidak memblokir CI.
Field `src` mendukung wildcard. Field `version` opsional (hanya untuk gaya object).

**Kapan menggunakan intentional_changes:**
- Layar dengan animasi sprite idle yang non-deterministik antar-render (Godot Vulkan renderer)
- Layar yang sengaja diubah di build ini — tandai agar tidak terdeteksi sebagai regresi tak terduga
- Layar dengan partikel, shadow, atau anti-aliasing yang berbeda tiap run

---

## ignore_regions — Kurangi False Positive Regression

Tambahkan ke `visual-diff-ignore.json` di root project:

```json
{
  "ignore_regions": [
    { "src": "01_main_menu.png", "x": 650, "y": 10, "w": 70, "h": 20, "reason": "timestamp" },
    { "src": "*", "x": 0, "y": 0, "w": 50, "h": 20, "reason": "fps counter" }
  ]
}
```

Field `src` mendukung wildcard `"*"` untuk semua screenshot.
Butuh ImageMagick untuk fitur ini — fallback ke MD5 hash jika tidak tersedia.

## region_thresholds — Threshold Berbeda per File

Untuk file tertentu yang secara alami punya variasi pixel lebih besar (misalnya layar dengan
animasi aktif), gunakan threshold berbeda dari default global (1%):

```json
{
  "region_thresholds": [
    { "src": "18_disabled_reason.png", "threshold": 3.0 },
    { "src": "battle_*.png", "threshold": 5.0 }
  ]
}
```

Semua field bisa digabung dalam satu file `visual-diff-ignore.json`:

```json
{
  "intentional_changes": ["04_battle.png", "04_seal_tip.png"],
  "region_thresholds": [
    { "src": "18_disabled_reason.png", "threshold": 3.0 }
  ],
  "ignore_regions": [
    { "src": "*", "x": 0, "y": 0, "w": 50, "h": 20, "reason": "fps counter" }
  ]
}
```

---

## Deteksi Hang vs Slow

`shot-harness.ps1` membedakan tiga kondisi saat game berjalan:

| Kondisi | Indikator | Exit |
|---|---|---|
| Normal | Game selesai dalam timeout | `ok` |
| Slow | Ada PNG dihasilkan tapi tidak selesai | `timeout_slow` |
| Hang | Tidak ada PNG + CPU ~0% | `timeout_hang` |

Tambahkan `-Timeout <detik>` jika game memang lambat secara normal.

---

## Fix-Loop Otonom (`-FixLoopMode`)

`run-and-analyze.ps1` mendukung mode fix-loop yang menjalankan verifikasi patch AI secara terisolasi.

```powershell
& "$env:USERPROFILE\.config\kilo\tools\run-and-analyze.ps1" `
    -ProjectPath "C:\dev\mygame" `
    -FixLoopMode `
    -PatchBranch "fix/bug-scene-value" `
    -FixRequestPath "fix-request.json"
```

### Alur fix-loop

1. **Worktree provisioning** — patch di-checkout ke git worktree terisolasi (`_worktree_<branch>`)
2. **`--import`** — Godot dijalankan dengan `--import` di worktree agar `.godot/` terisi sebelum scenario dieksekusi
3. **Gate protected-file** — verifikasi bahwa patch tidak menyentuh file verifikasi itu sendiri
4. **Scope constraint** — verifikasi bahwa patch hanya menyentuh file yang diizinkan di `fix-request.json`
5. **Scenario run** — scenario dijalankan di worktree; hasil dibandingkan dengan `ts_run` (guard stale result)
6. **Visual diff** — screenshot before/after dibandingkan; path PNG dicatat di laporan
7. **Cleanup** — worktree dihapus setelah selesai, baik gate pass maupun fail

### Gate protected-file dan `-ProtectedPatterns`

Gate memblokir patch yang menyentuh file verifikasi sendiri — skenario "AI melumpuhkan alat ukurnya sendiri".

**Default protected patterns** (built-in, selalu aktif):
```
scenarios/*
scenarios/*/*
shots.zoom.json
visual-diff-ignore.json
*ScenarioRunner.gd
*GameStateWriter.gd
*ErrorTracker.gd
```

Pola `*ScenarioRunner.gd` (tanpa komponen direktori) cocok dengan path apa pun yang berakhiran
nama file tersebut, terlepas dari layout folder project:
- `scripts/ScenarioRunner.gd` — layout default
- `source/scripts/ScenarioRunner.gd` — godot-open-rts
- `src/global/ScenarioRunner.gd` — bread-adventure
- `source/common/framework/ScenarioRunner.gd` — godot-tiny-mmo

Pola berbasis direktori seperti `*scripts/ScenarioRunner.gd` **tidak aman** karena mensyaratkan
direktori induk bernama persis "scripts" — layout non-standar akan lolos gate tanpa terdeteksi.

**Override per kasus dengan `-ProtectedPatterns`:**
```powershell
& "$env:USERPROFILE\.config\kilo\tools\run-and-analyze.ps1" `
    -ProjectPath "C:\dev\mygame" `
    -FixLoopMode -PatchBranch "fix/my-bug" `
    -ProtectedPatterns @("*MyCustomRunner.gd", "tests/*")
```

`-ProtectedPatterns` **ditambahkan** ke daftar default, bukan menggantikannya. Untuk menutup
lubang di project dengan layout non-standar, tambahkan pola spesifik project via parameter ini.

Jika gate terpicu: laporan akan berisi `overall_status: escalation_required` dan exit code 1 —
loop berhenti dan menunggu approval manual sebelum patch diaplikasikan.

### `-PatchRef` auto-wiring dari `-PatchBranch`

`-PatchRef` tidak perlu ditentukan secara eksplisit. Jika `-PatchBranch` diberikan,
`run-and-analyze.ps1` secara otomatis menyusun `PatchRef = "master..<branch>"` untuk
dipakai sebagai dua-ref diff di gate protected-file. Ini memastikan gate membandingkan
patch terhadap base branch yang benar tanpa membutuhkan input tambahan dari orchestrator.

Output konfirmasi di log: `Gate mode: two-ref diff (master..<branch>)`.

Jika `-PatchRef` ditentukan secara eksplisit, nilai tersebut dipakai langsung (override
auto-wiring). Jika keduanya tidak ada (non-FixLoopMode), gate memakai single-ref diff
terhadap working tree.

### Status `overall_status`

| Nilai | Kondisi |
|---|---|
| `clean` | Gate pass, scenario pass, tidak ada critical issue |
| `run_failed` | Scenario timeout, error, atau hasil `scenario_result.json` basi (file tidak diperbarui setelah run) |
| `issues_found` | Ada critical issue dari analisis (visual regression, dll) |
| `escalation_required` | Gate protected-file atau scope violation — butuh approval manual |

---

## Known Limitations — Fix-Loop Worktree (`--import` timeout)

**Pre-population `.godot/imported/` tidak menghilangkan timeout `--import` di worktree.**

Fix-loop menyalin seluruh direktori `.godot/imported/` dari `ProjectPath` ke worktree sebelum
menjalankan `--import`, dengan tujuan menghindari re-import lambat di headless run. Mekanisme
salin berhasil (terverifikasi: 770 file tersalin untuk godot-open-rts), namun `--import` di
worktree tetap timeout pada project yang sama.

**Root cause yang paling mungkin:** `git checkout` saat provisioning worktree me-reset `mtime`
semua file ke waktu checkout. Godot menggunakan `mtime` untuk mendeteksi apakah file source
berubah sejak cache dibuat — karena `mtime` file sumber di worktree lebih baru dari `mtime`
file cache yang disalin, Godot menganggap semua resource perlu di-import ulang.

**Konsekuensi praktis:**
- `--import` di worktree berjalan seperti project baru, bukan memanfaatkan cache.
- Untuk project dengan banyak resource (audio, texture, shader), ini bisa timeout 60 detik.
- Jika timeout terjadi, framework melanjutkan tanpa `.godot/` yang lengkap dan
  mencatat `proses Godot dibunuh, lanjutkan tanpa .godot/` di log.

**Workaround saat ini:**
Naikkan timeout `--import` lewat parameter internal (belum diekspos sebagai parameter publik).
Untuk project yang sangat besar, pertimbangkan menjalankan editor Godot sekali di worktree
sebelum menjalankan fix-loop, atau tambahkan `-Timeout` yang lebih besar ke `shot-harness.ps1`.

**Status:** Diketahui sejak audit 2026-07-28. Perbaikan yang tepat membutuhkan
touch `mtime` file cache setelah disalin agar lebih baru dari file sumber di worktree,
atau melewati `--import` sama sekali untuk project yang sudah punya full cache.
