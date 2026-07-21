---
description: >
  Kelola baseline screenshot untuk visual regression testing.
  Contoh: /baseline set | /baseline diff | /baseline status | /baseline reset | /baseline history
---

Kamu mengelola baseline screenshot untuk visual regression testing.

## Discover ShotsDir

Baca ShotsDir dari `shots-manifest.json` di working directory:
- Field `shots_dir` = path folder shots aktif
- BaselineDir = `<shots_dir>\baseline\`
- HistoryDir = `<shots_dir>\baseline\history\`

Jika manifest tidak ada, minta user jalankan harness dulu atau berikan path ShotsDir eksplisit.

## Perintah yang didukung

### /baseline set
Salin semua PNG terbaru dari ShotsDir ke BaselineDir sebagai referensi baru.
Sebelum menimpa baseline lama, archive baseline aktif ke history (maks 5 snapshot).
Gunakan setelah build stabil — ini "mengunci" tampilan yang benar sebagai acuan.

Langkah:
1. Baca ShotsDir dari manifest
2. Pastikan ShotsDir ada dan berisi PNG terbaru (jalankan harness dulu jika perlu)
3. **Archive baseline lama ke history** (jika baseline aktif sudah ada):
   a. Buat folder `baseline\history\` jika belum ada
   b. Buat subfolder dengan timestamp: `baseline\history\YYYYMMDD_HHMMSS\`
   c. Salin semua file dari `baseline\` (kecuali folder `history\`) ke subfolder tersebut
   d. **Prune history**: hapus snapshot terlama jika sudah lebih dari 5 snapshot
4. Buat folder `baseline\` jika belum ada
5. Salin semua `*.png` dari ShotsDir ke BaselineDir (SKIP file `zoom_*` dan `diff_*`)
6. Tulis `baseline-manifest.json` di BaselineDir dengan isi:
   ```json
   {
     "baseline_set_at": "<timestamp ISO>",
     "png_count": <jumlah file>,
     "set_from_shots_dir": "<ShotsDir>"
   }
   ```
7. Laporkan: berapa file disalin, path baseline, timestamp, berapa snapshot di history

### /baseline diff
Jalankan visual diff antara screenshot terbaru vs baseline.

Langkah:
1. Baca ShotsDir dari manifest
2. Jalankan script `visual-diff.ps1`:
```powershell
& "$env:USERPROFILE\.config\kilo\tools\visual-diff.ps1" `
    -ShotsDir "<shots_dir dari manifest>"
```
3. Baca `diff\diff-report.json` dari ShotsDir
4. Laporkan ringkasan: berapa OK, berapa regresi, berapa file baru/hilang
5. Untuk setiap regresi: sebutkan nama file dan persentase perubahan
6. Jika ada regresi ❌ → delegasikan ke agent `visual-qa` untuk analisis visual detail

### /baseline diff --against <snapshot>
Diff vs snapshot history tertentu (bukan baseline aktif).

Langkah:
1. Baca ShotsDir dari manifest
2. Jalankan `visual-diff.ps1` dengan flag `-Against`:
```powershell
& "$env:USERPROFILE\.config\kilo\tools\visual-diff.ps1" `
    -ShotsDir "<shots_dir>" `
    -Against "<snapshot>"
```
   Ganti `<snapshot>` dengan nama subfolder dari `/baseline history` (contoh: `20260719_143245`)
3. Laporkan seperti `/baseline diff` biasa, tapi sebutkan snapshot mana yang dijadikan referensi

### /baseline history
Tampilkan daftar snapshot history yang tersedia.

Langkah:
1. Baca ShotsDir dari manifest → HistoryDir = `<shots_dir>\baseline\history\`
2. Cek apakah HistoryDir ada
3. List semua subfolder, sort descending (terbaru di atas)
4. Untuk setiap subfolder:
   - Tampilkan nama (= timestamp): `20260719_143245`
   - Baca `baseline-manifest.json` di subfolder jika ada
   - Tampilkan jumlah PNG di folder tersebut
5. Laporkan total snapshot
6. Hint: gunakan `/baseline diff --against <nama>` untuk diff vs snapshot ini

### /baseline log <pesan>
Catat alasan perubahan baseline ke changelog. Berguna untuk audit trail.

Langkah:
1. Baca ShotsDir dari manifest
2. Tambahkan entry ke file <BaselineDir>\baseline-changelog.json:
   - 	imestamp: waktu sekarang
   - message: pesan dari argumen
   - snapshot: nama snapshot aktif (dari baseline-manifest.json jika ada)
   - png_count: jumlah PNG di BaselineDir saat ini
3. Tampilkan konfirmasi: pesan yang dicatat + total entries di changelog

Format baseline-changelog.json:
`json
[
  {
    "timestamp": "2026-07-19 18:00:00",
    "snapshot": "20260719_180000",
    "png_count": 12,
    "message": "Redesign HUD setelah sprint 3 — layout berubah intentional"
  }
]
`

Gunakan ini setelah /baseline set untuk mendokumentasikan MENGAPA baseline berubah.
Tanpa log ini, perubahan baseline tidak bisa dibedakan dari regresi yang tidak disadari.

### /baseline status
Tampilkan status baseline saat ini.

Langkah:
1. Baca ShotsDir dari manifest
2. Cek apakah BaselineDir ada
3. List semua PNG di BaselineDir beserta ukuran dan tanggal
4. Baca `baseline-manifest.json` jika ada — tampilkan `baseline_set_at`
5. Bandingkan jumlah file di baseline vs current ShotsDir
6. Tampilkan jumlah snapshot di history
7. Laporkan apakah baseline sinkron, ketinggalan, atau belum ada

### /baseline reset
Hapus semua file di BaselineDir (tapi bukan folder `history\` dan isinya).
Gunakan jika ingin mulai fresh — misalnya setelah perombakan besar UI.

**WAJIB konfirmasi ke user sebelum eksekusi** — ini operasi destruktif yang tidak bisa di-undo otomatis.
(History tetap aman, tidak ikut dihapus.)

---

## Aturan penting

- Jangan pernah overwrite baseline secara otomatis tanpa perintah eksplisit `/baseline set`
- Baseline hanya berisi PNG screenshot asli — bukan zoom crops dan bukan diff images
- History folder (`baseline\history\`) tidak pernah dihapus oleh `/baseline reset`
- Prune history otomatis hanya terjadi saat `/baseline set` — maksimum 5 snapshot disimpan
- ShotsDir selalu dibaca dari manifest — jangan hardcode path
- Setelah `/baseline set`, selalu konfirmasi: berapa file tersalin + berapa snapshot di history sekarang

## Argumen

$ARGUMENTS
