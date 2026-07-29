## Handoff — 2026-07-29

Status: tree bersih, repo ↔ deployed sinkron, **36/36 PASS**, sudah di-push ke publik.

Framework kini bernama **Saksi** — https://github.com/athalbudi/saksi (MIT).
Nama tampilan sudah diganti; identifier fungsional (`~/.config/kilo`, penanda blok,
`gamedev-framework.md`, `.kilo/command/`, `KILO_GAMES_DIR`) sengaja TIDAK diubah.
Alasannya di `FRAMEWORK.md` bagian "Catatan penamaan — JANGAN dirapikan".

### Selesai di sesi ini

**Layer 0 — bootstrap** (`setup.ps1`, `tools/doctor.ps1`, `VERSION`, `tools/_common.ps1`)

Sebelumnya tidak ada dokumentasi yang menyebut `sync.ps1` sama sekali — pengguna yang clone
dari GitHub tidak punya cara tahu langkah itu harus dijalankan. `setup.ps1` menjalankan
9 langkah: cek PowerShell, unblock `.ps1`, deteksi Godot/ImageMagick, healthcheck pra-sync,
sync, healthcheck pasca-sync, lalu tulis `version.json`.

Urutan verifikasi-sebelum-stamp disengaja: `version.json` adalah sinyal yang dibaca hook
`AGENTS.md`. Kalau ditulis sebelum verifikasi, instalasi gagal meninggalkan stamp menyesatkan.

**Layer 1 — distribusi aturan agent** (`agent-rules/`, `setup.ps1 -InstallAgentRules`)

Opt-in, menulis penunjuk pendek ke `~/.kilocode/rules/` dan `~/.claude/CLAUDE.md`
(blok bertanda BEGIN/END, idempoten, bisa dicabut). Yang dipasang bukan salinan `AGENTS.md`
melainkan penunjuk ~20 baris yang diam kalau tidak ada `project.godot`.

**`-InitProject`** — integrasi project game, dengan patch `project.godot` defensif:
backup, preview, idempoten, dan berhenti total saat nama autoload bentrok.

### Bug yang ditemukan lewat pengujian jalur nyata

Semuanya luput dari suite dan hanya muncul saat menjalankan alur pengguna sungguhan:

1. **`exit 0` hilang di 5 tool** — `$LASTEXITCODE` berisi nilai sisa setelah run sukses.
   Ditemukan saat dogfood clone-segar → setup → harness pada game nyata.
2. **`try/catch` yang tidak pernah aktif** di `autonomous-qa.ps1` dan `run-and-analyze.ps1` —
   `exit 1` dari script yang dipanggil dengan `&` tidak melempar exception, jadi harness
   yang gagal tercatat `phase1 = "ok"` di laporan JSON.
3. **`user://` ditebak dari nama direktori** di `feedback-bridge.ps1` — benar hanya di 1 dari
   4 game validasi, dan itu pun kebetulan. Logika ini terduplikasi di 4 tempat; 3 benar,
   1 tertinggal.
4. **Crash pada konfigurasi satu-agent** — PS 5.1 meng-unroll array yang di-return fungsi.
5. **Data loss** saat penanda BEGIN/END tidak berpasangan.
6. **Path absolut mesin maintainer** di `test-pipeline.ps1` — membuat TEST 9/10 diam-diam
   ter-skip di mesin lain sambil tetap melapor hijau.

Pola berulang: konvensi baru diterapkan di kode baru, salinan lama tertinggal — dan fixture
yang meniru lingkungan sendiri menyembunyikan bug.

### Audit mendalam terakhir (4 bug, semuanya lolos dari suite hijau)

1. `-InitProject` mengonversi CRLF→LF seluruh `project.godot` pengguna — git diff jadi
   menampilkan semua baris berubah. EOL kini dideteksi dan dipertahankan.
2. Blok penanda di `CLAUDE.md` menghasilkan line ending campur.
3. `doctor.ps1` bisa **lulus vakum**: hanya mencari tanda gagal di stderr, sehingga Godot
   yang gagal start dilaporkan "11 template bersih". Kini butuh bukti positif (`RESULT`
   tercetak + jumlah COMPILE_OK menutupi semua template).
4. Deteksi Godot melewatkan versi selain 4.7 — glob hanya `*win64_console.exe` di `C:\Godot`.
   Kini pencarian version-agnostic di 4 lokasi, build `_console` tetap didahulukan.

Tiga dugaan diperiksa dan ternyata BUKAN bug (jangan diaudit ulang): path berbracket,
exit code kosong pada `-InitProject`, dan CRLF di blob repo — yang ketiga adalah kesalahan
pengukuran (`grep -c $'\r'` mencocokkan pola kosong). Verifikasi byte-level: CR=0.

### Belum selesai

- Aturan agent belum dipasang ke config asli maintainer (`-InstallAgentRules` belum dijalankan)
- Kebijakan bump `VERSION` belum ada (masih `0.1.0`) — repo sudah publik, jadi ini momen
  wajar untuk memutuskan angka itu berarti apa
- Enam step type (`mouse_click`, `touch_tap`, `controller_press`, `wait_signal`, `assert_fps`,
  `assert_screenshot_exists`) SUDAH terimplementasi di `ScenarioRunner.gd`, tapi **nol test
  menjalankannya**. Template `input_methods.json` sudah publik, jadi orang akan menyalinnya
  dan berasumsi semuanya bekerja. Ini celah cakupan terbesar yang tersisa.
- `docs/token-efficiency.md` ada secara lokal tapi di-gitignore (berisi kuota/pengukuran
  pribadi) — tidak akan terlihat di clone baru
- Compile-check terduplikasi di `tools/doctor.ps1` dan TEST 17 — ubah satu, harus ubah keduanya
- Enam step type scenario (`assert_fps`, `assert_screenshot_exists`, `controller_press`,
  `mouse_click`, `touch_tap`, `wait_signal`) punya template di `scenarios-templates/input_methods.json`
  tapi implementasi behavioral di `ScenarioRunner.gd` belum ada (gap pre-existing)

### Catatan: TEST 19 adalah syarat tegas

TEST 19 FAIL di mesin tanpa keempat game validasi kecuali `KILO_GAMES_DIR` di-set.
Default: `%USERPROFILE%\Documents\games\`. SKIP dihitung FAIL — lebih jujur daripada PASS palsu.

### File yang perlu dibaca di sesi berikutnya

`setup.ps1`, `tools/_common.ps1`, `tools/doctor.ps1`, `AGENTS.md`, dan `git log --oneline -15`.
