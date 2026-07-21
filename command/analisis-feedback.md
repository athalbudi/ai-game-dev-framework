---
description: Analisis feedback playtester menggunakan feedback-bridge untuk menghubungkan keluhan ke screenshot, komponen UI, dan lokasi kode.
---

## Cara Pakai

```
/analisis-feedback <path_file_feedback>
/analisis-feedback build/PLAYTEST-FEEDBACK-20-PEMAIN-B04.txt
```

## Langkah 0: Jalankan feedback-bridge v1.1

```powershell
& "$env:USERPROFILE\.config\kilo\tools\feedback-bridge.ps1" `
    -FeedbackFile "$ARGUMENTS" `
    -ProjectPath (Get-Location).Path `
    -MinScore 2 `
    -OutputJson 2>$null | Out-File "$env:TEMP\bridge-result.json" -Encoding utf8

$bridge = Get-Content "$env:TEMP\bridge-result.json" -Raw | ConvertFrom-Json
```

**Mode otomatis berdasarkan format file:**
- File dengan delimiter `--- Profil N ---`: mode **frequency weighting** (hitung per profil)
- File tanpa delimiter: mode **keyword count** (fallback, B01/B02/B03)

**Parameter tambahan jika diperlukan:**
- `-MinProfil 2` — filter isu yang muncul di minimal N profil
- `-ProfileDelimiter "--- Profil"` — kustomisasi delimiter jika berbeda
- `-TopN 10` — jumlah isu maksimum di output
- `-Verbose` — tampilkan detail keyword per komponen

Jika `screen-index.json` belum ada di project root, buat dulu berdasarkan kode game.

## Langkah 1: Baca Feedback

Baca file feedback lengkap:
- Hitung berapa profil (`total_profil` dari bridge result)
- Identifikasi pola yang berulang (muncul di 3+ profil atau >30% profil)
- Catat masalah unik yang signifikan meski hanya 1 profil

## Langkah 2: Interpretasi bridge result

### Untuk file dengan format profil (B04+)
Gunakan `profil_count` dan `profil_pct` sebagai primary signal:
- `≥ 60%` profil → KRITIS
- `30–59%` profil → TINGGI
- `10–29%` profil → SEDANG
- `< 10%` profil → rendah / perlu cek manual

### Untuk file tanpa delimiter (B01/B02/B03)
Gunakan `score` sebagai proxy frekuensi:
- `score ≥ 6` → KRITIS
- `score 4–5` → TINGGI
- `score 2–3` → SEDANG

### Cek resolution_status
Jika issue punya `resolution` field di bridge result:
- `resolved` → flag sebagai "expected resolved — verifikasi apakah masih muncul"
- `persistent` → flag sebagai "diketahui belum diperbaiki"
- `ambiguous` → perlu analisis kualitatif lebih lanjut

## Langkah 3: Verifikasi kode (wajib untuk setiap klaim)

Untuk setiap issue yang terdeteksi:
- Baca fungsi terkait di `render_files` yang disebutkan bridge
- Konfirmasi: apakah implementasinya memang seperti yang dikeluhkan?
- Jangan tulis "bug" atau "gap" jika belum verifikasi di kode

## Langkah 4: Baca screenshot jika tersedia

Jika `shot_paths` tidak kosong:
- Gunakan `filesystem_read_media_file` untuk setiap PNG
- Baca semua screenshot relevan sebelum menulis analisis visual
- Jangan tulis analisis visual jika screenshot tidak tersedia

## Langkah 5: Klasifikasi per issue (untuk B04+)

Untuk setiap issue yang punya probe question di feedback:
- Hitung profil yang menunjukkan **resolution signal** vs **persistence signal** vs **learned behavior signal**
- Klasifikasikan sebagai:
  - `RESOLVED` — mayoritas profil menunjukkan resolution signal
  - `PERSISTENT` — mayoritas profil masih menunjukkan persistence signal
  - `AMBIGUOUS` — campuran, perlu analisis kualitatif
  - `LEARNED_BEHAVIOR` — masalah hilang karena pemain adaptive, bukan karena diperbaiki

## Langkah 6: Format laporan

```
## Analisis Feedback [Nama Batch] — [Build]

### Ringkasan
- N profil, M masalah teridentifikasi (mode: frequency weighting / keyword count)
- Top issues: ...

### Masalah Per Prioritas

#### [KRITIS] Nama Masalah  [N/M profil = X%] [STATUS: RESOLVED/PERSISTENT/AMBIGUOUS]
- Frekuensi: N/M profil
- Screen: xxx | Komponen: yyy | File: zzz
- Verifikasi kode: [apa yang ditemukan di source]
- Screenshot: [deskripsi visual jika ada]
- Klasifikasi: RESOLVED / PERSISTENT / AMBIGUOUS / LEARNED_BEHAVIOR
- Rekomendasi: ...

#### [TINGGI] Nama Masalah
...

### Gap Fitur (Belum Ada di Build Ini)
- Masalah yang membutuhkan fitur baru, bukan hanya perbaikan

### Sudah Resolved (Verifikasi)
- Masalah yang diharapkan resolved — konfirmasi dari feedback batch ini

### Tidak Perlu Diubah
- Masalah yang ternyata sudah benar / persepsi yang salah dari pemain

### Catatan untuk Framework
- Gap atau keterbatasan bridge yang ditemukan selama analisis ini
- Keyword baru yang perlu ditambahkan ke screen-index.json
- Screenshot baru yang perlu ditambahkan ke shot_files
```

## Langkah 7: Update screen-index.json (jika ada temuan baru)

Setelah analisis selesai, update `screen-index.json` di project root:
- Tambah keyword baru ke komponen yang relevan
- Tambah komponen baru jika ada layar/fitur yang belum ter-index
- Update `resolution_status` pada global issues yang terkonfirmasi resolved/persistent
- Catat gap baru ke `known_gaps`

$ARGUMENTS
