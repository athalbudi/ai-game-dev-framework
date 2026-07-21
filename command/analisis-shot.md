---
description: Analisis screenshot game terbaru dari disk (tanpa perlu attach manual)
---

## Langkah 0: Discover ShotsDir

Baca `shots-manifest.json` di working directory untuk mendapatkan ShotsDir dan konteks:
- `shots_dir` — path folder shots aktif (gunakan ini di semua langkah berikutnya)
- `project_name` — nama project
- `telemetry_phase` — fase game (prototype / developing / mature)

Jika `shots-manifest.json` tidak ada di working directory:
- Jalankan harness dulu: `& "$env:USERPROFILE\.config\kilo\tools\shot-harness.ps1" -ProjectPath <working_directory>`
- Atau minta user jalankan `/shot` untuk refresh

## Langkah 1: Baca Game State Telemetry

Dari manifest, ekstrak informasi berikut sebagai konteks analisis:
- `generated_at` — kapan harness terakhir dijalankan
- `game_state` — snapshot state game (null jika game belum menulis game_state.json)
- `screenshots` — daftar file PNG yang dihasilkan
- `assertion_results` — hasil validasi assertion deterministik (jika game menulis assertions)
- `scenario_result` — hasil test scenario runner (jika game dijalankan dengan --scenario)
- `coverage` — shot tour coverage tracker (screen mana yang tidak punya PNG)

Gunakan `game_state` untuk mengkontekstualisasi temuan visual:
- Label kosong → cek apakah memang kosong di state tertentu, bukan bug
- UI tidak muncul → cek apakah kondisi game memang tidak memicu elemen tersebut

Gunakan `assertion_results` untuk laporan pass/fail yang deterministik:
- Sebutkan berapa assertion pass dan berapa fail
- Untuk setiap failure: sebutkan id, description, actual vs expected
- Assertion fail adalah bug yang sudah terkonfirmasi — prioritaskan dalam analisis

Gunakan `scenario_result` jika ada:
- Sebutkan scenario_id, status (pass/fail/timeout), dan durasi
- Untuk setiap step yang fail: sebutkan id dan note
- Step fail mengindikasikan bug yang bisa direproduksi — tandai sebagai temuan kritis

Gunakan `coverage` untuk mendeteksi gap:
- Jika ada screen di `uncovered`: sebutkan bahwa coverage shot tour tidak lengkap
- Ini bukan bug visual, tapi gap dalam observability

Jika `telemetry_phase` adalah prototype atau developing: data yang belum ada adalah normal.

Jika `shots-manifest.json` tidak ada, lanjut ke Langkah 2 tanpa konteks state.

## Langkah 2: Cek Visual Diff (jika baseline tersedia)

Cek apakah ada `diff\diff-report.json` di ShotsDir (baca ShotsDir dari manifest).

Jika ada, baca laporan diff dan prioritaskan analisis pada file dengan status `REGRESI` atau `BERUBAH`.
File dengan status `OK` tidak perlu dianalisis kecuali ada alasan khusus.

Jika tidak ada diff-report, analisis semua screenshot.

## Langkah 3: Baca Screenshot

Gunakan `filesystem_read_media_file` (BUKAN `Read`) untuk membaca setiap file PNG dari ShotsDir.

**WAJIB: Baca SEMUA screenshot yang relevan terlebih dahulu sebelum menulis analisis apapun.**

Urutan yang benar:
1. List semua file PNG di ShotsDir (kecuali `zoom_*` dan `diff_*`)
2. Filter berdasarkan diff-report jika ada (prioritaskan REGRESI/BERUBAH)
3. Baca maksimal 6 file per batch secara paralel menggunakan `filesystem_read_media_file`
4. Tunggu setiap batch selesai ter-attach sebelum lanjut ke batch berikutnya
5. Setelah SEMUA batch selesai, baru tulis analisis menyeluruh mencakup:
   - UI/UX — keterbacaan, layout, konsistensi visual
   - Game feel — feedback visual, animasi, efek
   - Konten — teks, ikon, elemen desain
   - Bug atau artefak visual yang terlihat
   - Kontekstualisasi dengan game_state jika tersedia
   - Saran perbaikan konkret berdasarkan apa yang terlihat di screenshot

Jangan menulis analisis di tengah proses pembacaan — ini menyebabkan klaim yang tidak bisa
dipertanggungjawabkan karena sebagian gambar belum ter-delivered ke model.

$ARGUMENTS
